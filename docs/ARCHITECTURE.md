# Architecture

## Components

Identity is provided by an Auth0 tenant, which handles OpenID Connect and OAuth2,
enforces multi-factor authentication, holds the RBAC roles, and runs a post-login
Action that attaches role claims to the token. The user-facing surface is a
single-page app deployed on AKS in the `pam-governance` namespace, which
handles the SSO login and then shows a success dashboard. Traffic enters through
the Kong gateway in the `kong` namespace, a public load balancer that terminates
requests, redirects to HTTPS, and applies rate limiting. Istio runs in
`istio-system` and gives every pod a sidecar so that east-west traffic is
encrypted with mutual TLS.

The privileged tooling runs on a separate Azure virtual machine. HashiCorp Vault
provides the secrets engines, the OIDC authentication backend, the
least-privilege policies, the dynamic secrets, and the audit device. Splunk runs
in a Docker container on the same machine and ingests the Vault audit log along
with the host logs, presenting them on a forensic dashboard. Azure Key Vault
holds the escrowed Vault unseal keys and root token, and a managed identity lets
the virtual machine write to Key Vault without any stored credential.

## Request flow for the app

A user opens the Kong public IP over HTTP and Kong redirects them to HTTPS. The
single-page app starts the OIDC PKCE flow, which sends the user to Auth0 for
login and multi-factor authentication. Auth0 redirects back with an
authorization code, and the SDK exchanges it inside a web worker for tokens that
are kept in memory. The app then routes to the `/dashboard` success page. No
direct path to the back-office tooling is exposed to the end user.

## Request flow for privileged access

An operator opens the Vault UI and selects the OIDC method with the operator
role. Vault redirects to Auth0 for login and multi-factor authentication, then
receives the callback and issues a token bound to the read-only operator policy.
Administrator access requires the `PAM_Administrator` group claim, which the
admin role binds on. Every request is written to the audit device, which Splunk
tails in near real time.

## Bootstrap sequence

The virtual machine bootstrap runs from cloud-init in `install.sh.tpl`. It
installs Vault from the official binary, creates the `vault` user, and writes the
TLS configuration. It then initializes Vault with five key shares and a
threshold of three, unseals it, and enables the audit device. Next it enables the
dynamic secret engines, the SSH certificate authority, the database engine, the
transit engine, and the versioned key-value store. It writes the least-privilege
policies, configures the Auth0 OIDC backend, and creates the two roles. It
escrows the unseal keys and the root token to Azure Key Vault through the managed
identity and shreds the local copy. Finally it installs Splunk in Docker and
creates the `pam_audit` index, the log monitors, and the forensic dashboard.

## Mutual TLS between Kong and the app

Kong is part of the mesh through its Istio sidecar and routes to the app
Service cluster IP, which is enabled by the `service-upstream` annotation, so
Istio automatic mutual TLS applies to that hop. The namespace peer
authentication is set to permissive rather than strict, because the Kong
OpenResty upstream does not always originate mutual TLS and strict mode breaks
the Kong to app hop with a 503. For strict end-to-end mutual TLS, traffic
would be terminated at an Istio ingress gateway instead of Kong.

## Deployment order

The base infrastructure is provisioned first with `scripts/deploy-infra.sh`,
which runs Terraform to create the virtual machine, the AKS cluster, the Key
Vault, and the Auth0 configuration. The cluster workloads are deployed next with
`scripts/deploy-app.sh`, which installs Istio through Helm, then Kong, then
the app.

## Operational notes

Vault re-seals whenever the virtual machine reboots, because it uses file storage
with no auto-unseal, so it must be unlocked with three unseal keys from Key
Vault. The public IP is static, so it survives a VM recreation and the app
links and Auth0 callbacks stay valid. Recreating the virtual machine
re-initializes Vault with new keys escrowed to Key Vault, which is done with
`terraform apply -replace=azurerm_linux_virtual_machine.vm`.
