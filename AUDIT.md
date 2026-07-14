# Project Audit and Remediation Plan

This document is a full A-to-Z audit of the PAM / Identity Governance project.
It lists bugs, unimplemented or partially implemented features, and bad
practices, each with a concrete fix. It is written to be executed by an
implementing agent. Work top to bottom by severity, and after each change run
`make fmt`, `make validate`, and `shellcheck scripts/*.sh`.

Legend for severity: **P0** breaks or is a real security hole, **P1** important
gap or bad practice, **P2** polish. Every finding has a stable ID (for example
`A3`) so it can be referenced in commits.

## Priority summary

| ID | Severity | Area | Title |
|----|----------|------|-------|
| A3 | P0 | Terraform / Auth0 | Hardcoded Auth0 connection id breaks a fresh deploy |
| A7 | P0 | Vault | Vault re-seals on reboot, platform is down until manual unseal |
| C1 | P0 | Terraform | Local state holds plaintext secrets, no remote backend |
| C2 | P0 | Vault / Azure | Secrets shipped in VM custom_data |
| B2 | P1 | Vault | Database dynamic secrets claimed but not configured |
| B1 | P1 | IaC | Istio, Kong and the app are deployed imperatively, not as IaC |
| B3 | P1 | Splunk | No data or config persistence for Splunk |
| B6 | P1 | Auth0 | Google connection and admin user exist outside Terraform |
| C3 | P1 | Key Vault | Key Vault network default action is Allow |
| C4 | P1 | Key Vault | Purge protection disabled on break-glass vault |
| C5 | P1 | Network | Hardcoded default admin IP in variables |
| C8 | P1 | Vault | Root token left valid (no zero standing root) |
| C9 | P1 | App | Auth0 domain and client id hardcoded in app and CSP |
| C10 | P1 | CI | No IaC security scanning or tflint |
| A2 | P1 | Scripts | Kong public IP is read before it is assigned |
| A4 | P1 | Splunk | Splunk image pinned to :latest |
| B4 | P1 | Istio | mTLS is PERMISSIVE, weaker than the Zero-Trust claim |
| A1 | P2 | k8s | Residual French comments in k8s/app.yaml |
| A5 | P2 | Vault | Unused VAULT_VERSION variable |
| A6 | P2 | Bootstrap | Unused libcap2-bin package |
| B8 | P1 | Scripts | Auth0 callback sync after deploy is manual |
| D2 | P2 | Bootstrap | Fragile dashboard heredoc injection |
| C6 | P2 | Bootstrap | curl piped to shell to install Docker |
| C7 | P2 | Terraform | skip_provider_registration masks missing RPs |
| E1..E7 | P2 | Misc | See the Minor section |

---

## A. Correctness bugs

### A1 (P2) Residual French comments in `k8s/app.yaml`
The project is meant to be fully English, but two comments are still French.
- Location: `k8s/app.yaml`, the `app-service` annotations block (around lines
  152 to 153) and the ingress annotations (around lines 205 to 206).
- Problem: `# Kong route via la ClusterIP ...` and `# n'accepte que HTTPS` /
  `# redirige http -> https` are French. They were missed because they contain
  no accented characters, so the earlier grep did not catch them.
- Fix: replace with English, for example:
  - `# Route through the ClusterIP (not pod IPs) so Istio auto-mTLS applies.`
  - `# Accept HTTPS only` and `# Redirect http to https`.
- Verify: `grep -RniE "via la|n.accepte|redirige|ClusterIP \(pas" k8s/` returns nothing.

### A2 (P1) Kong public IP is read before it is assigned
- Location: `scripts/deploy-app.sh`, the `ip="$(invoke ... jsonpath ...)"` line.
- Problem: `helm install kong --wait` waits for pods, not for the Azure load
  balancer to be assigned an external IP, so the jsonpath can return empty and
  the script prints `App online at http://`.
- Fix: poll until the IP is non-empty, for example:
  ```bash
  ip=""
  for _ in $(seq 1 30); do
    ip="$(invoke --command "kubectl -n kong get svc kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" | tr -d '[:space:]')"
    [ -n "$ip" ] && break
    sleep 10
  done
  [ -n "$ip" ] || { log "Kong load balancer IP not assigned yet."; exit 1; }
  ```

