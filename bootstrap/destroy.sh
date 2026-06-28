#!/usr/bin/env bash
#
# destroy.sh — run BEFORE a KodeKloud session expires to tear everything down cleanly.
#
# WHAT THIS DOES (reverse of bootstrap.sh):
#   Phase 0  Preflight ........ verify tooling + Azure login, discover the KK resource group
#   Phase 1  Migrate back ..... copy remote state back to LOCAL state
#   Phase 2  Destroy .......... destroy the ENTIRE platform, including the state storage account
#   Phase 3  Cleanup .......... remove local state/backend artifacts from the working tree
#
# WHY migrate state back first: you cannot `terraform destroy` the storage account that
# is currently hosting your remote state — Terraform would delete the backend out from
# under itself mid-operation. So we pull state back to a LOCAL file, then destroy
# everything (storage account included) from there.
#
# KK NOTE: KodeKloud auto-reclaims the whole resource group when the session ends, so a
# missed destroy is not catastrophic — but running it keeps your habits production-clean
# and frees session quota immediately. This is idempotent: safe to re-run.
#
# PROD: you would NOT destroy the state storage account; you'd only destroy the
# application stack and leave the long-lived backend in place for the next deploy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

PREFIX="${PREFIX:-aksjenkins}"
LOCATION="${LOCATION:-eastus}"
STATE_KEY="${STATE_KEY:-platform.tfstate}"

BACKEND_FILE="${TF_DIR}/backend.tf"
BACKEND_PARKED="${TF_DIR}/backend.tf.bootstrap-parked"

c_reset='\033[0m'; c_blue='\033[34m'; c_grn='\033[32m'; c_yel='\033[33m'; c_red='\033[31m'
log()  { printf "${c_blue}[destroy]${c_reset} %s\n" "$*"; }
ok()   { printf "${c_grn}[  ok  ]${c_reset} %s\n" "$*"; }
warn() { printf "${c_yel}[ warn ]${c_reset} %s\n" "$*"; }
die()  { printf "${c_red}[ fail ]${c_reset} %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Phase 0 — Preflight
# ---------------------------------------------------------------------------
phase0_preflight() {
  log "Phase 0: preflight checks"
  for bin in az terraform; do
    command -v "${bin}" >/dev/null 2>&1 || die "'${bin}' not found on PATH. Run this inside the KodeKloud session."
  done
  az account show >/dev/null 2>&1 || die "Not logged in to Azure. Run 'az login' first."

  SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
  RESOURCE_GROUP="${RESOURCE_GROUP:-$(az group list --query "[?starts_with(name,'kk') || contains(name,'playground') || contains(name,'kodekloud')].name | [0]" -o tsv)}"
  if [[ -z "${RESOURCE_GROUP}" || "${RESOURCE_GROUP}" == "null" ]]; then
    RESOURCE_GROUP="$(az group list --query "[0].name" -o tsv)"
  fi
  [[ -n "${RESOURCE_GROUP}" && "${RESOURCE_GROUP}" != "null" ]] || die "Could not find the KodeKloud resource group. Set RESOURCE_GROUP=<name> and re-run."
  ok "subscription=${SUBSCRIPTION_ID} resource_group=${RESOURCE_GROUP}"

  export TF_VAR_resource_group_name="${RESOURCE_GROUP}"
  export TF_VAR_prefix="${PREFIX}"
  export TF_VAR_location="${LOCATION}"
  export ARM_SUBSCRIPTION_ID="${SUBSCRIPTION_ID}"
}

# ---------------------------------------------------------------------------
# Phase 1 — Pull remote state back to local
# ---------------------------------------------------------------------------
phase1_migrate_back() {
  log "Phase 1: migrating remote state back to local"
  cd "${TF_DIR}"

  if [[ ! -f "${BACKEND_FILE}" ]]; then
    warn "no backend.tf present — assuming state is already local; skipping migration"
    terraform init -input=false -reconfigure
    return 0
  fi

  # Discover the current state storage account so we can authenticate to it.
  # Try Terraform output first; fall back to az lookup by tag/prefix if state
  # is not readable yet.
  local state_sa
  state_sa="$(terraform output -raw state_storage_account_name 2>/dev/null || true)"
  if [[ -z "${state_sa}" ]]; then
    state_sa="$(az storage account list --resource-group "${RESOURCE_GROUP}" \
      --query "[?starts_with(name,'${PREFIX}')].name | [0]" -o tsv 2>/dev/null || true)"
  fi

  if [[ -n "${state_sa}" && "${state_sa}" != "null" ]]; then
    local access_key
    access_key="$(az storage account keys list --resource-group "${RESOURCE_GROUP}" \
      --account-name "${state_sa}" --query "[0].value" -o tsv 2>/dev/null || true)"
    [[ -n "${access_key}" ]] && export ARM_ACCESS_KEY="${access_key}"
  fi

  # Park backend.tf, then init with -migrate-state: with no backend block active,
  # Terraform migrates the REMOTE state into a LOCAL terraform.tfstate file.
  mv "${BACKEND_FILE}" "${BACKEND_PARKED}"
  terraform init -input=false -force-copy -migrate-state
  ok "state pulled back to local terraform.tfstate"
}

# ---------------------------------------------------------------------------
# Phase 2 — Destroy everything
# ---------------------------------------------------------------------------
phase2_destroy() {
  log "Phase 2: destroying the full platform (state storage account included)"
  cd "${TF_DIR}"
  terraform destroy -input=false -auto-approve
  ok "terraform destroy complete"
}

# ---------------------------------------------------------------------------
# Phase 3 — Local cleanup
# ---------------------------------------------------------------------------
phase3_cleanup() {
  log "Phase 3: cleaning up local state artifacts"
  cd "${TF_DIR}"
  # Restore backend.tf so the repo is ready for the next bootstrap run.
  [[ -f "${BACKEND_PARKED}" ]] && mv "${BACKEND_PARKED}" "${BACKEND_FILE}"
  rm -f terraform.tfstate terraform.tfstate.backup
  ok "working tree reset (backend.tf restored, local state files removed)"
}

# Safety net: never leave backend.tf parked if we abort unexpectedly.
restore_backend_on_exit() {
  if [[ -f "${BACKEND_PARKED}" && ! -f "${BACKEND_FILE}" ]]; then
    mv "${BACKEND_PARKED}" "${BACKEND_FILE}"
    warn "run interrupted — restored backend.tf"
  fi
}
trap restore_backend_on_exit EXIT

main() {
  log "aks-jenkins-platform teardown starting"
  phase0_preflight
  phase1_migrate_back
  phase2_destroy
  phase3_cleanup
  trap - EXIT
  ok "DESTROY COMPLETE — all session resources removed."
}

main "$@"
