# =====================================================================
#  Virtual machine (Vault + Splunk target)
# =====================================================================

resource "azurerm_linux_virtual_machine" "vm" {
  name                = "vm-splunk-target"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_D2s_v3"
  admin_username      = var.admin_username

  # Key-based SSH only - no password authentication.
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.nic.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.vm_ssh.public_key_openssh
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.vm_id.id]
  }

  custom_data = base64encode(templatefile("${path.module}/install.sh.tpl", {
    admin_password      = random_password.vm_password.result
    vault_cert          = tls_self_signed_cert.vault_cert.cert_pem
    vault_key           = tls_private_key.vault_key.private_key_pem
    auth0_domain        = var.auth0_domain
    auth0_client_id     = var.auth0_client_id
    auth0_client_secret = var.auth0_client_secret
    public_ip           = azurerm_public_ip.pip.ip_address
    key_vault_name      = local.key_vault_name
    identity_client_id  = azurerm_user_assigned_identity.vm_id.client_id
    splunk_dashboard    = file("${path.module}/pam_governance.xml")
  }))

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  boot_diagnostics {} # managed storage account

  # Ensure the VM identity can already reach Key Vault when cloud-init runs
  depends_on = [
    azurerm_key_vault_access_policy.vm,
    azurerm_network_interface_security_group_association.nsg_assoc,
  ]
}