### A3 (P0) Hardcoded Auth0 connection id breaks a fresh deploy
- Location: `terraform/auth0.tf`, `resource "auth0_connection_clients" "db_clients"`,
  `connection_id = "con_XkyAVXuIjcqHLJJV"`.
- Problem: this connection id belongs to one specific Auth0 tenant. A new user
  running `terraform apply` against their own tenant gets a 404, and the whole
  apply fails. The project is not reproducible.
- Fix: look the connection up by name instead of hardcoding the id.
  ```hcl
  data "auth0_connection" "db" {
    name = "Username-Password-Authentication"
  }

  resource "auth0_connection_clients" "db_clients" {
    connection_id   = data.auth0_connection.db.id
    enabled_clients = [auth0_client.app_spa.client_id, auth0_client.vault_client.client_id]
  }
  ```
- Note: if the provider version does not expose that data source, create the
  database connection in Terraform (`auth0_connection` with strategy `auth0`)
  and reference it.

### A4 (P1) Splunk image pinned to `:latest`
- Location: `terraform/install.sh.tpl`, `docker run ... splunk/splunk:latest`.
- Problem: `:latest` is not reproducible and can change under the deployment,
  which already bit this project once (the SPLUNK_GENERAL_TERMS requirement).
- Fix: pin a known-good version, for example `splunk/splunk:9.3` (or a specific
  patch), and note it next to the Vault version pin.

### A5 (P2) Unused `VAULT_VERSION` variable
- Location: `terraform/install.sh.tpl`, `VAULT_VERSION="1.17.6"` then a hardcoded
  URL `.../vault/1.17.6/vault_1.17.6_linux_amd64.zip`.
- Problem: the variable is dead and the version is duplicated in the URL, which
  drifts.
- Fix: use the variable, escaping `$${VAULT_VERSION}` so Terraform templatefile
  leaves it for bash:
  ```bash
  curl -fsSL -o /tmp/vault.zip "https://releases.hashicorp.com/vault/$${VAULT_VERSION}/vault_$${VAULT_VERSION}_linux_amd64.zip" && break
  ```

### A6 (P2) Unused `libcap2-bin` package
- Location: `terraform/install.sh.tpl`, `apt-get install -y ... libcap2-bin`.
- Problem: it was needed for `setcap` when mlock was enabled; mlock is now
  disabled (`disable_mlock = true`), so the package is dead weight.
- Fix: remove `libcap2-bin` from the apt install line.

### A7 (P0) Vault re-seals on reboot, no auto-unseal
- Location: `terraform/install.sh.tpl` (Vault config, `storage "file"`) and the
  operational model.
- Problem: Vault uses file storage with a one-time manual unseal during
  bootstrap. After any VM reboot, or after `scripts/start.sh`, Vault starts
  sealed and the platform is effectively down until an operator manually
  unseals it. This is a functional break for the advertised lifecycle.
- Fix (preferred): implement Azure Key Vault auto-unseal. Add a Key Vault key
  (not secret), grant the VM identity wrap/unwrap, and add a seal stanza:
  ```hcl
  seal "azurekeyvault" {
    tenant_id      = "<tenant>"
    vault_name     = "<key vault name>"
    key_name       = "vault-unseal"
    # resource and auth come from the VM managed identity
  }
  ```
  The VM identity needs `Key Vault Crypto User` (wrapKey, unwrapKey) on that key.
- Fix (minimum): ship an `scripts/unseal.sh` that reads `vault-unseal-keys` from
  Key Vault and runs three `vault operator unseal` calls, and call it out in
  `start.sh`.

---

## B. Missing or partially implemented features

### B1 (P1) Mesh, gateway and app are not Infrastructure-as-Code
- Location: `scripts/deploy-app.sh`, README claim "fully provisioned as
  Infrastructure-as-Code".
- Problem: Istio, Kong and the app are installed imperatively through
  `az aks command invoke` and Helm inside a shell script. Only the cluster
  itself is in Terraform. This contradicts the IaC claim and is not idempotent
  in the Terraform sense (no state, no drift detection).
