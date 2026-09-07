variable "name" {
  type    = string
  default = "mass-ingest"
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(any)
}

variable "image_registry" {
  type = string
  # example = "123456789012.dkr.ecr.us-west-2.amazonaws.com/mass-ingest"
}

variable "image_tag" {
  type = string
  default = "latest"
}

variable "moderne_tenant" {
  type = string
  # example = "https://tenant.moderne.io"
}

variable "moderne_token" {
  type = string
  # example = "arn:aws:secretsmanager:us-east-1:123456789012:secret:mass-ingest/moderne"
}

variable "moderne_git_credentials" {
  type = string
  default = ""
  # example = "arn:aws:secretsmanager:us-east-1:123456789012:secret:mass-ingest/git-credentials"
}

variable "moderne_ssh_credentials" {
  type = string
  default = ""
  # example = "arn:aws:secretsmanager:us-east-1:123456789012:secret:mass-ingest/ssh-private-key"
}

variable "moderne_publish_url" {
  type = string
  # example = "http://artifactory.example.com/artifactory/moderne-ingest"
}

variable "moderne_publish_user" {
  type = string
  default = ""
  # example = "arn:aws:secretsmanager:us-east-1:123456789012:secret:mass-ingest/publishing:username::"
}

variable "moderne_publish_password" {
  type = string
  default = ""
  # example = "arn:aws:secretsmanager:us-east-1:123456789012:secret:mass-ingest/publishing:password::"
}

variable "moderne_publish_token" {
  type = string
  default = ""
  # example = "arn:aws:secretsmanager:us-east-1:123456789012:secret:mass-ingest/publishing:password::"
}

variable "moderne_s3_endpoint" {
  type = string
  default = ""
  description = "S3 endpoint URL for S3-compatible services like MinIO (optional)"
  # example = "https://minio.example.com"
}

variable "moderne_s3_region" {
  type = string
  default = ""
  description = "S3 region for cross-region bucket access (optional)"
  # example = "us-west-2"
}

variable "moderne_s3_bucket_name" {
  type        = string
  default     = ""
  description = "S3 bucket name for LST storage (optional, only needed if using S3 for artifact storage)"
}

variable "organizations" {
  type        = list(string)
  default     = []
  description = "Organizations from the store's repos.csv to ingest, one scheduled job each. Empty ingests the whole file in one job."
}

variable "job_timeout_seconds" {
  type        = number
  default     = 86400
  description = "AWS Batch attempt timeout. A run publishes as it goes and flushes the central repos-lock.csv when terminated, so a timed-out run loses only the repository in flight."
}

variable "instance_type" {
  type        = string
  default     = "m6a.xlarge"
  description = "EC2 instance type for batch compute environment"
}

variable "schedule_expression" {
  type        = string
  default     = "cron(0 0 * * ? *)"
  description = "EventBridge Scheduler expression (default: daily at midnight UTC)"
}

variable "default_tags" {
  type = map(string)
  default = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
