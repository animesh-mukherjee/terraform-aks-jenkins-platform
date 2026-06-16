# =============================================================================
# Module: acr
#
# Purpose: Creates the Azure Container Registry (ACR) that stores every Docker
#          image produced by Jenkins agents. AKS pulls from this registry
#          during Helm deployments using a Kubernetes imagePullSecret (built in
#          Step 13, terraform/k8s-post/) because ACR role assignments are
#          blocked on the KodeKloud playground (docs/decisions.md ADR-002).
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

# ACR names: 5-50 chars, alphanumeric only, globally unique across Azure.
# "acr" (3) + prefix (3-11) + suffix (6) = 12-20 chars — safely within limits.
resource "random_string" "acr_suffix" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

# Terraform concept: `azurerm_container_registry` provisions an Azure Container
# Registry — a fully managed private Docker / OCI-artifact registry. Jenkins
# agents push images to it after a successful build; AKS pods pull from it
# at deploy time. The key attributes to understand are:
#
#   login_server  — the FQDN you use in Docker commands:
#                   `docker push <login_server>/myapp:latest`
#   admin_enabled — when true, Azure generates a static username + password
#                   pair that can be read back via `azurerm_container_registry`
#                   outputs (admin_username, admin_password). We store these in
#                   Key Vault and create a K8s imagePullSecret from them.
#   sku           — the pricing / feature tier (Basic → Standard → Premium).
resource "azurerm_container_registry" "this" {
  # Name rules: 5-50 chars, alphanumeric, globally unique.
  name                = "acr${var.prefix}${random_string.acr_suffix.result}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location

  # KK constraint: ACR must be Basic or Standard; Premium is not available.
  # Architecture uses Standard because it gives 100 GB included storage and
  # webhooks (vs Basic's 10 GB), with no extra cost on the playground.
  # PROD: Standard or Premium — Premium adds geo-replication, content trust,
  # private link, and customer-managed keys.
  sku = var.sku

  # KK constraint: assigning AcrPull to the AKS kubelet Managed Identity via
  # azurerm_role_assignment is blocked on the playground (docs/decisions.md
  # ADR-002). Enabling admin credentials is the fallback: the generated
  # username/password are stored in Key Vault (module.keyvault, Step 4) and
  # used to create a K8s imagePullSecret (module.k8s_post, Step 13).
  # PROD: set admin_enabled = false and assign the AcrPull built-in role to
  # the AKS kubelet managed identity — MSI avoids static credentials entirely.
  admin_enabled = true

  tags = var.tags

  # Explicit depends_on (project standard): the data source dependency is
  # already implied via resource_group_name/location, but we state it
  # explicitly to keep the dependency graph readable.
  depends_on = [data.azurerm_resource_group.this]
}
