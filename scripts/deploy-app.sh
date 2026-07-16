#!/usr/bin/env bash
#
# deploy-app.sh
#
# Builds the Angular app image in Azure Container Registry (no local Docker or
# Node needed), installs Istio and Kong on AKS, then deploys the app. It reads
# the Auth0 domain and client id from Terraform outputs, injects them into the
# image build and the runtime config, waits for the Kong public IP, and syncs
# the Auth0 callback URLs to that IP.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
TF_DIR="$ROOT/terraform"
RG="${RESOURCE_GROUP:-rg-pam-governance}"
AKS="${AKS_NAME:-aks-pam-governance}"
ISTIO_REPO="https://istio-release.storage.googleapis.com/charts"
KONG_REPO="https://charts.konghq.com"

log()  { printf '%s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
invoke() { az aks command invoke -g "$RG" -n "$AKS" --query "logs" -o tsv "$@"; }
tfout() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true; }

command -v az >/dev/null 2>&1 || die "Azure CLI (az) not found."

acr_name="$(tfout acr_name)"
acr_server="$(tfout acr_login_server)"
auth0_domain="$(tfout auth0_domain)"
client_id="$(tfout auth0_app_client_id)"
if [ -z "$acr_name" ] || [ -z "$acr_server" ]; then die "ACR outputs missing; run scripts/deploy-infra.sh first."; fi
if [ -z "$auth0_domain" ] || [ -z "$client_id" ]; then die "Auth0 outputs missing; run scripts/deploy-infra.sh first."; fi

# --- 1. Build the Angular image in ACR (cloud build) ---
tag="$(date +%Y%m%d%H%M%S)"
image="${acr_server}/pam-app:${tag}"
log "Building the Angular image in ACR: $image"
az acr build --registry "$acr_name" --image "pam-app:${tag}" \
  --build-arg "AUTH0_DOMAIN=${auth0_domain}" "$ROOT/apps/web" >/dev/null
log "Image built."

# --- 2. Istio (service mesh, mTLS) ---
log "Installing Istio (base and istiod)."
invoke --command "kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f - ; \
  helm status istio-base -n istio-system >/dev/null 2>&1 || helm install istio-base base --repo $ISTIO_REPO -n istio-system --set defaultRevision=default --wait --timeout 5m ; \
  helm status istiod -n istio-system >/dev/null 2>&1 || helm install istiod istiod --repo $ISTIO_REPO -n istio-system --wait --timeout 5m" >/dev/null
log "Istio ready."

# --- 3. Kong (edge API gateway, LoadBalancer) ---
log "Installing Kong as the edge load balancer."
invoke --command "kubectl create ns kong --dry-run=client -o yaml | kubectl apply -f - ; \
  kubectl label ns kong istio-injection=enabled --overwrite ; \
  helm status kong -n kong >/dev/null 2>&1 || helm install kong kong --repo $KONG_REPO -n kong --set ingressController.installCRDs=false --wait --timeout 6m" >/dev/null
log "Kong ready."

# --- 4. Deploy the app (manifest with the image, runtime config from outputs) ---
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sed "s#__APP_IMAGE__#${image}#g" "$ROOT/kubernetes/app.yaml" > "$work/app.yaml"
cat > "$work/config.json" <<EOF
{ "auth0Domain": "${auth0_domain}", "auth0ClientId": "${client_id}" }
EOF

log "Deploying the app ($image)."
invoke --file "$work/app.yaml" --file "$work/config.json" \
  --command "kubectl apply -f app.yaml ; \
    kubectl -n pam-governance create configmap app-config --from-file=config.json \
      --dry-run=client -o yaml | kubectl apply -f - ; \
    kubectl -n pam-governance rollout restart deploy/app ; \
    kubectl -n pam-governance rollout status deploy/app --timeout=180s" >/dev/null
log "App deployed."

# --- 5. Wait for the Kong public IP ---
log "Waiting for the Kong public IP."
ip=""
for _ in $(seq 1 30); do
  ip="$(invoke --command "kubectl -n kong get svc kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" | tr -d '[:space:]')"
  [ -n "$ip" ] && break
  sleep 10
done
[ -n "$ip" ] || { log "Kong load balancer IP not assigned yet. Re-run later."; exit 1; }
log "App online at http://${ip} (it redirects to https)."

# --- 6. Sync the Auth0 callback URLs to the Kong IP (needs the M2M env vars) ---
if [ -f "$TF_DIR/terraform.tfvars" ] && [ -n "${AUTH0_CLIENT_ID:-}" ] && [ -n "${AUTH0_CLIENT_SECRET:-}" ]; then
  log "Syncing Auth0 callbacks to http://${ip}."
  if grep -q '^app_url' "$TF_DIR/terraform.tfvars"; then
    sed -i -E "s#^app_url.*#app_url = \"http://${ip}\"#" "$TF_DIR/terraform.tfvars"
  else
    printf 'app_url = "http://%s"\n' "$ip" >> "$TF_DIR/terraform.tfvars"
  fi
  terraform -chdir="$TF_DIR" apply -target=auth0_client.app_spa -auto-approve \
    || log "Callback sync failed; run: terraform -chdir=terraform apply -target=auth0_client.app_spa"
else
  log "Skipping Auth0 callback sync (set AUTH0_* env vars and terraform.tfvars to enable)."
  log "Manual step: set app_url=\"http://${ip}\" and run terraform apply -target=auth0_client.app_spa."
fi
