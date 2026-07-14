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
#  - Unseal key & root token stored in Azure Key Vault (not on disk)
# =====================================================================

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y wget curl unzip python3 lsb-release libcap2-bin

# ---------------------------------------------------------------------
# Splunk admin password (may contain shell metacharacters): write it via
# a *quoted* heredoc so bash performs no expansion, then read it back.
# ---------------------------------------------------------------------
# No global `umask 077` here, since it would make /etc/vault.d and vault.hcl
# unreadable by the 'vault' user. The file is secured explicitly instead.
cat > /root/.splunk_pw <<'PWEOF'
${admin_password}
PWEOF
chmod 600 /root/.splunk_pw
SPLUNK_PW="$(head -n1 /root/.splunk_pw)"

# =====================================================================
# 1. INSTALL HASHICORP VAULT  (official binary, robust, no APT/GPG repo)
# =====================================================================
VAULT_VERSION="1.17.6"
for attempt in 1 2 3; do
  curl -fsSL -o /tmp/vault.zip "https://releases.hashicorp.com/vault/1.17.6/vault_1.17.6_linux_amd64.zip" && break
  sleep 5
done
unzip -o /tmp/vault.zip -d /usr/bin/
chmod +x /usr/bin/vault
# The apt package normally creates the user and /etc/vault.d; we do it here.
id vault >/dev/null 2>&1 || useradd --system --home /etc/vault.d --shell /bin/false vault
mkdir -p /etc/vault.d
vault --version

# ---- TLS material (generated & injected by Terraform) ----
mkdir -p /opt/vault/data /opt/vault/tls /opt/vault/audit
cat <<EOF > /opt/vault/tls/tls.crt
${vault_cert}
EOF
cat <<EOF > /opt/vault/tls/tls.key
${vault_key}
EOF
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
# 2. AUTO-INITIALISE & UNSEAL  (keys go to Azure Key Vault, not disk)
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

# ---- Push unseal keys + root token into Azure Key Vault via Managed Identity ----
push_kv_secret() {
  local name="$1"; local value="$2"
  local token
  token=$(curl -s -H "Metadata:true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net&client_id=${identity_client_id}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
  if [ -n "$token" ] && [ -n "${key_vault_name}" ]; then
    curl -s -X PUT "https://${key_vault_name}.vault.azure.net/secrets/$name?api-version=7.4" \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      -d "$(python3 -c "import json,sys;print(json.dumps({'value':sys.argv[1]}))" "$value")" >/dev/null || true
  fi
}
if [ -n "${key_vault_name}" ]; then
  push_kv_secret "vault-root-token" "$ROOT_TOKEN"
  push_kv_secret "vault-unseal-keys" "$(cat /opt/vault/init.json)"
  # Local copy no longer required once escrowed in Key Vault
  shred -u /opt/vault/init.json 2>/dev/null || rm -f /opt/vault/init.json
fi

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

# Database engine (dynamic DB credentials) - enabled, ready to be wired
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
    oidc_client_secret="${auth0_client_secret}" \
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
# Admin role via stdin JSON (the key=value form does not parse nested bound_claims)
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

# Map the Auth0 group -> Vault admin policy via an external group.
vault write identity/group name="PAM_Administrator" type="external" \
    policies="pam-admin-policy" || true

# =====================================================================
# 7. SECURITY CLEANUP
# =====================================================================
# The root token stays escrowed in Azure Key Vault for break-glass administration;
# it is only removed from the script environment. For a zero standing root
# posture, revoke it and regenerate it on demand with generate-root.
unset ROOT_TOKEN

# =====================================================================
# 8. SPLUNK ENTERPRISE (SIEM) via Docker  +  ingestion forensique
#    Official image avoids versioned .deb URLs that expire and 404.
# =====================================================================
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

docker run -d --name splunk --restart unless-stopped \
  -p 8000:8000 -p 8088:8088 \
  -e SPLUNK_GENERAL_TERMS="--accept-sgt-current-at-splunk-com" \
  -e SPLUNK_START_ARGS="--accept-license" \
  -e SPLUNK_PASSWORD="$SPLUNK_PW" \
  -v /opt/vault/audit:/var/log/vault:ro \
  -v /var/log:/var/log/host:ro \
  splunk/splunk:latest

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
indicator:sum_top3_cpu_percentage:yellow = 30
indicator:sum_top3_cpu_percentage:red = 60
indicator:single_cpu_percentage:yellow = 40
indicator:single_cpu_percentage:red = 70
HC

# Preinstalled forensic dashboard
docker exec -u root splunk mkdir -p /opt/splunk/etc/apps/search/local/data/ui/views
docker exec -i -u root splunk bash -c 'cat > /opt/splunk/etc/apps/search/local/data/ui/views/pam_governance.xml' <<'DASH'
${splunk_dashboard}
DASH

docker exec -u root splunk chown -R splunk:splunk /opt/splunk/etc/system/local /opt/splunk/etc/apps/search/local/data
docker restart splunk || true

# Wipe the transient Splunk password file
shred -u /root/.splunk_pw 2>/dev/null || rm -f /root/.splunk_pw
