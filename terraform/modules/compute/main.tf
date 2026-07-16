# Vault + Splunk target virtual machine. Secrets are pulled from Key Vault at
# boot via the managed identity; custom_data carries only non-secret config.
resource "azurerm_linux_virtual_machine" "vm" {
  name                            = "vm-splunk-target"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = "Standard_D2s_v3"
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [var.nic_id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity_id]
  }

  custom_data = base64encode(templatefile("${path.module}/templates/install.sh.tpl", {
    vault_cert         = var.vault_cert_pem
    auth0_domain       = var.auth0_domain
    auth0_client_id    = var.auth0_client_id
    public_ip          = var.public_ip_address
    key_vault_name     = var.key_vault_name
    identity_client_id = var.identity_client_id
    splunk_dashboard   = base64encode(file("${path.module}/templates/pam_governance.xml"))
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

  boot_diagnostics {}
}
