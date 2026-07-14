variable "location" {
  description = "Azure region for the deployment"
  type        = string
  default     = "polandcentral"
}

variable "resource_group_name" {
  description = "Azure resource group name"
  type        = string
  default     = "rg-pam-governance"
}

variable "admin_username" {
  description = "VM administrator username (key-based SSH)"
  type        = string
  default     = "azureuser"
}

variable "admin_source_ip" {
  description = "Public IP allowed to reach SSH/Vault/Splunk (NSG allow-list)"
  type        = string
  default     = "196.75.81.68"
}

# --- Auth0: 'HCP Vault OIDC' regular web app used by Vault ---
variable "auth0_domain" {
  description = "Auth0 tenant domain (e.g. dev-xxxx.eu.auth0.com)"
  type        = string
}

variable "auth0_client_id" {
  description = "Client ID of the Auth0 application for Vault OIDC"
  type        = string
}

variable "auth0_client_secret" {
  description = "Client Secret of the Auth0 application for Vault OIDC"
  type        = string
  sensitive   = true
}

# --- Public SPA frontend, managed as IaC ---
variable "frontend_url" {
  description = "Public URL of the SPA frontend (Auth0 callback/logout/origins)"
  type        = string
  default     = "http://localhost:8080"
}
