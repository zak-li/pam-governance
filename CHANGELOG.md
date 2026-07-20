# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-07-20

### Added
- `VERSION` file as the single source of truth for the release version.
- Release workflow (`.github/workflows/release.yml`): on a `vX.Y.Z` tag it
  verifies the tag matches `VERSION`, extracts the matching `CHANGELOG` section,
  and publishes a GitHub Release.
- `make version` and `make release` targets to print and tag the current version.

### Security
- Restrict the AKS public API server to the operator IP allow-list
  (`api_server_access_profile.authorized_ip_ranges`).
- Enable AKS control-plane/container logging via the OMS agent into a dedicated
  Log Analytics workspace.
- Set `content_type` and a two-year `expiration_date` on the escrowed Key Vault
  secrets. Clears the failing `tfsec` CI gate (was red on `main`).

## [1.0.0] - 2026-07-20

### Added
- Angular single-page app (`apps/web`) with `@auth0/auth0-angular`, built into
  Azure Container Registry (`az acr build`) and served by a non-root nginx.
- CI job that builds the Angular app on every push.
- Remote encrypted Terraform state option (`scripts/bootstrap-backend.sh` and
  `terraform/backend.tf.example`).
- `scripts/unseal.sh` and `make unseal` to unseal Vault after a restart using
  the keys escrowed in Key Vault.
- Optional Google social login managed in Terraform with the operator's own
  OAuth keys.
- CI security scanning: `tflint`, `tfsec`, and `kubeconform`.
- Runtime app config (`apps/web/src/assets/config.json`) generated from
  Terraform outputs so the app is portable across Auth0 tenants.

### Changed
- Repository restructured into an enterprise layout: `apps/` (application),
  `infra/` (Terraform), `deploy/` (Kubernetes), `docs/`, and `scripts/`.
- Secrets (Auth0 client secret, Vault TLS key, Splunk password) are pulled from
  Key Vault at boot instead of being shipped in the VM `custom_data`.
- Key Vault is network default-deny with purge protection enabled.
- Vault revokes its initial root token after configuration (no standing root).
- Splunk runs a pinned image with persistent data and config volumes.
- Terraform is organized by concern (network, keyvault, compute, and so on).
- The whole project is in English.

### Fixed
- Hardcoded Auth0 connection id replaced with a name lookup, so a fresh apply
  works in any tenant.
- `deploy-app.sh` waits for the Kong public IP and syncs the Auth0 callbacks.
- Removed dead code and unused packages from the bootstrap.

[Unreleased]: https://github.com/zak-li/pam-governance/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/zak-li/pam-governance/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/zak-li/pam-governance/releases/tag/v1.0.0
