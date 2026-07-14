# =====================================================================
#  Auth0 - OIDC SSO, MFA and RBAC for the PAM platform
# =====================================================================

locals {
  # Allow both http and https of the app host (Kong listens on 80 and 443).
  app_urls = distinct([
    var.app_url,
    replace(var.app_url, "http://", "https://"),
  ])
}

# --- Tenant hardening: short sessions ---
resource "auth0_tenant" "tenant" {
  session_lifetime      = 8   # absolute session cap: 8 hours
  idle_session_lifetime = 0.5 # log out after 30 minutes of inactivity

  flags {
    enable_public_signup_user_exists_error = true
    no_disclose_enterprise_connections     = true
  }
}

# --- Multi-Factor Authentication (enforced everywhere) ---
resource "auth0_guardian" "mfa" {
  policy = "all-applications" # Force MFA on every login

  otp           = true  # Authenticator app TOTP (strong)
  email         = false # Disabled: email OTP is a weak second factor
  recovery_code = true  # One-time recovery codes for account recovery
}

# --- Username/password database connection enabled for the apps ---
# The Google social connection (dev keys) was removed, so login uses the
# username/password database connection with MFA only.
resource "auth0_connection_clients" "db_clients" {
  connection_id = "con_XkyAVXuIjcqHLJJV" # Username-Password-Authentication
  enabled_clients = [
    auth0_client.app_spa.client_id,
    auth0_client.vault_client.client_id,
  ]
}

# --- RBAC role assumed by privileged administrators ---
resource "auth0_role" "pam_admin" {
  name        = "PAM_Administrator"
  description = "Privileged PAM access, mapped to the Vault pam-admin-policy"
}

resource "auth0_role" "pam_operator" {
  name        = "PAM_Operator"
  description = "Read-only operator access with short-lived SSH signing"
}

# --- Confidential application used by HashiCorp Vault (OIDC auth backend) ---
resource "auth0_client" "vault_client" {
  name        = "HCP Vault OIDC"
  description = "Confidential OIDC application connecting Auth0 to Vault"
  app_type    = "regular_web"

  oidc_conformant   = true
  cross_origin_auth = false

  grant_types = [
    "authorization_code",
    "refresh_token",
  ]

  jwt_configuration {
    alg = "RS256"
  }

  callbacks = [
    "https://${azurerm_public_ip.pip.ip_address}:8200/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback", # Vault CLI login helper
  ]

  allowed_logout_urls = [
    "https://${azurerm_public_ip.pip.ip_address}:8200/ui/vault/auth/oidc/oidc/callback",
  ]
}

# --- Public single-page app (app), managed as IaC ---
resource "auth0_client" "app_spa" {
  name        = "PAM Governance App"
  description = "Public SPA, OIDC single sign-on with PKCE"
  app_type    = "spa"

  oidc_conformant = true

  grant_types = [
    "authorization_code", # PKCE
    "refresh_token",
  ]

  jwt_configuration {
    alg = "RS256"
  }

  # Allow both http and https of the host (Kong exposes 80 and 443). The SPA
  # redirect_uri is window.location.origin, which depends on the visitor scheme.
  callbacks           = local.app_urls
  allowed_logout_urls = local.app_urls
  allowed_origins     = local.app_urls
  web_origins         = local.app_urls

  refresh_token {
    rotation_type   = "rotating"
    expiration_type = "expiring"
    token_lifetime  = 2592000
    leeway          = 0
  }
}

# --- Post-Login Action: surface roles as a namespaced claim for Vault ---
# Vault's admin OIDC role binds on groups_claim "https://pam-governance/roles".
# Users without PAM_Administrator get an empty list -> stay operator (least priv).
resource "auth0_action" "add_roles" {
  name    = "Add PAM Roles To Token"
  runtime = "node18"
  deploy  = true

  supported_triggers {
    id      = "post-login"
    version = "v3"
  }

  code = <<-EOT
    exports.onExecutePostLogin = async (event, api) => {
      const ns = 'https://pam-governance/roles';
      const roles = (event.authorization && event.authorization.roles) || [];
      api.idToken.setCustomClaim(ns, roles);
      api.accessToken.setCustomClaim(ns, roles);
    };
  EOT
}

resource "auth0_trigger_actions" "post_login" {
  trigger = "post-login"

  actions {
    id           = auth0_action.add_roles.id
    display_name = auth0_action.add_roles.name
  }
}
