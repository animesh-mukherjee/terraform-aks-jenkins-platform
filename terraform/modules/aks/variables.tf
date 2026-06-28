variable "resource_group_name" {
  type        = string
  description = "Name of the existing KodeKloud-provided resource group. This module never creates a resource group (docs/decisions.md ADR-001)."
}

variable "prefix" {
  type        = string
  description = "Short lowercase alphanumeric prefix used to build resource names (\"aks-\" + prefix + \"-\" + 6-char suffix for the cluster, same for the DNS prefix). Must match the value used across all modules."

  validation {
    condition     = can(regex("^[a-z0-9]{3,11}$", var.prefix))
    error_message = "prefix must be 3-11 lowercase letters/digits."
  }
}

variable "location" {
  type        = string
  description = "Azure region. KodeKloud only permits eastus, westus, centralus, or southcentralus. This project standardizes on eastus."
  default     = "eastus"
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes minor version to deploy (e.g. \"1.29\"). null lets Azure pick the latest recommended GA version — fine for the playground since the cluster is rebuilt each session. Pin this in production so version upgrades are explicit."
  default     = null
}

variable "node_count" {
  type        = number
  description = "Number of nodes in the default node pool. KodeKloud caps this at 2. Two nodes give one for the Jenkins controller + NGINX ingress and one for Jenkins pod agents."
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 2
    error_message = "KodeKloud caps the node count at 2."
  }
}

variable "vm_size" {
  type        = string
  description = "VM size for every node in the default node pool. KodeKloud only permits Standard_D2s_v3 (4 vCPU / 8 GiB RAM). Each node comfortably fits Jenkins controller (2 CPU / 3 Gi limit) or three small pod agents."
  default     = "Standard_D2s_v3"

  validation {
    condition     = var.vm_size == "Standard_D2s_v3"
    error_message = "KodeKloud only permits Standard_D2s_v3 for AKS node VMs."
  }
}

variable "os_disk_size_gb" {
  type        = number
  description = "OS disk size in GB for each node VM. KodeKloud caps storage disks at 128 GB; 64 GB is enough for the OS plus cached container image layers."
  default     = 64

  validation {
    condition     = var.os_disk_size_gb >= 30 && var.os_disk_size_gb <= 128
    error_message = "os_disk_size_gb must be 30–128 (KodeKloud storage cap is 128 GB)."
  }
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "Full Azure resource ID of the Log Analytics Workspace (output of module.loganalytics). Passed to the oms_agent block so Container Insights ships cluster and pod telemetry to that workspace."
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags applied to every resource created by this module."
  default     = {}
}