- Fix (preferred): add the Terraform `helm` and `kubernetes` providers wired to
  the AKS kubeconfig output, and manage `istio-base`, `istiod`, `kong`, and the
  app manifest as `helm_release` and `kubernetes_manifest` resources. Keep
  `deploy-app.sh` as a thin wrapper or remove it.
- Fix (minimum): soften the README to say the base infrastructure is IaC and the
  cluster workloads are deployed by a scripted, idempotent installer.

### B2 (P1) Database dynamic secrets are not actually configured
- Location: `terraform/install.sh.tpl`, `vault secrets enable -path=database`.
- Problem: the engine is enabled but there is no database connection and no role,
  so the advertised "dynamic database credentials" produces nothing. It is a
  claim without an implementation.
- Fix: either (a) provision a small PostgreSQL (Azure Flexible Server or an
  in-cluster instance), then `vault write database/config/...` and
  `vault write database/roles/...`, or (b) remove the database engine and drop
  the database claim from the docs to keep the project honest.

### B3 (P1) Splunk has no data or config persistence
- Location: `terraform/install.sh.tpl`, the `docker run ... splunk/splunk` line.
- Problem: no volume is mounted for `/opt/splunk/var` (indexed data) or
  `/opt/splunk/etc` (configuration). A container recreate loses all audit data,
  the `pam_audit` index, the inputs, and the dashboard.
- Fix: create host directories and mount them, for example
  `-v /opt/splunk-data/var:/opt/splunk/var -v /opt/splunk-data/etc:/opt/splunk/etc`,
  and set correct ownership so the container user can write.

### B4 (P1) mTLS is PERMISSIVE, not STRICT
- Location: `k8s/app.yaml`, `PeerAuthentication` `mode: PERMISSIVE`.
- Problem: the README and docs sell strict Zero-Trust mTLS, but the mesh accepts
  plaintext as well. Kong to app can run in the clear inside the cluster.
- Fix (accurate now): keep PERMISSIVE but state it plainly in the docs (already
  partly done in `docs/ARCHITECTURE.md`), and describe the strict path.
- Fix (strict): terminate north-south at an Istio IngressGateway rather than
  Kong for the app path, then set `mode: STRICT`. Move rate limiting to an
  Istio `EnvoyFilter` or keep Kong only for non-mesh routes.

### B5 (P1) No trusted TLS certificate
- Location: Kong edge, `k8s/app.yaml` ingress.
- Problem: Kong serves the app on its default self-signed certificate, so the
  browser always warns. A public IP with no domain cannot get a trusted cert.
- Fix: add a domain (even a free one), install `cert-manager` with a Let's
  Encrypt `ClusterIssuer`, and reference the issued `Certificate` in the ingress
  `tls` block. Document this as the production path.

### B6 (P1) Auth0 Google connection and admin user exist outside Terraform
- Location: created via the Management API during earlier work; referenced only
  by a note in `scripts/destroy.sh`.
- Problem: the Google social connection and `admin@pam-governance.local` are not
  in Terraform, so `terraform destroy` leaves them, and a fresh apply does not
  create them. This is configuration drift.
