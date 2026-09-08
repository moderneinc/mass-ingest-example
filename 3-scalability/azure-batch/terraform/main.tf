terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
}

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

data "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  resource_group_name = var.resource_group_name
}

data "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.resource_group_name
}

data "azurerm_key_vault" "kv" {
  name                = var.key_vault_name
  resource_group_name = var.resource_group_name
}

# User Assigned Identity for Batch pool nodes
resource "azurerm_user_assigned_identity" "batch" {
  name                = "${var.name}-batch-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# Grant identity access to Key Vault secrets
resource "azurerm_key_vault_access_policy" "batch" {
  key_vault_id = data.azurerm_key_vault.kv.id
  tenant_id    = azurerm_user_assigned_identity.batch.tenant_id
  object_id    = azurerm_user_assigned_identity.batch.principal_id

  secret_permissions = ["Get", "List"]
}

# Grant identity access to ACR (if specified)
data "azurerm_container_registry" "acr" {
  count               = var.acr_name != "" ? 1 : 0
  name                = var.acr_name
  resource_group_name = var.acr_resource_group_name != "" ? var.acr_resource_group_name : var.resource_group_name
}

resource "azurerm_role_assignment" "acr_pull" {
  count                = var.acr_name != "" ? 1 : 0
  scope                = data.azurerm_container_registry.acr[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.batch.principal_id
}

# Batch Account
resource "azurerm_batch_account" "batch" {
  name                         = replace(var.name, "-", "")
  resource_group_name          = var.resource_group_name
  location                     = var.location
  pool_allocation_mode         = "BatchService"
  allowed_authentication_modes = ["AAD"]

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.batch.id]
  }

  tags = var.tags
}

# Batch Pool with container support
resource "azurerm_batch_pool" "pool" {
  name                = "${var.name}-pool"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_batch_account.batch.name
  vm_size             = var.vm_size
  node_agent_sku_id   = "batch.node.ubuntu 22.04"

  auto_scale {
    evaluation_interval = "PT5M"
    formula             = <<-EOT
      $totalNodes = max($PendingTasks.GetSample(TimeInterval_Minute * 5, 0), $ActiveTasks.GetSample(TimeInterval_Minute * 5, 0));
      $targetNodes = min($totalNodes, ${var.max_nodes});
      $TargetDedicatedNodes = $targetNodes;
      $NodeDeallocationOption = taskcompletion;
    EOT
  }

  container_configuration {
    type                  = "DockerCompatible"
    container_image_names = [var.image]

    dynamic "container_registries" {
      for_each = var.acr_name != "" ? [1] : []
      content {
        registry_server           = data.azurerm_container_registry.acr[0].login_server
        user_assigned_identity_id = azurerm_user_assigned_identity.batch.id
      }
    }
  }

  storage_image_reference {
    publisher = "microsoft-azure-batch"
    offer     = "ubuntu-server-container"
    sku       = "22-04-lts"
    version   = "latest"
  }

  network_configuration {
    subnet_id = data.azurerm_subnet.subnet.id
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.batch.id]
  }

  task_scheduling_policy {
    node_fill_type = "Pack"
  }
}

# NSG rule for metrics scraping
resource "azurerm_network_security_rule" "metrics" {
  name                        = "${var.name}-metrics"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8080"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = var.nsg_name
}

# Automation Account for scheduling
resource "azurerm_automation_account" "automation" {
  name                = "${var.name}-automation"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "Basic"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.batch.id]
  }

  tags = var.tags
}

