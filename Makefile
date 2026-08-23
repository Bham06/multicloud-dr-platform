# `diff` uses process substitution, which /bin/sh does not reliably provide.
SHELL := /bin/bash

RUNTIME ?= k3d
CTX_PRIMARY   := $(RUNTIME)-aws-primary
CTX_SECONDARY := $(RUNTIME)-gcp-secondary

.DEFAULT_GOAL := help

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## //' | awk -F': ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

## up: create both local clusters, install Argo CD, apply root ApplicationSets
up:
	@RUNTIME=$(RUNTIME) ./local/bootstrap.sh

## down: delete both local clusters
down:
ifeq ($(RUNTIME),k3d)
	-k3d cluster delete aws-primary gcp-secondary
else
	-kind delete cluster --name aws-primary
	-kind delete cluster --name gcp-secondary
endif

## status: show Argo apps and workload state on both sides
status:
	@printf '\n\033[1;36m── aws-primary (active) ─────────────────────────\033[0m\n'
	@kubectl --context $(CTX_PRIMARY) -n argocd get applications 2>/dev/null || echo "  cluster not up"
	@kubectl --context $(CTX_PRIMARY) -n demo-api get deploy,pod 2>/dev/null || true
	@printf '\n\033[1;36m── gcp-secondary (pilot light) ──────────────────\033[0m\n'
	@kubectl --context $(CTX_SECONDARY) -n argocd get applications 2>/dev/null || echo "  cluster not up"
	@kubectl --context $(CTX_SECONDARY) -n demo-api get deploy,pod 2>/dev/null || true
	@echo

## slo: regenerate Prometheus rules from slo/dr.yaml
slo:
	@docker run --rm -i ghcr.io/slok/sloth:latest generate -i /dev/stdin \
		< slo/dr.yaml > platform/prometheus/base/rules/dr.rules.yaml
	@echo "regenerated platform/prometheus/base/rules/dr.rules.yaml"

## slo-status: SLO burn rate and error budget from Prometheus
slo-status:
	@./scripts/slo-status.sh

## db-status: replication health across both clusters
db-status:
	@./scripts/replication-status.sh

## db-load: write rows on the primary (make db-load N=500)
db-load:
	@./scripts/db-load.sh $(or $(N),500)

## db-sequences: find sequences that would break writes after promotion
db-sequences:
	@./scripts/check-sequences.sh

## db-creds: give both clusters the same Postgres credential
db-creds:
	@./scripts/sync-db-credentials.sh

## diff: prove the two overlays differ only where they should
diff:
	@diff --color=always -u \
		<(kubectl kustomize apps/demo-api/overlays/aws-primary) \
		<(kubectl kustomize apps/demo-api/overlays/gcp-secondary) || true

## check: run the portability guard (same check CI runs)
check:
	@./scripts/check-portability.sh

## render: render both overlays (fast feedback, no cluster needed)
render:
	@for o in apps/demo-api/overlays/*; do \
		printf '\n\033[1;36m── %s ──\033[0m\n' "$$o"; \
		kubectl kustomize "$$o"; \
	done

## password: print the Argo CD admin password for aws-primary
password:
	@kubectl --context $(CTX_PRIMARY) -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d; echo

## ui: port-forward the Argo CD UI for aws-primary on https://localhost:8080
ui:
	@echo "https://localhost:8080  (user: admin, password: make password)"
	@kubectl --context $(CTX_PRIMARY) -n argocd port-forward svc/argocd-server 8080:443

## mem: show what the local substrate is actually costing you in RAM
mem:
	@docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}'

.PHONY: help up down status check slo slo-status db-status db-load db-sequences db-creds diff render password ui mem
