# Architecture Decision Records (ADRs)

Each record captures a decision, its context, and its consequences. Sandbox-driven
decisions also note the **production delta** — what would change outside the KodeKloud
Playground.

---

## ADR-001 — Reference the existing resource group instead of creating one

**Status:** Accepted
**Context:** KodeKloud forbids creating resource groups; one is provided per session.
**Decision:** Every module consumes the RG via `data "azurerm_resource_group"`. The RG
name is discovered at runtime by `bootstrap.sh` and injected as `TF_VAR_resource_group_name`.
**Consequences:** The repo is portable to any RG. **PROD:** you would own the RG
lifecycle and likely create it (or receive it from a landing-zone module).

---

## ADR-002 — Kubernetes RBAC instead of Azure IAM

**Status:** Accepted
**Context:** Creating/modifying Azure role assignments is blocked.
**Decision:** Access control is expressed entirely in Kubernetes RBAC (Roles /
ClusterRoles / bindings) and Jenkins matrix authorization.
**Consequences:** Fully portable, cluster-scoped authz that is independent of Azure
RBAC. **PROD:** combine with AKS workload identity + Azure RBAC for defense in depth.

---

## ADR-003 — Jenkins JCasC matrix auth instead of Entra SSO

**Status:** Accepted
**Context:** Entra App Registrations / OIDC SSO cannot be created.
**Decision:** Jenkins security is defined in JCasC using matrix authorization with
built-in users (`admin` / `developer` / `viewer`). Credentials originate from Key Vault.
**Consequences:** Zero external IdP dependency; reproducible from code. **PROD:** wire
Jenkins to Entra ID (OIDC) or SAML and delete the built-in users.

---

## ADR-004 — Key Vault → kubernetes_secret instead of the CSI Secret Store driver

**Status:** Accepted
**Context:** AKS add-ons (including the CSI Secret Store driver) cannot be installed.
**Decision:** Terraform reads each Key Vault secret and creates a native
`kubernetes_secret`. All secret outputs are `sensitive = true`.
**Consequences:** Secrets are present in Terraform **state**, so state is treated as
sensitive and never committed. **PROD:** use the CSI driver or workload identity so
secrets are mounted at runtime and never enter state.

---

## ADR-005 — ACR admin user + imagePullSecret instead of the AcrPull role

**Status:** Accepted
**Context:** Assigning `AcrPull` to the AKS kubelet identity is blocked.
**Decision:** ACR runs with `admin_enabled=true`; its admin credentials are stored in
Key Vault and projected into AKS as an `imagePullSecret`.
**Consequences:** Works without any Azure role assignment. **PROD:** disable the admin
user and grant `AcrPull` to the kubelet managed identity.

---

## ADR-006 — Two-phase remote state (local → migrate)

**Status:** Accepted
**Context:** The azurerm backend needs the state storage account to exist before
`terraform init`, but Terraform also creates that account (chicken-and-egg).
**Decision:** `bootstrap.sh` first applies *only* the storage module with local state,
then enables `backend.tf` and runs `terraform init -migrate-state` to move state into
Azure Storage. `destroy.sh` reverses this (migrate back to local, then destroy).
**Consequences:** Demonstrates the real backend-migration workflow. **PROD:** the state
storage account is created once by a separate long-lived bootstrap and never destroyed;
app pipelines only ever `apply`. Backend auth here uses the storage access key because
AAD-based auth would need a role assignment; **PROD** uses `use_azuread_auth = true`.

---

## ADR-007 — azurerm provider 4.x

**Status:** Accepted
**Context:** Choice between azurerm 3.x (heavily documented) and 4.x (current).
**Decision:** Target **azurerm 4.x** for current best-practice syntax (explicit
`subscription_id`, `features {}` block) — appropriate for a 2026 portfolio piece.
**Consequences:** Some tutorials written for 3.x won't match verbatim; concept comments
in the code bridge the gap.

---

## ADR-008 — Jenkins via the official Helm chart + JCasC

**Status:** Accepted
**Context:** Choice between the official `jenkins/jenkins` Helm chart and hand-rolled
Kubernetes manifests.
**Decision:** Use the official Helm chart, configured entirely through
`helm/jenkins/values.yaml` and JCasC files. No manual UI configuration.
**Consequences:** Industry-standard, upgrade-friendly, fully reproducible. The chart's
Kubernetes plugin provides the ephemeral pod-agent capability we rely on.

---

## ADR-009 — Single node pool, controller/agent split via taint + label

**Status:** Accepted
**Context:** Sandbox allows only 1 node pool, max 2 nodes.
**Decision:** Taint Node 1 (`dedicated=controller:NoSchedule`) for the controller +
ingress; label Node 2 (`dedicated=agent`) for pod agents. Controller runs
`executors=0`. Both `requests` and `limits` are set on every pod.
**Consequences:** Deterministic scheduling within a tight 2-node budget. **PROD:** use
separate, autoscaling node pools for controller vs agents.

---

## ADR-010 — Ephemeral per-session state, re-applied each session

**Status:** Accepted
**Context:** KodeKloud reclaims the entire resource group (state storage included) when
a session ends.
**Decision:** Treat state as ephemeral; re-run `bootstrap.sh` each session. The
two-phase pattern is kept for its educational/portfolio value, not for cross-session
persistence.
**Consequences:** No long-lived state to manage or lock. **PROD:** state persists and
is locked; never destroyed between deploys.
