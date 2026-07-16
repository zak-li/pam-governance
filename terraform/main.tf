# =====================================================================
#  PAM / Identity Governance - root module
#
#  Wires the per-concern modules under modules/. Cross-cutting material
#  (resource group, name suffix, and generated crypto shared by the VM and the
#  Key Vault escrow) lives here; everything else is delegated to a module.
# =====================================================================

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# Global name suffix for globally-unique resources (Key Vault, ACR).
resource "random_string" "kv_suffix" {
  length  = 8
  special = false
  upper   = false
}

# --- Generated crypto (shared by the VM and the Key Vault escrow secrets) ---
resource "random_password" "vm_password" {
  length           = 24
  special          = true
  override_special = "!#%*()-_=+[]{}:?."
}

resource "tls_private_key" "vm_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_private_key" "vault_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "vault_cert" {
  private_key_pem = tls_private_key.vault_key.private_key_pem

  subject {
    common_name  = module.network.public_ip_address
    organization = "PAM Governance"
  }

  validity_period_hours = 8760

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  ip_addresses = [module.network.public_ip_address]
}

# =====================================================================
#  Modules
# =====================================================================
module "network" {
  source              = "./modules/network"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  admin_source_ip     = var.admin_source_ip
}

module "key_vault" {
  source              = "./modules/key-vault"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  admin_object_id     = data.azurerm_client_config.current.object_id
  subnet_id           = module.network.subnet_id
  admin_source_ip     = var.admin_source_ip
  name_suffix         = random_string.kv_suffix.result
  splunk_password     = random_password.vm_password.result
  auth0_client_secret = var.auth0_client_secret
  vault_tls_key       = tls_private_key.vault_key.private_key_pem
}

module "compute" {
  source              = "./modules/compute"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  admin_username      = var.admin_username
  nic_id              = module.network.nic_id
  identity_id         = module.key_vault.identity_id
  identity_client_id  = module.key_vault.identity_client_id
  key_vault_name      = module.key_vault.key_vault_name
  public_ip_address   = module.network.public_ip_address
  ssh_public_key      = tls_private_key.vm_ssh.public_key_openssh
  vault_cert_pem      = tls_self_signed_cert.vault_cert.cert_pem
  auth0_domain        = var.auth0_domain
  auth0_client_id     = var.auth0_client_id

  # Ensure the escrowed secrets, the VM identity's Key Vault access, and the NSG
  # association all exist before cloud-init runs.
  depends_on = [module.key_vault, module.network]
}

module "aks" {
  source              = "./modules/aks"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

module "registry" {
  source                = "./modules/registry"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  name_suffix           = random_string.kv_suffix.result
  aks_kubelet_object_id = module.aks.kubelet_object_id
}

module "auth0" {
  source               = "./modules/auth0"
  public_ip_address    = module.network.public_ip_address
  app_url              = var.app_url
  google_client_id     = var.google_client_id
  google_client_secret = var.google_client_secret
}
