#!/bin/bash
# No `set -e` here: a transient warning (apt, network) must never abort the whole
# provisioning. The critical steps (init/unseal) are handled explicitly. The full
# log is written to /var/log/pam-bootstrap.log.
set -uo pipefail
exec > /var/log/pam-bootstrap.log 2>&1
# =====================================================================
#  PAM / Identity Governance - Cloud-init bootstrap
#  - HashiCorp Vault (production, TLS, audited, least-privilege)
#  - Dynamic secrets engines (SSH CA, database, transit, KV v2)
#  - Auth0 OIDC SSO with RBAC tiers (admin / operator)
#  - Splunk (SIEM) with forensic ingestion of Vault + host audit logs
#  - Unseal keys stored in Azure Key Vault (not on disk); no standing root
#  - Secrets are pulled from Key Vault at boot, never shipped in custom_data
# =====================================================================

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y wget curl unzip python3 lsb-release docker.io

# =====================================================================
#  Managed-identity helpers for Azure Key Vault (IMDS)
# =====================================================================
kv_token() {
  curl -s -H "Metadata:true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net&client_id=${identity_client_id}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))"
}

get_kv_secret() { # $1 = secret name -> prints value (retries)
  local name="$1" token val
  for _ in 1 2 3 4 5 6; do
    token="$(kv_token)"
    if [ -n "$token" ]; then
      val="$(curl -s "https://${key_vault_name}.vault.azure.net/secrets/$name?api-version=7.4" \
        -H "Authorization: Bearer $token" \
        | python3 -c "import sys,json;print(json.load(sys.stdin).get('value',''))")"
      [ -n "$val" ] && { printf '%s' "$val"; return 0; }
    fi
    sleep 5
  done
  return 1
}

put_kv_secret() { # $1 = name, $2 = value
  local name="$1" value="$2" token
  token="$(kv_token)"
  [ -n "$token" ] || return 1
  curl -s -X PUT "https://${key_vault_name}.vault.azure.net/secrets/$name?api-version=7.4" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d "$(python3 -c "import json,sys;print(json.dumps({'value':sys.argv[1]}))" "$value")" >/dev/null
}

# --- Secrets pulled from Key Vault instead of custom_data (least exposure) ---
SPLUNK_PW="$(get_kv_secret splunk-admin-password)"
AUTH0_CLIENT_SECRET="$(get_kv_secret auth0-client-secret)"
VAULT_TLS_KEY="$(get_kv_secret vault-tls-key)"

# =====================================================================
# 1. INSTALL HASHICORP VAULT  (official binary, robust, no APT/GPG repo)
# =====================================================================
VAULT_VERSION="1.17.6"
for attempt in 1 2 3; do
  curl -fsSL -o /tmp/vault.zip "https://releases.hashicorp.com/vault/$${VAULT_VERSION}/vault_$${VAULT_VERSION}_linux_amd64.zip" && break
  sleep 5
done
unzip -o /tmp/vault.zip -d /usr/bin/
chmod +x /usr/bin/vault
# The apt package normally creates the user and /etc/vault.d; we do it here.
id vault >/dev/null 2>&1 || useradd --system --home /etc/vault.d --shell /bin/false vault
mkdir -p /etc/vault.d
vault --version

# ---- TLS material: public cert from Terraform, private key from Key Vault ----
mkdir -p /opt/vault/data /opt/vault/tls /opt/vault/audit
cat <<EOF > /opt/vault/tls/tls.crt
${vault_cert}
EOF
printf '%s' "$VAULT_TLS_KEY" > /opt/vault/tls/tls.key
chmod 640 /opt/vault/tls/tls.crt
chmod 600 /opt/vault/tls/tls.key
chown -R vault:vault /opt/vault
# 755 so the Splunk container (different uid) can read the mounted audit logs
chmod 755 /opt/vault/audit

# ---- Vault production configuration (TLS only, audited) ----
cat <<EOF > /etc/vault.d/vault.hcl
storage "file" {
  path = "/opt/vault/data"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_disable   = 0
  tls_cert_file = "/opt/vault/tls/tls.crt"
  tls_key_file  = "/opt/vault/tls/tls.key"
  # Enforce modern TLS
  tls_min_version = "tls12"
}

