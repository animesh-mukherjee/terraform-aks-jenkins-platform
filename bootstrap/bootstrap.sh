#!/usr/bin/env bash
#
# bootstrap.sh — run at the START of every KodeKloud (KK) Azure Playground session.
#
# WHAT THIS DOES (the "two-phase remote state" pattern):
#   Phase 0  Preflight ........ verify tooling + Azure login, discover the KK resource group
#   Phase 1  Local state ...... create ONLY the state storage account, tracked in LOCAL state
#   Phase 2  Migrate .......... enable the azurerm remote backend, copy local state into it
#   Phase 3  Full apply ....... provision the entire platform with state living in Azure
#   Phase 4  Post-apply ....... pull AKS kubeconfig so kubectl/helm work in this session
#
# WHY two-phase: Terraform's remote "backend" needs a storage account that already
# exists before `terraform init` can use it. But we also want Terraform to CREATE that
# storage account. That's a chicken-and-egg problem. The standard fix: create the
# storage account first with local state, then migrate state into it. bootstrap.sh
# automates both phases so a fresh KK session is one command away from a full platform.
#
# KK NOTE: KodeKloud sessions are ephemeral — the resource group AND the state storage
# account are destroyed when the session expires. Remote state therefore does NOT persist
# across sessions; we use it to demonstrate the real-world workflow, and simply re-run
# this script each session. See docs/kk-session-guide.md.
#
# PROD: in production the state storage account is created ONCE by a separate, long-lived
# bootstrap pipeline (or clickops) and never destroyed; app pipelines only ever run the
# Phase 3 `apply`. You would also use Azure AD / managed-identity auth for the backend
# instead of the storage access key used here.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths & configuration
# ---------------------------------------------------------------------------
# Resolve repo root from this script's location so the script works no matter
# what directory it is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

# Project identity. PREFIX feeds var.prefix in every Terraform module; resource
# names become "<prefix>-<random suffix>" so re-runs never collide.
PREFIX="${PREFIX:-aksjenkins}"
LOCATION="${LOCATION:-eastus}"          # KK: only eastus/westus/centralus/southcentralus — we standardize on eastus

# Remote-state coordinates. The state container lives INSIDE the state storage
# account that Phase 1 creates. These names are recomputed from Terraform outputs
# after Phase 1, so the defaults here are only used for messaging.
STATE_CONTAINER="${STATE_CONTAINER:-tfstate}"
STATE_KEY="${STATE_KEY:-platform.tfstate}"

