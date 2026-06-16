# =============================================================================
# Module: storage
#
# Purpose: Creates the Azure Storage Account + blob container that Terraform
#          uses as its REMOTE STATE BACKEND (the azurerm backend).
#
# This is the FIRST module bootstrap.sh applies (Phase 1, with local state) —
# see docs/decisions.md ADR-006 for why a two-phase apply is needed.
# =============================================================================

# Terraform concept: the `terraform` block configures Terraform itself, not a
# resource. `required_providers` declares which provider PLUGINS this module
# needs and which versions are acceptable.
#
# Child modules should declare required_providers, but should NOT contain a
# `provider "azurerm" { ... }` configuration block. The actual provider
# configuration (credentials, the `features {}` block) lives once in the ROOT
# module (terraform/versions.tf + terraform/main.tf) and every module it calls
# inherits that single configuration.
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

# Terraform concept: a `data` block is a READ-ONLY lookup of something that
# already exists. It creates/changes/destroys nothing — Terraform just reads
# the object's current attributes (here: name + location) so other resources
# in this module can reference them.
#
# PROD: in a normal subscription, this module's caller would provision the
# resource group itself with `resource "azurerm_resource_group"`. KodeKloud
# forbids creating resource groups, so every module in this project instead
# reads the session-provided RG via this data source (docs/decisions.md ADR-001).
data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

# Terraform concept: `resource "random_string"` comes from the `random`
# provider (it manages local randomness, not Azure objects). The generated
# value is PERSISTED in Terraform state, so it stays stable across future
# plans/applies — it only changes if this resource is destroyed or its
# arguments (length, character classes) change.
#
# Why we need it: Azure Storage Account names must be globally unique across
# ALL of Azure, 3-24 characters, lowercase letters and digits only. A fixed
# name like "staksjenkins" could collide with another KodeKloud user's
# account. Appending a random suffix keeps the name unique without us picking
# one by hand — this is the project's naming convention (var.prefix + random
# suffix) applied for the first time.
resource "random_string" "storage_suffix" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

# Terraform concept: a `resource` block is the core building block — it
# declares a real Azure object that Terraform will create, update, or delete
# to match this configuration. The label after the type ("state") is a LOCAL
# name used to reference this resource elsewhere in the config, e.g.
# azurerm_storage_account.state.id below.
resource "azurerm_storage_account" "state" {
  # Storage account names: 3-24 chars, lowercase letters/digits only,
  # globally unique. "st" + prefix + 6-char random suffix stays well under
  # the limit (the prefix length is constrained by validation in variables.tf).
  name                = "st${var.prefix}${random_string.storage_suffix.result}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location

  # KK constraint: Storage must be Standard_LRS or Standard_RAGRS, disk <=128GB,
  # no Premium. LRS (locally-redundant) is the cheapest tier and is sufficient
  # for an ephemeral, per-session state backend.
  # PROD: use GRS or ZRS for the state backend so Terraform state survives a
  # regional outage — losing state in production is a serious incident.
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # Security baseline: enforce TLS 1.2 and block any public/anonymous access
  # to blob data at the account level (the container below is also "private").
  min_tls_version                  = "TLS1_2"
  allow_nested_items_to_be_public  = false

  tags = var.tags

  # Explicit depends_on (project standard): the dependency on the resource
  # group is already implied by resource_group_name/location above, but we
  # state it explicitly to make the dependency graph obvious while learning.
  depends_on = [data.azurerm_resource_group.this]
}

# Terraform concept: this resource lives "inside" the storage account above —
# a blob CONTAINER is the unit the azurerm Terraform backend points at via its
# `container_name` argument (see terraform/backend.tf, built in Step 12).
#
# azurerm 4.x syntax note: the container is linked to its account via
# storage_account_id (a full resource ID). Older (3.x) examples you may find
# online use storage_account_name instead — that argument was removed in 4.x
# (see docs/decisions.md ADR-007 on why this project targets azurerm 4.x).
resource "azurerm_storage_container" "tfstate" {
  name                  = var.state_container_name
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"

  depends_on = [azurerm_storage_account.state]
}
