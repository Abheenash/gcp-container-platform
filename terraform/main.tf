data "google_project" "current" {}

locals {
  name = var.name_prefix
  labels = {
    project    = "gcp-container-platform"
    managed-by = "terraform"
    mirrors    = "secure-container-pipeline"
  }
}

# Enabling APIs in Terraform rather than by hand: a fresh project is otherwise a
# sequence of "API not enabled" errors discovered one apply at a time.
resource "google_project_service" "required" {
  for_each = toset([
    "run.googleapis.com",
    "firestore.googleapis.com",
    "artifactregistry.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])
  service = each.value

  # Leave the APIs on if this stack is destroyed — disabling them would break
  # anything else in the project that also uses them.
  disable_on_destroy = false
}
