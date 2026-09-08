output "batch_account_name" {
  value = azurerm_batch_account.batch.name
}

output "batch_account_endpoint" {
  value = "https://${azurerm_batch_account.batch.account_endpoint}"
}

output "pool_name" {
  value = azurerm_batch_pool.pool.name
}

output "identity_client_id" {
  description = "Client id of the user-assigned identity used by the pool and the runbook"
  value       = azurerm_user_assigned_identity.batch.client_id
}

output "runbook_name" {
  value = azurerm_automation_runbook.trigger.name
}

output "automation_account_name" {
  value = azurerm_automation_account.automation.name
}
