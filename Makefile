SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_.-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: verify
verify: schemas chart shell ## Everything CI's static job runs, no cluster needed
	@echo ""
	@echo "  All offline checks passed."
	@echo "  Run 'make cluster' for the real thing."

.PHONY: schemas
schemas: ## Validate the manifests against real API schemas
	@echo ">> kubeconform"
	@kubeconform -strict -summary -ignore-missing-schemas manifests/

.PHONY: chart
chart: ## Lint the chart, render it, and validate the output
	@echo ">> helm lint"
	@helm lint chart/
	@echo ">> helm template | kubeconform"
	@helm template demo chart/ | kubeconform -strict -summary -ignore-missing-schemas -
	@echo ">> the chart rejects an unsatisfiable PodDisruptionBudget"
	@if helm template demo chart/ --set podDisruptionBudget.minAvailable=3 \
		--set autoscaling.minReplicas=3 >/dev/null 2>&1; then \
		echo "   FAIL the chart accepted a PDB that would block every drain"; exit 1; \
	else \
		echo "   PASS rejected, as intended"; \
	fi

.PHONY: shell
shell: ## shellcheck
	@echo ">> shellcheck"
	@shellcheck scripts/*.sh

.PHONY: cluster
cluster: ## Create a kind cluster, deploy, verify, delete
	@./scripts/kind-verify.sh

.PHONY: keep
keep: ## Same, but leave the cluster running
	@KEEP=1 ./scripts/kind-verify.sh
