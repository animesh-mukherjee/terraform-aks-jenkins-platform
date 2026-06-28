# =============================================================================
# versions.tf — Terraform version constraints and provider configurations.
#
# Only the ROOT MODULE configures providers. Child modules declare
# `required_providers` for tooling, but have no `provider {}` block —
# they inherit the single provider instance configured here.
# =============================================================================

# Terraform concept: the root `terraform {}` block sets the minimum Terraform
# CLI version and locks provider versions for the whole project.
# `required_version` uses constraint syntax:
#   >= 1.9  — any version 1.9 or later (no upper bound)
# Provider versions use the pessimistic-constraint operator (~>):
#   ~> 4.0  — >= 4.0.0 AND < 5.0.0 (allows patch/minor, blocks major bumps)
terraform {
  required_version = ">= 1.9"

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

# Terraform concept: `provider "azurerm"` is the single configuration block
# for the Azure provider. Credentials (subscription ID, client ID, secret,
# tenant ID) are NOT hardcoded here — they come from environment variables:
#   ARM_SUBSCRIPTION_ID, ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID
# bootstrap.sh exports these from the KodeKloud session credentials before
# running terraform init / plan / apply.
#
# The `features {}` block is REQUIRED in azurerm 4.x even when empty.
# It controls provider-level lifecycle behaviour for certain resource types.
provider "azurerm" {
  features {
    # Terraform concept: the `key_vault` features block controls how the
    # provider handles Key Vault soft-delete lifecycle during `terraform destroy`.
    #
    # purge_soft_delete_on_destroy = true
    #   When Terraform destroys the Key Vault (and its secrets), it also
    #   permanently purges the soft-deleted vault immediately. Without this,
    #   the vault enters a 7-day soft-delete period — during which the name
    #   is reserved and cannot be reused. On KK playground, sessions are
    #   restarted frequently with the same prefix, so purging on destroy
    #   prevents "vault name already in use" errors on the next session.
    #   PROD: set to false — soft-delete is a safety net against accidental
    #   permanent loss of secrets. Never purge automatically in production.
    #
    # purge_soft_deleted_secrets_on_destroy = true
    #   Same logic applied to individual secrets within the vault.
    #
    # recover_soft_deleted_key_vaults = false
    #   When creating a vault, do NOT attempt to recover a soft-deleted vault
    #   with the same name. On KK, a prior session may have left a soft-deleted
    #   vault with the same name; we want a clean create, not a recovery.
    #   PROD: set to true so accidental deletes can be reversed by re-applying.
    key_vault {
      purge_soft_delete_on_destroy          = true  # KK workaround
      purge_soft_deleted_secrets_on_destroy = true  # KK workaround
      recover_soft_deleted_key_vaults       = false # KK workaround
    }
  }
}

provider "random" {}
