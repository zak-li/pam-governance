#!/usr/bin/env bash
#
# start.sh
#
# Restarts the infrastructure that stop.sh suspended. Note that Vault comes
# back sealed, because it uses file storage with no auto-unseal, so it must be
# unlocked with the unseal keys escrowed in Key Vault (see the README).
#
set -euo pipefail

RG="${RESOURCE_GROUP:-rg-pam-governance}"
AKS="${AKS_NAME:-aks-pam-governance}"
VM="${VM_NAME:-vm-splunk-target}"

log()  { printf '%s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null 2>&1   || die "Azure CLI (az) not found."
az account show >/dev/null 2>&1 || die "Not signed in to Azure. Run: az login"
az group show -n "$RG" >/dev/null 2>&1 || die "Resource group '$RG' not found. Was the infrastructure destroyed?"

# Start the VM.
if az vm show -g "$RG" -n "$VM" >/dev/null 2>&1; then
  log "Starting VM '$VM'."
  az vm start -g "$RG" -n "$VM" --only-show-errors >/dev/null
  log "VM started."
fi

# Start AKS.
if az aks show -g "$RG" -n "$AKS" >/dev/null 2>&1; then
  state="$(az aks show -g "$RG" -n "$AKS" --query "powerState.code" -o tsv 2>/dev/null || echo Unknown)"
  if [[ "$state" != "Running" ]]; then
    log "Starting AKS cluster '$AKS'. This can take a few minutes."
    az aks start -g "$RG" -n "$AKS" --only-show-errors >/dev/null
    log "AKS started."
  else
    log "AKS already running."
  fi
fi

log ""
ip="$(az network public-ip show -g "$RG" -n pip-splunk --query ipAddress -o tsv 2>/dev/null || echo '?')"
log "Infrastructure restarted."
log "Vault:  https://${ip}:8200 (unlock with three unseal keys from Key Vault)"
log "Splunk: http://${ip}:8000"
log "App: read the Kong IP with 'kubectl -n kong get svc kong-kong-proxy'."
