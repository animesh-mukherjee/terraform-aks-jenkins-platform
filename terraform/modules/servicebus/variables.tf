variable "resource_group_name" {
  type        = string
  description = "Name of the existing KodeKloud-provided resource group. This module never creates a resource group (docs/decisions.md ADR-001)."
}

variable "prefix" {
  type        = string
  description = "Short lowercase alphanumeric prefix used to build the globally-unique namespace name (\"sb-\" + prefix + \"-\" + 6-char suffix). Must match the value used across all modules."

  validation {
    condition     = can(regex("^[a-z0-9]{3,11}$", var.prefix))
    error_message = "prefix must be 3-11 lowercase letters/digits."
  }
}

variable "location" {
  type        = string
  description = "Azure region. KodeKloud only permits eastus, westus, centralus, or southcentralus. This project standardizes on eastus."
  default     = "eastus"
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags applied to every resource created by this module."
  default     = {}
}
