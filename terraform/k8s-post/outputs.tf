# k8s-post/ outputs are minimal — most consumed values come from the root
# module's state, not from this root. These outputs are useful for
# confirming successful apply and for scripting post-apply steps.

output "namespaces" {
  description = "Names of the Kubernetes namespaces created by this root. Verify with `kubectl get namespaces`."
  value = [
    kubernetes_namespace.jenkins.metadata[0].name,
    kubernetes_namespace.dev.metadata[0].name,
    kubernetes_namespace.staging.metadata[0].name,
  ]
}

output "acr_pull_secret_name" {
  description = "Name of the imagePullSecret created in each namespace (\"acr-pull-secret\"). Reference this in Helm chart values: imagePullSecrets: [{name: acr-pull-secret}]."
  value       = "acr-pull-secret"
}

output "jenkins_admin_secret_name" {
  description = "Name of the Jenkins admin credentials K8s Secret (\"jenkins-admin-credentials\"). Referenced in helm/jenkins/values.yaml as the admin.existingSecret value."
  value       = kubernetes_secret.jenkins_admin.metadata[0].name
}

output "app_db_secret_name" {
  description = "Name of the app DB credentials K8s Secret (\"app-db-credentials\"). Referenced in the sample app Helm chart values as envFrom.secretRef.name."
  value       = "app-db-credentials"
}

output "coredns_custom_configmap" {
  description = "Name of the CoreDNS custom ConfigMap (\"coredns-custom\" in kube-system). Verify DNS forwarding with: kubectl exec -n jenkins <pod> -- nslookup platform.internal"
  value       = kubernetes_config_map.coredns_custom.metadata[0].name
}
