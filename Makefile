# PAM Governance - developer and operator entry points.
# Run `make` or `make help` to list the available targets.

SHELL := bash
TF_DIR := terraform
VERSION := $(shell cat VERSION 2>/dev/null || echo 0.0.0)

.DEFAULT_GOAL := help
.PHONY: help deploy deploy-infra deploy-app stop start unseal destroy fmt validate lint version release

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

deploy: deploy-infra deploy-app ## Provision everything (infra then cluster workloads)

deploy-infra: ## Provision the base infrastructure with Terraform
	./scripts/deploy-infra.sh

deploy-app: ## Install Istio, Kong and the app on AKS
	./scripts/deploy-app.sh

stop: ## Stop all compute (zero cost), reversible
	./scripts/stop.sh

start: ## Restart the stopped infrastructure
	./scripts/start.sh

unseal: ## Unseal Vault after a restart (keys from Key Vault)
	./scripts/unseal.sh

destroy: ## Delete all infrastructure (irreversible)
	./scripts/destroy.sh

fmt: ## Format the Terraform code
	terraform -chdir=$(TF_DIR) fmt -recursive

validate: ## Validate the Terraform configuration
	terraform -chdir=$(TF_DIR) init -backend=false -input=false >/dev/null
	terraform -chdir=$(TF_DIR) validate

lint: ## Static-check the shell scripts (requires shellcheck)
	shellcheck scripts/*.sh

version: ## Print the current project version (from VERSION)
	@echo $(VERSION)

release: ## Tag v$(VERSION) and push it to trigger the release workflow
	@git diff --quiet || { echo "Working tree is dirty; commit before releasing."; exit 1; }
	@git tag -a "v$(VERSION)" -m "Release v$(VERSION)"
	@git push origin "v$(VERSION)"
	@echo "Pushed tag v$(VERSION) - the release workflow will publish the GitHub Release."
