# Terraform concept: AKS outputs split into two categories:
#   - Identification outputs (cluster_id, cluster_name, node_resource_group)
#     — safe to display, used in CLI commands and downstream module references.
#   - Credential outputs (kube_config_raw, host, client_certificate,
#     client_key, cluster_ca_certificate) — marked sensitive = true so they
#     are suppressed in plan/apply terminal output. These are passed directly
#     to the kubernetes/helm providers in terraform/k8s-post/ and never logged.

output "cluster_id" {
  description = "Full Azure resource ID of the AKS cluster (e.g. /subscriptions/.../resourceGroups/.../providers/Microsoft.ContainerService/managedClusters/...). Passed to any downstream module that references the cluster as a dependency."
  value       = azurerm_kubernetes_cluster.this.id
}

output "cluster_name" {
  description = "Short name of the AKS cluster (e.g. \"aks-<prefix>-<suffix>\"). Use with `az aks get-credentials --name <cluster_name>` to populate ~/.kube/config after apply."
  value       = azurerm_kubernetes_cluster.this.name
}

output "node_resource_group" {
  description = "Name of the auto-generated MC_ resource group where AKS places node VMs, managed disks, NICs, and the Standard Load Balancer. Read-only — do not create resources here manually; AKS owns this group."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

# Terraform concept: `kube_config_raw` is the full kubeconfig YAML as a
# string. It contains the cluster CA certificate, a client certificate, and
# a client private key — everything kubectl needs to authenticate.
# Treat this like a password: it grants cluster-admin access.
output "kube_config_raw" {
  description = "Raw kubeconfig YAML for this cluster. Write to ~/.kube/config or pipe to `kubectl --kubeconfig` to run commands. Sensitive — contains cluster CA and client credentials."
  value       = azurerm_kubernetes_cluster.this.kube_config_raw
  sensitive   = true
}

# Terraform concept: kube_config is also exposed as a structured list so
# individual fields can be referenced without parsing YAML. Index [0] is
# always present (single-cluster kubeconfig). Used by the kubernetes and helm
# Terraform providers in terraform/k8s-post/.
output "host" {
  description = "HTTPS URL of the Kubernetes API server. Passed to the kubernetes/helm provider `host` argument in terraform/k8s-post/. Sensitive — reveals the cluster endpoint."
  value       = azurerm_kubernetes_cluster.this.kube_config[0].host
  sensitive   = true
}

output "client_certificate" {
  description = "Base64-encoded client TLS certificate. Used with client_key for certificate-based authentication to the API server. Sensitive."
  value       = azurerm_kubernetes_cluster.this.kube_config[0].client_certificate
  sensitive   = true
}

output "client_key" {
  description = "Base64-encoded client TLS private key. Paired with client_certificate for API server auth. Sensitive — equivalent to a cluster password."
  value       = azurerm_kubernetes_cluster.this.kube_config[0].client_key
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate used to verify the AKS API server's TLS certificate. Prevents man-in-the-middle attacks between Terraform (or kubectl) and the control plane. Sensitive."
  value       = azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate
  sensitive   = true
}

# Terraform concept: AKS creates two Managed Identities automatically when
# identity.type = "SystemAssigned":
#   1. Control-plane MSI — used by the AKS control plane to manage Azure
#      resources (load balancers, NICs) in the MC_ resource group.
#   2. Kubelet MSI — used by worker nodes (the kubelet process) for
#      node-level operations such as pulling images or reading Key Vault.
#
# The kubelet identity is the one most often referenced downstream (e.g. to
# assign Key Vault access or ACR roles). Both IDs are exposed here.
output "kubelet_identity_object_id" {
  description = "Object ID of the AKS kubelet Managed Identity (the per-node MSI used by worker nodes). Reference this if you later assign Azure RBAC roles (e.g. AcrPull, Key Vault Secrets User) to the node identity."
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "kubelet_identity_client_id" {
  description = "Client ID (app ID) of the kubelet Managed Identity. Used in pod annotations when configuring Azure Workload Identity federation for pod-level MSI access."
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].client_id
}
