# Two identities, the same split as the other two clouds:
#   app     — what the running container is. Reads and writes its own Firestore
#             collection, pulls its own image, and nothing else.
#   deploy  — what CI is. Pushes images and updates the service. Never touches data.

resource "google_service_account" "app" {
  account_id   = "${local.name}-app"
  display_name = "Runtime identity for the ${local.name} Cloud Run service"
}

resource "google_service_account" "deploy" {
  account_id   = "${local.name}-deploy"
  display_name = "CI identity (GitHub Actions, keyless)"
}

# --- runtime permissions -----------------------------------------------------

# roles/datastore.user is read+write on documents but NOT admin on the database:
# the service cannot delete the database it depends on.
resource "google_project_iam_member" "app_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.app.email}"
}

resource "google_artifact_registry_repository_iam_member" "app_pull" {
  location   = google_artifact_registry_repository.app.location
  repository = google_artifact_registry_repository.app.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.app.email}"
}

# --- CI permissions ----------------------------------------------------------

resource "google_artifact_registry_repository_iam_member" "deploy_push" {
  location   = google_artifact_registry_repository.app.location
  repository = google_artifact_registry_repository.app.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_project_iam_member" "deploy_run" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.deploy.email}"
}

# Cloud Run needs the deployer to be able to "act as" the runtime account, or the
# revision cannot be created with that identity. This is GCP-specific and is the
# step people miss.
resource "google_service_account_iam_member" "deploy_acts_as_app" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deploy.email}"
}

# --- Workload Identity Federation: keyless CI --------------------------------
#
# GitHub's OIDC token is exchanged for a short-lived GCP token. No service account
# JSON key exists anywhere — which matters more here than on the other two clouds,
# because a leaked GCP SA key is a long-lived bearer credential with no expiry.
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "${local.name}-github"
  display_name              = "GitHub Actions"
  depends_on                = [google_project_service.required]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # WITHOUT a condition the pool would trust GitHub's OIDC issuer globally —
  # meaning ANY repository on GitHub could mint a token for this project. It is
  # the single most dangerous misconfiguration in GCP federation.
  #
  # Pinning `assertion.sub` rather than `assertion.repository` is the stricter
  # form and the one checkov's CKV_GCP_125 requires: repository alone still
  # admits every branch, tag and pull_request of that repo, so a PR from a fork
  # could run with deploy rights. The subject encodes repo AND ref together.
  attribute_condition = "assertion.sub == 'repo:${var.github_repo}:ref:refs/heads/main'"

  oidc {
    issuer_uri        = "https://token.actions.githubusercontent.com"
    allowed_audiences = ["https://github.com/${split("/", var.github_repo)[0]}"]
  }
}

# Only main-branch runs of this repo may impersonate the deploy account. The
# provider condition above already refuses anything else a token could claim;
# this binding is the second half of the same statement.
resource "google_service_account_iam_member" "github_deploy" {
  service_account_id = google_service_account.deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/subject/repo:${var.github_repo}:ref:refs/heads/main"
}
