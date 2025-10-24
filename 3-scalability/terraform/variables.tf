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
  # example = "arn:aws:secretsmanager:us-west-2:123456789012:secret:mass-ingest/publishing:password::"
}

variable "moderne_publish_token" {
  type = string
  default = ""
  # example = "arn:aws:secretsmanager:us-west-2:123456789012:secret:mass-ingest/publishing:password::"
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
