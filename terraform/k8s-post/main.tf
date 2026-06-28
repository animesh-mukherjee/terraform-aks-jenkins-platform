# =============================================================================
# k8s-post/main.tf
#
# Creates all Kubernetes resources that depend on values from the main
# Terraform root (secrets, configmaps, imagePullSecrets) plus two
# null_resource blocks that use `az aks command invoke` to:
#   1. Apply per-node taint (Node 1) and label (Node 2)
#   2. Restart CoreDNS to pick up the platform.internal forwarding rule
#
# Resources created here (static RBAC manifests are in k8s/rbac/ — Step 14):
#   - Namespaces: jenkins, dev, staging
#   - CoreDNS custom ConfigMap (forward platform.internal → Azure DNS)
#   - CoreDNS rolling restart trigger
#   - imagePullSecret (ACR) in all three namespaces
#   - K8s Secret: jenkins-admin-credentials (jenkins ns)
#   - K8s Secret: app-db-credentials (dev + staging ns)
#   - K8s Secret: app-config-credentials (dev + staging ns)
#   - K8s Secret: service-bus-credentials (jenkins ns)
#   - Node 1 taint: dedicated=controller:NoSchedule
#   - Node 2 label: dedicated=agent
# =============================================================================

# ---------------------------------------------------------------------------
# Read root module outputs via terraform_remote_state
# ---------------------------------------------------------------------------

# Terraform concept: `data "terraform_remote_state"` reads the OUTPUT values
# of ANOTHER Terraform root whose state is stored in the same (or a different)
# backend. This is how two separate Terraform roots share data without one
# calling the other as a module.
#
# The `config` block mirrors the backend config of the root module
# (terraform/backend.tf), pointing at the SAME storage account and container
# but with key = "platform.tfstate" (the root module's state file).
data "terraform_remote_state" "root" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.resource_group_name
    storage_account_name = var.storage_account_name
    container_name       = "tfstate"
    key                  = "platform.tfstate"
  }
}

# ---------------------------------------------------------------------------
# Read ACR credentials from Key Vault
# ---------------------------------------------------------------------------

# Terraform concept: `data "azurerm_key_vault_secret"` reads a secret VALUE
# from an existing Key Vault. This is the recommended pattern for retrieving
# secrets in Terraform rather than storing them in root outputs — the secret
# value is marked sensitive automatically, never printed in plan output, and
# the request is audited in Key Vault's diagnostic logs.
data "azurerm_key_vault" "main" {
  name                = data.terraform_remote_state.root.outputs.keyvault_name
  resource_group_name = var.resource_group_name
}

data "azurerm_key_vault_secret" "acr_username" {
  name         = "acr-username"
  key_vault_id = data.azurerm_key_vault.main.id
}

data "azurerm_key_vault_secret" "acr_password" {
  name         = "acr-password"
  key_vault_id = data.azurerm_key_vault.main.id
}

# ---------------------------------------------------------------------------
# Local values — convenience aliases for root state outputs
# ---------------------------------------------------------------------------

locals {
  cluster_name        = data.terraform_remote_state.root.outputs.aks_cluster_name
  rg_name             = data.terraform_remote_state.root.outputs.resource_group_name
  acr_login_server    = data.terraform_remote_state.root.outputs.acr_login_server
  acr_username        = data.azurerm_key_vault_secret.acr_username.value
  acr_password        = data.azurerm_key_vault_secret.acr_password.value
  dns_zone_name       = data.terraform_remote_state.root.outputs.dns_zone_name

  # Sensitive values — only used inside kubernetes_secret data blocks
  jenkins_admin_password   = data.terraform_remote_state.root.outputs.jenkins_admin_password
  postgresql_conn_string   = data.terraform_remote_state.root.outputs.postgresql_connection_string
  postgresql_server_fqdn   = data.terraform_remote_state.root.outputs.postgresql_server_fqdn
  postgresql_db_name       = data.terraform_remote_state.root.outputs.postgresql_database_name
  postgresql_admin_login   = data.terraform_remote_state.root.outputs.postgresql_admin_login
  appconfig_conn_string    = data.terraform_remote_state.root.outputs.appconfig_read_connection_string
  servicebus_conn_string   = data.terraform_remote_state.root.outputs.servicebus_connection_string
  servicebus_build_queue   = data.terraform_remote_state.root.outputs.servicebus_build_queue
  servicebus_deploy_queue  = data.terraform_remote_state.root.outputs.servicebus_deploy_queue
}

# ---------------------------------------------------------------------------
# Namespaces
# ---------------------------------------------------------------------------

