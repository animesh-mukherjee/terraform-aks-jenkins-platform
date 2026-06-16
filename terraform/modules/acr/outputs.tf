# Terraform concept: outputs that expose secrets MUST be marked `sensitive = true`.
# This suppresses the value in `terraform plan` / `terraform apply` terminal output
# and in `terraform output` (unless you add -raw or -json explicitly).
# The value is still stored in state, so encrypt your state backend.
# Non-secret outputs below are NOT marked sensitive — they are safe to display.

output "registry_name" {
  description = "Short name of the Azure Container Registry (e.g. \"acr<prefix><suffix>\"). Used by Jenkins JCasC to reference the registry in build pipelines and by module.keyvault to store the admin credentials."
  value       = azurerm_container_registry.this.name
}

output "registry_id" {
  description = "Full resource ID of the Azure Container Registry. Used by dependent resources that need an explicit reference to this registry."
  value       = azurerm_container_registry.this.id
}

output "login_server" {
  description = "Fully-qualified login server hostname (e.g. \"acr<prefix><suffix>.azurecr.io\"). Used as the image repository prefix in Jenkinsfiles (docker push), Helm chart values, and the AKS imagePullSecret."
  value       = azurerm_container_registry.this.login_server
}

output "admin_username" {
  description = "Admin username for the registry. Passed to module.keyvault to store as the \"acr-username\" secret, then referenced when creating the AKS imagePullSecret in terraform/k8s-post/."
  value       = azurerm_container_registry.this.admin_username
}

output "admin_password" {
  description = "Admin password for the registry. Passed to module.keyvault to store as the \"acr-password\" secret. Marked sensitive — never appears in plan/apply output or unguarded `terraform output`."
  sensitive   = true
  value       = azurerm_container_registry.this.admin_password
}
