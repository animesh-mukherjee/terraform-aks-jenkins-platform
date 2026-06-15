# Runbook

Operational procedures for the AKS Jenkins Platform. All commands run **inside a
KodeKloud session** unless noted.

---

## 1. Provision the platform

```bash
./bootstrap/bootstrap.sh
```

**Phases (what to expect in the output):**

| Phase | Action | Healthy signal |
|---|---|---|
| 0 Preflight | tool + login checks, RG discovery | prints subscription id + RG name |
| 1 Local state | `apply -target=module.storage` | "state storage account: …" |
| 2 Migrate | `init -migrate-state` | "state now lives in Azure …" |
| 3 Full apply | `terraform apply` | "terraform apply complete" |
| 4 Kubeconfig | `az aks get-credentials` | `kubectl get nodes` lists 2 nodes |

---

## 2. Tear down the platform

```bash
./bootstrap/destroy.sh
```

Migrates remote state back to local, destroys everything (storage account included),
then resets the working tree. Idempotent — safe to re-run.

---

## 3. The two-phase state mechanic (reference)

```
bootstrap.sh                          destroy.sh
────────────                          ──────────
park backend.tf                       discover state storage account
terraform init            (local)     export ARM_ACCESS_KEY
apply -target=module.storage          park backend.tf
read storage outputs                  terraform init -migrate-state   (remote → local)
restore backend.tf                    terraform destroy               (everything)
init -migrate-state       (→ remote)  restore backend.tf
apply                     (full)      remove local state files
```

Why: a remote backend can't host the very storage account it depends on during create
or destroy, so we bracket those operations with local state.

---

## 4. Verifying a healthy platform

```bash
# Nodes: expect 2, with the controller node tainted and the agent node labelled
kubectl get nodes -o wide
kubectl describe node <node-1> | grep -i taint        # dedicated=controller:NoSchedule
kubectl get nodes -l dedicated=agent                  # node-2

# Core workloads
kubectl get pods -A
helm status jenkins -n <jenkins-namespace>

# Jenkins reachability (via NGINX ingress)
kubectl get ingress -A

# Secrets materialized from Key Vault
kubectl get secret -A | grep -E 'acr|jenkins|postgres'
```

---

## 5. Troubleshooting

| Problem | Diagnosis | Action |
|---|---|---|
| Bootstrap stops in Phase 1 with "module.storage not found" | Terraform modules not built yet | Expected until build Steps 2/12 are complete |
| `terraform apply` fails on a SKU/quota error | Value exceeds a sandbox limit | Compare against the [Service SKU limits](kk-session-guide.md#service-sku-limits) |
| Pods stuck `Pending` | Node taint/label or resource budget | `kubectl describe pod` → check tolerations / requests |
| `ImagePullBackOff` | imagePullSecret missing or wrong | Verify the ACR secret in the pod's namespace (ADR-005) |
| Jenkins agent never starts | `jenkins-sa` RBAC or Kubernetes cloud config | Check ClusterRole binding + JCasC `clouds.yaml` |
| Backend prompts for interactive migration | Ran `terraform` manually | Use the scripts (they pass `-migrate-state -force-copy`) |
| `backend.tf.bootstrap-parked` present | Interrupted run | Re-run the script (EXIT trap self-heals) or `git checkout terraform/` |

---

## 6. Manual escape hatch (if a script is interrupted)

```bash
cd terraform
# If backend.tf is parked, restore it
[ -f backend.tf.bootstrap-parked ] && mv backend.tf.bootstrap-parked backend.tf
# Re-point state. To go back to local:
terraform init -migrate-state
# Then re-run the appropriate script.
```

---

## 7. Routine pipeline operations (after the platform is up)

| Task | Where |
|---|---|
| Trigger a build | Jenkins multibranch job (auto on PR) or "Build Now" |
| Approve promotion to staging | Jenkins `input()` gate (Stage 8) |
| Inspect build/deploy notifications | Service Bus queue |
| Roll back a dev deployment | `helm rollback <release> -n dev` (developer role) |
| Run an ad-hoc DB migration | Pipeline Stage 4 (ACI one-shot) |
