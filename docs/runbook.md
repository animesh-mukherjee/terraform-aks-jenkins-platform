# Runbook

Day-to-day operations for the AKS Jenkins Platform.
All commands assume a live KK session with `~/.kube/config` written.

---

## Deploy a new version

### Via the main pipeline (normal flow)

1. Push code to a branch.
2. Jenkins Multibranch detects it and runs `Jenkinsfile.build`.
3. Stages 1–7 run automatically.
4. If branch is `main`, Stage 8 pauses for approval.
5. Log in to Jenkins as `admin`, approve to promote to staging.

### Via the standalone deploy pipeline (specific tag)

```bash
# Find available tags in ACR
ACR_NAME=$(cd terraform && terraform output -raw acr_login_server | cut -d. -f1)
az acr repository show-tags \
  --name "$ACR_NAME" \
  --repository platform-sample-app \
  --orderby time_desc --top 10 -o table
```

Trigger `Jenkinsfile.deploy` in Jenkins UI with:
- `IMAGE_TAG` = the 8-char git SHA
- `ENVIRONMENT` = `dev` or `staging`

---

## Rollback a deployment

### Helm rollback (fastest — reverts to previous release revision)

```bash
# Show history
helm history platform-sample-app --namespace dev

# Roll back to the previous revision
helm rollback platform-sample-app --namespace dev --wait

# Roll back to a specific revision number
helm rollback platform-sample-app 3 --namespace dev --wait

# Verify
kubectl rollout status deployment/platform-sample-app -n dev
```

### Redeploy a known-good image tag

Use `Jenkinsfile.deploy` with the SHA of the last green build.
The pipeline validates the tag exists in ACR before deploying.

---

## Check logs

### Jenkins controller

```bash
kubectl logs deployment/jenkins -n jenkins --tail=100 -f
```

### Jenkins agent pod (during/after a build)

```bash
# List current and recent agent pods
kubectl get pods -n jenkins

# Logs from the main container of a nodejs-agent pod
kubectl logs <pod-name> -n jenkins -c nodejs --tail=200

# Logs from the DinD sidecar
kubectl logs <pod-name> -n jenkins -c docker --tail=100
```

### Application pod

```bash
# dev namespace — follow logs from the running app
kubectl logs -l app.kubernetes.io/instance=platform-sample-app \
  -n dev --tail=100 -f

# staging namespace
kubectl logs -l app.kubernetes.io/instance=platform-sample-app \
  -n staging --tail=100 -f
```

### ACI migration container

```bash
RG=$(kubectl get secret jenkins-pipeline-creds -n jenkins \
  -o jsonpath='{.data.RESOURCE_GROUP_NAME}' | base64 -d)
ACI=$(kubectl get secret jenkins-pipeline-creds -n jenkins \
  -o jsonpath='{.data.ACI_NAME}' | base64 -d)

az container logs --resource-group "$RG" --name "$ACI"

# Check exit code of the last run
az container show \
  --resource-group "$RG" --name "$ACI" \
  --query "containers[0].instanceView.currentState" -o json
```

---

## Debug a failed pipeline stage

### Stage 1 (Lint) failed

```bash
cd app-sample
npm ci
npm run lint

# Auto-fix most issues
npm run lint -- --fix
```

### Stage 2 (Tests) failed

```bash
cd app-sample
npm ci
npm test

# Run a single describe block
npx mocha test/app.test.js --grep "POST /api/items"
```

### Stage 3 (Docker build) failed

Check DinD sidecar:
```bash
kubectl logs <nodejs-agent-pod> -n jenkins -c docker --tail=50
```

Common causes:
- DinD not ready — the Stage 3 retry loop waits 15× 5 s; if DinD hasn't started by then, it failed. Check the sidecar logs above.
- ACR login failed — verify `ACR_USERNAME` and `ACR_PASSWORD` in `jenkins-pipeline-creds` secret.
- Dockerfile syntax error — check `docker build` output in the Jenkins console log.

### Stage 4 (DB migration) failed

```bash
# View migration container output
az container logs --resource-group "$RG" --name "$ACI"

# Check exit code
az container show \
  --resource-group "$RG" --name "$ACI" \
  --query "containers[0].instanceView.currentState.exitCode"
```

Common causes:
- SQL syntax error in `db/migrations/*.sql`
- PostgreSQL unreachable — verify `POSTGRESQL_CONNECTION_STRING` in secret
- ACI image pull failure — verify `ACR_USERNAME`/`ACR_PASSWORD` are correct and the image tag was actually pushed to ACR in Stage 3

### Stage 5 (Helm deploy) failed

```bash
helm status platform-sample-app --namespace dev

kubectl describe deployment platform-sample-app -n dev
kubectl get events -n dev --sort-by=.lastTimestamp
```

If the pod can't start, check what the readiness probe returns:
```bash
kubectl port-forward svc/platform-sample-app 3000:3000 -n dev &
curl http://localhost:3000/health
```

### Stage 6 (Smoke test) failed

The 15 curl retries (75 seconds) all returned non-200.

```bash
# Is the pod actually Running?
kubectl get pods -n dev

# Hit the health endpoint directly
kubectl port-forward svc/platform-sample-app 3000:3000 -n dev &
curl -v http://localhost:3000/health
```

Common cause: the app pod is Running but the database isn't reachable.
The `/health` endpoint returns 503 if the PostgreSQL ping fails.
Check the app pod logs and verify `DATABASE_URL` is correct:
```bash
kubectl exec -n dev deploy/platform-sample-app -- \
  env | grep -E "DATABASE_URL|DB_SSL"
```

