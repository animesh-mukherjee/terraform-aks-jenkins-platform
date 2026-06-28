variable "resource_group_name" {
  type        = string
  description = "Name of the KodeKloud-provided resource group. Used as the resource_group_name key in the terraform_remote_state backend config block so this root can read the main root's outputs."
}

variable "storage_account_name" {
  type        = string
  description = "Name of the Terraform state storage account (output of module.storage). Used as the storage_account_name key in the terraform_remote_state backend config block. Passed by bootstrap.sh Phase 4 via -var."
}

variable "kube_config_path" {
  type        = string
  description = "Path to the kubeconfig file the kubernetes provider uses to authenticate to AKS. bootstrap.sh calls `az aks get-credentials` before applying this root, which writes the credentials to this path."
  default     = "~/.kube/config"
}
