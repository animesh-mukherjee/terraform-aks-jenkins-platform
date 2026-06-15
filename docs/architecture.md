# Architecture

This document details the platform architecture: the Azure resource topology, the AKS
node strategy and resource budget, the two layers of RBAC, and the end-to-end CI/CD
data flow.

> All resources live inside the **KodeKloud-provided resource group** in **eastus**.
> No resource group is ever created by this project.

---

## 1. Azure resource topology

| # | Resource | SKU / Tier | Role in the platform |
|---|---|---|---|
| 1 | Storage Account | Standard_LRS | Terraform remote-state backend |
| 2 | Container Registry (ACR) | Standard, `admin_enabled=true` | Docker image store for app builds |
| 3 | Key Vault | Standard | All secrets (jenkins-admin, acr creds, postgres password) |
| 4 | Log Analytics Workspace | PerGB2018, 30d | AKS Container Insights |
| 5 | AKS Cluster | 1 pool · 2× Standard_D2s_v3 | Runs Jenkins controller, pod agents, app namespaces |
| 6 | PostgreSQL Flexible Server | Burstable B1ms | Sample-app database |
| 7 | Service Bus Namespace | Basic (queues only) | Build/deploy event notifications |
| 8 | App Configuration | Free | App feature flags / runtime config |
| 9 | Private DNS Zone | `platform.internal` | Internal service discovery |
| 10 | Container Instance (ACI) | Standard, one-shot | DB migration runner invoked by the pipeline |

**Provisioning order** is enforced by Terraform's dependency graph and made explicit
with `depends_on`: storage (state) → ACR / Key Vault / Log Analytics → AKS → data
services (PostgreSQL, Service Bus, App Config, DNS) → k8s-post (secrets, namespaces).

---

## 2. AKS node strategy

The cluster has exactly **2 nodes** (sandbox cap). We split responsibilities by
**tainting Node 1** and **labelling Node 2**, so Jenkins controller workloads never
compete with build agents for resources.

| Node | Marker | Hosts |
|---|---|---|
| **Node 1** | taint `dedicated=controller:NoSchedule` | Jenkins Controller + NGINX Ingress |
| **Node 2** | label `dedicated=agent` | Ephemeral Jenkins pod agents (nodejs / helm / db) |

- The controller and ingress **tolerate** the Node 1 taint and use a `nodeSelector`
  to pin there. Nothing else schedules onto Node 1 because of `NoSchedule`.
- Pod agents use a `nodeSelector` of `dedicated=agent` to land on Node 2.

### Resource budget

Each `Standard_D2s_v3` node = **2 vCPU / 8 GiB** allocatable-ish (the headroom figures
below assume the ~4 vCPU logical scheduling Jenkins requests against; values are tuned
so requests always fit).

```
Node 1 (controller):
  kube-system               ~0.3 CPU / 0.5 Gi
  nginx-ingress              0.1 CPU / 0.1 Gi
  jenkins-controller         1.5 CPU / 2.5 Gi   (limit 2 CPU / 3 Gi)
  → headroom retained for burst

Node 2 (agents):
  kube-system daemonsets    ~0.1 CPU / 0.2 Gi
  up to 3 pod agents        ~1.6 CPU / 3.5 Gi
  → headroom retained for burst
```

Every pod spec sets **both `requests` and `limits`** (project standard) so the
scheduler can honor this budget deterministically.

---

## 3. Two layers of RBAC

Because Azure IAM role assignments are blocked, access control is expressed in
**Kubernetes RBAC** (for cluster access) and **Jenkins matrix auth** (for CI/CD access).

### Jenkins RBAC (JCasC matrix authorization — not Entra SSO)

| Role | Permissions |
|---|---|
| `admin` | Full: configure, manage, build, delete, administer |
| `developer` | Build, cancel, read, workspace, viewStatus on assigned jobs |
| `viewer` | Read + viewStatus only (cannot trigger builds) |

### Kubernetes RBAC (replaces Azure IAM)

| Subject | Scope | Permissions |
|---|---|---|
| `jenkins-sa` (ServiceAccount) | ClusterRole | `pods/exec`, `pods/log`, pods CRUD — required by the Jenkins Kubernetes plugin to launch agents |
| `dev-developer-role` | Role in `dev` ns | deployments + services + pods CRUD + rollback |
| `dev-viewer-role` | Role in `dev` ns | get / list / watch only |

---

## 4. Secrets flow (no CSI driver)

```
Key Vault secret ──(Terraform data source reads value)──▶ kubernetes_secret in AKS
                                                            │
                                            mounted as env/volume by workloads
```

Because the CSI Secret Store driver cannot be installed, Terraform reads each Key Vault
secret and materializes it as a native `kubernetes_secret`. Secrets are **never** echoed
into Terraform outputs (all marked `sensitive = true`) and **never** committed.

ACR authentication follows the same constraint-driven pattern: instead of granting the
kubelet identity the `AcrPull` role, ACR runs with `admin_enabled=true` and its
credentials become a Kubernetes `imagePullSecret`.

---

## 5. CI/CD data flow

```
GitHub PR
   │
   ▼
GitHub Actions  ──  terraform fmt / validate / plan  (gate on infra changes)
   │
   ▼
Jenkins Multibranch pipeline detects the branch
   │
   ├─ Stage 1  Checkout + Lint            [nodejs-agent pod · Node 2]
   ├─ Stage 2  Unit Tests                 [nodejs-agent pod]
   ├─ Stage 3  Docker Build + Push → ACR  [nodejs-agent pod]
   ├─ Stage 4  DB Migration via ACI       [Container Instance · one-shot]
   ├─ Stage 5  Helm Deploy → dev ns       [helm-agent pod]
   ├─ Stage 6  Smoke Test                 [nodejs-agent pod]
   ├─ Stage 7  Service Bus Notify         [any agent]
   ├─ Stage 8  input() approval gate      [human]
   └─ Stage 9  Helm Promote → staging     [helm-agent pod]
```

Each agent is an **ephemeral pod** created on demand by the Jenkins Kubernetes plugin
and destroyed when the stage completes — the controller itself runs **zero executors**.

---

See [`decisions.md`](decisions.md) for *why* each of these choices was made, and
[`runbook.md`](runbook.md) for how to operate the platform.
