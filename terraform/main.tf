# =============================================================================
# main.tf — Root module. Wires all 11 child modules together.
#
# Apply order (Terraform resolves this from the dependency graph, but reading
# top-to-bottom reflects the logical sequence):
#   1. data sources (read-only, no Azure changes)
#   2. random_password resources (local, no Azure changes)
#   3. module.storage        → State backend storage account
#   4. module.acr            → Container registry
#   5. module.keyvault       → Key Vault + 4 secrets  (needs ACR outputs)
#   6. module.loganalytics   → Log Analytics Workspace
#   7. module.aks            → AKS cluster            (needs loganalytics output)
#   8. module.postgresql     → PostgreSQL server
#   9. module.servicebus     → Service Bus + queues
#  10. module.appconfig      → App Configuration store
#  11. data.azurerm_resources → AKS VNet lookup       (needs AKS to exist)
#  12. module.dns            → Private DNS Zone       (needs VNet ID)
#  13. module.aci            → Container Instance     (needs PostgreSQL + ACR)
# =============================================================================

# ---------------------------------------------------------------------------
# Data sources — read-only lookups; create nothing in Azure
# ---------------------------------------------------------------------------

# Terraform concept: `data "azurerm_client_config" "current"` reads the
# identity of the service principal (or user) currently authenticated to
# Azure. No arguments required — it returns the credentials already in use.
# We need:
#   tenant_id  → Key Vault requires this to scope access policies to the right AAD tenant
#   object_id  → Key Vault access policy: grants Terraform's own SP permission
#               to write secrets during apply
data "azurerm_client_config" "current" {}

# Read the KK-provided resource group so we can validate it exists before
# any child module tries to place resources in it.
data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

# ---------------------------------------------------------------------------
# Local values — computed once, referenced throughout
# ---------------------------------------------------------------------------

# Terraform concept: `locals` defines computed values that can be referenced
# as `local.<name>` throughout the module. Useful for values derived from
# variables or for reducing repetition. Unlike variables, locals cannot be
# overridden at apply time.
locals {
  tags = merge(var.tags, {
    project    = "aks-jenkins-platform"
    managed_by = "terraform"
    env        = "dev"
  })
}

# ---------------------------------------------------------------------------
# Password generation — stored in Terraform state, never passed as inputs
# ---------------------------------------------------------------------------

