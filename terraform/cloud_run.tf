resource "google_cloud_run_v2_service" "app" {
  name     = "${local.name}-app"
  location = var.region
  labels   = local.labels

  # Ingress is open because this is a public read/write demo API, exactly like the
  # ALB and Container Apps ingress on the other two. INGRESS_TRAFFIC_INTERNAL_ONLY
  # is the switch if that ever changes.
  ingress = "INGRESS_TRAFFIC_ALL"

  deletion_protection = false

  template {
    service_account = google_service_account.app.email

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    # Cloud Run's unit of concurrency is requests-per-instance, not CPU. 80 is the
    # default; this API is IO-bound so it holds up, and it is the number the
    # autoscaler actually reacts to.
    max_instance_request_concurrency = 80
    timeout                          = "30s"

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.app.repository_id}/app:${var.image_tag}"

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        # CPU only while a request is in flight — this is what makes
        # scale-to-zero cheap, and it has no AWS/Azure equivalent in this shape.
        cpu_idle          = true
        startup_cpu_boost = true
      }

      ports {
        container_port = 8080
      }

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "FIRESTORE_DATABASE"
        value = google_firestore_database.main.name
      }
      env {
        name  = "FIRESTORE_COLLECTION"
        value = "notes"
      }

      # Liveness must not depend on Firestore; readiness must. Same split as the
      # other two builds — Cloud Run calls them startup and liveness probes.
      startup_probe {
        http_get {
          path = "/ready"
          port = 8080
        }
        initial_delay_seconds = 2
        period_seconds        = 3
        failure_threshold     = 10
        timeout_seconds       = 3
      }

      liveness_probe {
        http_get {
          path = "/health"
          port = 8080
        }
        period_seconds    = 15
        failure_threshold = 3
        timeout_seconds   = 3
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [
    google_project_iam_member.app_firestore,
    google_artifact_registry_repository_iam_member.app_pull,
  ]
}

# Public invocation. Without this the service returns 403 to everyone — Cloud Run
# is private by default, which differs from both an ALB and Container Apps ingress.
resource "google_cloud_run_v2_service_iam_member" "public" {
  location = google_cloud_run_v2_service.app.location
  name     = google_cloud_run_v2_service.app.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
