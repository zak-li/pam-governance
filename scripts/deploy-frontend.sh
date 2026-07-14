#!/usr/bin/env bash
#
# deploy-frontend.sh
#
# Deploys Istio, then Kong, then the hardened frontend onto the AKS cluster.
# It drives the cluster through "az aks command invoke", so no local kubectl or
# helm is required. The script is idempotent and safe to re-run.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RG="${RESOURCE_GROUP:-rg-pam-governance}"
AKS="${AKS_NAME:-aks-pam-governance}"
ISTIO_REPO="https://istio-release.storage.googleapis.com/charts"
KONG_REPO="https://charts.konghq.com"

log()  { printf '%s\n' "$*"; }
invoke() { az aks command invoke -g "$RG" -n "$AKS" --query "logs" -o tsv "$@"; }

log "Installing Istio (base and istiod)."
invoke --command "kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f - ; \
  helm status istio-base -n istio-system >/dev/null 2>&1 || helm install istio-base base --repo $ISTIO_REPO -n istio-system --set defaultRevision=default --wait --timeout 5m ; \
  helm status istiod -n istio-system >/dev/null 2>&1 || helm install istiod istiod --repo $ISTIO_REPO -n istio-system --wait --timeout 5m" >/dev/null
log "Istio ready."

log "Installing Kong as the edge load balancer."
invoke --command "kubectl create ns kong --dry-run=client -o yaml | kubectl apply -f - ; \
  kubectl label ns kong istio-injection=enabled --overwrite ; \
  helm status kong -n kong >/dev/null 2>&1 || helm install kong kong --repo $KONG_REPO -n kong --set ingressController.installCRDs=false --wait --timeout 6m" >/dev/null
log "Kong ready."

log "Deploying the frontend manifest and assets."
invoke \
  --file "$ROOT/k8s/frontend.yaml" \
  --file "$ROOT/frontend/index.html" \
  --file "$ROOT/frontend/style.css" \
  --file "$ROOT/frontend/app.js" \
  --command "kubectl apply -f frontend.yaml ; \
    kubectl -n pam-governance create configmap frontend-files \
      --from-file=index.html --from-file=style.css --from-file=app.js \
      --dry-run=client -o yaml | kubectl apply -f - ; \
    kubectl -n pam-governance rollout restart deploy/frontend ; \
    kubectl -n pam-governance rollout status deploy/frontend --timeout=150s" >/dev/null
log "Frontend deployed."

log "Fetching the Kong public IP."
ip="$(invoke --command "kubectl -n kong get svc kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" | tr -d '[:space:]')"
log ""
log "Frontend online at http://${ip} (it redirects to https)."
log "Update frontend_url to \"http://${ip}\" in terraform.tfvars, then run"
log "terraform apply -target=auth0_client.frontend_spa to sync the Auth0 callbacks."
