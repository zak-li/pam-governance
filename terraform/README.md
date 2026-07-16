# Terraform

Infrastructure-as-Code for the PAM Governance platform, organized as a root
module that composes one child module per concern.

## Layout

```text
terraform/
├── versions.tf              # Terraform and provider version constraints
├── providers.tf             # Provider configuration (azurerm, auth0)
├── variables.tf             # Input variables
├── main.tf                  # Root: resource group, shared crypto, module wiring
├── outputs.tf               # Outputs (composed from module outputs)
├── backend.tf.example       # Remote encrypted state backend (opt-in)
├── terraform.tfvars.example # Variable template (copy to terraform.tfvars)
└── modules/
    ├── network/             # VNet, subnet, public IP, NSG, NIC
    ├── key-vault/           # Managed identity, Key Vault, escrowed boot secrets
    ├── compute/             # Vault/Splunk VM (+ templates/ cloud-init, dashboard)
    ├── aks/                 # AKS cluster
    ├── registry/            # Azure Container Registry + AcrPull role
    └── auth0/               # OIDC, MFA, RBAC roles, sessions
```

The root module holds only cross-cutting resources: the resource group, the
global name suffix, and the generated crypto (SSH key, Vault TLS certificate,
VM/Splunk password) that is shared between the VM and the Key Vault escrow. Each
module declares its own `variables.tf`, `outputs.tf`, and `versions.tf`, and is
wired together in `main.tf`.

## Module graph

```text
main (root)
 ├── network                      -> subnet_id, nic_id, public_ip_address
 ├── key-vault  (needs network)   -> identity, key_vault_name
 ├── compute    (needs kv, net)   -> vm public IP
 ├── aks                          -> name, kubelet identity
 ├── registry   (needs aks)       -> login server
 └── auth0      (needs network)   -> app/vault client ids
```

## Usage

```bash
export AUTH0_DOMAIN=... AUTH0_CLIENT_ID=... AUTH0_CLIENT_SECRET=...   # M2M app
cp terraform.tfvars.example terraform.tfvars                          # then edit
terraform init
terraform plan
terraform apply
```

Or drive it from the repository root with `make deploy-infra`.

## State

State is local by default and contains plaintext secrets (the Vault TLS key, the
VM password, the SSH key), so it is gitignored and must never be committed. For
shared or production use, provision a remote encrypted backend with
`scripts/bootstrap-backend.sh` and enable `backend.tf` (see `backend.tf.example`).

## Notes

- The module set targets a single environment. For multiple environments, add
  thin per-environment roots (`environments/dev`, `environments/prod`) that call
  the same modules with different variables.
- Provider authentication: `azurerm` uses the Azure CLI login; `auth0` reads the
  `AUTH0_*` environment variables of a Machine-to-Machine app authorized on the
  Auth0 Management API.
