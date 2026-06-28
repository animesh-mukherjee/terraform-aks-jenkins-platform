# Module: aks

Creates the AKS cluster that hosts the entire Jenkins CI/CD platform.

## What this module creates

| Resource | Name pattern | Purpose |
|---|---|---|
| `azurerm_kubernetes_cluster` | `aks-<prefix>-<suffix>` | Managed Kubernetes cluster (2× Standard_D2s_v3) |

## KodeKloud constraints applied

| Constraint | Implementation |
|---|---|
| Standard_D2s_v3 only | `vm_size` variable locked via validation |
| 1 node pool max | Single `default_node_pool` block; no additional pools |
| 2 nodes max | `node_count = 2`, `auto_scaling_enabled = false` |
| alerting=DISABLED | OMS agent wired for log collection only; no alert rules created |
| Disk ≤ 128 GB | `os_disk_size_gb = 64` |

## Per-node placement (applied AFTER this module)

The two nodes in the pool serve different roles, enforced at the Kubernetes layer in `terraform/k8s-post/`:

| Node | Taint / Label | Workloads |
|---|---|---|
| Node 1 | Taint: `dedicated=controller:NoSchedule` | Jenkins controller, NGINX ingress |
| Node 2 | Label: `dedicated=agent` | Jenkins dynamic pod agents |

These cannot be set differently per node at the Terraform pool level — `terraform/k8s-post/` applies them via `kubectl taint` and `kubectl label` after the cluster is ready.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `resource_group_name` | string | — | KodeKloud-provided resource group |
| `prefix` | string | — | 3-11 char alphanumeric prefix |
| `location` | string | `eastus` | Azure region |
| `kubernetes_version` | string | `null` | Pin K8s version; null = Azure picks latest |
| `node_count` | number | `2` | Nodes in default pool (KK max: 2) |
| `vm_size` | string | `Standard_D2s_v3` | Node VM size (KK: only this size allowed) |
| `os_disk_size_gb` | number | `64` | Node OS disk size in GB (KK max: 128) |
| `log_analytics_workspace_id` | string | — | From `module.loganalytics.workspace_id` |
| `tags` | map(string) | `{}` | Common tags |

## Outputs

| Name | Sensitive | Description |
|---|---|---|
| `cluster_id` | no | Full Azure resource ID |
| `cluster_name` | no | Short name for `az aks get-credentials` |
| `node_resource_group` | no | Auto-generated MC_ resource group |
| `kube_config_raw` | **yes** | Full kubeconfig YAML |
| `host` | **yes** | API server HTTPS endpoint |
| `client_certificate` | **yes** | Client TLS cert (base64) |
| `client_key` | **yes** | Client TLS key (base64) |
| `cluster_ca_certificate` | **yes** | Cluster CA cert (base64) |
| `kubelet_identity_object_id` | no | Kubelet MSI object ID |
| `kubelet_identity_client_id` | no | Kubelet MSI client ID |

## Usage in root module

```hcl
module "aks" {
  source = "./modules/aks"

  resource_group_name        = var.resource_group_name
  prefix                     = var.prefix
  log_analytics_workspace_id = module.loganalytics.workspace_id
  tags                       = local.tags
}
```

## Verify after apply

```bash
# Download kubeconfig
az aks get-credentials \
  --resource-group <rg> \
  --name <cluster_name> \
  --overwrite-existing

# Confirm 2 nodes are Ready
kubectl get nodes -o wide

# Confirm Container Insights DaemonSet is running on both nodes
kubectl get ds -n kube-system | grep omsagent

# Check logs are flowing (takes ~5 min after cluster creation)
az monitor log-analytics query \
  --workspace <workspace_id> \
  --analytics-query "KubePodInventory | take 5"
```
