# Architecture

AKS Jenkins Platform — complete system design for the KodeKloud Azure Playground.

---

## High-level diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Developer Workstation                                                  │
│   git push / PR → GitHub                                                │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                    ┌───────────▼────────────┐
                    │    GitHub Repository    │
                    │  terraform-aks-jenkins  │
                    │  ─────────────────────  │
                    │  PR  → tf-plan.yml      │
                    │  main → tf-apply.yml    │
                    └───────────┬────────────┘
                                │ terraform apply
                                ▼
┌───────────────────── Azure (KodeKloud Subscription) ───────────────────┐
│                                                                         │
│  ┌──────────────┐   ┌──────────┐   ┌─────────────┐   ┌─────────────┐  │
│  │ Storage Acct │   │   ACR    │   │  Key Vault  │   │ Log Analytics│  │
│  │ (tfstate)    │   │ (images) │   │ (secrets)   │   │ (AKS logs)  │  │
│  └──────────────┘   └────┬─────┘   └──────┬──────┘   └──────┬──────┘  │
│                          │                │                  │          │
│  ┌────────────────────── AKS Cluster ─────────────────────────────────┐ │
│  │                                                                     │ │
│  │  ┌──────────────────────────────────────────────────────────────┐  │ │
│  │  │  Node 1  taint: dedicated=controller:NoSchedule              │  │ │
│  │  │                                                              │  │ │
│  │  │  ┌──────────────────────┐  ┌───────────────────────┐        │  │ │
│  │  │  │  Jenkins Controller  │  │   NGINX Ingress        │        │  │ │
│  │  │  │  1.5 CPU / 2.5 Gi   │  │   0.1 CPU / 0.1 Gi    │        │  │ │
│  │  │  └──────────────────────┘  └───────────────────────┘        │  │ │
│  │  └──────────────────────────────────────────────────────────────┘  │ │
│  │                                                                     │ │
│  │  ┌──────────────────────────────────────────────────────────────┐  │ │
│  │  │  Node 2  label: dedicated=agent                              │  │ │
│  │  │                                                              │  │ │
│  │  │  ┌──────────────┐  ┌──────────────┐  ┌───────────────────┐  │  │ │
│  │  │  │ nodejs-agent │  │  helm-agent  │  │  app pod (dev/    │  │  │ │
│  │  │  │ (ephemeral)  │  │  (ephemeral) │  │  staging ns)      │  │  │ │
│  │  │  │ node:18      │  │ helm-kubectl │  │  Express + pg     │  │  │ │
│  │  │  │ + dind scar  │  │              │  │                   │  │  │ │
│  │  │  └──────────────┘  └──────────────┘  └───────────────────┘  │  │ │
│  │  └──────────────────────────────────────────────────────────────┘  │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────┐   │
│  │  PostgreSQL  │  │ Service Bus  │  │ App Config   │  │   ACI    │   │
│  │  Flex Server │  │  (Basic)     │  │  (Free)      │  │ migrator │   │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────┘   │
│                                                                         │
│  ┌──────────────────────────────────────────┐                          │
│  │  Private DNS Zone: platform.internal     │                          │
│  │  jenkins.platform.internal → ClusterIP   │                          │
│  └──────────────────────────────────────────┘                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Component inventory

| # | Component | Terraform module | Purpose |
|---|---|---|---|
| 1 | Storage Account (Standard_LRS) | `modules/storage` | Terraform remote state backend (tfstate container) |
| 2 | Container Registry (Standard) | `modules/acr` | Docker image store for app + migration images |
| 3 | Key Vault (Standard) | `modules/keyvault` | Secrets: jenkins-admin-password, acr-username, acr-password, postgresql-password |
| 4 | Log Analytics Workspace (PerGB2018) | `modules/loganalytics` | AKS Container Insights; retention 30 days |
| 5 | AKS Cluster (kubenet) | `modules/aks` | 1 node pool, 2× Standard_D2s_v3 (4 vCPU / 8 Gi each) |
| 6 | PostgreSQL Flexible Server (B1ms) | `modules/postgresql` | App database: `appdb` |
| 7 | Service Bus Namespace (Basic) | `modules/servicebus` | Build/deploy event queues: `build-events`, `deploy-events` |
| 8 | App Configuration (Free) | `modules/appconfig` | Feature flags: `dark-mode`, `new-user-flow` |
| 9 | Private DNS Zone | `modules/dns` | `platform.internal` — internal service discovery |
| 10 | Container Instance (one-shot) | `modules/aci` | DB migration runner — Jenkins Stage 4 |

---

## AKS two-node strategy

```
                    4 vCPU / 8 Gi RAM each
┌──────────────────────────────────────────────┐
│  Node 1  taint: dedicated=controller:NoSchedule │
│                                              │
│  kube-system daemonsets:  ~0.3 CPU / 0.5 Gi  │
│  NGINX Ingress Controller: 0.1 CPU / 0.1 Gi  │
│  Jenkins Controller:       1.5 CPU / 2.5 Gi  │
│  ────────────────────────────────────────     │
│  Headroom:                ~2.1 CPU / 4.9 Gi  │
└──────────────────────────────────────────────┘

┌──────────────────────────────────────────────┐
│  Node 2  label: dedicated=agent              │
│                                              │
│  kube-system daemonsets:  ~0.1 CPU / 0.2 Gi  │
│  app pod (long-running):   0.1 CPU / 0.1 Gi  │
│  up to 3 agent pods:      ~1.6 CPU / 3.5 Gi  │
│  ────────────────────────────────────────     │
│  Headroom:                ~2.2 CPU / 4.2 Gi  │
└──────────────────────────────────────────────┘
```

