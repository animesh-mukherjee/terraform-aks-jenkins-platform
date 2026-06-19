# Module: `loganalytics`

Creates the Log Analytics Workspace that AKS Container Insights (the
`oms_agent` add-on, wired up in `module.aks` at Step 6) ships cluster, pod,
and node logs/metrics into. This is Azure's native monitoring sink — no
third-party agent or AKS marketplace add-on required.

## What it creates

| Resource | Type | Notes |
|---|---|---|
| `random_string.suffix` | `random_string` | 6-char lowercase alphanumeric suffix (per-RG uniqueness, project naming convention) |
| `azurerm_log_analytics_workspace.this` | `azurerm_log_analytics_workspace` | `PerGB2018` SKU, 30-day retention |

No resource group is created — `data "azurerm_resource_group"` reads the
KodeKloud-provided one (ADR-001).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `resource_group_name` | `string` | — (required) | Name of the existing KK resource group |
| `prefix` | `string` | — (required) | 3-11 char lowercase alphanumeric prefix, e.g. `aksjenkins` |
| `location` | `string` | `eastus` | Azure region |
| `retention_in_days` | `number` | `30` | Must be exactly `30` — KK caps it at ≤30, Azure's PerGB2018 minimum is 30 |
| `tags` | `map(string)` | `{}` | Common resource tags |

## Outputs

| Name | Sensitive? | Description |
|---|---|---|
| `workspace_id` | No | Full Azure resource ID — passed to `module.aks`'s `oms_agent` add-on |
| `workspace_name` | No | Short name, e.g. `log-<prefix>-<suffix>` |
| `workspace_customer_id` | No | Workspace GUID (distinct from the resource ID) |
| `primary_shared_key` | **Yes** | Shared key for legacy agent-based auth |

## KodeKloud constraints honored

- No resource group created (`data "azurerm_resource_group"`).
- SKU fixed to `PerGB2018` — the only permitted Log Analytics SKU on the playground.
- `retention_in_days` fixed to `30` — validated in `variables.tf`.
- Region defaults to `eastus`.

## Why this module exists before `module.aks`

AKS Container Insights needs a workspace ID at cluster-creation time (it's an
argument on the `oms_agent` add-on block), so the workspace must exist first.
That's why this module is Step 5 in the Build Order — immediately before
`module.aks` at Step 6.

## Verify (inside a KodeKloud session)

```bash
cd terraform

# If running standalone (before root module is wired up in Step 12):
terraform init
terraform plan  -target=module.loganalytics
terraform apply -target=module.loganalytics -auto-approve

# Confirm the workspace exists with the expected SKU and retention
az monitor log-analytics workspace show \
  --resource-group <kk-resource-group> \
  --workspace-name "$(terraform output -raw workspace_name)" \
  --query "{name:name, sku:sku.name, retentionInDays:retentionInDays}"
```

Expected: SKU `PerGB2018`, `retentionInDays: 30`.
