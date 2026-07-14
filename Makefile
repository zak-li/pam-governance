# PAM Governance - developer and operator entry points.
# Run `make` or `make help` to list the available targets.

SHELL := bash
TF_DIR := terraform

.DEFAULT_GOAL := help
.PHONY: help deploy deploy-infra deploy-frontend stop start destroy fmt validate lint

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

deploy: deploy-infra deploy-frontend ## Provision everything (infra then cluster workloads)

deploy-infra: ## Provision the base infrastructure with Terraform
	./scripts/deploy-infra.sh

deploy-frontend: ## Install Istio, Kong and the frontend on AKS
	./scripts/deploy-frontend.sh

stop: ## Stop all compute (zero cost), reversible
	./scripts/stop.sh

start: ## Restart the stopped infrastructure
	./scripts/start.sh

destroy: ## Delete all infrastructure (irreversible)
	./scripts/destroy.sh

fmt: ## Format the Terraform code
	terraform -chdir=$(TF_DIR) fmt -recursive

validate: ## Validate the Terraform configuration
	terraform -chdir=$(TF_DIR) init -backend=false -input=false >/dev/null
	terraform -chdir=$(TF_DIR) validate

lint: ## Static-check the shell scripts (requires shellcheck)
	shellcheck scripts/*.sh
