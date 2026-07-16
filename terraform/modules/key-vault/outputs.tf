output "key_vault_name" { value = local.key_vault_name }
output "identity_id" { value = azurerm_user_assigned_identity.vm_id.id }
output "identity_client_id" { value = azurerm_user_assigned_identity.vm_id.client_id }
output "identity_principal_id" { value = azurerm_user_assigned_identity.vm_id.principal_id }
