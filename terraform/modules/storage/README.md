# Module: `storage`

Creates the Azure Storage Account and blob container that Terraform itself
uses as a **remote state backend**.

## What it creates

| Resource | Type | Notes |
|---|---|---|
| `random_string.storage_suffix` | `random_string` | 6-char lowercase alphanumeric suffix for global uniqueness |
| `azurerm_storage_account.state` | `azurerm_storage_account` | `Standard_LRS`, TLS 1.2 only, public blob access disabled |
| `azurerm_storage_container.tfstate` | `azurerm_storage_container` | Private container, default name `tfstate` |

No resource group is created — `data "azurerm_resource_group"` reads the
KodeKloud-provided one (ADR-001).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `resource_group_name` | `string` | — (required) | Name of the existing KK resource group |
| `prefix` | `string` | — (required) | 3-11 char lowercase alphanumeric prefix, e.g. `aksjenkins` |
| `location` | `string` | `eastus` | Azure region |
| `state_container_name` | `string` | `tfstate` | Blob container name for the state file |
| `tags` | `map(string)` | `{}` | Common resource tags |

## Outputs

| Name | Sensitive? | Description |
|---|---|---|
| `state_storage_account_name` | No | Consumed by `bootstrap.sh` to configure the azurerm backend |
| `state_storage_account_id` | No | Resource ID of the storage account |
| `state_container_name` | No | Consumed by `bootstrap.sh` to configure the azurerm backend |

## How this fits into the two-phase state pattern (ADR-006)

1. **Phase 1** (`bootstrap.sh`): `backend.tf` is parked, `terraform init` uses
   local state, and `terraform apply -target=module.storage` creates *only*
   the resources in this module.
2. `bootstrap.sh` reads `state_storage_account_name` and `state_container_name`
   from this module's outputs, fetches an access key via `az storage account
   keys list`, restores `backend.tf`, and runs `terraform init -migrate-state`
   — moving the local state file into the container this module just created.
3. **Phase 3**: the full `terraform apply` runs, including this module again
   (now a no-op, since it already exists) plus every other module.

## KodeKloud constraints honored

- No resource group created (`data "azurerm_resource_group"`).
- `Standard_LRS` replication (within the Storage SKU limit — see
  `docs/kk-session-guide.md#service-sku-limits`).
- Region defaults to `eastus`.

## Verify (inside a KodeKloud session)

```bash
cd terraform
terraform init               # local state at this point (Phase 1)
terraform plan  -target=module.storage
terraform apply -target=module.storage -auto-approve

terraform output state_storage_account_name
terraform output state_container_name

# Confirm in Azure
az storage account show \
  --name "$(terraform output -raw state_storage_account_name)" \
  --query "{name:name, sku:sku.name, tls:minimumTlsVersion, publicBlob:allowBlobPublicAccess}"

az storage container show \
  --name "$(terraform output -raw state_container_name)" \
  --account-name "$(terraform output -raw state_storage_account_name)" \
  --auth-mode login \
  --query "{name:name, publicAccess:properties.publicAccess}"
```

Expected: SKU `Standard_LRS`, TLS `TLS1_2`, `allowBlobPublicAccess: false`,
container `publicAccess: null` (private).
