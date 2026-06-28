# =============================================================================
# Module: dns
#
# Purpose: Creates the Azure Private DNS Zone "platform.internal" and
#          optionally links it to the AKS VNet so names like
#          jenkins.platform.internal resolve from within the cluster.
#
# How internal resolution works end-to-end:
#   1. This module creates the zone and a VNet link so Azure DNS answers
#      "platform.internal" queries from nodes in that VNet.
#   2. terraform/k8s-post/ patches CoreDNS with a forward block:
#        platform.internal → 168.63.129.16 (Azure's magic resolver IP)
#      so pods inside the cluster can resolve "platform.internal" names too.
#   3. DNS A records (e.g. jenkins.platform.internal) are NOT created here
#      because their IPs (LoadBalancer ingress IPs) are unknown at plan time.
#      They are added in terraform/k8s-post/ after Helm deploys Jenkins
#      and the NGINX ingress controller gets its external IP.
#
# VNet link is conditional: pass a non-empty aks_vnet_id to activate it.
# On KodeKloud, AKS (kubenet) creates its own VNet in the MC_ resource group.
# The root module looks it up with data "azurerm_resources" after AKS is ready
# and passes the ID here.
# =============================================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# KK constraint: resource groups cannot be created — read the session-provided
# one so we can reference its name below.
# PROD: replace with resource "azurerm_resource_group" and a depends_on.
data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

# Terraform concept: `azurerm_private_dns_zone` is a GLOBAL Azure resource —
# unlike almost every other Azure resource, it has NO `location` attribute.
# Private DNS zones are not tied to a region; they replicate across Azure
# globally. The zone only answers queries from VNets that are explicitly
# linked to it (see the VNet link resource below). Queries from the public
# internet never reach a private zone.
#
# The zone name "platform.internal" is an RFC-6762 private domain. Azure
# reserves certain suffixes (.local, .internal) for private use — these
# names will never be registered on the public internet, so there is no
# risk of name collision with real public domains.
resource "azurerm_private_dns_zone" "this" {
  name                = var.zone_name
  resource_group_name = data.azurerm_resource_group.this.name

  tags = var.tags

  depends_on = [data.azurerm_resource_group.this]
}

# Terraform concept: `azurerm_private_dns_zone_virtual_network_link` connects
# a private DNS zone to a VNet. Once linked, any DNS query made by a resource
# inside that VNet for a name in the zone (e.g. jenkins.platform.internal) is
# answered by Azure DNS using the records in this zone — no custom DNS server
# is needed.
#
# `registration_enabled = false` — disabling auto-registration means VMs in
# the VNet do NOT automatically get A records created for them in the zone.
# We want manual control over what names exist in platform.internal; allowing
# every AKS node to auto-register would pollute the zone with node names we
# don't need.
#
# `count` — controlled by var.enable_vnet_link (a plain bool, always true in
# normal deployments). We deliberately do NOT use `var.aks_vnet_id != "" ? 1 : 0`
# here because aks_vnet_id is passed from a data source with depends_on=[module.aks],
# making it "known after apply" on the first plan. Terraform rejects a deferred value
# in a count expression. A plain bool variable is always known at plan time, so
# count = 1 is concrete during plan even though virtual_network_id is deferred.
resource "azurerm_private_dns_zone_virtual_network_link" "aks" {
  count = var.enable_vnet_link ? 1 : 0

  # Link names must be unique within the zone; prefix scopes it to this cluster.
  name                  = "link-aks-${var.prefix}"
  resource_group_name   = data.azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.this.name
  virtual_network_id    = var.aks_vnet_id
  registration_enabled  = false

  tags = var.tags

  depends_on = [azurerm_private_dns_zone.this]
}
