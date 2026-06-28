# Module: appconfig

Creates the Azure App Configuration store pre-seeded with runtime config and feature flags for the sample application.

## What this module creates

| Resource | Name pattern | Purpose |
|---|---|---|
| `azurerm_app_configuration` | `appcfg-<prefix>-<suffix>` | Free SKU config store |
| `azurerm_app_configuration_key` | `app/log-level` | Logging verbosity (default: `info`) |
| `azurerm_app_configuration_key` | `app/max-db-connections` | PG connection pool size (default: `5`) |
| `azurerm_app_configuration_key` | `app/environment` | Environment name (`dev`) |
| `azurerm_app_configuration_key` | `.appconfig.featureflag/dark-mode` | Dark-mode UI feature flag (default: off) |
| `azurerm_app_configuration_key` | `.appconfig.featureflag/new-user-flow` | Onboarding wizard flag (default: off) |

All keys are labelled `"dev"` so the SDK can filter by environment.

## KodeKloud constraints applied

| Constraint | Implementation |
|---|---|
| Free or Developer SKU | `sku = "free"` |
| MAX 1 store per session | Enforced by project convention |
| No role assignments | `local_auth_enabled = true`; azurerm provider uses the write key automatically |

## Feature flag format

Feature flags are stored as regular key-values with a reserved prefix and content-type understood by the App Configuration SDK's feature manager:

```
key          = ".appconfig.featureflag/<name>"
content_type = "application/vnd.microsoft.appconfig.ff+json;charset=utf-8"
value        = { "id": "...", "enabled": false, "conditions": { "client_filters": [] } }
```

This lets the app toggle features in code without a redeployment:

```javascript
// Node.js — @azure/app-configuration + feature-management SDK
const isEnabled = await featureManager.isEnabled("dark-mode");
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `resource_group_name` | string | — | KodeKloud-provided resource group |
| `prefix` | string | — | 3-11 char alphanumeric prefix |
| `location` | string | `eastus` | Azure region |
| `log_level` | string | `"info"` | Sample app log verbosity |
| `max_db_connections` | number | `5` | PG connection pool ceiling |
| `tags` | map(string) | `{}` | Common tags |

## Outputs

| Name | Sensitive | Description |
|---|---|---|
| `store_id` | no | Full Azure resource ID |
| `store_name` | no | Short store name |
| `endpoint` | no | HTTPS data-plane URL |
| `primary_read_connection_string` | **yes** | Read-only connection string for the sample app |
| `primary_write_connection_string` | **yes** | Read+write connection string for Jenkins deploy stages |

## Usage in root module

```hcl
module "appconfig" {
  source = "./modules/appconfig"

  resource_group_name = var.resource_group_name
  prefix              = var.prefix
  tags                = local.tags
}
```

## Verify after apply

```bash
# List all keys in the store
az appconfig kv list \
  --name <store_name> \
  --label dev \
  --output table

# Read a specific config value
az appconfig kv show \
  --name <store_name> \
  --key "app/log-level" \
  --label dev

# List feature flags
az appconfig feature list \
  --name <store_name> \
  --label dev \
  --output table

# Toggle a feature flag on (without redeploying the app)
az appconfig feature enable \
  --name <store_name> \
  --feature dark-mode \
  --label dev
```
