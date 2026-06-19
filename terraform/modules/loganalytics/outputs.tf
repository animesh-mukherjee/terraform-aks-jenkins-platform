# Terraform concept: outputs that expose secrets MUST be marked `sensitive = true`.
# This suppresses the value in `terraform plan` / `terraform apply` terminal output
# and in `terraform output` (unless you add -raw or -json explicitly).
# The value is still stored in state, so encrypt your state backend.
# Non-secret outputs below are NOT marked sensitive — they are safe to display.

output "workspace_id" {
  description = "Full resource ID of the Log Analytics Workspace. Passed to module.aks as `log_analytics_workspace_id` in the `oms_agent` add-on block so Container Insights ships logs/metrics here."
  value       = azurerm_log_analytics_workspace.this.id
}

output "workspace_name" {
  description = "Short name of the workspace (e.g. \"log-<prefix>-<suffix>\"). Used in docs, runbooks, and `az monitor log-analytics` CLI commands."
  value       = azurerm_log_analytics_workspace.this.name
}

output "workspace_customer_id" {
  description = "The workspace's GUID (Customer ID / Workspace ID in Azure terminology), distinct from the resource ID. Used by any agent or SDK that authenticates directly against the Log Analytics Data Collector API."
  value       = azurerm_log_analytics_workspace.this.workspace_id
}

output "primary_shared_key" {
  description = "Primary shared key for the workspace. Used by legacy agents (e.g. the OMS/MMA agent) that authenticate via workspace ID + key rather than AKS's managed Container Insights add-on. Marked sensitive — never appears in plan/apply terminal output."
  value       = azurerm_log_analytics_workspace.this.primary_shared_key
  sensitive   = true
}
