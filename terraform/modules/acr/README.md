# Module: `acr`

Creates the Azure Container Registry that stores every Docker image produced
by Jenkins build agents. AKS pulls images from this registry during Helm
deployments using a Kubernetes **imagePullSecret** (built in Step 13,
`terraform/k8s-post/`) because IAM role assignments are blocked on the
KodeKloud playground (ADR-002).

## What it creates

| Resource | Type | Notes |
|---|---|---|
| `random_string.acr_suffix` | `random_string` | 6-char lowercase alphanumeric suffix for global uniqueness |
| `azurerm_container_registry.this` | `azurerm_container_registry` | Standard SKU, `admin_enabled = true` |

No resource group is created — `data "azurerm_resource_group"` reads the
KodeKloud-provided one (ADR-001).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `resource_group_name` | `string` | — (required) | Name of the existing KK resource group |
| `prefix` | `string` | — (required) | 3-11 char lowercase alphanumeric prefix, e.g. `aksjenkins` |
| `location` | `string` | `eastus` | Azure region |
| `sku` | `string` | `Standard` | ACR tier — `Basic` or `Standard` only (KK constraint) |
| `tags` | `map(string)` | `{}` | Common resource tags |

## Outputs

| Name | Sensitive? | Description |
|---|---|---|
| `registry_name` | No | Short registry name, e.g. `acr<prefix><suffix>` |
| `registry_id` | No | Full Azure resource ID |
| `login_server` | No | FQDN used in `docker push/pull`, e.g. `acr<prefix><suffix>.azurecr.io` |
| `admin_username` | No | Stored in Key Vault as `acr-username` |
| `admin_password` | **Yes** | Stored in Key Vault as `acr-password` |

## Why `admin_enabled = true`?

On a production Azure subscription you would assign the built-in **AcrPull**
role to the AKS kubelet Managed Identity — zero static credentials, fully
MSI-based. On the KodeKloud playground, `azurerm_role_assignment` is blocked.
The workaround is to enable admin credentials, store them in Key Vault, and
create a Kubernetes `imagePullSecret` from them in `terraform/k8s-post/`.

See `docs/decisions.md` ADR-002 for the full trade-off analysis.

## KodeKloud constraints honored

- No resource group created (`data "azurerm_resource_group"`).
- SKU limited to `Basic` or `Standard` — validated in `variables.tf`.
- `admin_enabled = true` replaces the blocked `azurerm_role_assignment`.
- Region defaults to `eastus`.

## Verify (inside a KodeKloud session)

```bash
cd terraform

# If running standalone (before root module is wired up in Step 12):
terraform init
terraform plan  -target=module.acr
terraform apply -target=module.acr -auto-approve

# Confirm the registry exists and admin is enabled
az acr show \
  --name "$(terraform output -raw registry_name)" \
  --resource-group <kk-resource-group> \
  --query "{name:name, sku:sku.name, adminEnabled:adminUserEnabled, loginServer:loginServer}"

# Verify admin credentials are available (password is redacted in output)
az acr credential show \
  --name "$(terraform output -raw registry_name)" \
  --resource-group <kk-resource-group> \
  --query "{username:username, password:passwords[0].value}"

# Confirm login_server output matches the az acr show loginServer field
terraform output login_server
```

Expected: SKU `Standard`, `adminUserEnabled: true`,
`loginServer` matching `acr<prefix><suffix>.azurecr.io`.