# ---------------------------------------------------------------------------
# Pretty logging
# ---------------------------------------------------------------------------
c_reset='\033[0m'; c_blue='\033[34m'; c_grn='\033[32m'; c_yel='\033[33m'; c_red='\033[31m'
log()  { printf "${c_blue}[bootstrap]${c_reset} %s\n" "$*"; }
ok()   { printf "${c_grn}[  ok  ]${c_reset} %s\n" "$*"; }
warn() { printf "${c_yel}[ warn ]${c_reset} %s\n" "$*"; }
die()  { printf "${c_red}[ fail ]${c_reset} %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Phase 0 — Preflight
# ---------------------------------------------------------------------------
phase0_preflight() {
  log "Phase 0: preflight checks"

  for bin in az terraform kubectl; do
    command -v "${bin}" >/dev/null 2>&1 || die "'${bin}' not found on PATH. Run this inside the KodeKloud session (Cloud Shell / lab VM)."
  done
  ok "az / terraform / kubectl present"

  # Confirm we are logged in to Azure (KK Cloud Shell is pre-authenticated).
  az account show >/dev/null 2>&1 || die "Not logged in to Azure. Run 'az login' (or open KodeKloud Cloud Shell) first."

  SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
  ok "Azure subscription: ${SUBSCRIPTION_ID}"

  # KK provides exactly ONE resource group per session and we are NOT allowed to
  # create one. Discover it dynamically. If several exist, prefer one matching the
  # KK naming pattern, else take the first.
  RESOURCE_GROUP="${RESOURCE_GROUP:-$(az group list --query "[?starts_with(name,'kk') || contains(name,'playground') || contains(name,'kodekloud')].name | [0]" -o tsv)}"
  if [[ -z "${RESOURCE_GROUP}" || "${RESOURCE_GROUP}" == "null" ]]; then
    RESOURCE_GROUP="$(az group list --query "[0].name" -o tsv)"
  fi
  [[ -n "${RESOURCE_GROUP}" && "${RESOURCE_GROUP}" != "null" ]] || die "Could not find a KodeKloud-provided resource group. Set RESOURCE_GROUP=<name> and re-run."
  ok "KodeKloud resource group: ${RESOURCE_GROUP}"

  # Export as TF_VAR_* so every module's variables pick these up automatically.
  # (TF_VAR_foo is Terraform's convention for setting var.foo from the environment.)
  export TF_VAR_resource_group_name="${RESOURCE_GROUP}"
  export TF_VAR_prefix="${PREFIX}"
  export TF_VAR_location="${LOCATION}"
  export ARM_SUBSCRIPTION_ID="${SUBSCRIPTION_ID}"   # azurerm provider/backend also read ARM_* env vars
}

# ---------------------------------------------------------------------------
# Phase 1 — Create the state storage account with LOCAL state
# ---------------------------------------------------------------------------
phase1_local_state() {
  log "Phase 1: creating the state storage account with LOCAL state"
  cd "${TF_DIR}"

  # -backend=false: ignore the backend.tf configuration entirely.
  # Terraform writes state to terraform.tfstate in the working directory instead
  # of initialising any remote backend. This avoids the "Unsetting the previously
  # set backend 'azurerm'" error that occurs on re-runs where .terraform/ still
  # holds azurerm backend configuration from a previous Phase 2.
  # PROD: always use a remote backend; -backend=false is a bootstrap-only workaround.
  terraform init -input=false -backend=false

  # -target limits apply to JUST the storage module (+ whatever it depends on),
  # so we don't try to build AKS etc. before the backend exists.
  terraform apply -input=false -auto-approve -target=module.storage

  # Read the storage coordinates straight from the module's outputs.
  STATE_SA="$(terraform output -raw state_storage_account_name)"
  STATE_CONTAINER="$(terraform output -raw state_container_name)"
  ok "state storage account: ${STATE_SA} (container: ${STATE_CONTAINER})"
}

# ---------------------------------------------------------------------------
# Phase 2 — Enable the remote backend and migrate state into it
# ---------------------------------------------------------------------------
phase2_migrate() {
  log "Phase 2: migrating local state into the azurerm remote backend"
  cd "${TF_DIR}"

  # Fetch a storage access key for the backend. KK forbids Azure IAM role
  # assignments, so AAD-based backend auth is unavailable — we use the access key.
  # PROD: use `use_azuread_auth = true` + a managed identity instead of a shared key.
  local access_key
  access_key="$(az storage account keys list \
    --resource-group "${RESOURCE_GROUP}" \
    --account-name "${STATE_SA}" \
    --query "[0].value" -o tsv)"
  export ARM_ACCESS_KEY="${access_key}"

  # -migrate-state + -force-copy: copy the existing LOCAL state (terraform.tfstate)
  # into the freshly configured REMOTE backend without an interactive prompt.
  # -backend-config passes the values that backend.tf intentionally leaves blank
  # (so no secrets are committed to the repo).
  # backend.tf is present and active here — Phase 1 used -backend=false to ignore it,
  # leaving the file untouched on disk.
  terraform init -input=false -force-copy -migrate-state \
    -backend-config="resource_group_name=${RESOURCE_GROUP}" \
    -backend-config="storage_account_name=${STATE_SA}" \
    -backend-config="container_name=${STATE_CONTAINER}" \
    -backend-config="key=${STATE_KEY}"

  ok "state now lives in Azure (${STATE_SA}/${STATE_CONTAINER}/${STATE_KEY})"
}

# ---------------------------------------------------------------------------
# Phase 3 — Provision the whole platform
# ---------------------------------------------------------------------------
phase3_full_apply() {
  cd "${TF_DIR}"

  # Pass 3a: create Log Analytics + AKS first.
  # The DNS module's VNet link uses `count = var.aks_vnet_id != "" ? 1 : 0`.
  # That value comes from `data.azurerm_resources.aks_vnet` which has
  # `depends_on = [module.aks]` — making it "known after apply" on the first
  # plan. Terraform refuses to evaluate `count` on an unknown value.
  # Solution: apply AKS in a targeted pass so the VNet exists before the
  # full plan runs. On Pass 3b the data source resolves at plan time (AKS
  # already exists), count is concrete, and the VNet link is created.
  log "Phase 3a: provisioning Log Analytics + AKS cluster (prerequisite for DNS VNet link)"
  terraform apply -input=false -auto-approve \
    -target=module.loganalytics \
    -target=module.aks
  ok "AKS cluster provisioned"

  log "Phase 3b: applying all remaining platform resources (~10 min)"
  terraform apply -input=false -auto-approve
  ok "terraform apply complete"
}

# ---------------------------------------------------------------------------
# Phase 4 — Wire up kubectl
# ---------------------------------------------------------------------------
phase4_kubeconfig() {
  log "Phase 4: fetching AKS credentials for kubectl/helm"
  cd "${TF_DIR}"

  local aks_name
  aks_name="$(terraform output -raw aks_cluster_name 2>/dev/null || true)"
  if [[ -z "${aks_name}" ]]; then
    warn "aks_cluster_name output not available yet (AKS module not built?) — skipping kubeconfig"
    return 0
  fi

  az aks get-credentials \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${aks_name}" \
    --overwrite-existing
  kubectl get nodes -o wide || warn "kubectl could not reach the cluster yet"
  ok "kubeconfig set; cluster reachable"
}

# ---------------------------------------------------------------------------
# Phase 5 — Apply terraform/k8s-post/ (K8s Secrets, namespaces, node taint)
# ---------------------------------------------------------------------------
# This MUST run after Phase 4 (kubeconfig written) because the kubernetes
# provider in k8s-post/ uses ~/.kube/config to authenticate to AKS.
# Resources created here:
#   - Namespaces: jenkins, dev, staging
#   - CoreDNS custom ConfigMap + rolling restart
#   - imagePullSecrets (ACR) in all three namespaces
#   - jenkins-admin-credentials K8s Secret
#   - app-db-credentials K8s Secret (dev + staging)
#   - app-config-credentials K8s Secret (dev + staging)
#   - jenkins-pipeline-creds K8s Secret
#   - service-bus-credentials K8s Secret
#   - Node 1 taint: dedicated=controller:NoSchedule
#   - Node 2 label: dedicated=agent
phase5_k8s_post() {
  log "Phase 5: applying terraform/k8s-post/ (namespaces, K8s secrets, node placement)"
  local k8s_post_dir="${REPO_ROOT}/terraform/k8s-post"

  # k8s-post/ uses the SAME storage account as the root but a different blob
  # key (k8s-post.tfstate). Pass the same -backend-config flags used in Phase 2.
  terraform -chdir="${k8s_post_dir}" init \
    -input=false \
    -reconfigure \
    -backend-config="resource_group_name=${RESOURCE_GROUP}" \
    -backend-config="storage_account_name=${STATE_SA}"

  # k8s-post/ needs resource_group_name and storage_account_name as input
  # variables so it can configure the terraform_remote_state data source that
  # reads the root module's outputs.
  terraform -chdir="${k8s_post_dir}" apply \
    -input=false \
    -auto-approve \
    -var="resource_group_name=${RESOURCE_GROUP}" \
    -var="storage_account_name=${STATE_SA}"

  ok "k8s-post complete — namespaces, secrets, and node placement applied"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "aks-jenkins-platform bootstrap starting (prefix=${PREFIX}, location=${LOCATION})"
  phase0_preflight
  phase1_local_state
  phase2_migrate
  phase3_full_apply
  phase4_kubeconfig
  phase5_k8s_post
  ok "BOOTSTRAP COMPLETE — platform is up."
  log "Next: helm upgrade --install jenkins jenkins/jenkins --namespace jenkins --values helm/jenkins/values.yaml --wait"
  log "Then: kubectl apply -k k8s/rbac/ && kubectl apply -k jenkins/casc/"
  log "When done for the session, run: bootstrap/destroy.sh"
}

main "$@"
