#!/usr/bin/env bash
#
# destroy.sh
#
# Full teardown of the infrastructure. Terraform destroys the AKS cluster and
# its load balancers, the virtual machine, Vault, Splunk, the Key Vault, the
# network, the identities, and the managed Auth0 resources (clients, roles,
# actions, tenant settings). This is irreversible.
#
# It requires the Auth0 Management API credentials in the environment
# (AUTH0_DOMAIN, AUTH0_CLIENT_ID, AUTH0_CLIENT_SECRET) and a terraform.tfvars file.
#
# Usage:
#   scripts/destroy.sh          asks for confirmation
#   scripts/destroy.sh --yes    skips confirmation, for CI
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

log()  { printf '%s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null 2>&1        || die "Azure CLI (az) not found."
command -v terraform >/dev/null 2>&1 || die "Terraform not found."
az account show >/dev/null 2>&1      || die "Not signed in to Azure. Run: az login"

: "${AUTH0_DOMAIN:?Export AUTH0_DOMAIN (the M2M Management API app)}"
: "${AUTH0_CLIENT_ID:?Export AUTH0_CLIENT_ID}"
: "${AUTH0_CLIENT_SECRET:?Export AUTH0_CLIENT_SECRET}"

if [[ "${1:-}" != "--yes" && "${1:-}" != "-y" ]]; then
  log "This permanently deletes the entire infrastructure and cannot be undone."
  log "Type 'destroy' to confirm:"
  read -r ans
  [[ "$ans" == "destroy" ]] || die "Aborted."
fi

cd "$TF_DIR"
log "Running terraform destroy."
terraform destroy -auto-approve

log ""
log "Infrastructure fully destroyed."
log "The Auth0 Google social connection and the admin@pam-governance.local account"
log "were created outside Terraform, so remove them manually if you no longer need them."
