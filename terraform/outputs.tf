output "service_url" {
  description = "Public HTTPS endpoint (Cloud Run provisions the certificate)"
  value       = google_cloud_run_v2_service.app.uri
}

output "registry" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.app.repository_id}"
}

output "workload_identity_provider" {
  description = "Set as WIF_PROVIDER in GitHub repo variables for keyless CI"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "deploy_service_account" {
  description = "Set as WIF_SERVICE_ACCOUNT in GitHub repo variables"
  value       = google_service_account.deploy.email
}
