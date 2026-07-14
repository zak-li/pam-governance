<br>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2E77F3.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/IaC-Terraform-7B42BC?logo=terraform&logoColor=white" alt="Terraform">
  <img src="https://img.shields.io/badge/cloud-Azure-0078D4?logo=microsoftazure&logoColor=white" alt="Azure">
  <img src="https://img.shields.io/badge/mesh-Istio-466BB0?logo=istio&logoColor=white" alt="Istio">
  <img src="https://img.shields.io/badge/secrets-Vault-FFEC6E?logo=vault&logoColor=black" alt="Vault"><br>
  <img src="https://img.shields.io/badge/model-Zero--Trust-0CBDFC.svg" alt="Zero-Trust">
  <img src="https://img.shields.io/badge/gateway-Kong-003459?logo=kong&logoColor=white" alt="Kong">
  <img src="https://img.shields.io/badge/identity-Auth0-EB5424?logo=auth0&logoColor=white" alt="Auth0">
  <img src="https://img.shields.io/badge/SIEM-Splunk-000000?logo=splunk&logoColor=white" alt="Splunk">
</p>

<br>

## PAM Governance

> **PAM Governance** (codename `Sentinel`): a cloud-native Privileged Access Management and identity governance platform. It centralizes secrets, enforces least-privilege access, and secures authentication across enterprise infrastructure under a Zero-Trust model.

