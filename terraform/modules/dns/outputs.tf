output "zone_id" {
  description = "Full Azure resource ID of the private DNS zone. Used by downstream modules (e.g. terraform/k8s-post/) that create DNS A records for Jenkins and the NGINX ingress controller after their LoadBalancer IPs are known."
  value       = azurerm_private_dns_zone.this.id
}

output "zone_name" {
  description = "Name of the private DNS zone (e.g. \"platform.internal\"). Used when constructing FQDN values for DNS A record resources and in the CoreDNS ConfigMap patch applied in terraform/k8s-post/."
  value       = azurerm_private_dns_zone.this.name
}

# Terraform concept: when a resource uses `count`, its outputs are lists.
# `length(...) > 0 ? ...[0].id : null` safely handles the case where count = 0
# (no VNet link created) without triggering an "index out of range" error.
# The null value is valid in Terraform outputs and downstream modules can
# check for it with `var.vnet_link_id != null`.
output "vnet_link_id" {
  description = "Full resource ID of the VNet link, or null if aks_vnet_id was not provided. Used to declare an explicit depends_on in terraform/k8s-post/ so DNS A records are only created after the link is established."
  value       = length(azurerm_private_dns_zone_virtual_network_link.aks) > 0 ? azurerm_private_dns_zone_virtual_network_link.aks[0].id : null
}
