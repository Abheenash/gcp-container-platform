resource "google_artifact_registry_repository" "app" {
  location      = var.region
  repository_id = "${local.name}-images"
  format        = "DOCKER"
  description   = "Container images for ${local.name}"
  labels        = local.labels

  # Keep the last 10 tagged images and drop untagged layers after a week. ECR
  # needs a lifecycle policy for this; ACR needs a retention setting; here it is
  # a first-class block.
  cleanup_policies {
    id     = "keep-recent-tagged"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
  cleanup_policies {
    id     = "drop-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s" # 7 days
    }
  }

  # Refuse to overwrite an existing tag. The AWS side gets this from ECR's
  # imageTagMutability; it is what makes "deployed image :abc123" a stable claim.
  docker_config {
    immutable_tags = true
  }

  depends_on = [google_project_service.required]
}
