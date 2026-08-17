# ADR 0001 — Terraform owns cloud resources, Argo CD owns cluster contents

**Status:** accepted · **Date:** 2026-08-17

## Context

Something has to provision cloud infrastructure (VPCs, EKS/GKE, RDS/Cloud SQL,
VPN) and something has to manage what runs inside the clusters. These can be
one tool or two. Crossplane was considered for the unified-API version.

## Decision

Two tools, split cleanly at the cluster boundary:

- **Terraform** — everything outside the cluster.
- **Argo CD** — everything inside it, pulled from Git.

Crossplane is rejected.

## Why not Crossplane

1. **Its value proposition does not apply here.** Crossplane earns its keep as a
   self-service provisioning API for many teams. This project has one operator.
   The abstraction cost is paid; the benefit is not collected.

2. **It fights the burst model, in a way that costs money.** Crossplane needs a
   permanently running management cluster continuously reconciling live cloud
   resources. This project's cost strategy (ADR 0002) depends on tearing real
   infrastructure down reliably. Under Crossplane the teardown path runs
   *through* the management cluster — so if that local cluster dies mid-burst,
   real infrastructure is orphaned and keeps billing. Designing in a failure
   mode whose blast radius is the credit card is a bad trade for a project
   whose binding constraint is spend.

Terraform's `destroy` producing a reliable, inspectable teardown plan is
precisely the property this project needs most.

## Consequences

- Two state models to understand (TF state, Argo's live-vs-desired). Acceptable.
- No unified cross-cloud provisioning API. Not needed at one operator.
- The cluster boundary becomes the tooling boundary — an easy rule to hold onto,
  and a good forcing function for keeping cloud specifics out of manifests.
