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
  description = "Public IP allowed to reach SSH/Vault/Splunk (NSG allow-list). Required; set it to your current public IP."
  type        = string

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.admin_source_ip))
    error_message = "admin_source_ip must be a single IPv4 address."
  }
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

# --- Public SPA app, managed as IaC ---
variable "app_url" {
  description = "Public URL of the SPA app (Auth0 callback/logout/origins)"
  type        = string
  default     = "http://localhost:8080"
}

# --- Optional Google social login (own OAuth keys, no shared dev keys) ---
variable "google_client_id" {
  description = "Google OAuth client ID to enable Google social login. Leave empty to disable."
  type        = string
  default     = ""
}

variable "google_client_secret" {
  description = "Google OAuth client secret (required when google_client_id is set)."
  type        = string
  default     = ""
  sensitive   = true
}
