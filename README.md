# AKS Jenkins Platform

> A complete, production-shaped **Jenkins multinode CI/CD platform on Azure Kubernetes Service (AKS)**, provisioned end-to-end with **Terraform** — engineered to run inside the constraints of the free, session-based **KodeKloud Azure Playground**.

[![Terraform](https://img.shields.io/badge/Terraform-1.9%2B-7B42BC?logo=terraform&logoColor=white)](https://www.terraform.io/)
[![azurerm](https://img.shields.io/badge/azurerm-4.x-0078D4?logo=microsoftazure&logoColor=white)](https://registry.terraform.io/providers/hashicorp/azurerm/latest)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-AKS-326CE5?logo=kubernetes&logoColor=white)](https://learn.microsoft.com/azure/aks/)
[![Jenkins](https://img.shields.io/badge/Jenkins-JCasC-D24939?logo=jenkins&logoColor=white)](https://www.jenkins.io/projects/jcasc/)
[![Helm](https://img.shields.io/badge/Helm-3.x-0F1689?logo=helm&logoColor=white)](https://helm.sh/)

---

## TL;DR — what this project demonstrates

This is a **DevOps portfolio project** that provisions and operates a full CI/CD platform from a single `terraform apply`, then runs a real application through a 9-stage Jenkins pipeline. It is deliberately built within hard sandbox constraints to show **how to engineer cloud platforms when you _don't_ control the environment** — exactly the situation in regulated enterprises with locked-down landing zones.

| Capability | How it's shown here |
|---|---|
| **Infrastructure as Code** | 10 reusable Terraform modules, two-phase remote state, explicit dependency graphs |
| **Kubernetes platform engineering** | Node taints/labels, resource budgeting, namespace isolation, NGINX ingress |
| **Configuration as Code** | Jenkins fully defined via JCasC — zero manual UI clicks |
| **CI/CD pipeline design** | Multibranch pipeline, ephemeral pod agents, approval gates, environment promotion |
| **Secrets management** | Azure Key Vault → Kubernetes secrets (no secrets in git, no secrets in state output) |
| **Constraint-driven design** | Every cloud-native shortcut that the sandbox blocks is replaced with a documented, portable alternative |

---

## Why "constraint-driven"? (the interesting part)

The KodeKloud Playground blocks the things most Azure tutorials quietly assume you have: you **cannot** create resource groups, **cannot** assign Azure IAM roles, **cannot** register Entra applications for SSO, and **cannot** install AKS add-ons like the CSI Secret Store driver.

Rather than give up on those features, this project replaces each blocked capability with a portable, well-understood alternative — and documents the production delta inline (`# PROD:` comments) so the trade-offs are explicit:

| Blocked by sandbox | Replaced with | Production note |
|---|---|---|
| Creating a resource group | `data "azurerm_resource_group"` referencing the provided RG | In prod you own the RG lifecycle |
| Azure IAM role assignments | Kubernetes-native RBAC (Roles / ClusterRoles) | In prod, AKS workload identity + Azure RBAC |
| `AcrPull` role for the kubelet identity | ACR `admin_enabled=true` + a Kubernetes `imagePullSecret` | In prod, attach AcrPull to the kubelet MI |
| CSI Secret Store driver | Terraform reads Key Vault → writes `kubernetes_secret` | In prod, mount secrets via CSI/workload identity |
| Entra App Registration / OIDC SSO | Jenkins JCasC matrix auth with built-in users | In prod, wire Jenkins to Entra ID / SAML |

Full reasoning lives in [`docs/decisions.md`](docs/decisions.md).

---

## Architecture

```
                          ┌────────────────────────────────────────────────────┐
                          │      KodeKloud-provided Resource Group (eastus)      │
                          │                                                      │
  Terraform remote state  │  ┌────────────┐  ┌────────────┐  ┌───────────────┐  │
  ───────────────────────▶│  │  Storage   │  │    ACR     │  │   Key Vault   │  │
        (azurerm backend)  │  │ Std_LRS    │  │ Standard   │  │  Standard SKU │  │
                          │  └────────────┘  └─────┬──────┘  └───────┬───────┘  │
                          │                        │ imagePullSecret │ secrets  │
                          │  ┌──────────────────────────────────────────────┐  │
                          │  │                  AKS Cluster                  │  │
                          │  │              (1 pool · 2× D2s_v3)             │  │
                          │  │                                              │  │
                          │  │  Node 1  taint dedicated=controller:NoSchedule │
                          │  │   ├─ NGINX Ingress                           │  │
                          │  │   └─ Jenkins Controller (executors=0, JCasC) │  │
                          │  │                                              │  │
                          │  │  Node 2  label dedicated=agent               │  │
                          │  │   └─ Ephemeral pod agents:                   │  │
                          │  │        nodejs-agent · helm-agent · db-agent  │  │
                          │  └──────────────────────────────────────────────┘  │
                          │                                                      │
                          │  ┌────────────┐ ┌────────────┐ ┌────────────────┐   │
                          │  │ PostgreSQL │ │ Service Bus│ │ App Config      │   │
                          │  │ Flexible   │ │ Basic      │ │ (feature flags) │   │
                          │  │ B1ms       │ │ (queues)   │ └────────────────┘   │
                          │  └────────────┘ └────────────┘                      │
                          │  ┌────────────┐ ┌────────────────────────────────┐  │
                          │  │ Private DNS│ │ Log Analytics (Container Insights)│ │
                          │  │ platform.  │ │ PerGB2018 · 30d                 │  │
                          │  │ internal   │ └────────────────────────────────┘  │
                          │  └────────────┘                                      │
                          └────────────────────────────────────────────────────┘

CI/CD lifecycle:
  GitHub PR → GitHub Actions (tf-plan) → Jenkins Multibranch
    → Checkout/Lint → Unit Tests → Docker Build+Push (ACR) → DB Migration (ACI one-shot)
    → Helm Deploy (dev) → Smoke Test → Service Bus Notify → input() approval → Helm Promote (staging)
```

A deeper write-up — node resource budget, RBAC matrices, data flow — is in [`docs/architecture.md`](docs/architecture.md).

---

## Tech stack

| Layer | Technology |
|---|---|
| IaC | Terraform 1.9+, azurerm 4.x, kubernetes & helm providers |
| Cloud | Azure — AKS, ACR, Key Vault, PostgreSQL Flexible Server, Service Bus, App Configuration, Log Analytics, Private DNS, Container Instances, Storage |
| Orchestration | Kubernetes (AKS), NGINX Ingress |
| CI/CD | Jenkins (Helm + JCasC), GitHub Actions |
| Packaging | Helm 3, Docker |
| App | Node.js sample service + PostgreSQL |
| Observability | Azure Monitor Container Insights |

---

## Repository structure

```
aks-jenkins-platform/
├── README.md             # You are here
├── bootstrap/            # Per-session lifecycle scripts (bootstrap.sh / destroy.sh)
├── terraform/
│   ├── modules/          # 10 reusable modules (storage, acr, keyvault, aks, …)
│   ├── k8s-post/         # K8s resources applied after AKS exists
│   └── *.tf              # Root: main, variables, outputs, backend, versions
├── k8s/rbac/             # Kubernetes RBAC (replaces Azure IAM)
├── helm/jenkins/         # Jenkins Helm values
├── jenkins/casc/         # Jenkins Configuration as Code (6 files)
├── pipelines/            # 4 Jenkinsfiles (build / deploy / promote / destroy)
├── app-sample/           # Demo Node.js app + Helm chart
├── .github/workflows/    # GitHub Actions (tf-plan / tf-apply)
└── docs/                 # architecture · decisions · kk-session-guide · runbook
```

---

## Quickstart

> **Where to run:** all `terraform` / `az` / `helm` commands run **inside a KodeKloud Azure Playground session** (its Cloud Shell or lab VM), which is pre-authenticated to Azure. See [`docs/kk-session-guide.md`](docs/kk-session-guide.md).

**Prerequisites (provided by the KK session):** `az`, `terraform` ≥ 1.9, `kubectl`, `helm`.

```bash
# 1. Clone the repo into your KodeKloud session
git clone <your-fork-url> aks-jenkins-platform
cd aks-jenkins-platform

# 2. Stand up the entire platform (discovers the RG, two-phase state, full apply, kube creds)
./bootstrap/bootstrap.sh

# 3. Explore
kubectl get nodes -o wide
kubectl get pods -A

# 4. Before the session expires — tear it all down cleanly
./bootstrap/destroy.sh
```

`bootstrap.sh` handles the **two-phase remote-state pattern** automatically: it first creates the
state storage account using local state, then migrates Terraform state into that Azure
Storage backend before provisioning the rest of the platform. The mechanics are explained
in [`docs/runbook.md`](docs/runbook.md).

---

## Build roadmap

Built in strict order. Progress:

- [x] **Step 1** — Session lifecycle scripts (`bootstrap.sh`, `destroy.sh`)
- [ ] **Step 2–11** — Terraform modules: storage · acr · keyvault · loganalytics · aks · postgresql · servicebus · appconfig · dns · aci
- [ ] **Step 12** — Terraform root (`main`/`variables`/`outputs`/`backend`/`versions`)
- [ ] **Step 13** — `k8s-post` (namespaces, KV→secret, imagePullSecret)
- [ ] **Step 14** — Kubernetes RBAC
- [ ] **Step 15** — Jenkins Helm values
- [ ] **Step 16** — Jenkins JCasC (6 files)
- [ ] **Step 17** — Pipelines (4 Jenkinsfiles)
- [ ] **Step 18** — Sample app + Helm chart
- [ ] **Step 19** — GitHub Actions
- [ ] **Step 20** — Documentation polish

---

## Documentation

| Doc | Purpose |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Detailed architecture, node budget, RBAC, data flow |
| [`docs/decisions.md`](docs/decisions.md) | Architecture Decision Records — why each choice was made |
| [`docs/kk-session-guide.md`](docs/kk-session-guide.md) | How to work within the KodeKloud session lifecycle |
| [`docs/runbook.md`](docs/runbook.md) | Operational procedures: bootstrap, destroy, troubleshooting |

---

## A note on scope & intent

This repository is a **learning and portfolio artifact**, not a product. It optimizes for
clarity and teaching: Terraform concepts are explained inline on first use, sandbox
workarounds are annotated with their production equivalents, and the commit history is
intended to read as a guided build. State is **ephemeral per KodeKloud session** by
design — the platform is re-applied fresh each session.

---

## Author

**Animesh Mukherjee** — DevOps Engineer (8+ yrs) · IT Analyst @ TCS
Azure · Terraform · Jenkins · Kubernetes · Docker · GitHub Actions
