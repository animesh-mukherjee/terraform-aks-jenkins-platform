# =============================================================================
# k8s-post/versions.tf
#
# This is a SEPARATE Terraform root from terraform/. It runs AFTER the main
# root has provisioned all Azure resources and bootstrap.sh has called:
#   az aks get-credentials --resource-group $RG --name $CLUSTER --overwrite-existing
#
# Three providers are needed here:
#   azurerm    — to read Key Vault secrets (ACR credentials) for imagePullSecrets
#   kubernetes — to create namespaces, secrets, ConfigMaps on the AKS cluster
#   null       — for null_resource local-exec blocks (node taint/label, CoreDNS restart)
#
# Provider auth:
#   azurerm    — ARM_* env vars set by bootstrap.sh (same as root module)
#   kubernetes — reads ~/.kube/config written by `az aks get-credentials`
#   null       — no auth needed
# =============================================================================

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy          = true
      purge_soft_deleted_secrets_on_destroy = true
      recover_soft_deleted_key_vaults       = false
    }
  }
}

# Terraform concept: the kubernetes provider authenticates to the cluster using
# the kubeconfig file at `config_path`. bootstrap.sh populates ~/.kube/config
# with `az aks get-credentials` before applying this root. The provider then
# uses the cluster-admin certificate credentials from that file.
#
# Alternative: pass host/client_certificate/client_key/cluster_ca_certificate
# directly from terraform_remote_state — but provider blocks cannot reference
# data sources (they are evaluated before data sources). Using config_path
# sidesteps that constraint cleanly.
provider "kubernetes" {
  config_path = var.kube_config_path
}

provider "null" {}
