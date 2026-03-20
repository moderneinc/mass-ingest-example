variable "name" {
  type    = string
  default = "mass-ingest"
}

variable "resource_group_name" {
  type        = string
  description = "Azure resource group name"
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "vnet_name" {
  type        = string
  description = "Virtual network name"
}

variable "subnet_name" {
  type        = string
  description = "Subnet name for Batch pool nodes"
}

variable "nsg_name" {
  type        = string
  description = "Network Security Group name for the Batch subnet"
}

variable "image" {
  type        = string
  description = "Container image URL (e.g., myregistry.azurecr.io/mass-ingest:latest)"
}

variable "acr_name" {
  type        = string
  default     = ""
  description = "Azure Container Registry name (optional, for ACR authentication)"
}

variable "vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}

variable "max_nodes" {
  type    = number
  default = 64
}

variable "disk_size_gb" {
  type    = number
  default = 64
}

variable "moderne_tenant" {
  type        = string
  description = "Moderne tenant URL"
}

variable "key_vault_name" {
  type        = string
  description = "Key Vault name for storing secrets"
}

variable "publish_url" {
  type        = string
  description = "Artifact repository URL (Maven/Artifactory)"
}

variable "csv_file" {
  type    = string
  default = "repos.csv"
}

variable "chunk_size" {
  type    = number
  default = 10
}

variable "tags" {
  type = map(string)
  default = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
