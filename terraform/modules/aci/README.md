# Module: aci

Defines the Container Instance used as a one-shot database migration runner in the Jenkins pipeline.

## What this module creates

| Resource | Name pattern | Purpose |
|---|---|---|
| `azurerm_container_group` | `aci-migrate-<prefix>-<suffix>` | One-shot migration runner |

## One-shot pattern

This ACI is **not** a long-running service. It follows the batch job pattern:

| Attribute | Value | Effect |
|---|---|---|
| `restart_policy` | `"Never"` | Runs once, stays in Terminated state |
| `lifecycle.ignore_changes` | `container[0].image` | Jenkins owns the image; Terraform doesn't revert it |
| Initial image | `alpine:3.19` | Public placeholder that exits cleanly on first apply |

## Jenkins Stage 4 workflow

```groovy
stage('DB Migration') {
  steps {
    // Remove previous run (ignore errors if not exists)
    sh 'az container delete --yes --name ${ACI_NAME} --resource-group ${RG} || true'

    // Start migration with actual image and current commit SHA
    sh """
      az container create \
        --name ${ACI_NAME} \
        --resource-group ${RG} \
        --image ${ACR_SERVER}/db-migrate:${GIT_COMMIT} \
        --cpu 0.5 --memory 1.0 \
        --restart-policy Never \
        --registry-login-server ${ACR_SERVER} \
        --registry-username ${ACR_USER} \
        --registry-password ${ACR_PASS} \
        --environment-variables DB_HOST=${DB_HOST} DB_NAME=${DB_NAME} DB_USER=${DB_USER} DB_SSL=true \
        --secure-environment-variables DB_PASSWORD=${DB_PASS}
    """

    // Wait for completion (blocks until Terminated)
    sh 'az container wait --name ${ACI_NAME} --resource-group ${RG} --condition Terminated'

    // Check exit code — non-zero fails the stage
    script {
      def exitCode = sh(
        script: "az container show --name ${ACI_NAME} --resource-group ${RG} --query 'containers[0].instanceView.currentState.exitCode' -o tsv",
        returnStdout: true
      ).trim()
      if (exitCode != '0') error("Migration failed with exit code ${exitCode}")
    }
  }
}
```

## KodeKloud constraints applied

| Constraint | Implementation |
|---|---|
| Standard tier | `azurerm_container_group` (Standard is the only option on ACI) |
| CPU 0.25–2 | `cpu_cores` variable, default `0.5`, validation enforces 0.25–2.0 |
| Memory 0.5–4 GB | `memory_gb` variable, default `1.0`, validation enforces 0.5–4.0 |
| No VNet integration | `ip_address_type = "Public"` (no custom VNet on KK; Private requires subnet delegation) |

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `resource_group_name` | string | — | KodeKloud-provided resource group |
| `prefix` | string | — | 3-11 char alphanumeric prefix |
| `location` | string | `eastus` | Azure region |
| `migration_image` | string | `"alpine:3.19"` | Placeholder image for first apply |
| `cpu_cores` | number | `0.5` | CPU cores (KK max: 2.0) |
| `memory_gb` | number | `1.0` | Memory in GB (KK max: 4.0) |
| `db_host` | string | — | PostgreSQL FQDN (from `module.postgresql.server_fqdn`) |
| `db_name` | string | — | Database name (from `module.postgresql.database_name`) |
| `db_user` | string | — | Admin username (from `module.postgresql.administrator_login`) |
| `db_password` | string | — | Admin password (sensitive) |
| `acr_login_server` | string | — | ACR FQDN (from `module.acr.login_server`) |
| `acr_username` | string | — | ACR admin username (from `module.acr.admin_username`) |
| `acr_password` | string | — | ACR admin password (sensitive) |
| `tags` | map(string) | `{}` | Common tags |

## Outputs

| Name | Description |
|---|---|
| `container_group_id` | Full resource ID (used in `az container delete --ids`) |
| `container_group_name` | Short name (used in all `az container` commands) |
| `resource_group_name` | RG name (required alongside name for all az container commands) |
| `ip_address` | Public IP (diagnostics only — no inbound connections needed) |

## Usage in root module

```hcl
module "aci" {
  source = "./modules/aci"

  resource_group_name = var.resource_group_name
  prefix              = var.prefix
  db_host             = module.postgresql.server_fqdn
  db_name             = module.postgresql.database_name
  db_user             = module.postgresql.administrator_login
  db_password         = random_password.postgresql.result
  acr_login_server    = module.acr.login_server
  acr_username        = module.acr.admin_username
  acr_password        = module.acr.admin_password
  tags                = local.tags

  depends_on = [module.postgresql, module.acr]
}
```

## Verify after first apply

```bash
# Container should be in Succeeded or Terminated state (alpine exits immediately)
az container show \
  --resource-group <rg> \
  --name <container_group_name> \
  --query "{state:instanceView.state, exitCode:containers[0].instanceView.currentState.exitCode}"

# View logs from the placeholder run (will be empty for alpine)
az container logs \
  --resource-group <rg> \
  --name <container_group_name>
```
