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
