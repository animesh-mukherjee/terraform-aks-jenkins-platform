variable "resource_group_name" {
  type        = string
  description = "Name of the existing KodeKloud-provided resource group. This module never creates a resource group (docs/decisions.md ADR-001)."
}

variable "prefix" {
  type        = string
  description = "Short lowercase alphanumeric prefix used to build the container group name (\"aci-migrate-\" + prefix + \"-\" + 6-char suffix). Must match the value used across all modules."

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

variable "migration_image" {
  type        = string
  description = "Container image used for the initial Terraform apply. A public image that exits immediately (e.g. alpine:3.19) is used as a placeholder until Jenkins builds and pushes the actual migration image to ACR. Terraform ignores image changes after the first apply via lifecycle.ignore_changes."
  default     = "alpine:3.19"
}

variable "cpu_cores" {
  type        = number
  description = "Number of CPU cores allocated to the migration container. KodeKloud caps ACI at 2 CPU cores. 0.5 is sufficient for running SQL migration scripts."
  default     = 0.5

  validation {
    condition     = var.cpu_cores >= 0.25 && var.cpu_cores <= 2.0
    error_message = "cpu_cores must be 0.25–2.0 (KodeKloud ACI constraint)."
  }
}

variable "memory_gb" {
  type        = number
  description = "Memory in GB allocated to the migration container. KodeKloud caps ACI at 4 GB. 1.0 GB is sufficient for migration tooling (Flyway, Alembic, node-pg-migrate)."
  default     = 1.0

  validation {
    condition     = var.memory_gb >= 0.5 && var.memory_gb <= 4.0
    error_message = "memory_gb must be 0.5–4.0 (KodeKloud ACI constraint)."
  }
}

variable "db_host" {
  type        = string
  description = "FQDN of the PostgreSQL Flexible Server (from module.postgresql.server_fqdn). Injected as the DB_HOST environment variable so the migration tool can connect to the database."
}

variable "db_name" {
  type        = string
  description = "Name of the application database inside the server (from module.postgresql.database_name). Injected as DB_NAME."
}

variable "db_user" {
  type        = string
  description = "PostgreSQL admin username (from module.postgresql.administrator_login). Injected as DB_USER."
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "PostgreSQL admin password. Injected as DB_PASSWORD via secure_environment_variables (masked in Azure Portal). Sensitive — never appears in plan/apply terminal output."
}

variable "acr_login_server" {
  type        = string
  description = "ACR login server FQDN (from module.acr.login_server, e.g. \"acr<prefix><suffix>.azurecr.io\"). Tells ACI which registry to authenticate with when pulling the migration image."
}

variable "acr_username" {
  type        = string
  description = "ACR admin username (from module.acr.admin_username). Used in the image_registry_credential block to authenticate image pulls from the private registry."
}

variable "acr_password" {
  type        = string
  sensitive   = true
  description = "ACR admin password (from module.acr.admin_password). Used in the image_registry_credential block. Sensitive — masked in plan/apply output."
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags applied to every resource created by this module."
  default     = {}
}
