# =============================================================================
# Module: aci
#
# Purpose: Defines the Container Instance used as a one-shot DB migration
#          runner. Jenkins Stage 4 creates/replaces this container with the
#          actual migration image, waits for it to exit, checks the exit code,
#          then continues. Terraform manages the "shape" (CPU, memory, env
#          vars, registry credentials, restart policy); Jenkins manages the
#          lifecycle of each migration run.
#
# One-shot pattern:
#   restart_policy = "Never" → container runs once and stops (Terminated state)
#   lifecycle.ignore_changes = [container[0].image] → Terraform does not revert
#     the image after Jenkins replaces it with <acr>/db-migrate:<commit-sha>
#
# Jenkins Stage 4 workflow:
#   1. az container delete --yes   (remove previous run if any)
#   2. az container create         (new run with migration image + commit SHA)
#   3. az container wait --condition Terminated
#   4. az container show → check instanceView.currentState.exitCode == 0
#   5. Continue or fail the pipeline
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

# ACI container group names must be unique within the resource group.
# "aci-migrate-" (12) + prefix (3-11) + "-" (1) + suffix (6) = 22-30 chars.
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

# Terraform concept: `azurerm_container_group` provisions an Azure Container
# Instance group. A group is the unit of scheduling — all containers in a
# group share the same host node, network namespace, and lifecycle.
# For a single migration job we use exactly one container per group.
#
# Key attributes:
#   os_type          — "Linux" or "Windows". Linux is required for most
#                       Docker Hub / ACR images.
#   restart_policy   — "Always" (long-running service) | "OnFailure" (retry
#                       on error) | "Never" (run once and stop). "Never" is
#                       the one-shot batch pattern: the container runs its
#                       command, exits, and the group stays in Terminated state.
#   ip_address_type  — "Public" assigns a public IP to the group. The migration
#                       container does not accept inbound connections (no ports
#                       exposed), but it DOES need outbound connectivity to
#                       reach PostgreSQL's public endpoint. A "Public" IP
#                       provides outbound NAT through that IP.
#                       KK playground has no custom VNet, so "Private"
#                       (VNet-delegated subnet) is not available.
#                       PROD: use "Private" with a VNet-delegated subnet and
#                       private endpoint for PostgreSQL — no public exposure.
resource "azurerm_container_group" "migration" {
  name                = "aci-migrate-${var.prefix}-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  os_type             = "Linux"

  # One-shot: run the migration command once and stop. Jenkins watches for the
  # Terminated state then reads instanceView.currentState.exitCode.
  restart_policy = "Never"

  # Public IP provides outbound TCP to the PostgreSQL public endpoint.
  # No ports are exposed (migration runner doesn't accept inbound connections).
  # KK constraint: no custom VNet → cannot use Private ip_address_type.
  # PROD: ip_address_type = "Private" with a VNet-delegated subnet.
  ip_address_type = "Public" # KK workaround

  # Terraform concept: the `container` block defines a single container within
  # the group. Multiple containers share the group's IP and can communicate
  # on localhost — useful for sidecar patterns (init containers, log shippers).
  # For this one-shot migration runner, exactly one container is needed.
  container {
    name = "db-migrate"

    # Placeholder image used for the initial Terraform apply before the actual
    # migration image is built and pushed to ACR by a Jenkins build.
    # alpine:3.19 starts and immediately exits with code 0 (no default command),
    # which puts the container group in Terminated state — correct behaviour
    # for restart_policy = "Never".
    # lifecycle.ignore_changes below prevents Terraform from reverting to this
    # placeholder after Jenkins replaces it with <acr>/db-migrate:<sha>.
    image = var.migration_image

    # KK constraint: CPU 0.25–2 cores, Memory 0.5–4 GB.
    # 0.5 CPU / 1.0 GB is enough for running Node.js / Flyway / Alembic
    # migration scripts against a B1ms PostgreSQL server.
    # PROD: tune based on migration runtime; 1 CPU / 2 GB is a safe default.
    cpu    = var.cpu_cores    # KK workaround (max 2.0)
    memory = var.memory_gb    # KK workaround (max 4.0)

    # Plain-text env vars: safe to log and visible in the Azure Portal.
    # These are connection parameters but NOT the password.
    environment_variables = {
      DB_HOST = var.db_host
      DB_PORT = "5432"
      DB_NAME = var.db_name
      DB_USER = var.db_user
      # SSL is required by Azure PostgreSQL Flexible Server.
      DB_SSL  = "true"
    }

    # Terraform concept: `secure_environment_variables` masks values in the
    # Azure Portal UI and strips them from ARM template exports. The values
    # ARE still stored in Terraform state (encrypt your backend). Use this
    # block for passwords and tokens that should not appear in logs or portal
    # screenshots — not as a substitute for proper secret management.
    secure_environment_variables = {
      DB_PASSWORD = var.db_password
    }
  }

  # Terraform concept: `image_registry_credential` provides authentication for
  # private container registries. When Jenkins replaces the image with
  # <acr_login_server>/db-migrate:<sha>, ACI needs these credentials to pull
  # the image. The ACR admin username/password come from module.acr outputs
  # (admin_enabled = true is set in module.acr, see ADR-002 in decisions.md).
  # PROD: replace with a User-Assigned Managed Identity with AcrPull role
  # once Azure role assignments are available (not on KK playground).
  image_registry_credential {
    server   = var.acr_login_server
    username = var.acr_username
    password = var.acr_password
  }

  # Terraform concept: `lifecycle.ignore_changes` tells Terraform to detect
  # but not fix drift in the listed attributes. Without this block, every
  # `terraform apply` after Jenkins swaps the migration image would revert the
  # container back to the placeholder image.
  # `container[0].image` targets the `image` attribute of the first (and only)
  # container in the group. After the initial apply with the placeholder, all
  # subsequent image changes are owned by the Jenkins pipeline.
  lifecycle {
    ignore_changes = [container[0].image]
  }

  tags = var.tags

  depends_on = [data.azurerm_resource_group.this]
}
