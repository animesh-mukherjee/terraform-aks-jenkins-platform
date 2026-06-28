# =============================================================================
# outputs.tf — Root module outputs.
#
# These are the values you need AFTER a successful apply to operate the
# platform. Three categories:
#   1. Reference outputs — safe to display; used in az / kubectl commands
#   2. Credential outputs — sensitive = true; consumed by k8s-post/ and
#      Helm values; never printed to the terminal without -raw / -json
#   3. Pass-through outputs for k8s-post/ — the Kubernetes provider in
#      k8s-post/ reads kube_config via `terraform_remote_state` or env var
# =============================================================================

# ---------------------------------------------------------------------------
# Infrastructure reference outputs
# ---------------------------------------------------------------------------

output "resource_group_name" {
  description = "Name of the KodeKloud-provided resource group used by all resources. Required as --resource-group in every az CLI command."
  value       = var.resource_group_name
}

output "state_storage_account_name" {
  description = "Name of the Terraform remote state storage account (e.g. \"st<prefix><suffix>\"). Used by bootstrap.sh Phase 2 to configure the azurerm backend."
  value       = module.storage.state_storage_account_name
}

output "acr_login_server" {
  description = "ACR FQDN (e.g. \"acr<prefix><suffix>.azurecr.io\"). Use as the image prefix in Docker push/pull commands and in Jenkinsfiles."
  value       = module.acr.login_server
}

output "acr_name" {
  description = "Short ACR resource name. Used with `az acr login --name <acr_name>` to authenticate the Docker daemon."
  value       = module.acr.registry_name
}

output "keyvault_name" {
  description = "Key Vault name (e.g. \"kv<prefix><suffix>\"). Used with `az keyvault secret show --vault-name <name>` to inspect secrets and in Jenkins JCasC credential bindings."
  value       = module.keyvault.key_vault_name
}

output "log_analytics_workspace_name" {
  description = "Log Analytics Workspace name. Used with `az monitor log-analytics query --workspace <name>` to run KQL queries against container logs."
  value       = module.loganalytics.workspace_name
}

output "log_analytics_workspace_id" {
  description = "Log Analytics Workspace resource ID. Used as the workspace parameter in KQL queries and in monitoring dashboards."
  value       = module.loganalytics.workspace_id
}

output "aks_cluster_name" {
  description = "AKS cluster name (e.g. \"aks-<prefix>-<suffix>\"). Run `az aks get-credentials --resource-group <rg> --name <aks_cluster_name>` to populate ~/.kube/config after apply."
  value       = module.aks.cluster_name
}

output "aks_node_resource_group" {
  description = "Auto-generated MC_ resource group that AKS uses for node VMs, disks, and the Standard Load Balancer. Read-only — do not create resources here manually."
  value       = module.aks.node_resource_group
}

output "postgresql_server_name" {
  description = "PostgreSQL server name (e.g. \"psql-<prefix>-<suffix>\"). Used with `az postgres flexible-server connect --name <name>` for ad-hoc queries."
  value       = module.postgresql.server_name
}

output "postgresql_database_name" {
  description = "Application database name inside the PostgreSQL server (default: \"appdb\"). Passed to Helm chart values and K8s secrets in k8s-post/."
  value       = module.postgresql.database_name
}

output "servicebus_namespace_name" {
  description = "Service Bus namespace name. Used with `az servicebus queue list --namespace-name <name>` and in Jenkins JCasC credentials."
  value       = module.servicebus.namespace_name
}

output "servicebus_build_queue" {
  description = "Name of the Service Bus queue for build-completion events (\"build-events\"). Referenced in Jenkinsfile Stage 7."
  value       = module.servicebus.build_queue_name
}

output "servicebus_deploy_queue" {
  description = "Name of the Service Bus queue for deploy-completion events (\"deploy-events\"). Referenced in Jenkinsfile Stage 7."
  value       = module.servicebus.deploy_queue_name
}