# Terraform concept: `kubernetes_namespace` creates a K8s Namespace — the
# primary isolation boundary for workloads. RBAC roles, ResourceQuotas, and
# NetworkPolicies are all scoped to a namespace. Three namespaces are used:
#   jenkins  — Jenkins controller pod and agent pods
#   dev      — sample app deployed by Jenkins on every PR merge
#   staging  — sample app promoted here after manual approval gate (Stage 8)
resource "kubernetes_namespace" "jenkins" {
  metadata {
    name = "jenkins"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubernetes_namespace" "dev" {
  metadata {
    name = "dev"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = "dev"
    }
  }
}

resource "kubernetes_namespace" "staging" {
  metadata {
    name = "staging"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = "staging"
    }
  }
}

# ---------------------------------------------------------------------------
# CoreDNS custom ConfigMap
# ---------------------------------------------------------------------------

# Terraform concept: `kubernetes_config_map` creates a K8s ConfigMap — a
# key-value store for non-sensitive configuration consumed by pods as env
# vars or mounted files.
#
# AKS CoreDNS reads the `coredns-custom` ConfigMap in kube-system and
# merges it into the main Corefile at reload time. Any key whose name ends
# in `.server` is treated as an additional server stanza; `.override`
# patches an existing zone.
#
# The stanza below adds a forwarding server for `platform.internal:53`.
# When a pod queries `jenkins.platform.internal`, CoreDNS forwards the
# request to 168.63.129.16 — Azure's magic internal resolver IP that answers
# queries from the Private DNS Zone linked to the AKS VNet (module.dns).
# Without this stanza, CoreDNS would try to resolve `platform.internal`
# via public DNS and fail (it's a private-use TLD with no public records).
resource "kubernetes_config_map" "coredns_custom" {
  metadata {
    name      = "coredns-custom"
    namespace = "kube-system"
  }

  data = {
    "platform.internal.server" = <<-EOT
      ${local.dns_zone_name}:53 {
          errors
          cache 30
          forward . 168.63.129.16
      }
    EOT
  }

  depends_on = [
    kubernetes_namespace.jenkins,
    data.terraform_remote_state.root,
  ]
}

# Restart CoreDNS so it picks up the new custom ConfigMap immediately.
# AKS CoreDNS does watch the ConfigMap and reloads via the `reload` plugin,
# but the watch interval can be up to 2 minutes. A rolling restart ensures
# the new forwarding rule is active before Helm deploys Jenkins (Step 15).
resource "null_resource" "coredns_restart" {
  triggers = {
    # Re-run whenever the ConfigMap content changes.
    coredns_config_hash = sha256(kubernetes_config_map.coredns_custom.data["platform.internal.server"])
  }

  provisioner "local-exec" {
    # `az aks command invoke` runs a kubectl command inside the cluster
    # without requiring a local kubeconfig. The CLI uses the same Azure
    # credentials already in use (ARM_* env vars). This works on Windows,
    # macOS, and Linux without extra tooling.
    command = <<-EOT
      az aks command invoke \
        --resource-group "${local.rg_name}" \
        --name "${local.cluster_name}" \
        --command "kubectl rollout restart deployment coredns -n kube-system && kubectl rollout status deployment coredns -n kube-system --timeout=120s"
    EOT
  }

  depends_on = [kubernetes_config_map.coredns_custom]
}

# ---------------------------------------------------------------------------
# Node 1 taint + Node 2 label (per-node placement strategy)
# ---------------------------------------------------------------------------

# Applied via az aks command invoke because:
#   1. The kubernetes Terraform provider has no node taint resource.
#   2. Sorting by creationTimestamp is the most reliable way to identify
#      "Node 1" (oldest) vs "Node 2" (newest) in a 2-node pool provisioned
#      sequentially — AKS creates nodes in order.
#
# Node 1 — taint dedicated=controller:NoSchedule
#   Only pods with tolerations: [{key: dedicated, value: controller,
#   effect: NoSchedule}] can schedule here. Jenkins controller and NGINX
#   ingress both carry this toleration in their Helm values (Step 15).
#
# Node 2 — label dedicated=agent
#   Jenkins pod agents use nodeSelector: {dedicated: agent} so they land
#   on Node 2 only, keeping build noise off the controller node.
resource "null_resource" "node_placement" {
  triggers = {
    cluster_name = local.cluster_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      az aks command invoke \
        --resource-group "${local.rg_name}" \
        --name "${local.cluster_name}" \
        --command "
          set -e
          NODES=($(kubectl get nodes --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[*].metadata.name}'))
          CONTROLLER=$${NODES[0]}
          AGENT=$${NODES[1]}
          echo \"Tainting $CONTROLLER as controller (NoSchedule)...\"
          kubectl taint nodes \"$CONTROLLER\" dedicated=controller:NoSchedule --overwrite
          echo \"Labelling $AGENT as agent...\"
          kubectl label nodes \"$AGENT\" dedicated=agent --overwrite
          echo \"Node placement applied.\"
          kubectl get nodes --show-labels
        "
    EOT
  }
}

# ---------------------------------------------------------------------------
# imagePullSecret — ACR credentials for all three namespaces
# ---------------------------------------------------------------------------

# Terraform concept: `for_each` on a set of strings creates one instance of
# the resource per element, each independently tracked in state. This avoids
# copy-pasting three near-identical kubernetes_secret blocks.
# Each instance is referenced as kubernetes_secret.acr_pull["jenkins"] etc.
#
# Type "kubernetes.io/dockerconfigjson" is the standard K8s type for registry
# credentials. The `.dockerconfigjson` key holds a JSON document that Docker
# and containerd understand when pulling private images.
resource "kubernetes_secret" "acr_pull" {
  for_each = toset(["jenkins", "dev", "staging"])

  metadata {
    name      = "acr-pull-secret"
    namespace = each.key
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${local.acr_login_server}" = {
          username = local.acr_username
          password = local.acr_password
          auth     = base64encode("${local.acr_username}:${local.acr_password}")
        }
      }
    })
  }

  depends_on = [
    kubernetes_namespace.jenkins,
    kubernetes_namespace.dev,
    kubernetes_namespace.staging,
  ]
}

