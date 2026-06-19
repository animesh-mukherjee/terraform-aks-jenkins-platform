# =============================================================================
# Module: loganalytics
#
# Purpose: Creates the Log Analytics Workspace that AKS Container Insights
#          (the `oms_agent` add-on, wired up in module.aks at Step 6) ships
#          cluster + pod logs and metrics into. This replaces any third-party
#          monitoring stack — it is Azure's native, fully-managed log sink.
# =============================================================================

# Child module required_providers declaration (no provider {} config block
# here — the root module owns the single azurerm provider configuration).
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

# Terraform concept: unlike Storage Account or Key Vault names, Log Analytics
# Workspace names only need to be unique WITHIN a resource group, not
# globally across Azure. A random suffix isn't strictly required for
# uniqueness here, but this project's naming convention (var.prefix +
# random_string suffix, see Terraform Coding Standards in CLAUDE.md) is
# applied consistently across every module so names never collide if this
# module is ever applied twice into the same RG (e.g. during testing).
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

# Terraform concept: `azurerm_log_analytics_workspace` provisions a Log
# Analytics Workspace — Azure's managed store for logs and metrics queried
# with the Kusto Query Language (KQL). AKS Container Insights writes
# container stdout/stderr, pod inventory, and node/pod resource metrics here.
# Key attributes:
#
#   sku               — pricing/feature tier. "PerGB2018" is the modern
#                        pay-as-you-go tier (cost scales with ingested GB).
#   retention_in_days — how long ingested data is queryable before Azure
#                        purges it.
resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.prefix}-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location

  # KK constraint: PerGB2018 is the only permitted SKU on the playground.
  # PROD: PerGB2018 is also the standard prod choice today (legacy
  # per-node/standalone SKUs are deprecated) — no change needed.
  sku = "PerGB2018"

  # KK constraint: retention_in_days must be <=30. Azure's own minimum for
  # the PerGB2018 SKU is also 30 days, so 30 is the only value that satisfies
  # both bounds at once.
  # PROD: retention_in_days = 90 (or higher) for compliance/audit trail needs.
  retention_in_days = var.retention_in_days # KK workaround

  tags = var.tags

  # Explicit depends_on (project standard): the data source dependency is
  # already implied via resource_group_name/location, but we state it
  # explicitly to keep the dependency graph readable.
  depends_on = [data.azurerm_resource_group.this]
}
