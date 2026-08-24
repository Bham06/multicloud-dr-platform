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
| `scripts/check-portability.sh` | The guard. Fails the build when portability breaks. |
| `scripts/replication-status.sh` | Replication health across both clusters. Surfaces sequence divergence. |
| `scripts/check-sequences.sh` | Pre-promotion gate: every sequence that would break writes, and the fix. |
| `scripts/slo-status.sh` | SLO burn rate, error budget, firing alerts. |
| `slo/dr.yaml` | SLO definitions. `make slo` regenerates `slo/rules/` and reloads the evaluator. |
| `scripts/evaluator.sh` | The SLO evaluator, running outside both clusters. |
| `scripts/traffic-manager.sh` | The external traffic manager and outside-in prober. |
| `scripts/promote.sh` | Role + replica swap for a failover, as one edit. |

## Quickstart

**Prerequisites:** `docker` (≥4 GB allocated), `kubectl`, `helm`, `gh` (authenticated),
and either `k3d` (default, lighter) or `kind`.

Argo CD pulls over the network — it cannot read your working copy — so the repo
must be pushed. This one lives at `Bham06/multicloud-dr-platform`, and because
it is **private**, `bootstrap.sh` reads a token from `gh auth token` and installs
it as an Argo repository Secret. The token is applied directly to the cluster and
never committed.

```bash
make check      # portability guard — no cluster needed (this is what CI runs)
make render     # render both overlays
make up         # two clusters, Argo CD in each, apps synced
make status     # aws-primary 2/2 · gcp-secondary 0/0
make diff       # prove the overlays differ only where they should
make db-status  # replication health across both clusters
make db-load    # write rows on the primary (make db-load N=500)
make slo-status # SLO burn rate, error budget, firing alerts
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

## What milestone 3 demonstrates

Postgres runs on both clusters, with row changes replicating from the primary
to the standby over the interconnect — a third Docker network standing in for
the AWS↔GCP VPN, since the two clusters otherwise sit on isolated subnets
exactly as two VPCs would.

Two traps are made concrete rather than described:

**DDL does not replicate.** The schema lives in `platform/postgres/base` and is
applied to both clusters by Git. A migration applied only to the primary breaks
the standby silently.

**Sequences do not replicate.** After writing 501 rows:

```
                        aws-primary  gcp-secondary
  rows in orders                501            501
  max(id)                       501            501
  orders_id_seq                 501              1   <- diverged
```

Every row is present. Promote the standby as-is and the first INSERT tries
`id=2`, colliding with a row replication already delivered. A failover that
looks perfect and corrupts on the first write — which is why the promotion
runbook resets sequences explicitly.

## What milestone 4 demonstrates

OTel collectors on both clusters push to a single evaluator running **outside
both clusters** (ADR 0006), which evaluates Sloth-generated multi-window
burn-rate rules. It started on the passive side; the first game day showed that
losing the cluster hosting it loses the SLO during precisely the failover the
SLO measures.

Verified by breaking replication on purpose:

```
                     rows      slot        subscriber
  before             1302/1302 active      up (1.04s)
  subscription off   1302/1002 INACTIVE    DOWN

  SLO                     TARGET   ERR 5m    BURN
  replication-freshness    99.0%  100.00%  100.00x
  demo-api-availability    99.5%    0.00%    0.00x   <- correctly unaffected

  FIRING  DRReplicationStale  severity=page
          DRReplicationStale  severity=ticket
```

Re-enabling the subscription caught up from retained WAL and the alert
cleared.

The evaluator writes to a persistent volume, so a restart mid-drill does not
destroy the measured evidence the exercise exists to produce.

Three details that matter more than the alert firing:

**`replication-status.sh` reported "In sync — 1002 rows on both sides" while
replication was dead.** Nothing was writing, so the row counts agreed
perfectly. Row equality is not a health check.

**The SLI requires `worker_up` AND lag < 60s, never lag alone.** A stopped
subscriber reports lag 0 — a lag-only SLI reads healthiest at exactly the
moment replication has died.

**The error-budget column reads `n/a` until the data earns it.** The budget
averages over the 30d SLO period; a short-retention evaluator has hours. The
arithmetic is correct and the answer is meaningless, so `make slo-status`
measures its own coverage and refuses to print a number it cannot support. A
gate that is always red is a gate everyone learns to ignore.

## Roadmap

| # | Milestone | Cost | Status |
| --- | --- | --- | --- |
| 1 | Repo skeleton · 2 clusters · Argo syncing both overlays | $0 | **done** |
| 2 | Portability register resolved + enforced by a build guard | $0 | **done** |
| 3 | CloudNativePG logical replication; **replication lag as an SLI** | $0 | **done** |
| 4 | OTel + SLOs (Sloth); evaluator outside both clusters | $0 | **done** |
| 5 | **First failover game day, fully local.** Measure RTO/RPO. | $0 | **done** — RTO 2m 07s, RPO 0 rows |
| 6 | Kyverno, audit→warn→enforce; DORA control mapping + evidence | $0 | next |
| 7 | Terraform for real AWS+GCP — **budget kill-switch first** | $0 | |
| 8 | Burst #1: real EKS + GKE + HA VPN + real failover, then destroy | ~$30 | |
| 9 | FinOps: FOCUS-normalize the real burst bills + OpenCost | ~$0 | |

Data replication comes before observability, reversing the original order. Two
reasons: the measured local budget (ADR 0002) does not fit a self-hosted LGTM
stack, and replication lag is a more useful first SLI than a synthetic one — it
means the metric exists before the framework meant to measure it.

Milestone 5 was the one that mattered: a working, measured DR drill before a
single dollar is spent on real cloud. It ran on 2026-08-24 — 2m 07s RTO against
a 1-hour target, zero rows lost. The failover itself behaved; all three defects
it found were in the tooling around it, and the worst of them is that the
availability SLO reported perfect health throughout a total outage. The drill
log in `docs/runbooks/failover.md` has the numbers and the evidence.

## Ground rules

- **Manual failover decision, automated failover steps.** Automatic cross-cloud
  failover invites split brain on the data tier.
- **The failover trigger lives outside both clouds.** Not Route 53 — the DR
  mechanism must not share a failure domain with the thing that is failing.
- **Nothing in `apps/*/base/` may name a cloud** — including registry
  hostnames. Enforced by `make check` and CI, not by good intentions:
  portability decays silently, and you find out during a game day.
- **Every app must have an overlay for every cluster.** An app on the primary
  with no standby overlay is a workload that quietly will not come back.
- **Replication lag is an SLI**, held to the same standard as availability.
- **The standby's cost is a named, budgeted line item.** Otherwise it gets cut
  in a cost review and you find out during an incident.
