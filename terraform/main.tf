# =====================================================================
#  PAM / Identity Governance - Azure infrastructure
#
#  Files in this module:
#    versions.tf   provider requirements
#    providers.tf  provider configuration
#    variables.tf  input variables
#    main.tf       resource group and generated crypto material
#    network.tf    VNet, subnet, public IP, NSG, NIC
#    keyvault.tf   managed identity and Key Vault escrow
#    compute.tf    the Vault/Splunk virtual machine
#    aks.tf        the AKS cluster
#    auth0.tf      OIDC, MFA, RBAC and session policy
#    outputs.tf    outputs
# =====================================================================

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# --- Secrets: dynamically generated, never hard-coded ---
# Shell-safe charset (no $ ` " \ & < > | ; ' space) so it can never break
# cloud-init string interpolation.
resource "random_password" "vm_password" {
  length           = 24
  special          = true
  override_special = "!#%*()-_=+[]{}:?."
}

# --- SSH key pair for VM administration (replaces password SSH auth) ---
resource "tls_private_key" "vm_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- TLS certificate for Vault HTTPS ---
resource "tls_private_key" "vault_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "vault_cert" {
  private_key_pem = tls_private_key.vault_key.private_key_pem

  subject {
    common_name  = azurerm_public_ip.pip.ip_address
    organization = "PAM Governance"
  }

  validity_period_hours = 8760

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  ip_addresses = [azurerm_public_ip.pip.ip_address]
}
