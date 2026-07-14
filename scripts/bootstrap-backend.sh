#!/usr/bin/env bash
#
# bootstrap-backend.sh
#
# Creates an encrypted, versioned Azure Storage account to hold the Terraform
# state remotely, so secrets no longer sit in a local state file. Run this once,
# then copy terraform/backend.tf.example to terraform/backend.tf, fill in the
# printed values, and run: terraform -chdir=terraform init -migrate-state
#
set -euo pipefail

LOCATION="${LOCATION:-polandcentral}"
RG="${BACKEND_RG:-rg-tfstate}"
CONTAINER="${BACKEND_CONTAINER:-tfstate}"
# Storage account names must be globally unique and lowercase alphanumeric.
SA="${BACKEND_SA:-tfstatepam$RANDOM$RANDOM}"

log() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null 2>&1   || die "Azure CLI (az) not found."
az account show >/dev/null 2>&1 || die "Not signed in to Azure. Run: az login"

log "Creating resource group '$RG' in '$LOCATION'."
az group create -n "$RG" -l "$LOCATION" --only-show-errors >/dev/null

log "Creating storage account '$SA' (encrypted, versioned, TLS 1.2)."
az storage account create -n "$SA" -g "$RG" -l "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
  --allow-blob-public-access false --only-show-errors >/dev/null
az storage account blob-service-properties update \
  --account-name "$SA" --enable-versioning true --only-show-errors >/dev/null

log "Creating container '$CONTAINER'."
az storage container create -n "$CONTAINER" --account-name "$SA" \
  --auth-mode login --only-show-errors >/dev/null

cat <<EOF

Remote backend ready. Put this in terraform/backend.tf:

terraform {
  backend "azurerm" {
    resource_group_name  = "$RG"
    storage_account_name = "$SA"
    container_name       = "$CONTAINER"
    key                  = "pam-governance.tfstate"
  }
}

Then migrate the existing state:

  terraform -chdir=terraform init -migrate-state
EOF
