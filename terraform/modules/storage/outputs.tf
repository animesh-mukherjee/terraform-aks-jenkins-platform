# Terraform concept: `output` values are how a module exposes data to whatever
# called it (the root module), and to you via `terraform output`. They are the
# module's public "return values".
#
# None of these outputs are marked `sensitive = true` because none of them are
# secrets — they are resource names/IDs, safe to show in plan/apply output and
# `terraform output`. Later modules (e.g. keyvault) DO mark outputs sensitive
# when they expose passwords or connection strings.

output "state_storage_account_name" {
  description = "Name of the storage account used as the Terraform remote-state backend. Read by bootstrap.sh (via `terraform output -raw`) to configure the azurerm backend during state migration."
  value       = azurerm_storage_account.state.name
}

output "state_storage_account_id" {
  description = "Resource ID of the state storage account."
  value       = azurerm_storage_account.state.id
}

output "state_container_name" {
  description = "Name of the blob container holding the Terraform state file. Read by bootstrap.sh to configure the azurerm backend."
  value       = azurerm_storage_container.tfstate.name
}
