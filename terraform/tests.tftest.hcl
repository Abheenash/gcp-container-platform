# Native terraform tests against a mocked provider — no GCP project, no cost.
# These assert the promises the README makes, especially around federation, which
# is the control with the worst failure mode on this cloud.

mock_provider "google" {
  # The pool's resource `name` is assigned by GCP, so the member string that
  # interpolates it is unknown at plan. Making it concrete lets the assertion
  # about repository scoping actually run — which is the one worth having.
  # Service account emails are derived by GCP from the account_id and project.
  override_resource {
    target          = google_service_account.app
    override_during = plan
    values = {
      email = "notes-app@test-project-000000.iam.gserviceaccount.com"
      name  = "projects/test-project-000000/serviceAccounts/notes-app@test-project-000000.iam.gserviceaccount.com"
    }
  }
  override_resource {
    target          = google_service_account.deploy
    override_during = plan
    values = {
      email = "notes-deploy@test-project-000000.iam.gserviceaccount.com"
      name  = "projects/test-project-000000/serviceAccounts/notes-deploy@test-project-000000.iam.gserviceaccount.com"
    }
  }
  override_resource {
    target          = google_iam_workload_identity_pool.github
    override_during = plan
    values = {
      name = "projects/000000000000/locations/global/workloadIdentityPools/notes-github"
    }
  }
}

variables {
  project_id = "test-project-000000"
}

run "ci_federation_cannot_be_used_by_another_repo" {
  command = plan

  # Without an attribute_condition, a workload identity pool provider trusts the
  # GitHub OIDC issuer GLOBALLY — any repository on GitHub could mint a token for
  # this project. It is the most dangerous single misconfiguration in GCP
  # federation, so it gets the most explicit test in this repo.
  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.sub == 'repo:${var.github_repo}:ref:refs/heads/main'"
    error_message = "The OIDC provider must pin assertion.sub (repo AND ref). Pinning only assertion.repository still admits every branch, tag and pull_request of that repo — a fork's PR could run with deploy rights."
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.oidc[0].issuer_uri == "https://token.actions.githubusercontent.com"
    error_message = "The issuer must be GitHub's OIDC endpoint."
  }

  assert {
    condition     = strcontains(google_service_account_iam_member.github_deploy.member, "subject/repo:${var.github_repo}:ref:refs/heads/main")
    error_message = "The impersonation binding must be scoped to the main-branch subject, not the whole pool."
  }
}

run "no_service_account_keys_are_created" {
  command = plan

  # A GCP service account key is a long-lived bearer credential with no expiry.
  # The whole point of federation here is that none exists. If someone adds one,
  # this plan grows a resource type that should never appear.
  assert {
    condition     = length(google_service_account.app.email) > 0 && length(google_service_account.deploy.email) > 0
    error_message = "Both service accounts must exist and be distinct — runtime and CI never share an identity."
  }
}

run "runtime_identity_is_not_a_database_admin" {
  command = plan

  # datastore.user is read+write on documents. datastore.owner would let the
  # service delete the database it depends on.
  assert {
    condition     = google_project_iam_member.app_firestore.role == "roles/datastore.user"
    error_message = "The runtime identity must hold datastore.user, not an admin role."
  }
}

run "images_are_immutable_and_the_database_is_protected" {
  command = plan

  assert {
    condition     = google_artifact_registry_repository.app.docker_config[0].immutable_tags
    error_message = "Tags must be immutable, or 'deployed image :abc123' is not a stable claim."
  }

  assert {
    condition     = google_firestore_database.main.delete_protection_state == "DELETE_PROTECTION_ENABLED"
    error_message = "The database holds the only copy of the data; deletion must require a deliberate change."
  }

  assert {
    condition     = google_firestore_database.main.point_in_time_recovery_enablement == "POINT_IN_TIME_RECOVERY_ENABLED"
    error_message = "PITR is off by default on Firestore, unlike DynamoDB PITR and Cosmos continuous backup. Turn it on explicitly."
  }
}

run "liveness_does_not_depend_on_the_database" {
  command = plan

  # The lesson from the EKS drill: a liveness probe that touches a dependency
  # gets pods KILLED during a dependency outage instead of drained.
  assert {
    condition     = google_cloud_run_v2_service.app.template[0].containers[0].liveness_probe[0].http_get[0].path == "/health"
    error_message = "Liveness must hit /health, which makes no backend call."
  }

  assert {
    condition     = google_cloud_run_v2_service.app.template[0].containers[0].startup_probe[0].http_get[0].path == "/ready"
    error_message = "Startup must hit /ready, which does check Firestore."
  }
}