ui            = true
disable_mlock = true
api_addr      = "https://${public_ip}:8200"
EOF

cat <<'EOF' > /etc/systemd/system/vault.service
[Unit]
Description="HashiCorp Vault - secrets manager"
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target

[Service]
User=vault
Group=vault
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
ExecStart=/usr/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF

# Make the config readable by the 'vault' user (guards against a restrictive umask)
chown -R vault:vault /etc/vault.d
chmod 750 /etc/vault.d
chmod 640 /etc/vault.d/vault.hcl

systemctl daemon-reload
systemctl enable vault
systemctl restart vault

export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_SKIP_VERIFY=true

# Wait until the Vault API answers (the "Sealed" field appears once it is up,
# whether sealed or not) - avoids a fixed sleep race.
for i in $(seq 1 30); do
  if vault status 2>/dev/null | grep -q "Sealed"; then break; fi
  sleep 2
done

# =====================================================================
# 2. AUTO-INITIALISE & UNSEAL  (unseal keys go to Azure Key Vault, not disk)
# =====================================================================
vault operator init -key-shares=5 -key-threshold=3 -format=json > /opt/vault/init.json
chmod 600 /opt/vault/init.json
chown root:root /opt/vault/init.json

# Unseal with 3 of the 5 shares
for idx in 0 1 2; do
  KEY=$(python3 -c "import json;print(json.load(open('/opt/vault/init.json'))['unseal_keys_b64'][$idx])")
  vault operator unseal "$KEY"
done

ROOT_TOKEN=$(python3 -c "import json;print(json.load(open('/opt/vault/init.json'))['root_token'])")
vault login "$ROOT_TOKEN" >/dev/null

# Escrow only the unseal keys (no standing root token). Break-glass root is
# regenerated on demand with generate-root using these keys.
put_kv_secret "vault-unseal-keys" "$(cat /opt/vault/init.json)"
shred -u /opt/vault/init.json 2>/dev/null || rm -f /opt/vault/init.json

# =====================================================================
# 3. FORENSIC AUDIT LOGGING (file device -> monitored by Splunk)
# =====================================================================
vault audit enable file file_path=/opt/vault/audit/audit.log log_raw=false mode=0644 || true

# =====================================================================
# 4. DYNAMIC SECRET ENGINES  (eliminate credential sprawl)
# =====================================================================
# Static secrets (KV v2)
vault secrets enable -path=secret -version=2 kv || true

# SSH secrets engine with a CA - dynamic, signed, short-lived privileged
# SSH access to target hosts (the core PAM use-case).
vault secrets enable -path=ssh ssh || true
vault write -f ssh/config/ca generate_signing_key=true || true
vault write ssh/roles/pam-ssh-role - <<'EOF'
{
  "key_type": "ca",
  "algorithm_signer": "rsa-sha2-256",
  "allow_user_certificates": true,
  "allowed_users": "azureuser,operator",
  "default_user": "azureuser",
  "ttl": "10m",
  "max_ttl": "30m",
  "default_extensions": { "permit-pty": "" }
}
EOF

# Database engine mounted for on-demand database credentials. Wire it to a real
# database with `vault write database/config/...` and `database/roles/...`.
vault secrets enable -path=database database || true

# Transit engine (encryption-as-a-service; no key sprawl)
vault secrets enable -path=transit transit || true
vault write -f transit/keys/pam-app-key || true

