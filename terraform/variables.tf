variable "project_id" {
  description = "GCP project to deploy into. Required — there is no sensible default."
  type        = string
}

variable "region" {
  description = "Cloud Run and Artifact Registry region"
  type        = string
  default     = "us-central1"
}

variable "name_prefix" {
  type    = string
  default = "notes"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}$", var.name_prefix))
    error_message = "Must be 2-19 chars, lowercase alphanumeric or hyphen, starting with a letter (Cloud Run service name rules)."
  }

  # GCP reserves the "gcp-", "goog" and "google" prefixes on workload identity
  # pool ids. The obvious default for this repo was "gcp", which fails at APPLY
  # time with a message that does not mention the pool — caught here instead by
  # tests.tftest.hcl, and pinned so it cannot come back.
  validation {
    condition     = !startswith(var.name_prefix, "gcp-") && var.name_prefix != "gcp" && !startswith(var.name_prefix, "goog")
    error_message = "name_prefix must not start with 'gcp-', 'goog' or be 'gcp': those prefixes are reserved for workload identity pool ids."
  }
}

variable "image_tag" {
  type    = string
  default = "v0.1.0"
}

variable "github_repo" {
  description = "owner/repo allowed to federate into the deploy service account (keyless CI)"
  type        = string
  default     = "Abheenash/gcp-container-platform"
}

variable "min_instances" {
  description = "0 enables scale-to-zero, and with it cold starts. The whole point of Cloud Run."
  type        = number
  default     = 0
}

variable "max_instances" {
  type    = number
  default = 4
}