### Stage 8 (Approval) timed out

The 30-minute window expired. The build is ABORTED, not FAILED.
Re-trigger with `Build Now` or push a new commit. The pipeline restarts from Stage 1.

---

## Inspect the running application

### Via kubectl port-forward (works without DNS)

```bash
# App (dev)
kubectl port-forward svc/platform-sample-app 3000:3000 -n dev &
curl http://localhost:3000/health
curl http://localhost:3000/api/items
curl http://localhost:3000/api/config
curl -X POST http://localhost:3000/api/items \
  -H "Content-Type: application/json" \
  -d '{"name": "test item"}'

# Jenkins
kubectl port-forward svc/jenkins 8080:8080 -n jenkins &
open http://localhost:8080
```

### Via NGINX Ingress (with /etc/hosts)

```bash
NGINX_IP=$(kubectl get svc ingress-nginx-controller \
  -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Add to /etc/hosts (Linux/macOS) or
# C:\Windows\System32\drivers\etc\hosts (Windows, run as Admin)
echo "$NGINX_IP jenkins.platform.internal" | sudo tee -a /etc/hosts
echo "$NGINX_IP app.dev.platform.internal" | sudo tee -a /etc/hosts
echo "$NGINX_IP app.staging.platform.internal" | sudo tee -a /etc/hosts

curl http://app.dev.platform.internal/health
```

---

## Rotate secrets

### Jenkins admin password

```bash
NEW_PASS=$(openssl rand -base64 20 | tr -dc 'A-Za-z0-9' | head -c 20)
echo "New password: $NEW_PASS"

kubectl patch secret jenkins-admin-credentials -n jenkins \
  --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/data/jenkins-admin-password\",\"value\":\"$(echo -n "$NEW_PASS" | base64)\"}]"

# Restart Jenkins to reload the secret
kubectl rollout restart deployment/jenkins -n jenkins
kubectl rollout status deployment/jenkins -n jenkins
```

### ACR credentials (after regenerating in Azure Portal)

```bash
ACR_NAME=$(cd terraform && terraform output -raw acr_login_server | cut -d. -f1)
NEW_ACR_PASS=$(az acr credential show \
  --name "$ACR_NAME" --query "passwords[0].value" -o tsv)

# Update jenkins-pipeline-creds
kubectl patch secret jenkins-pipeline-creds -n jenkins \
  --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/data/ACR_PASSWORD\",\"value\":\"$(echo -n "$NEW_ACR_PASS" | base64)\"}]"

# Rebuild acr-pull-secret in all namespaces
for NS in jenkins dev staging; do
  kubectl delete secret acr-pull-secret -n "$NS" --ignore-not-found
done

# Re-run k8s-post to recreate the pull secrets
cd terraform/k8s-post
terraform apply -auto-approve
```

---

## Check cluster health

```bash
# Nodes Ready and correctly placed
kubectl get nodes -o wide
kubectl describe nodes | grep -E "(Name:|Taints:|Labels:)" | grep -A2 "Taints"

# All system pods Running
kubectl get pods -n kube-system

# Jenkins controller Running on Node 1
kubectl get pod -n jenkins -o wide -l app.kubernetes.io/name=jenkins

# App pods Running on Node 2
kubectl get pods -n dev -o wide
kubectl get pods -n staging -o wide

# Resource usage
kubectl top nodes
kubectl top pods -n jenkins
kubectl top pods -n dev
```

---

## Scale the application (within KK limits)

KK limits AKS to 2 nodes total. The app and Jenkins share Node 2.
Do NOT scale above `replicaCount: 2` — you will evict Jenkins agents.

```bash
# Scale to 2 replicas (use only if Node 2 has headroom)
helm upgrade platform-sample-app app-sample/helm/app-chart \
  --namespace dev \
  --reuse-values \
  --set replicaCount=2
```

---

## Destroy the app (K8s resources only)

Removes Helm releases. Does NOT destroy Azure resources.

```bash
# Via Jenkinsfile.destroy (safe — has double confirmation gate):
# Jenkins UI → Build with Parameters:
#   ENVIRONMENT = dev
#   CONFIRM_DESTROY = true

# Manually:
helm uninstall platform-sample-app --namespace dev --wait
helm uninstall platform-sample-app --namespace staging --wait

kubectl get all -n dev      # should show nothing
kubectl get all -n staging  # should show nothing
```

---

## Destroy all Azure infrastructure

Run before the KK session expires. This cannot be undone within the session.

```bash
cd bootstrap
./destroy.sh
```

If `destroy.sh` fails:

```bash
# Manually delete Helm releases first
helm uninstall jenkins -n jenkins --ignore-not-found
helm uninstall platform-sample-app -n dev --ignore-not-found
helm uninstall platform-sample-app -n staging --ignore-not-found

# Destroy k8s-post root
cd terraform/k8s-post
terraform destroy -auto-approve

# Destroy main root
cd ../
terraform destroy -auto-approve

# If Terraform fails on AKS (common — K8s API is gone once the cluster deletes):
az aks delete --resource-group "<RG>" --name "<CLUSTER_NAME>" --yes
# Then remove AKS from Terraform state and re-run destroy
terraform state rm module.aks.azurerm_kubernetes_cluster.main
terraform destroy -auto-approve
```
