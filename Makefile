###############################################################################
# Makefile — aws-observability-stack
###############################################################################
SHELL          := /usr/bin/env bash
.SHELLFLAGS    := -eu -o pipefail -c
.DEFAULT_GOAL  := help

TF_DIR        ?= terraform
ENV           ?= dev

# --------------------------------------------------------------------------- #
# Help                                                                         #
# --------------------------------------------------------------------------- #
.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n\nTargets:\n"} \
	     /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# --------------------------------------------------------------------------- #
# Terraform lifecycle                                                          #
# --------------------------------------------------------------------------- #
.PHONY: init
init: ## terraform init
	terraform -chdir=$(TF_DIR) init

.PHONY: fmt
fmt: ## terraform fmt -recursive
	terraform fmt -recursive $(TF_DIR)

.PHONY: validate
validate: ## terraform validate
	terraform -chdir=$(TF_DIR) validate

.PHONY: plan
plan: ## terraform plan
	terraform -chdir=$(TF_DIR) plan -var environment=$(ENV)

.PHONY: apply
apply: ## terraform apply (with prompt)
	terraform -chdir=$(TF_DIR) apply -var environment=$(ENV)

.PHONY: destroy
destroy: ## terraform destroy
	terraform -chdir=$(TF_DIR) destroy -var environment=$(ENV)

# --------------------------------------------------------------------------- #
# CI helpers                                                                   #
# --------------------------------------------------------------------------- #
.PHONY: lint
lint: ## Run all linters (terraform fmt-check, tflint, checkov, ruff, black --check)
	terraform fmt -check -recursive $(TF_DIR)
	tflint --recursive --format compact --chdir $(TF_DIR)
	checkov --directory $(TF_DIR) --framework terraform --quiet --compact
	ruff check lambda/ scripts/
	black --check lambda/ scripts/

.PHONY: promtool
promtool: ## promtool check rules over alerts/*.yaml
	@for r in alerts/*.yaml; do echo "--- $$r"; promtool check rules $$r; done

.PHONY: dashboards-check
dashboards-check: ## Validate dashboard JSON schema + uid uniqueness
	python3 scripts/validate-dashboards.py

.PHONY: dashboards-import
dashboards-import: ## Import dashboards via terraform grafana provider
	terraform -chdir=$(TF_DIR) apply -target=grafana_dashboard -var environment=$(ENV)

.PHONY: ci
ci: fmt validate lint promtool dashboards-check ## Run the full CI suite locally
	@echo "all CI checks passed"