**Placement mechanism:**
- The **taint** on Node 1 (`dedicated=controller:NoSchedule`) prevents any pod from landing there unless the pod spec includes a matching `toleration`. Only the Jenkins controller and NGINX Ingress carry this toleration.
- The **label** on Node 2 (`dedicated=agent`) is the `nodeSelector` target for all Jenkins agent pod templates and the app deployment. No pod is *forced* to Node 2 — it is the only node that doesn't have the controller taint, so pods without the toleration schedule there naturally.
- Taints and labels are applied by `null_resource.node_placement` in `terraform/k8s-post/main.tf` using `az aks command invoke`. The oldest node (by `creationTimestamp`) becomes Node 1.

---

## Kubernetes namespace layout

```
kube-system   — AKS system components (CoreDNS, kube-proxy, omsagent)
jenkins       — Jenkins controller + ephemeral agent pods + K8s secrets
dev           — sample app (Helm release: platform-sample-app)
staging       — sample app after promotion through the approval gate
```

---

## Pipeline data flow

```
GitHub push / PR
      │
      ▼
Multibranch Pipeline (Jenkins — Jenkinsfile.build)
      │
      ├─ Stage 1: Checkout + Lint      nodejs-agent pod (Node 2)
      ├─ Stage 2: Unit Tests           nodejs-agent pod (Node 2)
      ├─ Stage 3: Docker Build + Push  nodejs-agent + DinD sidecar (Node 2)
      │               └──► ACR: platform-sample-app:<sha>
      │               └──► ACR: platform-sample-app-migrations:<sha>
      │
      ├─ Stage 4: DB Migration         helm-agent pod (Node 2)
      │               └──► az container create (ACI, one-shot)
      │                       └──► migrate.js → PostgreSQL (appdb)
      │                       └──► exits 0/1
      │
      ├─ Stage 5: Helm Deploy (dev)    helm-agent pod (Node 2)
      │               └──► helm upgrade --install → dev namespace
      │                       └──► app pod pulls image from ACR
      │
      ├─ Stage 6: Smoke Test           nodejs-agent pod (Node 2)
      │               └──► curl http://platform-sample-app.dev.svc.cluster.local:3000/health
      │
      ├─ Stage 7: Service Bus Notify   nodejs-agent pod (Node 2)
      │               └──► POST build-events queue (REST + HMAC-SHA256 SAS token)
      │
      ├─ Stage 8: Approval Gate        Jenkins controller (no agent pod)
      │               └──► input() — waits for admin click in Jenkins UI
      │               └──► only executes when branch == main
      │
      └─ Stage 9: Helm Promote         helm-agent pod (Node 2)
                      └──► helm upgrade --install → staging namespace
                              └──► same image tag as Stage 5
```

---

## Secret distribution chain

```
Terraform (random_password) ──► Azure Key Vault
                                      │
                     terraform/k8s-post/ reads secrets from Key Vault
                                      │
                    ┌─────────────────┼──────────────────────┐
                    │                 │                      │
          acr-pull-secret      jenkins-admin-          jenkins-pipeline-creds
          (dockerconfigjson)   credentials             (flat key-value)
          jenkins + dev +      jenkins ns              jenkins ns
          staging ns           │                       ├── ACR_USERNAME
                               │                       ├── ACR_PASSWORD
                               │                       ├── ACR_LOGIN_SERVER
                               │                       ├── POSTGRESQL_CONNECTION_STRING
                               │                       ├── RESOURCE_GROUP_NAME
                               │                       └── ACI_NAME
                               │
                  Helm values.yaml containerEnv
                  (secretKeyRef per-key)
                               │
                  Jenkins controller pod env vars
                               │
                  JCasC ${VAR_NAME} interpolation (credentials.yaml)
                               │
                  Jenkinsfile withCredentials{} / env {}
```

---

## Ingress routing

```
External request (from laptop, via /etc/hosts or DNS)
      │
      ▼
NGINX Ingress Controller  (Node 1, Azure LoadBalancer external IP)
      │
      ├─ jenkins.platform.internal  ──►  jenkins:8080 (jenkins ns)
      ├─ app.dev.platform.internal  ──►  platform-sample-app:3000 (dev ns)
      └─ app.staging.platform.internal ► platform-sample-app:3000 (staging ns)

Internal cluster DNS (CoreDNS):
  platform.internal queries ──► 168.63.129.16 (Azure internal resolver)
  Azure resolver answers from Private DNS Zone (platform.internal)
  Private DNS Zone is linked to the AKS VNet by terraform/modules/dns/
```

---

## RBAC layers

### Jenkins authorization (JCasC Matrix Strategy)

| Role | Permissions |
|---|---|
| `admin` | Hudson.Administer — full access |
| `developer` | Build, Cancel, Read, Workspace, ViewStatus on jobs |
| `viewer` | Read + ViewStatus only |

### Kubernetes RBAC

| Subject | Scope | Permissions |
|---|---|---|
| `jenkins-sa` (ServiceAccount) | ClusterRole | pods CRUD, pods/exec, pods/log (for K8s cloud plugin) |
| `dev-developer` (Group) | Role in `dev` ns | deployments + services + pods CRUD + rollback |
| `dev-viewer` (Group) | Role in `dev` ns | get/list/watch only |
