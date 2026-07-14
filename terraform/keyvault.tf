# =====================================================================
#  Managed identity + Azure Key Vault (escrow of Vault unseal/root)
# =====================================================================

resource "random_string" "kv_suffix" {
  length  = 8
  special = false
  upper   = false
}

locals {
  key_vault_name = "kvpam${random_string.kv_suffix.result}"
}

resource "azurerm_user_assigned_identity" "vm_id" {
  name                = "id-pam-vm"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_key_vault" "kv" {
  name                       = local.key_vault_name
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  network_acls {
    default_action             = "Allow" # Data-plane still requires AAD auth
    bypass                     = "AzureServices"
    virtual_network_subnet_ids = [azurerm_subnet.subnet.id]
  }
}

# The human operator that runs Terraform can read the escrowed break-glass keys
resource "azurerm_key_vault_access_policy" "admin" {
  key_vault_id       = azurerm_key_vault.kv.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = data.azurerm_client_config.current.object_id
  secret_permissions = ["Get", "List", "Set", "Delete", "Purge", "Recover"]
}

# The VM identity may only write (escrow) and read its own secrets
resource "azurerm_key_vault_access_policy" "vm" {
  key_vault_id       = azurerm_key_vault.kv.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = azurerm_user_assigned_identity.vm_id.principal_id
  secret_permissions = ["Get", "Set", "List"]
}