# Terraform concept: `random_password` generates a cryptographically random
# string and stores it in Terraform state. Because it is stored in state, it
# stays stable across applies — Terraform does not regenerate it unless you
# taint or destroy this resource. The result is sensitive (Terraform marks it
# as such and suppresses it in output).
#
# Passwords are generated HERE rather than accepted as input variables to:
#   1. Prevent secrets appearing in .tfvars files, CI logs, or plan output
#   2. Ensure they are strong and consistent without manual management
#   3. Allow Key Vault (module.keyvault) to be the single source of truth
#
# override_special limits the special chars to a safe subset that survives
# YAML serialisation (JCasC) and shell quoting without escaping.
resource "random_password" "jenkins_admin" {
  length           = 20
  special          = true
  override_special = "!@#%^&*"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "random_password" "postgresql" {
  length           = 20
  special          = true
  override_special = "!@#%^&*"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

# ---------------------------------------------------------------------------
# Module 1 — Storage (Terraform remote state backend)
# ---------------------------------------------------------------------------

# Terraform concept: a `module` block calls a child module, passing values
# for the module's input variables. `source` is the path to the module
# directory (relative to this file). All child modules in this project live
# under ./modules/.
module "storage" {
  source = "./modules/storage"

  resource_group_name = var.resource_group_name
  prefix              = var.prefix
  location            = var.location
  tags                = local.tags

  # Explicit depends_on (project standard): data source is already implied
  # by how resource_group_name flows into the module, but stated explicitly.
  depends_on = [data.azurerm_resource_group.main]
}

# ---------------------------------------------------------------------------
# Module 2 — ACR (Azure Container Registry)
# ---------------------------------------------------------------------------

module "acr" {
  source = "./modules/acr"

  resource_group_name = var.resource_group_name
  prefix              = var.prefix
  location            = var.location
  sku                 = "Standard"
  tags                = local.tags

  depends_on = [data.azurerm_resource_group.main]
}

# ---------------------------------------------------------------------------
# Module 3 — Key Vault (secrets store)
# ---------------------------------------------------------------------------

# Depends on module.acr because the ACR admin credentials are written as
# secrets into Key Vault at apply time.
module "keyvault" {
  source = "./modules/keyvault"

  resource_group_name = var.resource_group_name
  prefix              = var.prefix
  location            = var.location

  # Identity of the Terraform runner — grants this SP full secret permissions
  # so it can write/read secrets during apply.
  tenant_id = data.azurerm_client_config.current.tenant_id
  object_id = data.azurerm_client_config.current.object_id

  # Secrets to write on first apply:
  jenkins_admin_password = random_password.jenkins_admin.result
  acr_username           = module.acr.admin_username
  acr_password           = module.acr.admin_password
  postgresql_password    = random_password.postgresql.result

  tags = local.tags

  depends_on = [module.acr]
}

# ---------------------------------------------------------------------------
# Module 4 — Log Analytics Workspace
# ---------------------------------------------------------------------------

module "loganalytics" {
  source = "./modules/loganalytics"

  resource_group_name = var.resource_group_name
  prefix              = var.prefix
  location            = var.location
  retention_in_days   = 30
  tags                = local.tags

  depends_on = [data.azurerm_resource_group.main]
}

# ---------------------------------------------------------------------------
# Module 5 — AKS Cluster
# ---------------------------------------------------------------------------

# Depends on module.loganalytics because the workspace ID is wired into the
# AKS oms_agent block (Container Insights). AKS provisioning fails if the
# workspace does not exist yet.
module "aks" {
  source = "./modules/aks"

  resource_group_name        = var.resource_group_name
  prefix                     = var.prefix
  location                   = var.location
  log_analytics_workspace_id = module.loganalytics.workspace_id
  tags                       = local.tags

  depends_on = [module.loganalytics]
}

# ---------------------------------------------------------------------------
# Module 6 — PostgreSQL Flexible Server
# ---------------------------------------------------------------------------

module "postgresql" {
  source = "./modules/postgresql"

  resource_group_name    = var.resource_group_name
  prefix                 = var.prefix
  location               = var.location
  administrator_password = random_password.postgresql.result
  tags                   = local.tags

  depends_on = [data.azurerm_resource_group.main]
}

# ---------------------------------------------------------------------------
# Module 7 — Service Bus
# ---------------------------------------------------------------------------

module "servicebus" {
  source = "./modules/servicebus"

  resource_group_name = var.resource_group_name
  prefix              = var.prefix
  location            = var.location
  tags                = local.tags

  depends_on = [data.azurerm_resource_group.main]
}

# ---------------------------------------------------------------------------
# Module 8 — App Configuration
# ---------------------------------------------------------------------------

module "appconfig" {
  source = "./modules/appconfig"

  resource_group_name = var.resource_group_name
  prefix              = var.prefix
  location            = var.location
  tags                = local.tags

  depends_on = [data.azurerm_resource_group.main]
}

# ---------------------------------------------------------------------------
# AKS VNet lookup — needed by module.dns
# ---------------------------------------------------------------------------

# Terraform concept: AKS (kubenet) automatically creates a VNet named
# "aks-vnet-<cluster-id>" in the MC_ node resource group. We do not know
# this name at plan time (it includes the cluster's internal ID), so we
# use `data "azurerm_resources"` to LIST all VNets in that resource group
# and pick the first result.
#
# `depends_on = [module.aks]` is critical here: data sources are normally
# evaluated during the plan phase BEFORE resources are created. Without an
# explicit depends_on, Terraform might try to read this data source before
# AKS (and its MC_ resource group) exist, returning an empty list. The
# depends_on forces Terraform to apply module.aks first, then evaluate this
# data source during the same apply run.
data "azurerm_resources" "aks_vnet" {
  resource_group_name = module.aks.node_resource_group
  type                = "Microsoft.Network/virtualNetworks"

  depends_on = [module.aks]
}

# ---------------------------------------------------------------------------
# Module 9 — Private DNS Zone
# ---------------------------------------------------------------------------

module "dns" {
  source = "./modules/dns"

  resource_group_name = var.resource_group_name
  prefix              = var.prefix

  # Safe guard: if the VNet lookup returns no results (e.g. on a fresh plan
  # before AKS exists), pass an empty string so the module skips VNet link
  # creation (count = 0 path). The link is created on the next apply once
  # AKS and its VNet are present.
  aks_vnet_id = length(data.azurerm_resources.aks_vnet.resources) > 0 ? data.azurerm_resources.aks_vnet.resources[0].id : ""

  tags = local.tags

  depends_on = [module.aks, data.azurerm_resources.aks_vnet]
}

# ---------------------------------------------------------------------------
# Module 10 — Container Instance (DB migration runner)
# ---------------------------------------------------------------------------

module "aci" {
  source = "./modules/aci"

  resource_group_name = var.resource_group_name
  prefix              = var.prefix
  location            = var.location

  # PostgreSQL connection details — wired from module.postgresql outputs
  db_host     = module.postgresql.server_fqdn
  db_name     = module.postgresql.database_name
  db_user     = module.postgresql.administrator_login
  db_password = random_password.postgresql.result

  # ACR credentials for pulling the migration image
  acr_login_server = module.acr.login_server
  acr_username     = module.acr.admin_username
  acr_password     = module.acr.admin_password

  tags = local.tags

  depends_on = [module.postgresql, module.acr]
}
