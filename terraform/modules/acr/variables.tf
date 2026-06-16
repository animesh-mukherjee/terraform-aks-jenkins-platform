variable "resource_group_name" {
  type        = string
  description = "Name of the existing KodeKloud-provided resource group. This module never creates a resource group (docs/decisions.md ADR-001)."
}

variable "prefix" {
  type        = string
  description = "Short lowercase alphanumeric prefix used to build the globally-unique ACR name (\"acr\" + prefix + 6-char random suffix). Must be the same value used across all modules so resource names are consistent."

  validation {
    condition     = can(regex("^[a-z0-9]{3,11}$", var.prefix))
    error_message = "prefix must be 3-11 lowercase letters/digits. The resulting ACR name (\"acr\" + prefix + 6-char suffix) must be 5-50 alphanumeric characters; this range keeps it within that limit while matching the stricter storage account name constraint used by module.storage."
  }
}

variable "location" {
  type        = string
  description = "Azure region for all resources. KodeKloud only permits eastus, westus, centralus, or southcentralus; this project standardizes on eastus."
  default     = "eastus"
}

variable "sku" {
  type        = string
  description = "ACR pricing tier. KodeKloud allows Basic or Standard only (no Premium). Standard is the project default — it provides 100 GB included storage and webhook support at no additional playground cost."
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard"], var.sku)
    error_message = "KodeKloud only permits Basic or Standard ACR SKU. Premium is not available on the playground."
  }
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags applied to every resource created by this module."
  default     = {}
}
