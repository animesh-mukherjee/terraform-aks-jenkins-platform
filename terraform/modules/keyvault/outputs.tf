output "key_vault_id" {
  description = "Full resource ID of the Key Vault. Passed to terraform/k8s-post/ so it can read secrets back out using azurerm_key_vault_secret data sources to populate Kubernetes secrets."
  value       = azurerm_key_vault.this.id
}

output "key_vault_name" {
  description = "Short name of the Key Vault (e.g. \"kv<prefix><suffix>\"). Used in docs, runbooks, and the bootstrap destroy script."
  value       = azurerm_key_vault.this.name
}

output "vault_uri" {
  description = "HTTPS URI of the Key Vault (e.g. \"https://kv<prefix><suffix>.vault.azure.net/\"). Used by any application that talks directly to the Key Vault REST API."
  value       = azurerm_key_vault.this.vault_uri
}

# Secret IDs are versioned URIs — useful when you need to pin a resource to a specific secret version.
output "jenkins_admin_password_secret_id" {
  description = "Versioned Key Vault secret URI for jenkins-admin-password. Used as a reference when wiring the secret into the AKS workload identity or K8s secret in k8s-post/."
  value       = azurerm_key_vault_secret.jenkins_admin_password.id
  sensitive   = true
}

output "acr_username_secret_id" {
  description = "Versioned Key Vault secret URI for acr-username."
  value       = azurerm_key_vault_secret.acr_username.id
  sensitive   = true
}

output "acr_password_secret_id" {
  description = "Versioned Key Vault secret URI for acr-password."
  value       = azurerm_key_vault_secret.acr_password.id
  sensitive   = true
}

output "postgresql_password_secret_id" {
  description = "Versioned Key Vault secret URI for postgresql-password."
  value       = azurerm_key_vault_secret.postgresql_password.id
  sensitive   = true
}
