# =============================================================================
# k8s-post/backend.tf
#
# Uses the SAME Azure Storage Account as the root module but a different
# blob key so the two roots have independent state files:
#   root module  → platform.tfstate
#   k8s-post     → k8s-post.tfstate
#
# bootstrap.sh Phase 5 initialises this root with the same -backend-config
# flags used in Phase 2:
#
#   terraform -chdir=terraform/k8s-post init -reconfigure \
#     -backend-config="resource_group_name=${RESOURCE_GROUP}" \
#     -backend-config="storage_account_name=${STATE_SA}"
#   terraform -chdir=terraform/k8s-post apply \
#     -var="resource_group_name=${RESOURCE_GROUP}" \
#     -var="storage_account_name=${STATE_SA}"
# =============================================================================

terraform {
  backend "azurerm" {
    container_name = "tfstate"
    key            = "k8s-post.tfstate"
    # resource_group_name  — supplied via -backend-config by bootstrap.sh
    # storage_account_name — supplied via -backend-config by bootstrap.sh
  }
}