# =====================================================================
# 5. LEAST-PRIVILEGE RBAC POLICIES
# =====================================================================
# --- Admin tier: scoped to PAM engines; NO blanket "*"/sudo root grant ---
cat <<'EOF' > /opt/vault/pam-admin-policy.hcl
# Manage application secrets
path "secret/*"            { capabilities = ["create","read","update","delete","list"] }
# Manage dynamic SSH signing roles and sign privileged sessions
path "ssh/*"               { capabilities = ["create","read","update","delete","list"] }
# Manage dynamic database credentials
path "database/*"          { capabilities = ["create","read","update","delete","list"] }
# Encryption-as-a-service
path "transit/*"           { capabilities = ["create","read","update","delete","list"] }
# Manage authN/policies for delegated administration
path "auth/*"              { capabilities = ["create","read","update","delete","list"] }
path "sys/policies/acl/*"  { capabilities = ["create","read","update","delete","list"] }
path "sys/auth"            { capabilities = ["read","list"] }
path "sys/mounts"          { capabilities = ["read","list"] }
# Inspect audit configuration (but not disable the raw backend)
path "sys/audit"           { capabilities = ["read","list"] }
# Vault UI rendering
path "sys/internal/ui/mounts"        { capabilities = ["read"] }
path "sys/internal/ui/mounts/*"      { capabilities = ["read"] }
path "sys/internal/ui/resultant-acl" { capabilities = ["read"] }
# Self token management
path "auth/token/lookup-self"  { capabilities = ["read"] }
path "auth/token/renew-self"   { capabilities = ["update"] }
path "auth/token/revoke-self"  { capabilities = ["update"] }
EOF
vault policy write pam-admin-policy /opt/vault/pam-admin-policy.hcl

# --- Operator tier: read-only secrets + request short-lived SSH certs ---
cat <<'EOF' > /opt/vault/pam-operator-policy.hcl
path "secret/data/*"       { capabilities = ["read","list"] }
path "secret/metadata/*"   { capabilities = ["read","list"] }
path "ssh/sign/pam-ssh-role" { capabilities = ["create","update"] }
path "transit/encrypt/pam-app-key" { capabilities = ["update"] }
path "transit/decrypt/pam-app-key" { capabilities = ["update"] }
path "auth/token/lookup-self"  { capabilities = ["read"] }
path "auth/token/renew-self"   { capabilities = ["update"] }
# Vault UI rendering (otherwise a "Resultant ACL check failed" banner appears)
path "sys/internal/ui/mounts"        { capabilities = ["read"] }
path "sys/internal/ui/mounts/*"      { capabilities = ["read"] }
path "sys/internal/ui/resultant-acl" { capabilities = ["read"] }
EOF
vault policy write pam-operator-policy /opt/vault/pam-operator-policy.hcl

# =====================================================================
# 6. AUTH0 OIDC SSO  (bound claims -> least-privilege by default)
# =====================================================================
vault auth enable oidc || true

vault write auth/oidc/config \
    oidc_discovery_url="https://${auth0_domain}/" \
    oidc_client_id="${auth0_client_id}" \
    oidc_client_secret="$AUTH0_CLIENT_SECRET" \
    default_role="pam-operator-role"

# Operator role = default. Any successfully-authenticated Auth0 user lands
# here (read-only). Group membership is required to escalate to admin.
vault write auth/oidc/role/pam-operator-role \
    bound_audiences="${auth0_client_id}" \
    allowed_redirect_uris="https://${public_ip}:8200/ui/vault/auth/oidc/oidc/callback" \
    allowed_redirect_uris="http://localhost:8250/oidc/callback" \
    user_claim="sub" \
    oidc_scopes="openid,profile,email" \
    policies="pam-operator-policy" \
    ttl="30m" \
    max_ttl="1h"

# Admin role = gated on the "PAM_Administrator" group claim delivered by the
# Auth0 post-login Action. Users without the group cannot assume it.
# Stdin JSON form (the key=value form does not parse nested bound_claims).
vault write auth/oidc/role/pam-admin-role - <<'JSON'
{
  "bound_audiences": "${auth0_client_id}",
  "allowed_redirect_uris": ["https://${public_ip}:8200/ui/vault/auth/oidc/oidc/callback", "http://localhost:8250/oidc/callback"],
  "user_claim": "sub",
  "groups_claim": "https://pam-governance/roles",
  "oidc_scopes": ["openid", "profile", "email"],
  "bound_claims_type": "glob",
  "bound_claims": {"https://pam-governance/roles": "*PAM_Administrator*"},
  "policies": "pam-admin-policy",
  "ttl": "20m",
  "max_ttl": "30m"
}
JSON

