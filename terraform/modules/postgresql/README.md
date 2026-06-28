# Module: postgresql

Creates the PostgreSQL Flexible Server used as the sample application database.

## What this module creates

| Resource | Name pattern | Purpose |
|---|---|---|
| `azurerm_postgresql_flexible_server` | `psql-<prefix>-<suffix>` | Managed PostgreSQL server |
| `azurerm_postgresql_flexible_server_database` | `appdb` (configurable) | Application database inside the server |
| `azurerm_postgresql_flexible_server_firewall_rule` | `AllowAzureServices` | Permits AKS node egress to reach the server |

## KodeKloud constraints applied

| Constraint | Implementation |
|---|---|
| Burstable tier only | `sku_name` validation locks to `B_Standard_B1ms/B2s/B2ms` |
| Disk ≤ 32 GB | `storage_mb = 32768` (also the Flexible Server minimum) |
| Backup ≤ 7 days | `backup_retention_days = 7` |
| No HA | `high_availability` block omitted entirely |
| MAX 1 instance | Enforced by project convention; only one `module "postgresql"` call in root |
| No geo-redundant backup | `geo_redundant_backup_enabled = false` |

## Network access

Public endpoint is enabled (no custom VNet on KK). The firewall rule `0.0.0.0–0.0.0.0` allows Azure-internal traffic only — AKS node outbound IPs route through Azure's backbone and match this rule. The server is not reachable from non-Azure IPs.

**PROD**: use VNet integration (`delegated_subnet_id` + `private_dns_zone_id`) to remove the public endpoint entirely.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `resource_group_name` | string | — | KodeKloud-provided resource group |
| `prefix` | string | — | 3-11 char alphanumeric prefix |
| `location` | string | `eastus` | Azure region |
| `postgresql_version` | string | `"16"` | PostgreSQL major version |
| `administrator_login` | string | `"pgadmin"` | Admin username |
| `administrator_password` | string | — | Admin password (sensitive; from Key Vault) |
| `sku_name` | string | `"B_Standard_B1ms"` | Compute SKU (Burstable only on KK) |
| `storage_mb` | number | `32768` | Storage in MB (32 GB; KK floor = ceiling) |
| `backup_retention_days` | number | `7` | Point-in-time backup retention (KK max: 7) |
| `database_name` | string | `"appdb"` | Application database name |
| `tags` | map(string) | `{}` | Common tags |

## Outputs

| Name | Sensitive | Description |
|---|---|---|
| `server_id` | no | Full Azure resource ID |
| `server_name` | no | Short server name |
| `server_fqdn` | **yes** | Server hostname for connection strings |
| `database_name` | no | Application database name |
| `administrator_login` | no | Admin username |
| `connection_string` | **yes** | Full `postgresql://...` URI with password embedded |

## Usage in root module

```hcl
module "postgresql" {
  source = "./modules/postgresql"

  resource_group_name    = var.resource_group_name
  prefix                 = var.prefix
  administrator_password = random_password.postgresql.result
  tags                   = local.tags
}
```

## Verify after apply

```bash
# Check server is in 'Ready' state
az postgres flexible-server show \
  --resource-group <rg> \
  --name <server_name> \
  --query "state"

# Connect and verify the app database exists
az postgres flexible-server connect \
  --name <server_name> \
  --admin-user pgadmin \
  --admin-password <password> \
  --database-name appdb

# Inside psql:
\l          # list databases — appdb should appear
\q          # quit
```
