variable "resource_group_name" {
  type        = string
  description = "Name of the existing KodeKloud-provided resource group. This module never creates a resource group (docs/decisions.md ADR-001)."
}

variable "prefix" {
  type        = string
  description = "Short lowercase alphanumeric prefix used to build the Log Analytics Workspace name (\"log-\" + prefix + \"-\" + 6-char random suffix). Must be the same value used across all modules."

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

variable "retention_in_days" {
  type        = number
  description = "How many days ingested logs/metrics are queryable. KodeKloud caps this at 30; Azure's own minimum for the PerGB2018 SKU is also 30, so 30 is the only value that satisfies both constraints."
  default     = 30

  validation {
    condition     = var.retention_in_days == 30
    error_message = "retention_in_days must be exactly 30 on KodeKloud: the playground policy caps it at <=30, and the PerGB2018 SKU's own minimum is 30."
  }
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags applied to every resource created by this module."
  default     = {}
}
