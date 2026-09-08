variable "name" {
  type        = string
  default     = "mass-ingest"
  description = "Prefix for the resources created by this module"
}

variable "resource_group_name" {
  type        = string
  description = "Existing resource group for the Batch account, pool, identity and Automation account"
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "batch_account_name" {
  type        = string
  default     = ""
  description = "Batch account name: 3-24 lowercase letters and digits, unique within the region. Defaults to var.name without hyphens."

  validation {
    condition     = var.batch_account_name == "" || can(regex("^[a-z0-9]{3,24}$", var.batch_account_name))
    error_message = "batch_account_name must be 3-24 lowercase letters and digits."
  }
}

variable "vnet_name" {
  type        = string
  description = "Existing virtual network for the Batch pool nodes"
}

variable "subnet_name" {
  type        = string
  description = "Existing subnet for the Batch pool nodes (needs outbound internet access)"
}

variable "nsg_name" {
  type        = string
  default     = ""
  description = "Network security group on the Batch subnet. When set, an inbound rule for the CLI metrics port (8080) is added for Prometheus scraping."
}

variable "metrics_nsg_rule_priority" {
  type        = number
  default     = 200
  description = "Priority of the metrics NSG rule (must be unused in the NSG)"
}

variable "image" {
  type        = string
  description = "Container image, e.g. myregistry.azurecr.io/mass-ingest:latest. Build it with chunk.sh and task.sh included (see README)."
}

variable "acr_name" {
  type        = string
  default     = ""
  description = "Azure Container Registry name. When set, the pool identity gets AcrPull and the pool authenticates to the registry with it."
}

variable "acr_resource_group_name" {
  type        = string
  default     = ""
  description = "Resource group of the ACR (defaults to resource_group_name)"
}

variable "vm_size" {
  type        = string
  default     = "Standard_D4s_v5"
  description = "VM size for pool nodes. Each processor task gets a whole node."
}

variable "max_nodes" {
  type        = number
  default     = 64
  description = "Maximum number of pool nodes (concurrent processor tasks)"
}

variable "moderne_tenant" {
  type        = string
  description = "Moderne tenant URL (e.g. https://app.moderne.io)"
}

variable "key_vault_name" {
  type        = string
  description = "Existing Key Vault holding the secrets read by task.sh (moderne-token, git-credentials, ssh-private-key, publish-user, publish-password, publish-token)"
}

variable "key_vault_resource_group_name" {
  type        = string
  default     = ""
  description = "Resource group of the Key Vault (defaults to resource_group_name)"
}

variable "publish_url" {
  type        = string
  description = "Artifact repository URL for LSTs (Maven/Artifactory)"
}

variable "csv_file" {
  type        = string
  default     = "repos.csv"
  description = "repos.csv location: an HTTPS URL fetched at runtime (must be readable without extra auth, e.g. a blob SAS URL) or a path inside the container image, relative to /app"

  validation {
    condition     = var.csv_file != "" && !can(regex("\\s", var.csv_file))
    error_message = "csv_file must be a non-empty URL or path without whitespace."
  }
}

variable "chunk_size" {
  type        = number
  default     = 10
  description = "Repositories per processor task"
}

variable "tags" {
  type = map(string)
  default = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
