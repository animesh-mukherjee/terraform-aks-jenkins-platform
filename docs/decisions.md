# Architectural Decision Records

Each ADR documents a decision forced by KodeKloud Playground constraints.
Every record includes the production alternative so these constraints are
easy to lift when moving to a real Azure environment.

---

## ADR-001: Reference the KK resource group instead of creating one

**Context**  
Every Azure resource must live in a resource group. Normally Terraform creates
one with `azurerm_resource_group`.

**Decision**  
Use `data "azurerm_resource_group"` to reference the KK-provided group.
The name is passed in via `var.resource_group_name`.

**Consequences**  
Terraform cannot manage the resource group lifecycle. `terraform destroy`
does not delete it. The KK session expiry handles cleanup.

**PROD alternative**  
Add `resource "azurerm_resource_group" "main"` and reference it with
`azurerm_resource_group.main.name` throughout all modules.

---

## ADR-002: No Azure IAM role assignments → Kubernetes-native RBAC

**Context**  
The platform needs access control for Jenkins users and for AKS workload
identities (e.g., AcrPull for the kubelet identity).

**Decision**  
KK blocks `azurerm_role_assignment`. Replaced entirely with:
- **Jenkins users** → Matrix Authorization Strategy via JCasC (`security.yaml`)
- **K8s workloads** → ClusterRole + RoleBinding via `k8s/rbac/`
- **ACR image pull** → `admin_enabled = true` on ACR + `dockerconfigjson` K8s Secret

**Consequences**  
ACR admin credentials are long-lived and cannot be scoped to read-only.
The `jenkins-sa` ClusterRoleBinding grants cluster-wide pod permissions.

**PROD alternative**  
Enable Workload Identity and Federated Credentials. Assign `AcrPull` to the
kubelet managed identity (pods pull images automatically). Assign `AcrPush`
to the CI managed identity for builds. Remove `admin_enabled = true`.

---

## ADR-003: No Entra App Registrations → JCasC local security realm

**Context**  
Standard Jenkins SSO on Azure uses the Azure Active Directory plugin with an
Entra App Registration.

**Decision**  
KK blocks App Registration creation. Using the Jenkins built-in local security
realm with three accounts (admin, developer, viewer) in `jenkins/casc/users.yaml`.
Admin password is injected from a K8s Secret; developer/viewer passwords are
hardcoded in JCasC.

**Consequences**  
No SSO. If the repo is public, the developer and viewer passwords are visible.
Change them before sharing repo access.

**PROD alternative**  
Replace `securityRealm.local` with the `azure-ad` JCasC plugin block. Create
an Entra App Registration, configure redirect URIs, and map Entra groups to
Jenkins roles in the matrix strategy.

---

## ADR-004: No AKS CSI Secret Store addon → Terraform-managed K8s Secrets

**Context**  
The standard pattern for feeding Azure Key Vault secrets into pods is the CSI
Secret Store driver, enabled as an AKS add-on.

**Decision**  
KK blocks AKS add-on installation. Instead, `terraform/k8s-post/main.tf` reads
secrets from Key Vault with `data "azurerm_key_vault_secret"` and writes them
as standard `kubernetes_secret` resources. Pods consume them via `envFrom`.

**Consequences**  
Secrets live in Kubernetes etcd. Secret values appear in Terraform state.
Rotation requires `terraform apply`.

**PROD alternative**  
Enable the CSI Secret Store add-on:
```hcl
key_vault_secrets_provider {
  secret_rotation_enabled = true
}
```
Use `SecretProviderClass` objects to mount secrets directly from Key Vault
without etcd and without touching Terraform state.

---

## ADR-005: ACR admin credentials for image pull → imagePullSecret

**Context**  
The standard approach for AKS pulling from ACR is assigning the `AcrPull`
role to the kubelet managed identity — no credentials needed.

**Decision**  
KK blocks role assignments. Using `admin_enabled = true` on the ACR resource
and a `kubernetes.io/dockerconfigjson` Secret (`acr-pull-secret`) in all three
namespaces. Pods reference it via `imagePullSecrets`.

**Consequences**  
ACR admin is a single shared credential; not per-workload. Both the pull secret
and `jenkins-pipeline-creds` contain the same ACR password.

**PROD alternative**  
`admin_enabled = false`. Use managed identity + `AcrPull` role assignment.
AKS nodes pull images using their Azure identity automatically — no secrets.

---

## ADR-006: Single node pool with per-node taint/label via null_resource

**Context**  
The architecture requires Node 1 for the Jenkins controller (tainted to repel
agents) and Node 2 for agent pods (labeled for affinity).

**Decision**  
KK limits AKS to 1 node pool. Node-pool-level taints apply to ALL nodes in
the pool. Per-node taint/label is applied post-provision by
`null_resource.node_placement` in `k8s-post/main.tf` via `az aks command invoke`.

Nodes are sorted by `creationTimestamp`: oldest → Node 1 (controller),
newest → Node 2 (agent). AKS provisions nodes sequentially so this is stable.

