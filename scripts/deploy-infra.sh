#!/usr/bin/env bash
#
# deploy-infra.sh
#
# Provisions the base infrastructure with Terraform: the Vault and Splunk
# virtual machine, the AKS cluster, the Key Vault, the network, the identities,
# and the Auth0 tenant configuration.
#
# It requires an Azure login, the Auth0 Management API credentials in the
# environment (AUTH0_DOMAIN, AUTH0_CLIENT_ID, AUTH0_CLIENT_SECRET), and a
# terraform.tfvars file copied from terraform.tfvars.example.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

log()  { printf '%s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null 2>&1        || die "Azure CLI (az) not found."
command -v terraform >/dev/null 2>&1 || die "Terraform not found."
az account show >/dev/null 2>&1      || die "Not signed in to Azure. Run: az login"
: "${AUTH0_DOMAIN:?Export AUTH0_DOMAIN}"
: "${AUTH0_CLIENT_ID:?Export AUTH0_CLIENT_ID}"
: "${AUTH0_CLIENT_SECRET:?Export AUTH0_CLIENT_SECRET}"
[[ -f "$TF_DIR/terraform.tfvars" ]] || die "Create terraform/terraform.tfvars from terraform.tfvars.example."

cd "$TF_DIR"
log "Initializing Terraform."
terraform init -input=false >/dev/null
log "Validating the configuration."
terraform validate >/dev/null
log "Applying."
terraform apply -input=false -auto-approve

log ""
log "Infrastructure provisioned. Outputs:"
terraform output vault_ui_url splunk_ui_url key_vault_name aks_name 2>/dev/null || true
log ""
log "Next, run scripts/deploy-app.sh to install Istio, Kong, and the app."