PAM Governance eliminates credential sprawl through dynamic secret generation, role-based access control, and OpenID Connect single sign-on. It runs a Zero-Trust security model with end-to-end TLS, service-to-service mutual TLS through `Istio`, hardened network boundaries, and forensic audit logging that flows into a SIEM for continuous monitoring. The base infrastructure is provisioned as Infrastructure-as-Code with Terraform, and the cluster workloads, meaning the mesh, the gateway, and the app, are deployed by an idempotent installer, so an environment can be built, stopped, restarted, or destroyed with a single command each.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Operations](#operations)
- [Security](#security)
- [Repository Layout](#repository-layout)
- [License](#license)

## Overview

Privileged credential management is delegated to `HashiCorp Vault`, which issues short-lived secrets on demand rather than distributing static keys. Vault runs a signing certificate authority for privileged SSH access, a database engine for dynamic database credentials, a transit engine for encryption as a service, and a versioned key-value store, so no long-lived credential ever needs to sit in a config file. Access to Vault is granted only after an operator authenticates through `Auth0` with multi-factor authentication, and every request is written to a forensic audit trail.

Workloads are orchestrated on `Azure Kubernetes Service` and wrapped in the `Istio` service mesh, which gives every pod a sidecar and encrypts east-west traffic with mutual TLS. The public entry point is the `Kong` API gateway, exposed through an Azure load balancer, which terminates traffic, redirects everything to HTTPS, and applies rate limiting at the edge. A single-page app sits behind Kong and lets a user sign in through `Auth0` before landing on a success dashboard, with no direct path to the back-office tooling.

Continuous security monitoring is handled by `Splunk`, which ingests the Vault audit device together with host authentication and system logs into a dedicated index and renders them on a forensic dashboard. Vault unseal keys and the root token are never left on disk; they are escrowed into `Azure Key Vault` through a managed identity, which keeps break-glass material off the machine while still recoverable by an authorized operator.

## Architecture

A user reaches the app over HTTPS. Kong terminates the request at the edge, and the Istio mesh carries it to the app pod over mutual TLS. Authentication is federated to Auth0, which enforces MFA and returns an OIDC identity. The privileged tooling, Vault and Splunk, runs on a separate hardened virtual machine that is only reachable from an allow-listed administrator address.

```
                       Auth0  (OIDC / OAuth2, MFA, RBAC roles)
                         |  SSO
     User  --HTTPS-->  Kong Gateway (public load balancer, rate limit)
                         |
                         v   Istio service mesh (sidecars, auto mTLS)
                       App SPA (non-root nginx, strict CSP)

     Azure VM (admin-only, default-deny NSG)
       HashiCorp Vault (TLS 8200)          Splunk SIEM (8000)
         least-privilege policies            index pam_audit + dashboard
         dynamic secrets (SSH CA, DB...)     forensic audit ingestion
         unseal/root token  ->  Azure Key Vault (off-disk escrow)
```

The full component breakdown, request flows, and bootstrap sequence live in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Quick Start

The deployment expects the following tools and credentials on the machine running it.

| Requirement | Notes |
|---|---|
| `Azure CLI` | Signed in with `az login` to the target subscription |
| `Terraform` | Version 1.5 or later |
| `Auth0` M2M app | A Machine-to-Machine application authorized on the Auth0 Management API |
| `Auth0` Vault app | A regular web application used by Vault for OIDC |

Export the Auth0 Management API credentials so the Terraform provider can manage the tenant, then set the project variables.

```bash
az login

export AUTH0_DOMAIN="dev-xxxx.eu.auth0.com"
export AUTH0_CLIENT_ID="<m2m client id>"
export AUTH0_CLIENT_SECRET="<m2m secret>"

cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edit terraform/terraform.tfvars: Vault OIDC app credentials and your admin IP
```

Provision the base infrastructure, then deploy the mesh, the gateway, and the app onto the cluster.

```bash
make deploy-infra      # VM (Vault + Splunk), AKS, Key Vault, Auth0
make deploy-app   # Istio, then Kong, then the hardened app
```

Both steps are idempotent, so they can be re-run safely if something needs to be reconciled.

## Operations

The AKS node and the virtual machine incur cost while they run, so the project ships with a full lifecycle. Stopping suspends all compute without losing any data, and starting brings the same environment back. Destroying removes everything the code created.

```bash
make stop       # deallocate AKS and the VM, compute cost drops to zero
make start      # bring the same environment back up
make destroy    # delete all infrastructure, irreversible
```

After a restart, Vault comes back sealed because it uses file storage with no auto-unseal. Run `make unseal`, which reads the escrowed keys from Azure Key Vault and unseals Vault on the VM for you.

## Security

Authorization in Vault is scoped rather than global. The administrator policy grants access to the specific secret engines it needs and never receives a blanket `path "*"` grant or `sudo`, and the default OIDC role is the read-only operator. Escalation to administrator requires a group claim that Auth0 attaches only to members of the `PAM_Administrator` role, so a successful login is not by itself a grant of privilege.

The network is closed by default. The security group denies all inbound traffic except from an allow-listed administrator address, the virtual machine accepts key-based SSH only, and Kubernetes network policy restricts ingress to the gateway and the mesh control plane. Inside the cluster, Istio encrypts pod-to-pod traffic with mutual TLS, and the app container runs as a non-root user on a read-only root filesystem with all Linux capabilities dropped.

The app is hardened for a hostile browser. It forces HTTPS, sets HSTS, ships a strict Content Security Policy with subresource integrity on its one external script, keeps tokens in memory instead of local storage, and refuses to restore an authenticated view through the browser back button. Auth0 enforces MFA on every login and expires sessions after eight hours, or after thirty minutes of inactivity.

## Repository Layout

```
terraform/            Infrastructure-as-Code for Azure and Auth0
  main.tf             resource group and generated crypto material
  network.tf          VNet, subnet, public IP, NSG, NIC
  keyvault.tf         managed identity, Key Vault, escrowed secrets
  compute.tf          the Vault/Splunk virtual machine
  aks.tf              AKS cluster
  auth0.tf            OIDC, MFA, RBAC, session policy, connections
  outputs.tf          outputs
  install.sh.tpl      cloud-init: Vault, Splunk, audit pipeline
  pam_governance.xml  pre-installed Splunk forensic dashboard
  backend.tf.example  optional remote encrypted state backend
app/                  single-page app, SSO login to a success dashboard
k8s/                  namespace, mTLS policy, hardened deployment, Kong ingress
scripts/              deploy, stop, start, unseal, destroy, backend bootstrap
docs/                 architecture documentation
AUDIT.md              audit findings and remediation plan
```

## License

This project is licensed under the [MIT License](LICENSE).
