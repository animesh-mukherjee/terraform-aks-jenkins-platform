# KodeKloud Session Guide

KodeKloud Azure Playground sessions are time-limited (60–240 minutes).
Every session starts with a blank Azure subscription. Follow this guide
in order every time you start a new session.

---

## One-time setup (do this once, not per session)

### 1. Clone the repo

```bash
git clone https://github.com/animeshmkhrj/terraform-aks-jenkins-platform
cd terraform-aks-jenkins-platform
```

### 2. Create the GitHub `production` environment

GitHub repo → Settings → Environments → New environment → name: `production`

Add yourself as a Required Reviewer. This adds a manual approval click
before `terraform apply` runs on every merge to `main`. Without it, apply
runs automatically.

### 3. Install local tools

```bash
# Windows (winget)
winget install HashiCorp.Terraform
winget install Microsoft.AzureCLI
winget install Helm.Helm
winget install Kubernetes.kubectl

# macOS (brew)
brew install terraform azure-cli helm kubectl
```

Required versions: Terraform >= 1.9, az CLI >= 2.55, Helm >= 3.14, kubectl >= 1.28.

---

## Session start (repeat each KK session)

### Step 1 — Start the KK lab and note credentials

Start the lab in the KodeKloud portal. Wait ~3 minutes for provisioning.

Note these values — they change every session:

```
Subscription ID:  _______________________________
Tenant ID:        _______________________________
Resource Group:   _______________________________   (e.g. "Regroup_12345")
SP Client ID:     _______________________________
SP Client Secret: _______________________________
```

> **Finding the Service Principal:** Azure Portal → Azure Active Directory →
> App Registrations. Or copy the credentials the KK lab panel provides directly.

### Step 2 — Azure CLI login

```bash
az login --username "<kk-username>" --password "<kk-password>"
az account set --subscription "<subscription-id>"
az account show --query "{name:name,id:id}" -o table   # verify
```

### Step 3 — Update GitHub Secrets

GitHub repo → Settings → Secrets and variables → Actions → Repository secrets

Update these secrets with the current KK session values:

| Secret | Value |
|---|---|
| `ARM_CLIENT_ID` | SP Application (client) ID |
| `ARM_CLIENT_SECRET` | SP client secret |
| `ARM_SUBSCRIPTION_ID` | Subscription ID |
| `ARM_TENANT_ID` | Directory (tenant) ID |
| `RESOURCE_GROUP_NAME` | KK-provided resource group name |
| `TF_VAR_PREFIX` | Your prefix, e.g. `animesh` (set once, never changes) |

> `STORAGE_ACCOUNT_NAME` is set in Step 6 after the storage account exists.

### Step 4 — Run bootstrap.sh

```bash
cd bootstrap
chmod +x bootstrap.sh destroy.sh
./bootstrap.sh
```

