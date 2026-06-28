# =============================================================================
# Module: appconfig
#
# Purpose: Creates the Azure App Configuration store that holds feature flags
#          and runtime configuration for the sample application. The sample
#          app reads these values at startup (and optionally at runtime via
#          the App Configuration SDK) instead of baking them into the Docker
#          image or Helm chart values.
#
# Two types of entries are pre-seeded here:
#   1. Regular key-values — environment-specific config the app reads on boot
#      (log level, DB connection pool size, environment name).
#   2. Feature flags — boolean switches the app checks at runtime to enable
#      or disable UI features without a new deployment.
#
# Feature flags are stored as key-values with a well-known key prefix
# (.appconfig.featureflag/) and a specific JSON content-type so the App
# Configuration SDK can parse them as typed FeatureFlag objects.
# =============================================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# KK constraint: resource groups cannot be created — read the session-provided
# one so we can reference its name and location below.
# PROD: replace with resource "azurerm_resource_group" and a depends_on.
data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

# App Configuration store names: 5-50 chars, alphanumeric + hyphens,
# globally unique across Azure.
# "appcfg-" (7) + prefix (3-11) + "-" (1) + suffix (6) = 17-25 chars.
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
  keepers = {
    prefix = var.prefix
  }
}

# Terraform concept: `azurerm_app_configuration` provisions a managed key-value
# store optimised for application configuration. Unlike a generic key-value
# store (Redis, etcd), App Configuration has first-class support for:
#   - Feature flags (typed boolean toggles with filter conditions)
#   - Labels (dimension for environment/region segmentation, e.g. "dev", "prod")
#   - Key Vault references (pointer to a KV secret instead of the value itself)
#   - Change-event streaming (SDK can watch for config changes without polling)
#
# Key attributes:
#   sku               — "free" (1000 keys, 10 MB, no SLA) or
#                       "standard" (unlimited keys, geo-replication, RBAC, SLA).
#   local_auth_enabled — when true, clients can authenticate with the store's
#                       primary read/write connection strings (SAS-like keys).
#                       Required on Free SKU: RBAC (AAD) auth is Standard-only.
resource "azurerm_app_configuration" "this" {
  name                = "appcfg-${var.prefix}-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location

  # KK constraint: Free or Developer SKU only; MAX 1 store per session.
  # Free tier: 1000 key-values, 10 MB storage, no SLA, no geo-replication.
  # PROD: sku = "standard" for unlimited keys, private link, geo-replication,
  # and AAD-based RBAC (so local_auth_enabled can be set to false).
  sku = "free" # KK workaround

  # Required on Free SKU because AAD/RBAC-based data-plane auth is a
  # Standard-only feature. The azurerm provider uses the primary write
  # connection string automatically when creating azurerm_app_configuration_key
  # resources below, so no manual auth wiring is needed here.
  # PROD: local_auth_enabled = false once on Standard SKU; grant the app's
  # Managed Identity the "App Configuration Data Reader" role instead.
  local_auth_enabled = true

  tags = var.tags

  depends_on = [data.azurerm_resource_group.this]
}

# ---------------------------------------------------------------------------
# Regular key-values — environment config the sample app reads at startup.
# Label "dev" scopes these to the dev namespace so the same key (e.g.
# "app/log-level") can have different values per environment without key
# name conflicts. The app SDK filters by label at startup.
# ---------------------------------------------------------------------------

# Terraform concept: `azurerm_app_configuration_key` creates a single
# key-value entry in the store. `type = "kv"` (the default) means a plain
# string value. The alternative is `type = "vault"` for a Key Vault reference
# where `value` is the KV secret URI and the app SDK resolves it at runtime.
resource "azurerm_app_configuration_key" "log_level" {
  configuration_store_id = azurerm_app_configuration.this.id
  key                    = "app/log-level"
  value                  = var.log_level
  label                  = "dev"
  content_type           = "text/plain"

  depends_on = [azurerm_app_configuration.this]
}

resource "azurerm_app_configuration_key" "max_db_connections" {
  configuration_store_id = azurerm_app_configuration.this.id
  key                    = "app/max-db-connections"
  value                  = tostring(var.max_db_connections)
  label                  = "dev"
  content_type           = "text/plain"

  depends_on = [azurerm_app_configuration.this]
}

resource "azurerm_app_configuration_key" "environment" {
  configuration_store_id = azurerm_app_configuration.this.id
  key                    = "app/environment"
  value                  = "dev"
  label                  = "dev"
  content_type           = "text/plain"

  depends_on = [azurerm_app_configuration.this]
}

# ---------------------------------------------------------------------------
# Feature flags — boolean toggles the app checks at runtime via the
# App Configuration SDK's feature manager.
#
# Terraform concept: feature flags are stored as regular key-values with:
#   key          = ".appconfig.featureflag/<feature-name>"  (reserved prefix)
#   content_type = "application/vnd.microsoft.appconfig.ff+json;charset=utf-8"
#   value        = JSON with the FeatureFlag schema
#
# The reserved prefix and content-type together tell the SDK to parse this
# entry as a typed FeatureFlag object (with enabled bool + filter conditions)
# rather than a plain string. The `conditions.client_filters` list is empty
# here — that means the flag is globally on/off. Filters (e.g.
# TargetingFilter for % rollouts) can be added without changing the key.
# ---------------------------------------------------------------------------
locals {
  # Reusable helper to build the feature flag JSON body.
  # `jsonencode` produces compact, valid JSON from a Terraform map.
  feature_flag = {
    dark_mode = jsonencode({
      id          = "dark-mode"
      description = "Enable dark-mode colour scheme across all UI pages."
      enabled     = false
      conditions  = { client_filters = [] }
    })
    new_user_flow = jsonencode({
      id          = "new-user-flow"
      description = "Route new registrations through the redesigned onboarding wizard."
      enabled     = false
      conditions  = { client_filters = [] }
    })
  }
}

resource "azurerm_app_configuration_key" "feature_dark_mode" {
  configuration_store_id = azurerm_app_configuration.this.id

  # The .appconfig.featureflag/ prefix is reserved by the SDK — do not change it.
  key          = ".appconfig.featureflag/dark-mode"
  content_type = "application/vnd.microsoft.appconfig.ff+json;charset=utf-8"
  value        = local.feature_flag.dark_mode
  label        = "dev"

  depends_on = [azurerm_app_configuration.this]
}

resource "azurerm_app_configuration_key" "feature_new_user_flow" {
  configuration_store_id = azurerm_app_configuration.this.id
  key                    = ".appconfig.featureflag/new-user-flow"
  content_type           = "application/vnd.microsoft.appconfig.ff+json;charset=utf-8"
  value                  = local.feature_flag.new_user_flow
  label                  = "dev"

  depends_on = [azurerm_app_configuration.this]
}
