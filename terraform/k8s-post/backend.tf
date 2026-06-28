# =============================================================================
# k8s-post/backend.tf
#
# Uses the SAME Azure Storage Account as the root module but a different
# blob key so the two roots have independent state files.
# bootstrap.sh Phase 4 initialises this root with the same -backend-config
# flags used in Phase 2:
#
#   cd terraform/k8s-post
#   terraform init -reconfigure \
#     -backend-config="resource_group_name=${RG_NAME}" \
#     -backend-config="storage_account_name=${SA_NAME}"
#   terraform apply \
#     -var="resource_group_name=${RG_NAME}" \
#     -var="storage_account_name=${SA_NAME}"
# =============================================================================

terraform {
  backend "azurerm" {
    container_name = "tfstate"
    key            = "k8s-post.tfstate"
    # resource_group_name  — supplied via -backend-config by bootstrap.sh
    # storage_account_name — supplied via -backend-config by bootstrap.sh
  }
}
