# ADR 0003 — No hub cluster; Argo CD runs inside each managed cluster

**Status:** accepted · **Date:** 2026-08-17

## Context

The common GitOps topology is a hub cluster running a central Argo CD that
pushes to registered spoke clusters. An earlier sketch of this project had
three clusters: `hub`, `aws-primary`, `gcp-secondary`.

## Decision

Two clusters. No hub. Each cluster runs its own Argo CD and deploys only to
itself (`destination: https://kubernetes.default.svc`).

## Rationale

1. **A hub is a shared failure domain, and it would live on AWS.** The primary
   is the thing expected to fail. Reconciliation on the standby must not depend
   on anything hosted in the failing cloud — otherwise the DR mechanism dies
   with the disaster it exists to survive.

2. **The hub's remaining job disappeared.** Once Crossplane was rejected
   (ADR 0001), the hub had no management-plane workload left to justify it.
   Observability is deliberately sited on the passive side, not a hub, so it is
   already running where failover lands.

3. **It fits the RAM budget**, which on this machine is a real constraint.

## Consequences

- Argo CD is installed twice, and its configuration is duplicated. Acceptable,
  and arguably desirable: the standby's deployment path is identical to the
  primary's rather than a special case. A standby maintained differently from
  the primary is a standby that fails on the day it is needed.
- There is no single pane of glass across both clusters. Grafana takes that
  role in milestone 3, as a *read* path — not a control path.
- Cluster-scoped bootstrapping is per-cluster. `local/bootstrap.sh` handles it.
