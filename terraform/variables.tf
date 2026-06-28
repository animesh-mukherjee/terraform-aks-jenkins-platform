# =============================================================================
# variables.tf — Root module input variables.
#
# Only three variables are required at apply time: resource_group_name,
# prefix, and location. Everything else has safe defaults or is generated
# internally (passwords use random_password in main.tf so they are never
# passed as input — this avoids secrets appearing in .tfvars files or CI logs).
# =============================================================================

variable "resource_group_name" {
  type        = string
  description = "Name of the KodeKloud-provided resource group that all Azure resources are placed in. Do NOT create this group — KK provisions it at session start. Read its name from the Azure Portal or with `az group list --output table`."
}

variable "prefix" {
  type        = string
  description = "Short lowercase alphanumeric identifier used in every resource name (e.g. \"aksjenk\"). Combined with a 6-char random suffix for globally-unique names. Keep it short: Storage Account names are capped at 24 chars and this prefix contributes to that limit."

  validation {
    condition     = can(regex("^[a-z0-9]{3,11}$", var.prefix))
    error_message = "prefix must be 3-11 lowercase letters/digits. \"st\" + prefix + 6-char suffix must fit within the 24-char Storage Account name limit."
  }
}

variable "location" {
  type        = string
  description = "Azure region for all resources. KodeKloud only permits eastus, westus, centralus, or southcentralus. eastus is the project standard and the most feature-complete region on the playground."
  default     = "eastus"

  validation {
    condition     = contains(["eastus", "westus", "centralus", "southcentralus"], var.location)
    error_message = "KodeKloud only permits: eastus, westus, centralus, southcentralus."
  }
}

variable "tags" {
  type        = map(string)
  description = "Additional resource tags merged with the project standard tags (project, managed_by, env) defined in local.tags in main.tf. Use this to add cost-centre, owner, or ticket-number tags without modifying main.tf."
  default     = {}
}
