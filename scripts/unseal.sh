#!/usr/bin/env bash
#
# unseal.sh
#
# Unseals Vault after a VM reboot or a start. Vault uses file storage with no
# auto-unseal, so it comes back sealed. This runs on the VM through
# "az vm run-command", fetches the unseal keys from Key Vault using the VM
# managed identity, and applies three of the five shares. The keys never leave
# the VM. For a production upgrade, replace this with an azurekeyvault seal
# stanza (see docs/ARCHITECTURE.md).
#
set -euo pipefail

RG="${RESOURCE_GROUP:-rg-pam-governance}"
VM="${VM_NAME:-vm-splunk-target}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

log() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null 2>&1   || die "Azure CLI (az) not found."
az account show >/dev/null 2>&1 || die "Not signed in to Azure. Run: az login"

kv="$(terraform -chdir="$TF_DIR" output -raw key_vault_name 2>/dev/null || true)"
[ -n "$kv" ] || kv="$(az keyvault list -g "$RG" --query "[0].name" -o tsv 2>/dev/null)"
[ -n "$kv" ] || die "Could not determine the Key Vault name."

cid="$(az identity show -g "$RG" -n id-pam-vm --query clientId -o tsv 2>/dev/null)"
[ -n "$cid" ] || die "Could not determine the VM managed identity client id."

log "Unsealing Vault on '$VM' using keys from Key Vault '$kv'."

remote="$(cat <<EOF
set -e
export VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true
tok=\$(curl -s -H Metadata:true "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net&client_id=$cid" | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
init=\$(curl -s "https://$kv.vault.azure.net/secrets/vault-unseal-keys?api-version=7.4" -H "Authorization: Bearer \$tok" | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')
for i in 0 1 2; do
  key=\$(printf '%s' "\$init" | python3 -c "import sys,json;print(json.load(sys.stdin)['unseal_keys_b64'][\$i])")
  vault operator unseal "\$key" >/dev/null
done
vault status | grep -E 'Sealed|Initialized'
EOF
)"

b64="$(printf '%s' "$remote" | base64 -w0)"
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
  --scripts "echo $b64 | base64 -d | bash" \
  --query "value[0].message" -o tsv
