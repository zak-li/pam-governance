# =====================================================================
#  Outputs
# =====================================================================

output "splunk_public_ip" {
  description = "Public IP of the Vault/Splunk virtual machine"
  value       = module.compute.public_ip_address
}

output "vault_ui_url" {
  description = "HTTPS URL of the Vault UI"
  value       = "https://${module.network.public_ip_address}:8200"
}

output "splunk_ui_url" {
  description = "URL of the Splunk web UI"
  value       = "http://${module.network.public_ip_address}:8000"
}

output "key_vault_name" {
  description = "Name of the Azure Key Vault holding the escrowed Vault keys"
  value       = module.key_vault.key_vault_name
}

output "aks_name" {
  description = "Name of the AKS cluster"
  value       = module.aks.name
}

output "aks_node_rg" {
  description = "Node resource group created by AKS"
  value       = module.aks.node_resource_group
}

output "acr_login_server" {
  description = "Login server of the container registry (for az acr build)"
  value       = module.registry.login_server
}

output "acr_name" {
  description = "Container registry name"
  value       = module.registry.name
}

output "auth0_app_client_id" {
  description = "Client ID of the IaC-managed SPA application"
  value       = module.auth0.app_client_id
}

output "auth0_domain" {
  description = "Auth0 tenant domain"
  value       = var.auth0_domain
}

output "auth0_vault_client_id" {
  description = "Client ID of the Vault OIDC application"
  value       = module.auth0.vault_client_id
}

output "vm_and_splunk_password" {
  description = "Admin password for the VM and the Splunk instance"
  value       = random_password.vm_password.result
  sensitive   = true
}

output "vm_ssh_private_key" {
  description = "Private SSH key to reach the VM as the admin user"
  value       = tls_private_key.vm_ssh.private_key_openssh
  sensitive   = true
}
