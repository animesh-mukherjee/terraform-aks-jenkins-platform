# Terraform concept: `default_primary_connection_string` is the connection
# string for the namespace's built-in `RootManageSharedAccessKey` SAS policy,
# which grants Manage + Send + Listen permissions on ALL entities in the
# namespace. It is marked sensitive because anyone with this string can
# read from AND write to every queue in the namespace.
#
# PROD: create dedicated `azurerm_servicebus_namespace_authorization_rule`
# resources with only the Send permission for Jenkins (producer) and only
# the Listen permission for consumers — principle of least privilege.

output "namespace_id" {
  description = "Full Azure resource ID of the Service Bus namespace. Used by downstream resources (e.g. Private Endpoint, RBAC role assignments) that need an explicit reference."
  value       = azurerm_servicebus_namespace.this.id
}

output "namespace_name" {
  description = "Short name of the Service Bus namespace (e.g. \"sb-<prefix>-<suffix>\"). Used in Azure Portal navigation and `az servicebus` CLI commands."
  value       = azurerm_servicebus_namespace.this.name
}

output "primary_connection_string" {
  description = "Connection string for the namespace's RootManageSharedAccessKey SAS policy (Manage + Send + Listen). Used by Jenkins Stage 7 to publish build/deploy events. Sensitive — grants full access to all queues in this namespace."
  value       = azurerm_servicebus_namespace.this.default_primary_connection_string
  sensitive   = true
}

output "build_queue_name" {
  description = "Name of the queue that receives build-completion events (\"build-events\"). Referenced in Jenkins JCasC credentials and Jenkinsfile Stage 7 to target the correct queue."
  value       = azurerm_servicebus_queue.build_events.name
}

output "deploy_queue_name" {
  description = "Name of the queue that receives deploy-completion events (\"deploy-events\"). Referenced in Jenkins JCasC credentials and Jenkinsfile Stage 7 to target the correct queue."
  value       = azurerm_servicebus_queue.deploy_events.name
}

output "build_queue_id" {
  description = "Full Azure resource ID of the build-events queue. Used if an authorization rule scoped to this specific queue (rather than the namespace) is added in a later step."
  value       = azurerm_servicebus_queue.build_events.id
}

output "deploy_queue_id" {
  description = "Full Azure resource ID of the deploy-events queue. Used if an authorization rule scoped to this specific queue is added in a later step."
  value       = azurerm_servicebus_queue.deploy_events.id
}
