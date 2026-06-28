# Terraform concept: random_string generates a short unique suffix appended to
# globally-scoped names (Key Vault names must be globally unique across all of Azure).
# `keepers` pins the suffix to the prefix — the suffix only regenerates if prefix changes.
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
  keepers = {
    prefix = var.prefix
  }
}

# Terraform concept: azurerm_key_vault creates an Azure Key Vault.
# Key Vault is a managed HSM-backed secret store. This project uses it as the single
# source of truth for all credentials so nothing sensitive touches Terraform state
# in plaintext after the first apply (secrets are still in state — encrypt your backend).
resource "azurerm_key_vault" "this" {
  name                = "kv${var.prefix}${random_string.suffix.result}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = var.tenant_id

  # KK constraint: Standard SKU only (Premium requires dedicated HSM allocation unavailable on playground).
  # PROD: sku_name = "Premium" for HSM-backed keys and regulatory compliance (PCI, HIPAA).
  sku_name = "standard"

  # KK constraint: purge_protection=false required — enabling it would lock the vault
  # for 90 days after deletion, which conflicts with the session-based playground lifecycle.
  # PROD: purge_protection_enabled = true to prevent accidental permanent deletion.
  purge_protection_enabled = false # KK workaround

  # KK constraint: minimum retention must be ≥7 days per KodeKloud policy; 90d is typical prod value.
  # PROD: soft_delete_retention_days = 90
  soft_delete_retention_days = 7 # KK workaround

  # Terraform concept: access_policy block grants a specific principal (user/app/MSI)
  # permissions to Key Vault data plane operations (secrets, keys, certificates).
  # The object_id here is the Terraform runner — without this, Terraform cannot write secrets.
  access_policy {
    tenant_id = var.tenant_id
    object_id = var.object_id

    secret_permissions = [
      "Get",
      "List",
      "Set",
      "Delete",
      "Recover",
      "Backup",
      "Restore",
      "Purge",
    ]
  }

  tags = var.tags
}

# Terraform concept: azurerm_key_vault_secret stores a single secret value inside the vault.
# Each secret has its own versioned history. The `key_vault_id` links it to the vault above.
# All four secrets below follow the same pattern — only name and value differ.

resource "azurerm_key_vault_secret" "jenkins_admin_password" {
  name         = "jenkins-admin-password"
  value        = var.jenkins_admin_password
  key_vault_id = azurerm_key_vault.this.id

  # depends_on ensures the vault access policy is fully applied before any secret write.
  # Without this, Terraform may attempt the write before the policy propagates, causing a 403.
  depends_on = [azurerm_key_vault.this]
}

resource "azurerm_key_vault_secret" "acr_username" {
  name         = "acr-username"
  value        = var.acr_username
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_key_vault.this]
}

resource "azurerm_key_vault_secret" "acr_password" {
  name         = "acr-password"
  value        = var.acr_password
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_key_vault.this]
}

resource "azurerm_key_vault_secret" "postgresql_password" {
  name         = "postgresql-password"
  value        = var.postgresql_password
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_key_vault.this]
}
