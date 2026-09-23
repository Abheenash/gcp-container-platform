# Firestore in Native mode — the closest GCP analogue to DynamoDB on-demand and
# Cosmos serverless: pay per operation, no capacity to provision.
resource "google_firestore_database" "main" {
  name        = "(default)"
  location_id = var.region
  type        = "FIRESTORE_NATIVE"

  # Point-in-time recovery: the equivalent of DynamoDB PITR and Cosmos continuous
  # backup, and off by default here unlike both of them.
  point_in_time_recovery_enablement = "POINT_IN_TIME_RECOVERY_ENABLED"
  delete_protection_state           = "DELETE_PROTECTION_ENABLED"

  depends_on = [google_project_service.required]
}

# NOTE — Firestore security rules.
#
# Rules are a Firestore concept with no AWS or Azure equivalent: they govern
# access from UNTRUSTED clients (a browser or mobile app talking to Firestore
# directly, with no server in between). This service never does that — every read
# and write goes through Cloud Run under a service account, so IAM is the control
# and rules are not in the path.
#
# That is worth stating explicitly rather than leaving as an absence, because the
# default rules on a new database allow full access for 30 days and then deny
# everything, and a project that relies on them silently breaks on day 31.
