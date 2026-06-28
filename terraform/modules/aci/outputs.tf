output "container_group_id" {
  description = "Full Azure resource ID of the container group. Used in Jenkins Stage 4 az CLI commands: `az container delete --ids <id>` to remove the previous run before starting a new one."
  value       = azurerm_container_group.migration.id
}

output "container_group_name" {
  description = "Short name of the container group (e.g. \"aci-migrate-<prefix>-<suffix>\"). Used in Jenkins Stage 4 az CLI commands: `az container create --name <name>`, `az container wait --name <name>`, `az container show --name <name>`."
  value       = azurerm_container_group.migration.name
}

output "resource_group_name" {
  description = "Resource group the container group lives in. Passed alongside container_group_name to every az container command in Jenkins Stage 4 (az container commands require both --name and --resource-group)."
  value       = azurerm_container_group.migration.resource_group_name
}

# Terraform concept: ACI container group state transitions:
#   Pending → Running → Succeeded | Failed  (with restart_policy="Never")
# `ip_address` is populated once the group reaches Running state.
# The migration runner does not accept inbound connections, but the IP
# is useful for debugging (checking outbound NAT in network logs).
output "ip_address" {
  description = "Public IP address assigned to the container group. The migration runner makes no inbound connections so this IP is for diagnostics only (e.g. confirming outbound traffic to PostgreSQL via network flow logs)."
  value       = azurerm_container_group.migration.ip_address
}