# Automation Runbook — creates a Batch job and submits chunk task
resource "azurerm_automation_runbook" "trigger" {
  name                    = "${var.name}-trigger"
  location                = var.location
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.automation.name
  log_verbose             = false
  log_progress            = false
  runbook_type            = "PowerShell"

  content = <<-PS
    Connect-AzAccount -Identity

    $batchContext = Get-AzBatchAccount -AccountName "${azurerm_batch_account.batch.name}" -ResourceGroupName "${var.resource_group_name}"

    # Fetch secrets from Key Vault
    $moderneToken = (Get-AzKeyVaultSecret -VaultName "${var.key_vault_name}" -Name "moderne-token" -AsPlainText) 2>$null
    $gitCredentials = (Get-AzKeyVaultSecret -VaultName "${var.key_vault_name}" -Name "git-credentials" -AsPlainText) 2>$null
    $publishUser = (Get-AzKeyVaultSecret -VaultName "${var.key_vault_name}" -Name "publish-user" -AsPlainText) 2>$null
    $publishPassword = (Get-AzKeyVaultSecret -VaultName "${var.key_vault_name}" -Name "publish-password" -AsPlainText) 2>$null
    $publishToken = (Get-AzKeyVaultSecret -VaultName "${var.key_vault_name}" -Name "publish-token" -AsPlainText) 2>$null

    $jobId = "${var.name}-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    New-AzBatchJob -Id $jobId -PoolInformation (New-Object Microsoft.Azure.Commands.Batch.Models.PSPoolInformation -Property @{PoolId="${azurerm_batch_pool.pool.name}"}) -BatchContext $batchContext

    $taskSettings = New-Object Microsoft.Azure.Commands.Batch.Models.PSTaskContainerSettings -Property @{
      ImageName = "${var.image}"
    }

    $envVars = @(
      (New-Object Microsoft.Azure.Commands.Batch.Models.PSEnvironmentSetting -Property @{Name="BATCH_JOB_ID"; Value=$jobId}),
      (New-Object Microsoft.Azure.Commands.Batch.Models.PSEnvironmentSetting -Property @{Name="BATCH_ACCOUNT_ENDPOINT"; Value="${azurerm_batch_account.batch.name}.${var.location}.batch.azure.com"}),
      (New-Object Microsoft.Azure.Commands.Batch.Models.PSEnvironmentSetting -Property @{Name="IMAGE"; Value="${var.image}"}),
      (New-Object Microsoft.Azure.Commands.Batch.Models.PSEnvironmentSetting -Property @{Name="MODERNE_TENANT"; Value="${var.moderne_tenant}"}),
      (New-Object Microsoft.Azure.Commands.Batch.Models.PSEnvironmentSetting -Property @{Name="PUBLISH_URL"; Value="${var.publish_url}"})
    )

    # Add secrets as environment variables (only if they exist in Key Vault)
    if ($moderneToken) { $envVars += (New-Object Microsoft.Azure.Commands.Batch.Models.PSEnvironmentSetting -Property @{Name="MODERNE_TOKEN"; Value=$moderneToken}) }
    if ($gitCredentials) { $envVars += (New-Object Microsoft.Azure.Commands.Batch.Models.PSEnvironmentSetting -Property @{Name="GIT_CREDENTIALS"; Value=$gitCredentials}) }
    if ($publishUser) { $envVars += (New-Object Microsoft.Azure.Commands.Batch.Models.PSEnvironmentSetting -Property @{Name="PUBLISH_USER"; Value=$publishUser}) }
    if ($publishPassword) { $envVars += (New-Object Microsoft.Azure.Commands.Batch.Models.PSEnvironmentSetting -Property @{Name="PUBLISH_PASSWORD"; Value=$publishPassword}) }
    if ($publishToken) { $envVars += (New-Object Microsoft.Azure.Commands.Batch.Models.PSEnvironmentSetting -Property @{Name="PUBLISH_TOKEN"; Value=$publishToken}) }

    $task = New-Object Microsoft.Azure.Commands.Batch.Models.PSCloudTask -Property @{
      Id = "chunk"
      CommandLine = "./chunk.sh ${var.csv_file} ${var.chunk_size}"
      ContainerSettings = $taskSettings
      EnvironmentSettings = $envVars
    }

    New-AzBatchTask -JobId $jobId -Task $task -BatchContext $batchContext
  PS

  tags = var.tags
}

# Schedule — daily trigger
resource "azurerm_automation_schedule" "daily" {
  name                    = "${var.name}-daily"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.automation.name
  frequency               = "Day"
  interval                = 1
  timezone                = "UTC"
  start_time              = timeadd(timestamp(), "24h")

  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_job_schedule" "trigger" {
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.automation.name
  schedule_name           = azurerm_automation_schedule.daily.name
  runbook_name            = azurerm_automation_runbook.trigger.name
}
