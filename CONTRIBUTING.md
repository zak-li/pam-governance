# Contributing

Thanks for taking the time to contribute. This document explains how to work on
the project locally and what is expected before a change is merged.

## Prerequisites

You will need the Azure CLI, Terraform 1.5 or later, and a Bash shell. Static
checks also use `shellcheck` for the scripts. To deploy against real
infrastructure you additionally need an Auth0 tenant and its Management API
credentials, as described in the README.

## Local workflow

Format and validate the Terraform code before opening a pull request.

```bash
make fmt
make validate
make lint
```

The `terraform validate` step runs without a backend and without contacting any
provider, so it does not need cloud credentials. Deployment targets such as
`make deploy-infra` and `make deploy-frontend` do require credentials and will
create billable resources, so run them only against an account you own.

## Conventions

The project is written in English throughout, including code comments and
documentation. Terraform is organized by concern, with one file per domain such
as `network.tf`, `keyvault.tf`, and `compute.tf`, and all outputs collected in
`outputs.tf`. Shell scripts use `set -euo pipefail` and keep their output plain
and readable.

## Secrets

Never commit secrets. The `.gitignore` already excludes the Terraform state,
`terraform.tfvars`, private keys, and certificates. If you believe a secret was
committed, rotate it immediately and open an issue.

## Pull requests

Keep pull requests focused on a single change, describe what and why in the
description, and make sure CI passes. Security-sensitive changes should explain
their impact on the threat model documented in `docs/SECURITY.md`.
