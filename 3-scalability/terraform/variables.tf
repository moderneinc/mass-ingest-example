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

variable "moderne_s3_profile" {
  type = string
  default = ""
  description = "AWS profile name for S3 access (optional, uses IAM instance profile by default)"
  # example = "default"
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

variable "ingest_csv_file" {
  type = string
  default = "repos.csv"
}

variable "ingest_chunk_size" {
  type = number
  default = 10
}

variable "default_tags" {
  type = map(string)
  default = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
