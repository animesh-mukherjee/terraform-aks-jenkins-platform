# =============================================================================
# backend.tf — Remote state backend configuration.
#
# Terraform concept: by default Terraform stores state locally (terraform.tfstate
# in the working directory). A REMOTE BACKEND moves that file to a shared,
# durable store so multiple team members and CI systems share the same state.
# The `azurerm` backend stores state in an Azure Blob Storage container.
#
# Bootstrap chicken-and-egg problem:
#   The storage account that holds our state is created by module.storage,
#   but Terraform needs the backend configured BEFORE it can apply anything.
#   Solution: two-phase bootstrap in bootstrap.sh:
#     Phase 1 — `terraform init -backend=false` (ignores this file entirely)
#               then `terraform apply -target=module.storage`
#               State is written to a local terraform.tfstate file.
#     Phase 2 — `terraform init -migrate-state -force-copy -backend-config=...`
#               This file is now active; Terraform copies local state into
#               the blob container and switches all future operations to remote.
#     Phase 3 — apply the rest of the root module normally with remote state.
#
# Partial backend configuration:
#   Terraform allows some backend keys to be omitted from the file and
#   supplied at `terraform init` time via -backend-config flags. This is
#   necessary here because `storage_account_name` is generated with a random
#   suffix and is unknown until Phase 1 completes.
#
#   Fixed keys (in this file):
#     container_name — always "tfstate" (set in module.storage variables.tf)
#     key            — the blob path within the container
#
#   Dynamic keys (passed by bootstrap.sh Phase 2 via -backend-config):
#     resource_group_name  — the KK-provided RG name
#     storage_account_name — output of module.storage (includes random suffix)
#
# bootstrap.sh Phase 2 command:
#   terraform init -input=false -force-copy -migrate-state \
#     -backend-config="resource_group_name=${RESOURCE_GROUP}" \
#     -backend-config="storage_account_name=${STATE_SA}" \
#     -backend-config="container_name=tfstate" \
#     -backend-config="key=platform.tfstate"
# =============================================================================

terraform {
  backend "azurerm" {
    container_name = "tfstate"
    key            = "platform.tfstate"
    # resource_group_name  — supplied via -backend-config by bootstrap.sh
    # storage_account_name — supplied via -backend-config by bootstrap.sh
  }
}
