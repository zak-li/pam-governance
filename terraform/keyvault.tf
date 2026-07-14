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
  soft_delete_retention_days = 30
  # Escrowed unseal keys are the only break-glass material: protect from purge.
  purge_protection_enabled = true

  # Default-deny: only the target subnet and the operator IP reach the data plane.
  network_acls {
    default_action             = "Deny"
    bypass                     = "AzureServices"
    virtual_network_subnet_ids = [azurerm_subnet.subnet.id]
    ip_rules                   = [var.admin_source_ip]
  }
}

# =====================================================================
#  Secrets escrowed for the VM to fetch at boot (kept out of custom_data)
# =====================================================================
resource "azurerm_key_vault_secret" "splunk_password" {
  name         = "splunk-admin-password"
  value        = random_password.vm_password.result
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
  value        = tls_private_key.vault_key.private_key_pem
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault_access_policy.admin]
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
