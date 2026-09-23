terraform {
  required_version = ">= 1.9"

  required_providers {
    google = { source = "hashicorp/google", version = "~> 8.0" }
  }

  # Remote state — bootstrap a GCS bucket once, then uncomment.
  # backend "gcs" {
  #   bucket = "abheenash-tfstate-<project>"
  #   prefix = "gcp-container-platform"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