The script does (in order):
1. Prompts for `PREFIX` and `RESOURCE_GROUP_NAME` (or reads from env vars)
2. `terraform init -backend=false` (local state, storage doesn't exist yet)
3. `terraform apply -target=module.storage` (creates storage account + container)
4. `terraform init -migrate-state -force-copy` (migrates local state to Azure blob)
5. `terraform apply` (provisions all remaining Azure resources — ~15–20 min)
6. `az aks get-credentials` (writes `~/.kube/config`)
7. `kubectl apply -k k8s/rbac/` (applies RBAC manifests)
8. `terraform -chdir=k8s-post init && apply` (creates K8s Secrets, node placement)

Total expected time: **20–30 minutes**.

### Step 5 — Install NGINX Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace kube-system \
  --set controller.tolerations[0].key=dedicated \
  --set controller.tolerations[0].operator=Equal \
  --set controller.tolerations[0].value=controller \
  --set controller.tolerations[0].effect=NoSchedule \
  --set controller.nodeSelector.dedicated='' \
  --wait --timeout 5m
```

### Step 6 — Update STORAGE_ACCOUNT_NAME secret

```bash
cd terraform
terraform output -raw storage_account_name
```

Copy the output and add it to GitHub Secrets as `STORAGE_ACCOUNT_NAME`.
This lets the GitHub Actions workflows init the backend correctly.

### Step 7 — Install Jenkins via Helm

```bash
helm repo add jenkins https://charts.jenkins.io
helm repo update

helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins \
  --values helm/jenkins/values.yaml \
  --wait --timeout 12m
```

Expected startup time: **6–10 minutes** (plugin downloads on cold start).

### Step 8 — Apply the JCasC ConfigMap

```bash
kubectl apply -k jenkins/casc/
```

If Jenkins is already running, reload JCasC without a restart:

```bash
JENKINS_URL="http://jenkins.platform.internal"
ADMIN_PASS=$(kubectl get secret jenkins-admin-credentials -n jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)

curl -s -X POST "${JENKINS_URL}/reload-configuration-as-code/?casc-reload-token=reload" \
  -u "admin:${ADMIN_PASS}"
```

### Step 9 — Verify the platform is healthy

```bash
# All pods Running
kubectl get pods -A

# Node placement is correct (Node 1 = controller taint, Node 2 = agent label)
kubectl describe nodes | grep -E "Taints|Labels" -A3

# Jenkins accessible
kubectl port-forward svc/jenkins 8080:8080 -n jenkins &

# Get the admin password
kubectl get secret jenkins-admin-credentials -n jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
echo ""
```

Open `http://localhost:8080` in a browser. Log in as `admin` with the password above.

### Step 10 — Trigger the first pipeline run

Option A: Push a commit to any branch in the GitHub repo.

Option B: In Jenkins UI:
1. Dashboard → platform-sample-app
2. Scan Multibranch Pipeline Now
3. Click the branch → Build Now

Watch the build progress in Blue Ocean.

---

## Session end checklist

Run **at least 15 minutes before** the KK session timer expires.

### Step 1 — Destroy all infrastructure

```bash
cd bootstrap
./destroy.sh
```

The destroy script (in order):
1. `helm uninstall jenkins -n jenkins --wait`
2. `helm uninstall platform-sample-app -n dev --wait` (if installed)
3. `helm uninstall platform-sample-app -n staging --wait` (if installed)
4. `terraform -chdir=../terraform/k8s-post destroy -auto-approve`
5. `terraform -chdir=../terraform destroy -auto-approve`

Expected time: **5–10 minutes**.

### Step 2 — Verify no resources remain

```bash
az resource list \
  --resource-group "<RESOURCE_GROUP_NAME>" \
  --query "[].{name:name, type:type}" \
  -o table
```

The list should be empty (or show only the resource group itself, which KK owns).

### Step 3 — Clean up local kubeconfig

```bash
# List contexts
kubectl config get-contexts

# Remove the AKS entry (name contains your cluster name)
kubectl config delete-context <aks-context-name>
kubectl config delete-cluster <aks-cluster-name>
kubectl config delete-user <aks-user-name>
```

---

## Common problems and fixes

### `az login` fails: "No subscriptions found"

Use the tenant flag:
```bash
az login --username "<email>" --password "<pass>" --tenant "<tenant-id>"
az account set --subscription "<subscription-id>"
```

### bootstrap.sh fails at Phase 2 init: backend not found

The storage account wasn't created in Phase 1. Run manually:
```bash
cd terraform
terraform init -backend=false -no-color
terraform apply -target=module.storage -auto-approve -no-color
# Then re-run bootstrap.sh — it will migrate state correctly
```

### Jenkins pod stuck in Pending

```bash
kubectl describe pod -n jenkins -l app.kubernetes.io/name=jenkins
kubectl get events -n jenkins --sort-by=.lastTimestamp
```

Usually a resource issue on Node 1 (or wrong node placement). Check:
```bash
kubectl describe node | grep -A8 "Allocated resources"
```

If the taint is missing from Node 1, re-apply:
```bash
cd terraform/k8s-post
terraform apply -auto-approve
```

### Jenkins plugin download fails on startup

KK sometimes has intermittent internet access. Check the init container:
```bash
kubectl logs -n jenkins -l app.kubernetes.io/name=jenkins -c init
```

Restart the pod to retry:
```bash
kubectl rollout restart deployment/jenkins -n jenkins
```

### terraform destroy fails on AKS cluster

```bash
# Force-delete the AKS cluster directly
az aks delete --resource-group "<RG>" --name "<CLUSTER_NAME>" --yes --no-wait

# Wait ~3 minutes, then re-run destroy
cd terraform
terraform destroy -auto-approve \
  -var="resource_group_name=<RG>" \
  -var="prefix=<PREFIX>"
```

### GitHub Actions plan fails: "AuthorizationFailed"

KK credentials have been rotated (new session). Update `ARM_CLIENT_ID`,
`ARM_CLIENT_SECRET`, `ARM_SUBSCRIPTION_ID`, `ARM_TENANT_ID` in GitHub Secrets.
