# =============================================================================
# Module: servicebus
#
# Purpose: Creates the Azure Service Bus namespace and the two queues used
#          for build and deploy event notifications in the Jenkins pipeline.
#          Stage 7 of every Jenkinsfile posts a message to the appropriate
#          queue after a build or deploy completes so downstream consumers
#          (monitoring, ticketing, Slack bots) can react without polling Jenkins.
#
# Basic SKU restriction: Basic namespaces support queues ONLY.
# Topics and subscriptions (pub/sub fan-out) require Standard or Premium.
# Two separate queues are used instead: build-events and deploy-events.
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

# Service Bus namespace names: 6-50 chars, alphanumeric + hyphens,
# globally unique across Azure.
# "sb-" (3) + prefix (3-11) + "-" (1) + suffix (6) = 13-21 chars.
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

# Terraform concept: `azurerm_servicebus_namespace` provisions a Service Bus
# namespace — the top-level container that owns all messaging entities
# (queues, topics, subscriptions). Think of it as the "server" in a
# traditional message broker analogy.
#
# Key attributes:
#   sku           — determines available features and pricing:
#                   Basic  = queues only, 256 KB max message, no topics
#                   Standard = queues + topics/subscriptions, 256 KB max message
#                   Premium = VNet integration, large messages (100 MB), MSI auth
#   local_auth_enabled — when true, clients can authenticate with SAS keys
#                   (connection strings). Basic SKU requires this to be true
#                   because AAD-based auth is a Standard/Premium feature.
resource "azurerm_servicebus_namespace" "this" {
  name                = "sb-${var.prefix}-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location

  # KK constraint: Basic namespace only.
  # PROD: "Standard" to unlock topics/subscriptions for proper fan-out
  # (one build event → multiple subscribers: Slack, ticketing, metrics).
  sku = "Basic" # KK workaround

  # Basic SKU requires SAS key auth (AAD auth is Standard/Premium only).
  # PROD: local_auth_enabled = false once migrated to Standard and
  # Managed Identity auth is configured for all producers/consumers.
  local_auth_enabled = true

  tags = var.tags

  depends_on = [data.azurerm_resource_group.this]
}

# Terraform concept: `azurerm_servicebus_queue` creates a named queue inside
# a namespace. A queue is a first-in, first-out (FIFO) message store with
# at-least-once delivery semantics: a receiver locks a message, processes it,
# then deletes it. If the lock expires before deletion, the message becomes
# visible again for re-delivery (up to max_delivery_count times).
#
# Key queue attributes:
#   lock_duration              — how long a receiver holds the message lock
#                                before it is automatically released. ISO 8601
#                                duration; maximum on Basic is PT5M.
#   max_size_in_megabytes      — total queue storage quota. Valid values on
#                                Basic: 1024 MB (1 GB). Higher values need
#                                Standard/Premium.
#   default_message_ttl        — how long an unconsumed message lives before
#                                it is expired. ISO 8601 duration.
#   dead_lettering_on_message_expiration — when true, expired messages are
#                                moved to the queue's dead-letter sub-queue
#                                (suffix /$DeadLetterQueue) instead of being
#                                silently deleted. Useful for debugging missed
#                                notifications.
#   max_delivery_count         — how many delivery attempts before a message
#                                is automatically dead-lettered.

# Queue for build-completion events (success or failure).
# Jenkins Stage 7 publishes here after every build so consumers know the
# outcome without polling the Jenkins API.
resource "azurerm_servicebus_queue" "build_events" {
  name         = "build-events"
  namespace_id = azurerm_servicebus_namespace.this.id

  # PT5M = 5 minutes. Gives consumers enough time to process and acknowledge
  # a build notification before the lock auto-releases.
  lock_duration = "PT5M"

  # 1024 MB is the only valid value for Basic SKU queues.
  # PROD: up to 80 GB on Premium for high-throughput pipelines.
  max_size_in_megabytes = 1024 # KK workaround (Basic cap)

  # Build notifications are only actionable for a short window — if a
  # consumer hasn't picked them up in 24 hours, they are no longer useful.
  # P1D = 1 day (ISO 8601 period).
  default_message_ttl = "P1D"

  # Move expired build events to the DLQ so we can inspect missed notifications
  # during pipeline debugging rather than silently losing them.
  dead_lettering_on_message_expiration = true

  # After 5 failed delivery attempts the message is dead-lettered so a
  # repeatedly failing consumer doesn't block the queue indefinitely.
  max_delivery_count = 5

  depends_on = [azurerm_servicebus_namespace.this]
}

# Queue for deploy-completion events (Helm deploy to dev or staging).
# Jenkins Stage 7 publishes here after a successful Helm rollout so
# downstream watchers (e.g. integration test triggers, change-management
# tools) can react without polling Kubernetes.
resource "azurerm_servicebus_queue" "deploy_events" {
  name         = "deploy-events"
  namespace_id = azurerm_servicebus_namespace.this.id

  lock_duration         = "PT5M"
  max_size_in_megabytes = 1024 # KK workaround (Basic cap)
  default_message_ttl   = "P1D"

  dead_lettering_on_message_expiration = true
  max_delivery_count                   = 5

  depends_on = [azurerm_servicebus_namespace.this]
}