**Consequences**  
On node replacement (OS upgrade, spot eviction), the new node gets wrong
placement until the null_resource re-triggers (any cluster change causes this).

**PROD alternative**  
Two separate node pools:
- Pool 1: `node_taints = ["dedicated=controller:NoSchedule"]` (count = 1)
- Pool 2: `node_labels = { dedicated = "agent" }` (count = N, autoscaling)

Node pools handle placement declaratively and survive node replacement.

---

## ADR-007: Docker-in-Docker (DinD) for image builds

**Context**  
Jenkins Stage 3 needs `docker build` and `docker push`. AKS uses containerd,
so there is no `/var/run/docker.sock` on the host.

**Decision**  
The `nodejs-agent` pod template (JCasC `clouds.yaml`) runs a `docker:dind`
sidecar with `privileged: true`. The main container connects via
`DOCKER_HOST=tcp://localhost:2375`. `DOCKER_TLS_CERTDIR=""` disables TLS for
the localhost connection.

**Consequences**  
`privileged: true` gives the DinD container full host kernel access — a
significant security risk in production. KK does not enforce Pod Security
Standards, so it works here.

**PROD alternative**  
Replace DinD with [kaniko](https://github.com/GoogleContainerTools/kaniko):
```yaml
image: gcr.io/kaniko-project/executor
args: ["--dockerfile=Dockerfile", "--context=dir://app-sample", "--destination=<acr>.azurecr.io/app:<tag>"]
```
Kaniko builds without a daemon, without root, and without privileged mode.

---

## ADR-008: ClusterRoleBinding for jenkins-sa (not RoleBinding)

**Context**  
The Jenkins Kubernetes plugin needs to create, exec into, and delete agent pods
in the `jenkins` namespace. The `jenkins-sa` ServiceAccount requires pod
permissions.

**Decision**  
A `ClusterRole` is bound via `ClusterRoleBinding`, giving `jenkins-sa` pod
permissions across ALL namespaces.

**Consequences**  
A compromised build running as `jenkins-sa` could create, exec into, or delete
pods in any namespace, including `kube-system`.

**PROD alternative**  
Replace the `ClusterRoleBinding` with a `RoleBinding` scoped to the `jenkins`
namespace. The `ClusterRole` definition remains; only the binding type changes.
If agents need to deploy to `dev`/`staging`, add separate RoleBindings there.

---

## ADR-009: Partial backend configuration (no hardcoded storage account name)

**Context**  
Terraform requires a backend configuration for remote state. The storage account
name has a random suffix (from `random_string`) that isn't known before the first
`terraform apply`.

**Decision**  
`terraform/backend.tf` hardcodes only the static values (`container_name`, `key`).
The dynamic values (`resource_group_name`, `storage_account_name`) are passed via
`-backend-config` flags at `terraform init` time — in `bootstrap.sh` and both
GitHub Actions workflows.

**Consequences**  
`terraform init` always needs the `-backend-config` flags. A plain `terraform init`
fails. This is documented in all places that call init.

**PROD alternative**  
Use a pre-existing storage account with a stable, known name — provisioned
separately by a platform team. Hardcode all four backend values in `backend.tf`.

---

## ADR-010: Separate Terraform root for k8s-post/

**Context**  
Kubernetes resources (K8s Secrets, node taints) depend on the AKS cluster
existing AND on values from other Azure modules (Key Vault secrets, ACR
login server). They also need the cluster's kubeconfig.

**Decision**  
`terraform/k8s-post/` is a separate Terraform root that reads root outputs via
`data "terraform_remote_state"`. The kubernetes provider uses `config_path =
"~/.kube/config"` written by `az aks get-credentials` in `bootstrap.sh`.

**Consequences**  
The kubeconfig must be written by bootstrap before `k8s-post apply`. The
provider block cannot use `data` source values (evaluated at plan time, before
data sources). Two `terraform apply` runs are required per session.

**PROD alternative**  
Single Terraform root with the kubernetes provider configured directly from AKS
outputs (`host`, `client_certificate`, `client_key`, `cluster_ca_certificate`).
Eliminates the two-root split but creates a provider dependency order constraint.

---

## ADR-011: ACI one-shot pattern with lifecycle ignore_changes

**Context**  
Jenkins Stage 4 runs a DB migration container using the image built in Stage 3
(with a commit SHA tag). Terraform provisions the ACI shape; Jenkins manages
each run's image.

**Decision**  
`azurerm_container_group.migration` is provisioned with a placeholder image
(`alpine:3.19`) and `lifecycle { ignore_changes = [container[0].image] }`.
Jenkins replaces the image at build time via `az container create --image
<acr>/<migration-image>:<sha>`. Terraform ignores the image field on subsequent
applies.

**Consequences**  
`terraform state` shows the placeholder image. `terraform plan` always shows
"no changes" for the image field. The actual running image is only visible via
`az container show`.

**PROD alternative**  
Use Azure Container Apps Jobs or a Kubernetes Job for migrations. Both support
managed identity, retry policies, and direct ACR integration — no placeholder
image, no state drift.
