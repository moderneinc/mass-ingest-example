terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
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

data "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.resource_group_name
}

data "azurerm_key_vault" "kv" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group_name != "" ? var.key_vault_resource_group_name : var.resource_group_name
}

data "azurerm_container_registry" "acr" {
  count               = var.acr_name != "" ? 1 : 0
  name                = var.acr_name
  resource_group_name = var.acr_resource_group_name != "" ? var.acr_resource_group_name : var.resource_group_name
}

locals {
  batch_account_name = var.batch_account_name != "" ? var.batch_account_name : replace(var.name, "-", "")
}

# One user-assigned identity shared by the pool nodes and the Automation account.
resource "azurerm_user_assigned_identity" "batch" {
  name                = "${var.name}-batch-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# Key Vaults use either access policies or Azure RBAC; grant whichever model the vault is configured with.
resource "azurerm_key_vault_access_policy" "batch" {
  count = data.azurerm_key_vault.kv.rbac_authorization_enabled ? 0 : 1

  key_vault_id = data.azurerm_key_vault.kv.id
  tenant_id    = azurerm_user_assigned_identity.batch.tenant_id
  object_id    = azurerm_user_assigned_identity.batch.principal_id

  secret_permissions = ["Get"]
}

resource "azurerm_role_assignment" "key_vault_secrets_user" {
  count = data.azurerm_key_vault.kv.rbac_authorization_enabled ? 1 : 0

  scope                = data.azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.batch.principal_id
}

# Pull the container image from ACR.
resource "azurerm_role_assignment" "acr_pull" {
  count = var.acr_name != "" ? 1 : 0

  scope                = data.azurerm_container_registry.acr[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.batch.principal_id
}

# Lets the runbook create jobs and chunk.sh add tasks through the Batch data plane with Entra ID; no pool or account writes.
resource "azurerm_role_assignment" "batch_job_submitter" {
  scope                = azurerm_batch_account.batch.id
  role_definition_name = "Azure Batch Job Submitter"
  principal_id         = azurerm_user_assigned_identity.batch.principal_id
}

# Get-AzBatchAccount in the runbook reads the account resource.
resource "azurerm_role_assignment" "batch_reader" {
  scope                = azurerm_batch_account.batch.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.batch.principal_id
}

resource "azurerm_batch_account" "batch" {
  name                         = local.batch_account_name
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

resource "azurerm_batch_pool" "pool" {
  name                = "${var.name}-pool"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_batch_account.batch.name
  vm_size             = var.vm_size
  node_agent_sku_id   = "batch.node.ubuntu 22.04"

  # One task per node: each processor task gets a whole VM.
  max_tasks_per_node = 1

  # Nodes only need outbound HTTPS to the Batch service (no inbound NSG rules).
  target_node_communication_mode = "Simplified"

  # One dedicated node per pending task up to max_nodes, zero when idle; nodes leave only after their task finishes.
  auto_scale {
    evaluation_interval = "PT5M"
    formula             = <<-EOT
      $samples = $PendingTasks.GetSamplePercent(TimeInterval_Minute * 5);
      $tasks = $samples < 70 ? max(0, $PendingTasks.GetSample(1)) : max($PendingTasks.GetSample(1), avg($PendingTasks.GetSample(TimeInterval_Minute * 5)));
      $TargetDedicatedNodes = max(0, min($tasks, ${var.max_nodes}));
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

  # Ubuntu 22.04 image with a container runtime, maintained for Batch.
  storage_image_reference {
    publisher = "microsoft-dsvm"
    offer     = "ubuntu-hpc"
    sku       = "2204"
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

# Allow Prometheus scraping of the CLI metrics endpoint from inside the VNet.
resource "azurerm_network_security_rule" "metrics" {
  count = var.nsg_name != "" ? 1 : 0

  name                        = "${var.name}-metrics"
  priority                    = var.metrics_nsg_rule_priority
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

# Scheduling: the runbook creates a Batch job with the chunk task, and chunk.sh adds the processor tasks to it.
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

resource "azurerm_automation_runbook" "trigger" {
  name                    = "${var.name}-trigger"
  location                = var.location
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.automation.name
  log_verbose             = false
  log_progress            = false
  runbook_type            = "PowerShell"
  description             = "Creates a mass-ingest Batch job and submits its chunk task"

  content = <<-PS
    $ErrorActionPreference = "Stop"

    # Sign in with the user-assigned identity attached to the Automation account.
    Connect-AzAccount -Identity -AccountId "${azurerm_user_assigned_identity.batch.client_id}" | Out-Null

    # Get-AzBatchAccount yields a context that authenticates to the Batch data plane with Entra ID.
    $batchContext = Get-AzBatchAccount -AccountName "${azurerm_batch_account.batch.name}" -ResourceGroupName "${var.resource_group_name}"

    $jobId = "${var.name}-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $poolInformation = New-Object -TypeName "Microsoft.Azure.Commands.Batch.Models.PSPoolInformation"
    $poolInformation.PoolId = "${azurerm_batch_pool.pool.name}"
    New-AzBatchJob -Id $jobId -PoolInformation $poolInformation -BatchContext $batchContext

    # Batch replaces the image WORKDIR and user; run in /app as root so the CLI configuration under /home/moderne is writable.
    $containerSettings = New-Object -TypeName "Microsoft.Azure.Commands.Batch.Models.PSTaskContainerSettings" -ArgumentList "${var.image}", "--workdir /app", $null
    $autoUser = New-Object -TypeName "Microsoft.Azure.Commands.Batch.Models.PSAutoUserSpecification" -ArgumentList @("Pool", "Admin")
    $userIdentity = New-Object -TypeName "Microsoft.Azure.Commands.Batch.Models.PSUserIdentity" -ArgumentList $autoUser

    # Only non-secret settings. Credentials are read from Key Vault by the tasks themselves.
    $environment = @{
      IMAGE                    = "${var.image}"
      AZURE_CLIENT_ID          = "${azurerm_user_assigned_identity.batch.client_id}"
      KEY_VAULT_URI            = "${data.azurerm_key_vault.kv.vault_uri}"
      MODERNE_TENANT           = "${var.moderne_tenant}"
      PUBLISH_URL              = "${var.publish_url}"
      TASK_MAX_WALL_CLOCK_TIME = "${var.task_max_wall_clock_time}"
      TASK_MAX_RETRY_COUNT     = "${var.task_max_retry_count}"
    }

    New-AzBatchTask -JobId $jobId -Id "chunk" -CommandLine "/app/chunk.sh ${var.csv_file} ${var.chunk_size}" -ContainerSettings $containerSettings -UserIdentity $userIdentity -EnvironmentSettings $environment -BatchContext $batchContext
    Write-Output "Submitted Batch job $jobId"
  PS

  tags = var.tags
}

resource "azurerm_automation_schedule" "daily" {
  name                    = "${var.name}-daily"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.automation.name
  frequency               = "Day"
  interval                = 1
  timezone                = "Etc/UTC"
  start_time              = timeadd(timestamp(), "24h")
  description             = "Daily mass-ingest run"

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
