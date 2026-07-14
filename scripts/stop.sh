#!/usr/bin/env bash
#
# stop.sh
#
# Stops all compute infrastructure cleanly. The AKS node pool is deallocated
# with "az aks stop" and the virtual machine is deallocated with
# "az vm deallocate", which brings the compute cost down to zero.
#
# This is reversible. Run scripts/start.sh to bring the same environment back.
# No data is lost, since the disk, the static public IP, the Key Vault and the
# configuration are all preserved. To remove every resource, use
# scripts/destroy.sh instead.
#
set -euo pipefail

RG="${RESOURCE_GROUP:-rg-pam-governance}"
AKS="${AKS_NAME:-aks-pam-governance}"
VM="${VM_NAME:-vm-splunk-target}"

log()  { printf '%s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null 2>&1   || die "Azure CLI (az) not found."
az account show >/dev/null 2>&1 || die "Not signed in to Azure. Run: az login"

if ! az group show -n "$RG" >/dev/null 2>&1; then
  log "Resource group '$RG' does not exist. Nothing to stop."
  exit 0
fi

log "Subscription: $(az account show --query name -o tsv)"
log "Resource group: $RG"
log ""

# Stop AKS.
if az aks show -g "$RG" -n "$AKS" >/dev/null 2>&1; then
  state="$(az aks show -g "$RG" -n "$AKS" --query "powerState.code" -o tsv 2>/dev/null || echo Unknown)"
  if [[ "$state" == "Running" ]]; then
    log "Stopping AKS cluster '$AKS' and deallocating its nodes."
    az aks stop -g "$RG" -n "$AKS" --only-show-errors >/dev/null
    log "AKS stopped."
  else
    log "AKS already stopped (state: $state)."
  fi
else
  log "AKS '$AKS' not found. Skipped."
fi

# Deallocate the VM.
if az vm show -g "$RG" -n "$VM" >/dev/null 2>&1; then
  power="$(az vm get-instance-view -g "$RG" -n "$VM" \
        --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv 2>/dev/null || echo Unknown)"
  if [[ "$power" == "PowerState/deallocated" ]]; then
    log "VM already deallocated."
  else
    log "Deallocating VM '$VM' (Vault and Splunk)."
    az vm deallocate -g "$RG" -n "$VM" --only-show-errors >/dev/null
    log "VM deallocated."
  fi
else
  log "VM '$VM' not found. Skipped."
fi

log ""
log "Infrastructure stopped. Compute cost is now zero."
log "Restart with scripts/start.sh. Delete everything with scripts/destroy.sh."
