# =============================================================================
# Module: postgresql
#
# Purpose: Creates the PostgreSQL Flexible Server used as the database backend
#          for the sample application deployed through the Jenkins pipeline.
#          The server is publicly accessible (KK has no custom VNet) and
#          restricted to Azure-internal traffic via a firewall rule.
#          Password is supplied from Key Vault (module.keyvault) via the
#          root module and injected into the K8s app secret in k8s-post/.
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

# PostgreSQL Flexible Server names: 3-63 chars, lowercase alphanumeric +
# hyphens, globally unique across Azure.
# "psql-" (5) + prefix (3-11) + "-" (1) + suffix (6) = 15-23 chars.
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

# Terraform concept: `azurerm_postgresql_flexible_server` provisions a managed
# PostgreSQL Flexible Server — Azure's current-generation fully managed
# PostgreSQL PaaS (Single Server is retired). "Flexible" means you have more
# control over compute tier, HA mode, and maintenance windows than the
# older Single Server model.
#
# Key attributes:
#   sku_name      — "<tier>_<vm_sku>" where tier is B (Burstable), GP
#                   (General Purpose), or MO (Memory Optimized). The VM SKU
#                   determines vCPU count and RAM.
#   storage_mb    — allocated disk in MB. The Flexible Server minimum is
#                   32768 MB (32 GB); KK's cap is also ≤32 GB, so 32768 is
#                   both the floor and ceiling here.
#   version       — PostgreSQL major version. 16 is the current GA release.
#   backup_retention_days — how many days point-in-time restore snapshots
#                   are kept. Range is 1-35; KK caps this at 7.
resource "azurerm_postgresql_flexible_server" "this" {
  name                = "psql-${var.prefix}-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location

  version = var.postgresql_version

  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password

  # Terraform concept: sku_name format is "<tier_prefix>_<azure_vm_sku>".
  # "B" = Burstable — the compute tier that allocates fractional CPU credits
  # and can burst above the baseline when credits are available. Ideal for
  # workloads with moderate average CPU but occasional spikes (e.g. a sample
  # app database serving CI pipeline tests rather than sustained production traffic).
  # Standard_B1ms = 1 vCPU / 2 GiB RAM — sufficient for the sample app.
  # KK constraint: Burstable tier only (Standard_B1ms or B2s).
  # PROD: "GP_Standard_D2s_v3" (General Purpose, 2 vCPU / 8 GiB) for
  # predictable latency without CPU credit exhaustion.
  sku_name = var.sku_name # KK workaround

  # KK constraint: disk ≤ 32 GB. 32768 MB = 32 GB.
  # The PostgreSQL Flexible Server minimum storage is also 32768 MB, so this
  # value is simultaneously the KK ceiling AND the service floor.
  # PROD: start at 128 GB (131072 MB) with auto-grow to avoid manual
  # resize operations under load.
  storage_mb = var.storage_mb # KK workaround

  # KK constraint: backup_retention_days ≤ 7.
  # PROD: 14-35 days; 30 days is a common compliance baseline.
  backup_retention_days = var.backup_retention_days # KK workaround

  # KK constraint: no HA. The high_availability block is intentionally
  # omitted — when absent, Flexible Server provisions a single-node instance
  # with no standby replica.
  # PROD: high_availability { mode = "ZoneRedundant" } with a standby in
  # a different availability zone for automatic failover.

  # KK: geo-redundant backup disabled — not needed on a session-based
  # playground and would add cost.
  # PROD: geo_redundant_backup_enabled = true for cross-region DR.
  geo_redundant_backup_enabled = false # KK workaround

  tags = var.tags

  # Explicit depends_on (project standard): data source dependency is already
  # implied by resource_group_name/location; stated explicitly for clarity.
  depends_on = [data.azurerm_resource_group.this]
}

# Terraform concept: `azurerm_postgresql_flexible_server_database` creates a
# logical database (schema namespace) inside the server. This is equivalent to
# running `CREATE DATABASE <name>` on the server. The sample app connects to
# this database, not to the default "postgres" admin database.
# charset/collation match standard PostgreSQL UTF-8 defaults.
resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  depends_on = [azurerm_postgresql_flexible_server.this]
}

# Terraform concept: `azurerm_postgresql_flexible_server_firewall_rule`
# controls which source IPs can reach the server over the public endpoint.
# The magic range 0.0.0.0–0.0.0.0 is interpreted by Azure as
# "allow all traffic originating from within the Azure datacenter IP space"
# (i.e. other Azure services, including AKS node egress IPs routed through
# the Standard Load Balancer).
# This is NOT the same as opening the server to the entire internet — Azure
# blocks non-Azure source IPs. It is the lightest-touch option that lets
# AKS pods reach PostgreSQL without knowing the outbound node IP in advance.
# PROD: replace public access with VNet integration:
#   delegated_subnet_id  = azurerm_subnet.psql.id
#   private_dns_zone_id  = azurerm_private_dns_zone.psql.id
# This confines the server to the cluster VNet with no public endpoint at all.
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"

  depends_on = [azurerm_postgresql_flexible_server.this]
}
