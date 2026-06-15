# KodeKloud Session Guide

The KodeKloud Azure Playground is a **free, time-boxed, session-based** Azure sandbox.
Everything you create is **destroyed when the session expires**. This guide explains how
to work productively within that lifecycle.

---

## The golden rules

1. **One resource group, already created.** You cannot create resource groups. A single
   RG is provided; everything goes inside it. `bootstrap.sh` discovers its name for you.
2. **Region is always `eastus`.** Allowed: eastus / westus / centralus / southcentralus.
   This project standardizes on `eastus`.
3. **State does not survive the session.** The Terraform state storage account is inside
   the session RG and is reclaimed with it. Re-apply fresh each session.
4. **Respect the SKU limits** (see [Service SKU limits](#service-sku-limits) below).
   Going over a limit fails the apply, not just at runtime.

---

## Session start checklist

```bash
# 1. Confirm you are authenticated (KK Cloud Shell usually is already)
az account show

# 2. Confirm the tooling is present
terraform version    # ≥ 1.9
kubectl version --client
helm version

# 3. Clone (or pull) the repo
git clone <your-fork-url> aks-jenkins-platform && cd aks-jenkins-platform

# 4. Bring up the platform
./bootstrap/bootstrap.sh
```

`bootstrap.sh` will:
- discover the provided resource group and your subscription id,
- export them as `TF_VAR_*` so every module picks them up,
- create the state storage account (local state), migrate state to Azure,
- apply the full platform, and fetch AKS credentials for `kubectl`.

---

## Overriding defaults

The scripts read a few environment variables; set them before running if needed:

| Variable | Default | Purpose |
|---|---|---|
| `PREFIX` | `aksjenkins` | Name prefix for all resources |
| `LOCATION` | `eastus` | Azure region |
| `RESOURCE_GROUP` | auto-discovered | Force a specific RG name |
| `STATE_CONTAINER` | `tfstate` | Blob container for remote state |
| `STATE_KEY` | `platform.tfstate` | State blob name |

```bash
PREFIX=mylab LOCATION=westus ./bootstrap/bootstrap.sh
```

---

## Session end checklist

```bash
# Tear everything down BEFORE the timer expires (frees quota, keeps habits clean)
./bootstrap/destroy.sh
```

If you forget, KodeKloud reclaims the RG automatically — but running `destroy.sh`
is the production-correct habit and avoids surprises.

---

## Sandbox constraints reference

These are the hard limits the platform is engineered around. Violating a **globally
blocked** rule or a **SKU limit** causes `terraform apply` to fail.

### Globally blocked

- Cannot create resource groups → reference the provided RG via `data "azurerm_resource_group"`.
- Cannot create or modify Azure IAM role assignments → use Kubernetes-native RBAC.
- Cannot create Entra App Registrations / OIDC SSO → use Jenkins JCasC built-in users.
- Cannot install AKS add-ons (no CSI Secret Store driver) → Terraform reads Key Vault and creates `kubernetes_secret`.
- Cannot assign `AcrPull` to the AKS identity → ACR `admin_enabled=true` + a Kubernetes `imagePullSecret`.
- Cannot access marketplace or billing; cannot elevate access or create management groups.
- Regions: eastus / westus / centralus / southcentralus → standardize on **eastus**.

### Service SKU limits

| Service | Constraint |
|---|---|
| AKS | VM `Standard_D2s_v3` only · 1 node pool max · 2 nodes max · alerting disabled |
| Key Vault | Standard SKU · `purge_protection=false` · no HA · `soft_delete_retention_days=7` |
| Storage | `Standard_LRS` or `Standard_RAGRS` · disk ≤ 128 GB · no Premium |
| ACR | Basic or Standard · no task runs |
| PostgreSQL | Burstable tier · `Standard_B1ms`/`B2s` · no HA · disk ≤ 32 GB · backup ≤ 7d · max 1 instance |
| Log Analytics | `PerGB2018` SKU only · retention ≤ 30 days |
| Service Bus | Basic namespace only (queues; no topics) |
| App Configuration | Free or Developer SKU · max 1 store per session |
| Container Instance | Standard · CPU 0.25–2 · memory 0.5–4 GB |
| Load Balancer | max 3 per session |

The reasoning behind how each blocked capability is replaced lives in
[`decisions.md`](decisions.md).

---

## Common gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `Could not find a KodeKloud-provided resource group` | RG name doesn't match the heuristic | `RESOURCE_GROUP=<name> ./bootstrap/bootstrap.sh` |
| Backend init asks to migrate interactively | Running `terraform` by hand instead of the script | Use `bootstrap.sh`; it passes `-migrate-state -force-copy` |
| `backend.tf.bootstrap-parked` left in `terraform/` | A script run was interrupted | Re-run the script (it self-heals via an EXIT trap) or `git checkout` the dir |
| AKS apply is slow | Cluster creation genuinely takes several minutes | Wait; this is normal |
| Quota / SKU error | A value exceeds a sandbox limit | Check the [Service SKU limits](#service-sku-limits) table below |

---

## What persists vs what doesn't

| Artifact | Survives session end? |
|---|---|
| This git repository | ✅ (it lives in GitHub, not in Azure) |
| Azure resources | ❌ reclaimed with the RG |
| Terraform remote state | ❌ stored in the reclaimed RG |
| Local kubeconfig entry | ❌ points at a deleted cluster |

Because the repo is the single source of truth, a fresh session is always just
`git pull` + `bootstrap.sh` away from a fully reconstructed platform.
