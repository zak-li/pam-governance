output "subnet_id" { value = azurerm_subnet.subnet.id }
output "nic_id" { value = azurerm_network_interface.nic.id }
output "public_ip_address" { value = azurerm_public_ip.pip.ip_address }
output "nsg_assoc_id" { value = azurerm_network_interface_security_group_association.nsg_assoc.id }
