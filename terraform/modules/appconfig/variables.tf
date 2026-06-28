variable "resource_group_name" {
  type        = string
  description = "Name of the existing KodeKloud-provided resource group. This module never creates a resource group (docs/decisions.md ADR-001)."
}

variable "prefix" {
  type        = string
  description = "Short lowercase alphanumeric prefix used to build the globally-unique store name (\"appcfg-\" + prefix + \"-\" + 6-char suffix). Must match the value used across all modules."

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

variable "log_level" {
  type        = string
  description = "Value seeded into the app/log-level key. Controls the sample app's logging verbosity. Consumed by the app at startup via the App Configuration SDK."
  default     = "info"

  validation {
    condition     = contains(["debug", "info", "warn", "error"], var.log_level)
    error_message = "log_level must be one of: debug, info, warn, error."
  }
}

variable "max_db_connections" {
  type        = number
  description = "Value seeded into the app/max-db-connections key. Sets the PostgreSQL connection pool ceiling in the sample app. Keep low on KK because the B1ms server has limited memory."
  default     = 5

  validation {
    condition     = var.max_db_connections >= 1 && var.max_db_connections <= 20
    error_message = "max_db_connections must be 1–20. The B1ms PostgreSQL server (2 GiB RAM) cannot sustain more than ~20 concurrent connections."
  }
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags applied to every resource created by this module."
  default     = {}
}
