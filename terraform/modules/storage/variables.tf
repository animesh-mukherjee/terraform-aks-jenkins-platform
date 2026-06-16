variable "resource_group_name" {
  type        = string
  description = "Name of the existing KodeKloud-provided resource group that all resources are created in. This module never creates a resource group (docs/decisions.md ADR-001)."
}

# Terraform concept: a `validation` block lets a variable reject bad input at
# `terraform plan` time with a clear error message, instead of failing deep
# inside an `apply` once Azure rejects an invalid name.
variable "prefix" {
  type        = string
  description = "Short lowercase alphanumeric prefix used to build globally-unique Azure resource names (e.g. \"aksjenkins\"). Combined with a random suffix for resources that require global uniqueness, such as this module's storage account."

  validation {
    condition     = can(regex("^[a-z0-9]{3,11}$", var.prefix))
    error_message = "prefix must be 3-11 lowercase letters/digits, so that \"st\" + prefix + a 6-character random suffix stays within Azure's 24-character storage account name limit."
  }
}

variable "location" {
  type        = string
  description = "Azure region for all resources. KodeKloud only permits eastus, westus, centralus, or southcentralus; this project standardizes on eastus."
  default     = "eastus"
}

variable "state_container_name" {
  type        = string
  description = "Name of the blob container that will hold the Terraform remote state file. Must match the container_name used in terraform/backend.tf and the STATE_CONTAINER value used by bootstrap.sh."
  default     = "tfstate"
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags applied to every resource created by this module."
  default     = {}
}
