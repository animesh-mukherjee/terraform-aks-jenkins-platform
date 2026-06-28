# =============================================================================
# Module: aks
#
# Purpose: Creates the AKS cluster — the runtime platform for the entire
#          Jenkins CI/CD pipeline. Two Standard_D2s_v3 nodes share a single
#          node pool (KodeKloud allows only 1 pool). Per-node taints and
#          labels (Node 1 → controller, Node 2 → agent) cannot be expressed
#          at pool level in Terraform when both nodes share the same pool;
#          they are applied by kubectl in terraform/k8s-post/ after the
#          cluster is ready.
#          Container Insights is wired to the Log Analytics Workspace from
#          module.loganalytics so AKS ships cluster/pod logs and metrics
#          without any third-party monitoring stack.
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

# AKS cluster names: 1-63 chars, alphanumeric + hyphens, unique within RG.
# "aks-" (4) + prefix (3-11) + "-" (1) + suffix (6) = 14-22 chars.
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

# Terraform concept: `azurerm_kubernetes_cluster` provisions a fully managed
# Kubernetes control plane (API server, etcd, scheduler, controller-manager)
# hosted by Azure. You pay only for worker nodes — the control plane is free
# on the Free SKU tier. Key attributes to understand:
#
#   dns_prefix        — used to build the API server FQDN:
#                       <dns_prefix>.<location>.azmk8s.io
#   sku_tier          — Free = no SLA; Standard = 99.95% SLA. Free is enough
#                       for the KK playground.
#   identity          — tells AKS which MSI the control plane uses to manage
#                       Azure resources (load balancers, NICs, etc.) in the
#                       auto-generated MC_ node resource group.
#   default_node_pool — the single mandatory pool; every cluster requires
#                       exactly one. Additional pools are blocked on KK.
#   oms_agent         — enables Container Insights (Azure Monitor for AKS);
#                       AKS deploys an OMS DaemonSet that ships container
#                       stdout/stderr, pod inventory, and CPU/memory metrics
#                       to the specified Log Analytics Workspace.
#   network_profile   — CNI choice and load-balancer SKU.
resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${var.prefix}-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  dns_prefix          = "${var.prefix}-${random_string.suffix.result}"

  # kubernetes_version = null → Azure picks the latest recommended GA version.
  # Pin to a specific minor version (e.g. "1.29") in production so upgrades
  # are explicit and tested. Here null is fine because the playground is
  # rebuilt from scratch each session.
  kubernetes_version = var.kubernetes_version

  # KK constraint: Free tier has no SLA but costs nothing extra.
  # PROD: sku_tier = "Standard" for 99.95% control-plane SLA.
  sku_tier = "Free" # KK workaround

  # Terraform concept: `default_node_pool` is the single mandatory node pool.
  # With KodeKloud's 1-pool limit both Jenkins controller and agent pods share
  # this pool. Per-node placement (Node 1 = controller, Node 2 = agents) is
  # enforced at the K8s layer via taints and labels applied post-creation in
  # terraform/k8s-post/, not here in Terraform.
  default_node_pool {
    name = "default"

    # KK constraint: max 2 nodes; this is the project's target count.
    # PROD: enable auto_scaling_enabled = true with min/max_count instead
    # of a fixed node_count, sized to actual workload.
    node_count           = var.node_count      # KK workaround
    auto_scaling_enabled = false

    # KK constraint: Standard_D2s_v3 is the only permitted VM size.
    # PROD: choose a size based on workload profiling (e.g. Standard_D4s_v3
    # for heavier Jenkins builds).
    vm_size = var.vm_size # KK workaround

    # KK constraint: disk ≤ 128 GB. 64 GB is enough for OS + container layers.
    # PROD: 128 GB managed disk or an ephemeral OS disk (faster node boot,
    # zero extra cost for ephemeral on D-series).
    os_disk_size_gb = var.os_disk_size_gb # KK workaround

    # Terraform concept: `upgrade_settings.max_surge` controls how many extra
    # nodes AKS can provision during a node-image or Kubernetes version upgrade
    # (surge = extra capacity so old nodes drain before new ones are removed).
    # "1" means at most 1 surplus node — safe for a 2-node pool.
    # PROD: "33%" is a common rule-of-thumb for larger pools.
    upgrade_settings {
      max_surge = "1"
    }
  }

  # Terraform concept: `identity { type = "SystemAssigned" }` creates and
  # manages an Azure Managed Identity for the AKS control plane automatically.
  # AKS uses this MSI to manage the MC_ node resource group (create load
  # balancers, attach NICs, manage public IPs). No client secret to rotate.
  # The worker nodes get their own separate kubelet_identity MSI (exposed in
  # outputs) used for node-level operations (e.g. image pulls, Key Vault).
  # PROD: `type = "UserAssigned"` gives explicit control over the MSI lifecycle
  # and lets you pre-assign permissions before cluster creation.
  identity {
    type = "SystemAssigned"
  }

  # Terraform concept: `oms_agent` enables Azure Monitor Container Insights.
  # AKS deploys the OMS DaemonSet on every node. It collects:
  #   - Container stdout/stderr (searchable in Log Analytics via ContainerLog table)
  #   - Pod inventory (KubePodInventory)
  #   - Node and pod CPU/memory (Perf table)
  # `msi_auth_for_monitoring_enabled = true` tells the OMS agent to authenticate
  # to the workspace using the cluster's MSI rather than a shared workspace key.
  # KK constraint: alerting = DISABLED — we wire the workspace but create NO
  # alert rules, action groups, or metric alerts. This module only ships
  # telemetry; alerting infra is intentionally omitted on the playground.
  # PROD: add azurerm_monitor_metric_alert resources for node CPU, memory
  # pressure, pod restart rate, and OOMKilled counts.
  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  # Terraform concept: `network_profile` sets the cluster-level network model.
  #
  #   network_plugin = "kubenet"
  #     The simpler overlay model: pods get IPs from a private RFC-1918
  #     range (10.244.0.0/16 by default) that exists only inside the cluster.
  #     Node-to-pod traffic is NAT'd via the node's IP. Requires fewer Azure
  #     VNet IPs than Azure CNI (which needs a VNet IP per pod).
  #     Good fit here: we have no custom VNet, no integration with other VNet
  #     services, and kubenet's IP usage is minimal.
  #
  #   load_balancer_sku = "standard"
  #     Required for AKS clusters that need external traffic (inbound to
  #     services of type LoadBalancer). The Basic LB is deprecated in AKS.
  #     Standard LB also supports multiple frontends and outbound rules.
  #
  # PROD: network_plugin = "azure" (Azure CNI) if pods need direct VNet
  # reachability from on-prem or other VNets; requires pre-sized VNet subnet.
  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
  }

  tags = var.tags

  # Explicit depends_on (project standard): the data source dependency is
  # already implied via resource_group_name/location, but we state it
  # explicitly to keep the dependency graph readable.
  depends_on = [data.azurerm_resource_group.this]
}