- Fix: manage them in Terraform. Add an `auth0_connection` for `google-oauth2`
  (with the operator's own OAuth keys, see C9), and if a seed admin is wanted,
  an `auth0_user` plus an `auth0_user_roles` assignment. Otherwise remove them
  and delete the note.

### B7 (P1) No automated tests
- Location: repository root, CI.
- Problem: there is no test beyond `terraform validate`. Scripts and the bootstrap
  template are unverified.
- Fix: add at least a `terraform plan` dry run in CI against a throwaway or
  mocked backend, `bash -n` syntax checks on all scripts and the template, and
  optionally `terratest` for a smoke deploy.

### B8 (P1) Post-deploy Auth0 callback sync is manual
- Location: `scripts/deploy-app.sh` tail, which prints instructions to edit
  `terraform.tfvars` and re-apply.
- Problem: a manual step is error prone and breaks the "one command" story.
- Fix: after resolving the Kong IP, have the script write `app_url` into
  `terraform.tfvars` (or pass `-var`) and run
  `terraform -chdir=terraform apply -target=auth0_client.app_spa -auto-approve`.

---

## C. Security weaknesses and bad practices

### C1 (P0) Local Terraform state holds plaintext secrets
- Location: `terraform/` state files (gitignored, but local).
- Problem: the state contains the Vault TLS private key, the VM and Splunk
  password, the SSH private key, and the Auth0 client secret in clear text on
  disk with no encryption and no locking.
- Fix: configure a remote encrypted backend with locking.
  ```hcl
  terraform {
    backend "azurerm" {
      resource_group_name  = "rg-tfstate"
      storage_account_name = "<unique>"
      container_name       = "tfstate"
      key                  = "pam-governance.tfstate"
    }
  }
  ```
  Enable blob versioning and encryption on the storage account.

### C2 (P0) Secrets shipped in VM custom_data
- Location: `terraform/compute.tf`, `custom_data = base64encode(templatefile(...))`
  passing `auth0_client_secret`, `vault_key`, and `admin_password`.
- Problem: custom_data is stored in Azure and readable by anyone with reader
  access to the VM, and it is not encrypted at rest by the caller. Long-lived
  secrets should not travel this way.
- Fix: put those secrets in Key Vault first, give the VM identity read access,
  and have `install.sh.tpl` fetch them at boot through the managed identity
  (the same IMDS pattern already used for escrow). custom_data then carries only
  non-secret configuration.

### C3 (P1) Key Vault network default action is Allow
- Location: `terraform/keyvault.tf`, `network_acls { default_action = "Allow" }`.
- Problem: there is no network restriction; the vault is reachable from anywhere
  that has AAD credentials. The subnet service endpoint is configured but unused.
- Fix: set `default_action = "Deny"`, keep `bypass = "AzureServices"`, and allow
  the VM subnet and the admin IP:
  ```hcl
  network_acls {
    default_action             = "Deny"
    bypass                     = "AzureServices"
    virtual_network_subnet_ids = [azurerm_subnet.subnet.id]
    ip_rules                   = [var.admin_source_ip]
  }
  ```

### C4 (P1) Purge protection disabled on the break-glass vault
- Location: `terraform/keyvault.tf`, `purge_protection_enabled = false`,
  `soft_delete_retention_days = 7`.
- Problem: the vault holds the only escrowed unseal keys and root token. Without
  purge protection they can be permanently deleted, which is an unrecoverable
  loss of break-glass material.
- Fix: `purge_protection_enabled = true` and a longer retention (for example 30
  days). Accept that this makes teardown slower, and document it.

### C5 (P1) Hardcoded default admin IP
- Location: `terraform/variables.tf`, `variable "admin_source_ip"` with
  `default = "196.75.81.68"`.
- Problem: a default that opens SSH, Vault, and Splunk to a specific real IP is
  both tenant-specific and a footgun (a user who forgets to set it grants access
  to someone else's address).
- Fix: remove the default so it is required, and consider accepting a list of
  CIDRs. Update `terraform.tfvars.example` accordingly.

### C6 (P2) Docker installed by piping curl to shell
- Location: `terraform/install.sh.tpl`, `curl -fsSL https://get.docker.com | sh`.
- Problem: piping a remote script into a shell is a supply-chain risk.
- Fix: install `docker.io` (or the Docker apt repo pinned to a version and
  verified by key) through `apt-get` instead.

### C7 (P2) skip_provider_registration masks missing resource providers
- Location: `terraform/providers.tf`, `skip_provider_registration = true`.
- Problem: it was a workaround for a subscription where RPs were not registered.
  It hides real configuration problems.
- Fix: register the needed RPs (`Microsoft.KeyVault`, `Microsoft.ManagedIdentity`,
  `Microsoft.ContainerService`) explicitly or in a bootstrap step, then remove
  the flag.

### C8 (P1) Root token left valid, no zero standing root
- Location: `terraform/install.sh.tpl` section 7, which only `unset ROOT_TOKEN`.
- Problem: the initial root token remains valid and escrowed. A PAM platform
  should have no standing root.
- Fix: after configuration, `vault token revoke -self`, keep only the unseal
  keys escrowed, and document that break-glass root is regenerated on demand with
  `vault operator generate-root` (there is already a working recipe for this).

### C9 (P1) Auth0 domain and client id hardcoded in the app and the CSP
- Location: `app/app.js` (`AUTH0_CONFIG`), `k8s/app.yaml` CSP
  (`https://dev-k5xncag6gzsmst88.eu.auth0.com` in `connect-src` and `frame-src`).
- Problem: tenant-specific values are baked into source, so the app is not
  portable and must be hand-edited per environment.
- Fix: template these at deploy time. Have `deploy-app.sh` substitute the domain
  and the `auth0_app_client_id` Terraform output into `app.js` and the CSP (for
  example with `envsubst` on a `.tmpl`), or serve a small `/config.json` the app
  fetches at startup.

### C10 (P1) No IaC security scanning in CI
- Location: `.github/workflows/ci.yml`.
- Problem: CI only formats, validates, and shellchecks. There is no static
  security analysis of the Terraform or Kubernetes manifests.
- Fix: add jobs for `tflint`, and `tfsec` or `checkov`, and a `kube-linter` or
  `kubeconform` pass on `k8s/app.yaml`. Fail the build on high findings.

---

## D. Reproducibility and portability

### D1 (P1) The deployment assumes one specific Auth0 tenant
- Location: `app/app.js`, `k8s/app.yaml` CSP, `terraform/auth0.tf` (connection
  id, see A3), `terraform/terraform.tfvars.example` (real domain).
- Problem: a new adopter must edit several files by hand to point at their own
  tenant, and one of those (the connection id) causes a hard failure.
- Fix: drive every tenant-specific value from variables and Terraform outputs,
  and template the app and the CSP at deploy time (see A3 and C9).

### D2 (P2) Fragile dashboard heredoc injection
- Location: `terraform/install.sh.tpl`, `... <<'DASH'` with `${splunk_dashboard}`.
- Problem: the entire dashboard XML is spliced into a bash heredoc. If the XML
  ever contains a line equal to `DASH`, or a `%{` sequence, the template or the
  heredoc breaks.
- Fix: base64-encode the dashboard in Terraform
  (`base64encode(file("pam_governance.xml"))`) and in the script do
  `echo "$${DASH_B64}" | base64 -d > .../pam_governance.xml`, which removes all
  delimiter and interpolation risk.

---

## E. Minor and polish

- **E1 (P2)** `terraform/install.sh.tpl` publishes `-p 8088:8088` (Splunk HEC),
  which is neither configured nor allowed by the NSG. Remove it or configure HEC.
- **E2 (P2)** `install.sh.tpl` creates `identity/group name="PAM_Administrator"
  type="external"` but never creates the matching group-alias to the OIDC
  accessor, so it does nothing (the OIDC role `bound_claims` already gates
  admin). Remove it or complete it with `identity/group-alias`.
- **E3 (P2)** `terraform/aks.tf` sets `automatic_channel_upgrade = "patch"`,
  which can upgrade nodes without warning. Consider `none` plus a maintenance
  window for a demo.
- **E4 (P2)** `terraform/versions.tf` pins `azurerm ~> 3.0`; 4.x is current.
  Plan an upgrade and re-validate.
- **E5 (P2)** `app/index.html` loads Google Fonts from a CDN. For privacy and
  offline use, self-host the font.
- **E6 (P2)** The Splunk container runs as root and is otherwise unhardened.
  Acceptable for a demo, worth noting.
- **E7 (P2)** No `CHANGELOG.md`. Add one if the project will be versioned.

---

## Suggested implementation order

1. P0 correctness and security first: A3, A7, C1, C2.
2. Then the P1 gaps that affect trust and reproducibility: B2, B6, C3, C4, C5,
   C8, C9, D1, and the honesty fixes B1 and B4 (either implement or correct the
   claim).
3. Then operational P1s: A2, A4, B3, B8, C10.
4. Finally the P2 cleanups: A1, A5, A6, C6, C7, D2, and the E series.

After each group, run `make fmt && make validate && shellcheck scripts/*.sh`,
and for anything that changes the VM bootstrap, plan a
`terraform apply -replace=azurerm_linux_virtual_machine.vm` and re-verify Vault
init, the OIDC roles, Key Vault escrow, and the Splunk dashboard.
