variable "resource_group_name" {
  type        = string
  description = "Name of the existing KodeKloud-provided resource group. The private DNS zone is placed here. This module never creates a resource group (docs/decisions.md ADR-001)."
}

variable "prefix" {
  type        = string
  description = "Short lowercase alphanumeric prefix used to name the VNet link (\"link-aks-\" + prefix). Must match the value used across all modules."

  validation {
    condition     = can(regex("^[a-z0-9]{3,11}$", var.prefix))
    error_message = "prefix must be 3-11 lowercase letters/digits."
  }
}

variable "zone_name" {
  type        = string
  description = "Name of the private DNS zone to create. Must be a valid RFC-1035 domain label. Use a private-use TLD (.internal, .local, .corp, .home) that will never appear in public DNS."
  default     = "platform.internal"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9\\-\\.]{1,61}[a-z0-9]$", var.zone_name))
    error_message = "zone_name must be a valid DNS name (lowercase alphanumeric and hyphens/dots, 3-63 chars)."
  }
}

variable "aks_vnet_id" {
  type        = string
  description = "Full Azure resource ID of the VNet to link to this DNS zone. For kubenet AKS the VNet lives in the MC_ node resource group; the root module looks it up with data \"azurerm_resources\" after AKS is created. May be \"(known after apply)\" at plan time — set via enable_vnet_link instead of using this for count."
  default     = ""
}

variable "enable_vnet_link" {
  type        = bool
  description = "Whether to create the VNet link between this DNS zone and the AKS VNet. Always true in normal deployments. Kept as a variable (rather than using aks_vnet_id != \"\" as the count guard) because aks_vnet_id is \"known after apply\" on the first plan — Terraform forbids using a deferred value in a count expression. A plain bool is always known at plan time."
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags applied to every resource created by this module."
  default     = {}
}
