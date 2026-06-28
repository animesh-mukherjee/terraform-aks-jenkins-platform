# Module: servicebus

Creates the Azure Service Bus namespace and queues used for Jenkins pipeline event notifications.

## What this module creates

| Resource | Name | Purpose |
|---|---|---|
| `azurerm_servicebus_namespace` | `sb-<prefix>-<suffix>` | Basic SKU namespace (queue container) |
| `azurerm_servicebus_queue` | `build-events` | Build-completion notifications |
| `azurerm_servicebus_queue` | `deploy-events` | Deploy-completion notifications |

## Why two queues instead of one topic

The Basic SKU supports **queues only** — topics and subscriptions (pub/sub fan-out) require Standard or Premium. Two queues are used to separate build and deploy concerns: a consumer interested only in deploys doesn't need to filter out build messages.

**PROD**: upgrade to Standard SKU and replace the two queues with a single `pipeline-events` topic with `build-events` and `deploy-events` subscriptions filtered by message property. All existing publishers (Jenkins Stage 7) send to the topic; each subscriber type gets its own filtered feed.

## Queue settings

| Setting | Value | Reason |
|---|---|---|
| `lock_duration` | `PT5M` | 5 minutes for a consumer to process and ack a notification |
| `max_size_in_megabytes` | `1024` | Only valid value for Basic SKU queues (1 GB) |
| `default_message_ttl` | `P1D` | Notifications older than 24 hours are no longer actionable |
| `dead_lettering_on_message_expiration` | `true` | Expired messages go to DLQ for debugging instead of silent deletion |
| `max_delivery_count` | `5` | Dead-letter after 5 failed attempts to prevent consumer loops |

## KodeKloud constraints applied

| Constraint | Implementation |
|---|---|
| Basic namespace only | `sku = "Basic"` locked in main.tf |
| No topics/subscriptions | Two queues used instead |
| `local_auth_enabled = true` | Required on Basic (AAD auth is Standard/Premium only) |

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `resource_group_name` | string | — | KodeKloud-provided resource group |
| `prefix` | string | — | 3-11 char alphanumeric prefix |
| `location` | string | `eastus` | Azure region |
| `tags` | map(string) | `{}` | Common tags |

## Outputs

| Name | Sensitive | Description |
|---|---|---|
| `namespace_id` | no | Full Azure resource ID |
| `namespace_name` | no | Short namespace name |
| `primary_connection_string` | **yes** | RootManageSharedAccessKey connection string for Jenkins |
| `build_queue_name` | no | `"build-events"` |
| `deploy_queue_name` | no | `"deploy-events"` |
| `build_queue_id` | no | Full resource ID of build-events queue |
| `deploy_queue_id` | no | Full resource ID of deploy-events queue |

## Usage in root module

```hcl
module "servicebus" {
  source = "./modules/servicebus"

  resource_group_name = var.resource_group_name
  prefix              = var.prefix
  tags                = local.tags
}
```

## How Jenkins uses this

Jenkins Stage 7 (`Jenkinsfile.build` and `Jenkinsfile.deploy`) posts a JSON message to the appropriate queue using the Azure Service Bus SDK or `az servicebus message send`. The connection string is stored as a Jenkins credential (type: Secret Text) populated from Key Vault via JCasC.

## Verify after apply

```bash
# List queues in the namespace
az servicebus queue list \
  --resource-group <rg> \
  --namespace-name <namespace_name> \
  --query "[].{name:name, status:status}" \
  --output table

# Send a test message to build-events
az servicebus message send \
  --resource-group <rg> \
  --namespace-name <namespace_name> \
  --queue-name build-events \
  --body '{"pipeline":"test","status":"success"}'

# Peek at the message (non-destructive)
az servicebus message peek \
  --resource-group <rg> \
  --namespace-name <namespace_name> \
  --queue-name build-events
```