output "appconfig_store_name" {
  description = "App Configuration store name. Used with `az appconfig kv list --name <name>` and `az appconfig feature list --name <name>`."
  value       = module.appconfig.store_name
}

output "appconfig_endpoint" {
  description = "App Configuration HTTPS endpoint (e.g. \"https://appcfg-<prefix>-<suffix>.azconfig.io\"). Used by the sample app SDK in Workload Identity mode."
  value       = module.appconfig.endpoint
}

output "dns_zone_name" {
  description = "Name of the private DNS zone (\"platform.internal\"). Used when creating DNS A records in k8s-post/ and when patching the CoreDNS ConfigMap."
  value       = module.dns.zone_name
}

output "aci_container_group_name" {
  description = "ACI container group name. Used in Jenkins Stage 4: `az container delete --name <name>` and `az container create --name <name>`."
  value       = module.aci.container_group_name
}

output "aci_resource_group_name" {
  description = "Resource group of the ACI container group (same as var.resource_group_name). Included as a named output so Jenkins Stage 4 can use `terraform output -raw aci_resource_group_name` without hardcoding the RG."
  value       = module.aci.resource_group_name
}

# ---------------------------------------------------------------------------
# Credential outputs — sensitive = true
# ---------------------------------------------------------------------------

output "jenkins_admin_password" {
  description = "Auto-generated Jenkins admin password. Used for the first login to the Jenkins UI and in JCasC bootstrap. Retrieve with: terraform output -raw jenkins_admin_password"
  value       = random_password.jenkins_admin.result
  sensitive   = true
}

output "postgresql_connection_string" {
  description = "Full libpq-compatible connection URI for the application database (postgresql://user:pass@host:5432/db?sslmode=require). Passed to k8s-post/ to build the app DB K8s Secret."
  value       = module.postgresql.connection_string
  sensitive   = true
}

output "appconfig_read_connection_string" {
  description = "Read-only connection string for the App Configuration store. Injected into the sample app's K8s Secret so it can pull feature flags and config at startup."
  value       = module.appconfig.primary_read_connection_string
  sensitive   = true
}

output "servicebus_connection_string" {
  description = "Service Bus namespace connection string (RootManageSharedAccessKey — Send + Listen + Manage). Stored as a Jenkins credential for Jenkinsfile Stage 7."
  value       = module.servicebus.primary_connection_string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# AKS credential outputs — consumed by terraform/k8s-post/ provider config
# ---------------------------------------------------------------------------

# Terraform concept: these AKS credential outputs are marked sensitive so
# they are masked in `terraform output` by default. k8s-post/ reads them
# via `data "terraform_remote_state"` to configure its kubernetes/helm
# providers without re-running AKS provisioning.

output "kube_config_raw" {
  description = "Raw kubeconfig YAML. Write to ~/.kube/config or set KUBECONFIG to connect kubectl and helm. Also consumed by terraform/k8s-post/ via terraform_remote_state."
  value       = module.aks.kube_config_raw
  sensitive   = true
}

output "aks_host" {
  description = "AKS API server HTTPS endpoint. Used as the `host` argument in the kubernetes/helm provider blocks in terraform/k8s-post/."
  value       = module.aks.host
  sensitive   = true
}

output "aks_client_certificate" {
  description = "Base64-encoded client TLS certificate for AKS API server auth. Used in terraform/k8s-post/ kubernetes provider."
  value       = module.aks.client_certificate
  sensitive   = true
}

output "aks_client_key" {
  description = "Base64-encoded client TLS private key. Used in terraform/k8s-post/ kubernetes provider."
  value       = module.aks.client_key
  sensitive   = true
}

output "aks_cluster_ca_certificate" {
  description = "Base64-encoded AKS cluster CA certificate. Used in terraform/k8s-post/ kubernetes provider."
  value       = module.aks.cluster_ca_certificate
  sensitive   = true
}
