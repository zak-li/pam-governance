# Auth0: OIDC SSO, MFA, RBAC and session policy for the PAM platform.
locals {
  app_urls = distinct([
    var.app_url,
    replace(var.app_url, "http://", "https://"),
  ])
}

resource "auth0_tenant" "tenant" {
  session_lifetime      = 8
  idle_session_lifetime = 0.5

  flags {
    enable_public_signup_user_exists_error = true
    no_disclose_enterprise_connections     = true
  }
}

resource "auth0_guardian" "mfa" {
  policy        = "all-applications"
  otp           = true
  email         = false
  recovery_code = true
}

# Default database connection, looked up by name so it is portable across tenants.
data "auth0_connection" "db" {
  name = "Username-Password-Authentication"
}

resource "auth0_connection_clients" "db_clients" {
  connection_id = data.auth0_connection.db.id
  enabled_clients = [
    auth0_client.app_spa.client_id,
    auth0_client.vault_client.client_id,
  ]
}

# Optional Google social connection using the operator's own OAuth keys.
resource "auth0_connection" "google" {
  count    = var.google_client_id != "" ? 1 : 0
  name     = "google-oauth2"
  strategy = "google-oauth2"

  options {
    client_id     = var.google_client_id
    client_secret = var.google_client_secret
  }
}

resource "auth0_connection_clients" "google_clients" {
  count           = var.google_client_id != "" ? 1 : 0
  connection_id   = auth0_connection.google[0].id
  enabled_clients = [auth0_client.app_spa.client_id]
}

resource "auth0_role" "pam_admin" {
  name        = "PAM_Administrator"
  description = "Privileged PAM access, mapped to the Vault pam-admin-policy"
}

resource "auth0_role" "pam_operator" {
  name        = "PAM_Operator"
  description = "Read-only operator access with short-lived SSH signing"
}

resource "auth0_client" "vault_client" {
  name              = "HCP Vault OIDC"
  description       = "Confidential OIDC application connecting Auth0 to Vault"
  app_type          = "regular_web"
  oidc_conformant   = true
  cross_origin_auth = false

  grant_types = ["authorization_code", "refresh_token"]

  jwt_configuration {
    alg = "RS256"
  }

  callbacks = [
    "https://${var.public_ip_address}:8200/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]

  allowed_logout_urls = [
    "https://${var.public_ip_address}:8200/ui/vault/auth/oidc/oidc/callback",
  ]
}

resource "auth0_client" "app_spa" {
  name            = "PAM Governance App"
  description     = "Public SPA, OIDC single sign-on with PKCE"
  app_type        = "spa"
  oidc_conformant = true

  grant_types = ["authorization_code", "refresh_token"]

  jwt_configuration {
    alg = "RS256"
  }

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

resource "auth0_branding_theme" "default" {
  borders {}

  colors {
    widget_background = "#ffffff"
  }

  fonts {
    font_url = "https://cdn.jsdelivr.net/npm/@fontsource/inter@5.0.18/files/inter-latin-400-normal.woff2"
    title {}
    subtitle {}
    links {}
    input_labels {}
    buttons_text {}
    body_text {}
  }

  page_background {
    background_color = "#f8fafc"
  }

  widget {}
}

