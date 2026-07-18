# Terraform

Infrastructure as Code for the `PAM Governance` platform, organized as a root module that composes one child module per concern.

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

The root module holds only cross-cutting resources, such as the resource group, the global name suffix, and the generated crypto. This includes the `SSH` key, `Vault` `TLS` certificate, and the VM/Splunk password that is shared between the VM and the Key Vault escrow. 

Each module declares its own `variables.tf`, `outputs.tf`, and `versions.tf`. These modules are wired together in `main.tf`.

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

Configure your variables and deploy using the following sequence of commands. First export the required environment variables, then create the variables file. Finally, initialize, plan, and apply the `Terraform` configuration.

```bash
export AUTH0_DOMAIN="dev-xxxx.eu.auth0.com"
export AUTH0_CLIENT_ID="<m2m_client_id>"
export AUTH0_CLIENT_SECRET="<m2m_secret>"

cp terraform.tfvars.example terraform.tfvars

terraform init
terraform plan
terraform apply
```

Alternatively, you can drive it from the repository root using the Makefile deployment command.

```bash
make deploy-infra
```

## State

State is local by default and contains plaintext secrets such as the `Vault` `TLS` key, the VM password, and the `SSH` key. It is gitignored and must never be committed to the repository. 

For shared or production use, provision a remote encrypted backend with the bootstrap script and enable the backend configuration file.

```bash
scripts/bootstrap-backend.sh
```

## Notes

The module set targets a single environment. For multiple environments, add thin per-environment roots such as `environments/dev` or `environments/prod` that call the same modules with different variables.

Provider authentication for `azurerm` uses the `Azure CLI` login. The `auth0` provider reads the `AUTH0` environment variables of a Machine-to-Machine app authorized on the `Auth0` Management API.
