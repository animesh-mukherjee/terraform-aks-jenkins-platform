# Module: dns

Creates the `platform.internal` Azure Private DNS Zone and optionally links it to the AKS VNet for internal service discovery.

## What this module creates

| Resource | Name | Purpose |
|---|---|---|
| `azurerm_private_dns_zone` | `platform.internal` | Private zone for internal FQDNs |
| `azurerm_private_dns_zone_virtual_network_link` | `link-aks-<prefix>` | Links zone to AKS VNet (conditional) |

DNS A records (e.g. `jenkins.platform.internal`) are **not** created here — their IPs (NGINX ingress LoadBalancer IP) are unknown until after Helm deploys Jenkins. Records are added in `terraform/k8s-post/` once the IP is available.

## How the full resolution chain works

```
Pod inside cluster
  → CoreDNS (patched in k8s-post/ to forward platform.internal)
    → Azure DNS resolver (168.63.129.16)
      → Private DNS Zone (platform.internal, linked to AKS VNet)
        → A record: jenkins.platform.internal → <ingress-ip>
```

Without the CoreDNS patch, pods resolve `<svc>.<ns>.svc.cluster.local` (Kubernetes native) but cannot resolve `platform.internal` names. With it, both namespaces work.

## VNet link — why it is conditional

KodeKloud kubenet AKS creates its own VNet in the auto-generated `MC_` resource group. The VNet ID is not known at plan time (before AKS exists). The root module uses `data "azurerm_resources"` after AKS is created to look up the VNet ID, then passes it to this module.

Set `aks_vnet_id = ""` (default) during initial bootstrapping. Once the AKS cluster is up, re-run with the VNet ID.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `resource_group_name` | string | — | KodeKloud-provided resource group |
| `prefix` | string | — | 3-11 char alphanumeric prefix |
| `zone_name` | string | `"platform.internal"` | Private DNS zone name |
| `aks_vnet_id` | string | `""` | AKS VNet resource ID (empty = no VNet link) |
| `tags` | map(string) | `{}` | Common tags |

## Outputs

| Name | Description |
|---|---|
| `zone_id` | Full resource ID of the DNS zone |
| `zone_name` | Zone name (e.g. `"platform.internal"`) |
| `vnet_link_id` | VNet link resource ID, or `null` if not created |

## Usage in root module

```hcl
# Step 1 — look up the VNet that kubenet AKS created in its MC_ resource group
data "azurerm_resources" "aks_vnet" {
  resource_group_name = module.aks.node_resource_group
  type                = "Microsoft.Network/virtualNetworks"

  depends_on = [module.aks]
}

module "dns" {
  source = "./modules/dns"

  resource_group_name = var.resource_group_name
  prefix              = var.prefix
  aks_vnet_id         = data.azurerm_resources.aks_vnet.resources[0].id
  tags                = local.tags

  depends_on = [module.aks]
}
```

## Verify after apply

```bash
# Confirm the zone exists
az network private-dns zone show \
  --resource-group <rg> \
  --name platform.internal

# Confirm the VNet link is Active
az network private-dns link vnet show \
  --resource-group <rg> \
  --zone-name platform.internal \
  --name link-aks-<prefix> \
  --query "virtualNetworkLinkState"
# Expected: "Completed"

# After k8s-post/ adds A records, test resolution from a debug pod
kubectl run dns-test --image=busybox --restart=Never --rm -it -- \
  nslookup jenkins.platform.internal
```
