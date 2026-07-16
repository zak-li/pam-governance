# Managed identity + Azure Key Vault escrow of Vault unseal/root and boot secrets.
locals {
  key_vault_name = "kvpam${var.name_suffix}"
}

resource "azurerm_user_assigned_identity" "vm_id" {
  name                = "id-pam-vm"
  location            = var.location
  resource_group_name = var.resource_group_name
}

resource "azurerm_key_vault" "kv" {
  name                       = local.key_vault_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 30
  purge_protection_enabled   = true

  network_acls {
    default_action             = "Deny"
    bypass                     = "AzureServices"
    virtual_network_subnet_ids = [var.subnet_id]
    ip_rules                   = [var.admin_source_ip]
  }
}

resource "azurerm_key_vault_access_policy" "admin" {
  key_vault_id       = azurerm_key_vault.kv.id
  tenant_id          = var.tenant_id
  object_id          = var.admin_object_id
  secret_permissions = ["Get", "List", "Set", "Delete", "Purge", "Recover"]
}

resource "azurerm_key_vault_access_policy" "vm" {
  key_vault_id       = azurerm_key_vault.kv.id
  tenant_id          = var.tenant_id
  object_id          = azurerm_user_assigned_identity.vm_id.principal_id
  secret_permissions = ["Get", "Set", "List"]
}

resource "azurerm_key_vault_secret" "splunk_password" {
  name         = "splunk-admin-password"
  value        = var.splunk_password
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault_access_policy.admin]
}

resource "azurerm_key_vault_secret" "auth0_client_secret" {
  name         = "auth0-client-secret"
  value        = var.auth0_client_secret
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault_access_policy.admin]
}

resource "azurerm_key_vault_secret" "vault_tls_key" {
  name         = "vault-tls-key"
  value        = var.vault_tls_key
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault_access_policy.admin]
}