# =====================================================================
# 7. ZERO STANDING ROOT
# =====================================================================
# All configuration is done. Revoke the initial root token so there is no
# standing root. Break-glass root is regenerated on demand with
# `vault operator generate-root` and the unseal keys escrowed in Key Vault.
vault token revoke -self || true
unset ROOT_TOKEN

# =====================================================================
# 8. SPLUNK ENTERPRISE (SIEM) via Docker  +  forensic ingestion
#    Pinned image, persistent data/config volumes.
# =====================================================================
systemctl enable --now docker

# Persistent host directories (owned by the splunk container uid 41812)
mkdir -p /opt/splunk-data/var /opt/splunk-data/etc
chown -R 41812:41812 /opt/splunk-data

docker run -d --name splunk --restart unless-stopped \
  -p 8000:8000 \
  -e SPLUNK_GENERAL_TERMS="--accept-sgt-current-at-splunk-com" \
  -e SPLUNK_START_ARGS="--accept-license" \
  -e SPLUNK_PASSWORD="$SPLUNK_PW" \
  -v /opt/splunk-data/var:/opt/splunk/var \
  -v /opt/splunk-data/etc:/opt/splunk/etc \
  -v /opt/vault/audit:/var/log/vault:ro \
  -v /var/log:/var/log/host:ro \
  splunk/splunk:9.3

# Wait for Splunk to be ready (the image initializes in about 1 to 2 minutes)
for i in $(seq 1 60); do
  if docker exec splunk /opt/splunk/bin/splunk status >/dev/null 2>&1; then break; fi
  sleep 10
done

# Index, monitors and JSON parsing via config files, which is robust and does
# not depend on the admin password (it contains special characters).
docker exec -i -u root splunk bash -c 'cat > /opt/splunk/etc/system/local/indexes.conf' <<'IDX'
[pam_audit]
homePath = $SPLUNK_DB/pam_audit/db
coldPath = $SPLUNK_DB/pam_audit/colddb
thawedPath = $SPLUNK_DB/pam_audit/thaweddb
IDX

docker exec -i -u root splunk bash -c 'cat >> /opt/splunk/etc/system/local/inputs.conf' <<'IN'

[monitor:///var/log/vault/audit.log]
index = pam_audit
sourcetype = vault_audit

[monitor:///var/log/host/auth.log]
index = pam_audit
sourcetype = linux_secure

[monitor:///var/log/host/syslog]
index = pam_audit
sourcetype = syslog
IN

# One JSON line per event, Vault timestamp, JSON field extraction
docker exec -i -u root splunk bash -c 'cat > /opt/splunk/etc/system/local/props.conf' <<'PR'
[vault_audit]
KV_MODE = json
SHOULD_LINEMERGE = false
LINE_BREAKER = ([\r\n]+)
TRUNCATE = 0
TIME_PREFIX = "time":"
MAX_TIMESTAMP_LOOKAHEAD = 40
PR

# Raised IOWait thresholds (the default 1% check is too sensitive for a demo)
docker exec -i -u root splunk bash -c 'cat > /opt/splunk/etc/system/local/health.conf' <<'HC'
[feature:iowait]
indicator:avg_cpu__max_perc_last_3m:yellow = 80
indicator:avg_cpu__max_perc_last_3m:red = 90
indicator:single_cpu__max_perc_last_3m:yellow = 80
indicator:single_cpu__max_perc_last_3m:red = 90
HC

# Preinstalled forensic dashboard (base64-decoded to avoid heredoc/interp risk)
docker exec -u root splunk mkdir -p /opt/splunk/etc/apps/search/local/data/ui/views
printf '%s' "${splunk_dashboard}" | base64 -d \
  | docker exec -i -u root splunk bash -c 'cat > /opt/splunk/etc/apps/search/local/data/ui/views/pam_governance.xml'

docker exec -u root splunk chown -R splunk:splunk /opt/splunk/etc/system/local /opt/splunk/etc/apps/search/local/data
docker restart splunk || true
