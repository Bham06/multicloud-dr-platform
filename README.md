# multicloud-dr-platform

An active-passive multi-cloud disaster recovery system — **AWS primary, GCP
secondary** — with observability/SLOs, policy-as-code, a FinOps pipeline, and a
platform layer managing access and config across both clusters.

Solo learning project. Not production. Built local-first so it costs roughly
**$120–180 in total** rather than $250–400 per month (see
[ADR 0002](docs/decisions/0002-local-first-cloud-in-bursts.md)).

**Targets:** RTO < 1 hour · RPO < minutes · Postgres + object storage ·
DORA-style control framework.

---

## The shape

Five pillars, but they are not five projects. Four ride on the same two
foundations, and **DR is an emergent property of the other four** rather than a
separate system:

```
                 ┌──────────────────────────────┐
                 │  Git (desired state) + IdP   │   the substrate
                 └───────────────┬──────────────┘
                                 │
  ┌────────────┬────────────┬────┴───────┬────────────┬────────────┐
  │            │            │            │            │            │
Platform  Observability   Policy       FinOps        DR
(Argo CD)   (OTel/SLO)   (Kyverno)    (FOCUS)   (falls out)
  │            │            │            │            │
  └────────────┴─── same tags, same repo, same clusters ──────────┘
```

Everything depends on two things: a **resource labeling standard** (FinOps
allocation, policy scoping and SLO ownership all key off it) and **portable
workload definitions**. Get those wrong and all five pillars get rebuilt.

## Two substrates, one repo

```
  DEFAULT MODE ($0)                      BURST MODE (~$15-30/weekend)
  ┌───────────────────────┐              ┌───────────────────────┐
  │ k3d: aws-primary      │              │ real EKS  + RDS       │
  │ k3d: gcp-secondary    │ ── same ────▶│ real GKE  + Cloud SQL │
  │ CNPG logical rep      │   manifests  │ HA VPN between them   │
  │ MinIO ↔ MinIO         │              │ S3 → GCS via STS      │
  └───────────────────────┘              └───────────────────────┘
       ~90% of the time                       4-6 weekends total
```

The same Argo repo drives both. **That equivalence is the portability test** —
and it is a stronger check than most production teams actually have.

## Layout

| Path | What |
| --- | --- |
| `apps/` | Workloads. `base/` is cloud-agnostic; `overlays/<cluster>/` carries the cloud-specific delta. |
| `clusters/<name>/apps.yaml` | Root ApplicationSet for that cluster. Scans Git for matching overlays. |
| `platform/` | In-cluster platform components (observability, policy, data). |
| `local/` | k3d/kind cluster definitions + `bootstrap.sh`. |
| `infra/` | Terraform for the real AWS + GCP burst environment. |
| `docs/decisions/` | ADRs — the *why*. |
| `docs/portability-register.md` | **The highest-value artifact here.** Every AWS dependency and its failover verdict. |
| `docs/runbooks/failover.md` | The drill. Manual decision, automated steps. |

## Quickstart

**Prerequisites:** `docker` (≥4 GB allocated), `kubectl`, `helm`, `gh` (authenticated),
and either `k3d` (default, lighter) or `kind`.

Argo CD pulls over the network — it cannot read your working copy — so the repo
must be pushed. This one lives at `Bham06/multicloud-dr-platform`, and because
it is **private**, `bootstrap.sh` reads a token from `gh auth token` and installs
it as an Argo repository Secret. The token is applied directly to the cluster and
never committed.

```bash
make render     # render both overlays — no cluster needed
make up         # two clusters, Argo CD in each, apps synced
make status     # aws-primary 2/2 · gcp-secondary 0/0
make diff       # prove the overlays differ only where they should
make down
```

`RUNTIME=kind make up` to use kind instead of k3d.

## What milestone 1 demonstrates

`make status` should show `demo-api` running **2/2 on aws-primary** and **0/0 on
gcp-secondary**. That is the pilot light: on the standby the Deployment exists,
is reconciled, and has its image pulled — it just runs zero copies.

Failover is one integer in Git:

```diff
  replicas:
    - name: demo-api
-     count: 0
+     count: 2
```

The active-passive posture, expressed as a single reviewable line.

## Roadmap

| # | Milestone | Cost |
| --- | --- | --- |
| **1** | **Repo skeleton · 2 clusters · Argo syncing both overlays** | **$0** |
| 2 | Portability register completed; overlays prove the split | $0 |
| 3 | OTel + LGTM + first SLOs (Sloth) | $0 |
| 4 | CloudNativePG logical replication; **replication lag as an SLI** | $0 |
| 5 | **First failover game day, fully local.** Measure RTO/RPO. | $0 |
| 6 | Kyverno, audit→warn→enforce; DORA control mapping + evidence | $0 |
| 7 | Terraform for real AWS+GCP — **budget kill-switch first** | $0 |
| 8 | Burst #1: real EKS + GKE + HA VPN + real failover, then destroy | ~$30 |
| 9 | FinOps: FOCUS-normalize the real burst bills + OpenCost | ~$0 |

Milestone 5 is the one that matters: a working, measured DR drill before a
single dollar is spent on real cloud.

## Ground rules

- **Manual failover decision, automated failover steps.** Automatic cross-cloud
  failover invites split brain on the data tier.
- **The failover trigger lives outside both clouds.** Not Route 53 — the DR
  mechanism must not share a failure domain with the thing that is failing.
- **Nothing in `apps/*/base/` may name a cloud.** If it does, portability is
  broken and the DR story goes with it.
- **Replication lag is an SLI**, held to the same standard as availability.
- **The standby's cost is a named, budgeted line item.** Otherwise it gets cut
  in a cost review and you find out during an incident.
