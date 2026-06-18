# Module: keyvault

Provisions an Azure Key Vault and writes four secrets consumed by the rest of the platform.

## Resources created

| Resource | Name pattern | Purpose |
|---|---|---|
| `azurerm_key_vault` | `kv<prefix><6-char suffix>` | Central secret store |
| `azurerm_key_vault_secret` | `jenkins-admin-password` | Jenkins built-in admin credential |
| `azurerm_key_vault_secret` | `acr-username` | ACR admin username for imagePullSecret |
| `azurerm_key_vault_secret` | `acr-password` | ACR admin password for imagePullSecret |
| `azurerm_key_vault_secret` | `postgresql-password` | PostgreSQL Flexible Server admin password |

## KodeKloud constraints applied

- `sku_name = "Standard"` — Premium not available on playground
- `purge_protection_enabled = false` — vault must be deletable at session end
- `soft_delete_retention_days = 7` — minimum permitted value

## Inputs

| Name | Type | Required | Description |
|---|---|---|---|
| `resource_group_name` | string | yes | KK-provided resource group |
| `prefix` | string | yes | Short prefix for name uniqueness |
| `location` | string | no (default: eastus) | Azure region |
| `tenant_id` | string | yes | AAD tenant ID for access policy |
| `object_id` | string | yes | Object ID of Terraform runner |
| `acr_username` | string | yes | From `module.acr.admin_username` |
| `acr_password` | string | yes | From `module.acr.admin_password` |
| `jenkins_admin_password` | string | yes | Generated `random_password` |
| `postgresql_password` | string | yes | Generated `random_password` |
| `tags` | map(string) | no | Resource tags |

## Outputs

| Name | Sensitive | Description |
|---|---|---|
| `key_vault_id` | no | Full resource ID |
| `key_vault_name` | no | Short vault name |
| `vault_uri` | no | HTTPS vault URI |
| `jenkins_admin_password_secret_id` | yes | Versioned secret URI |
| `acr_username_secret_id` | yes | Versioned secret URI |
| `acr_password_secret_id` | yes | Versioned secret URI |
| `postgresql_password_secret_id` | yes | Versioned secret URI |

## What to verify after `terraform apply`

1. `az keyvault show --name <vault_name>` — vault is provisioned with Standard SKU
2. `az keyvault secret list --vault-name <vault_name>` — all four secrets appear
3. `az keyvault secret show --vault-name <vault_name> --name jenkins-admin-password` — returns a value (not empty)
