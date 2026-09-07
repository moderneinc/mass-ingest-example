variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "name" {
  type    = string
  default = "mass-ingest"
}

variable "network" {
  type        = string
  description = "VPC network name or self_link"
  default     = "default"
}

variable "subnetwork" {
  type        = string
  description = "VPC subnetwork name or self_link"
  default     = "default"
}

variable "image_registry" {
  type        = string
  description = "Container image registry (e.g., us-docker.pkg.dev/project/repo/mass-ingest)"
}

variable "image_tag" {
  type    = string
  default = "latest"
}

variable "machine_type" {
  type    = string
  default = "n2-standard-4"
}

variable "boot_disk_size_gb" {
  type    = number
  default = 64
}

variable "moderne_tenant" {
  type        = string
  description = "Moderne tenant URL (e.g., https://app.moderne.io)"
}

variable "moderne_token_secret" {
  type        = string
  description = "Secret Manager secret name for Moderne token"
  default     = "mass-ingest-moderne-token"
}

variable "git_credentials_secret" {
  type        = string
  default     = ""
  description = "Secret Manager secret name for git credentials (optional)"
}

variable "ssh_credentials_secret" {
  type        = string
  default     = ""
  description = "Secret Manager secret name for SSH private key (optional)"
}

variable "publish_url" {
  type        = string
  description = "Artifact repository URL (Maven/Artifactory URL or s3:// with S3_ENDPOINT for GCS interop)"
}

variable "publish_user_secret" {
  type        = string
  default     = ""
  description = "Secret Manager secret name for publish username (optional)"
}

variable "publish_password_secret" {
  type        = string
  default     = ""
  description = "Secret Manager secret name for publish password (optional)"
}

variable "publish_token_secret" {
  type        = string
  default     = ""
  description = "Secret Manager secret name for publish token (optional, alternative to user/password)"
}

variable "s3_endpoint" {
  type        = string
  default     = ""
  description = "S3-compatible endpoint for GCS interop (e.g., https://storage.googleapis.com)"
}

variable "s3_region" {
  type        = string
  default     = ""
  description = "S3 region for GCS interop (e.g., auto)"
}

variable "organizations" {
  type        = list(string)
  default     = []
  description = "Organizations from the store's repos.csv to ingest, one Batch task each. Empty ingests the whole file in one task."
}

variable "max_run_duration_seconds" {
  type        = number
  default     = 86400
  description = "Batch task timeout. A run publishes as it goes and flushes the central repos-lock.csv when terminated, so a timed-out run loses only the repository in flight."
}

variable "max_retry_count" {
  type        = number
  default     = 0
  description = "Maximum retries per task (useful with Spot VMs where tasks can be preempted)"
}

variable "schedule" {
  type        = string
  default     = "0 0 * * *"
  description = "Cron schedule for the batch job (default: daily at midnight UTC)"
}

variable "labels" {
  type = map(string)
  default = {
    environment = "production"
    managed-by  = "terraform"
  }
}