# ---------------------------------------------------------------------------
# Jenkins admin credentials secret
# ---------------------------------------------------------------------------

# JCasC (Jenkins Configuration as Code) reads JENKINS_ADMIN_PASSWORD from
# this secret via an envFrom block in the Helm chart values. The variable
# ${JENKINS_ADMIN_PASSWORD} is then referenced in jenkins/casc/users.yaml
# to set the built-in admin account password without hardcoding it.
resource "kubernetes_secret" "jenkins_admin" {
  metadata {
    name      = "jenkins-admin-credentials"
    namespace = "jenkins"
  }

  # `data` values are provided as plaintext strings; the kubernetes provider
  # base64-encodes them when creating the K8s Secret object (standard K8s
  # secret encoding). The values are NOT double-encoded.
  data = {
    jenkins-admin-user     = "admin"
    jenkins-admin-password = local.jenkins_admin_password
  }

  depends_on = [kubernetes_namespace.jenkins]
}

# ---------------------------------------------------------------------------
# App DB credentials secret (dev + staging)
# ---------------------------------------------------------------------------

# The sample app reads database connection details from these env vars:
#   DATABASE_URL  — full libpq URI (used by ORMs like Sequelize, Prisma)
#   DB_HOST       — raw hostname (used by pg module directly)
#   DB_PORT       — 5432 (standard PostgreSQL port)
#   DB_NAME       — database name
#   DB_USER       — admin username
#   DB_PASSWORD   — admin password (extracted from connection string)
# The Helm chart mounts this secret as envFrom in the app Deployment.
resource "kubernetes_secret" "app_db" {
  for_each = toset(["dev", "staging"])

  metadata {
    name      = "app-db-credentials"
    namespace = each.key
  }

  data = {
    DATABASE_URL = local.postgresql_conn_string
    DB_HOST      = local.postgresql_server_fqdn
    DB_PORT      = "5432"
    DB_NAME      = local.postgresql_db_name
    DB_USER      = local.postgresql_admin_login
    # DB_PASSWORD is not stored separately because the full connection string
    # already embeds it. If the app needs it standalone, add it here.
  }

  depends_on = [
    kubernetes_namespace.dev,
    kubernetes_namespace.staging,
  ]
}

# ---------------------------------------------------------------------------
# App Configuration credentials secret (dev + staging)
# ---------------------------------------------------------------------------

# The sample app's App Configuration SDK reads APPCONFIG_CONNECTION_STRING
# at startup to connect to the feature flag / config store. The SDK caches
# values locally and re-fetches in the background when they change.
resource "kubernetes_secret" "app_config" {
  for_each = toset(["dev", "staging"])

  metadata {
    name      = "app-config-credentials"
    namespace = each.key
  }

  data = {
    APPCONFIG_CONNECTION_STRING = local.appconfig_conn_string
  }

  depends_on = [
    kubernetes_namespace.dev,
    kubernetes_namespace.staging,
  ]
}

# ---------------------------------------------------------------------------
# Service Bus credentials secret (jenkins namespace)
# ---------------------------------------------------------------------------

# Jenkins Stage 7 reads SERVICE_BUS_CONNECTION_STRING (from this secret via
# withCredentials in the Jenkinsfile) and uses the az servicebus CLI or the
# Azure Service Bus SDK to publish build/deploy event messages.
resource "kubernetes_secret" "service_bus" {
  metadata {
    name      = "service-bus-credentials"
    namespace = "jenkins"
  }

  data = {
    SERVICE_BUS_CONNECTION_STRING = local.servicebus_conn_string
    BUILD_QUEUE_NAME              = local.servicebus_build_queue
    DEPLOY_QUEUE_NAME             = local.servicebus_deploy_queue
  }

  depends_on = [kubernetes_namespace.jenkins]
}
