# ADR 0002 — Local by default, real cloud in timeboxed bursts

**Status:** accepted · **Date:** 2026-08-17

## Context

This is a solo learning project on a personal budget. An always-on version of
this architecture costs **$250–400/month doing nothing**, and — importantly —
the cost driver is not the one that dominates in production.

At production scale, cross-cloud **egress** dominates the DR bill. At this
scale egress is effectively free (AWS gives 100 GB/month, which this project
will never approach). What actually costs money here is **hourly rent on idle
infrastructure**:

| Item | Hourly | Left running 1 month |
| --- | --- | --- |
| EKS control plane | $0.10 | **$73** |
| NAT Gateway (×2) | $0.045 ea | **$65** |
| VPN tunnels | ~$0.05–0.10 | **$36–72** |
| ALB / NLB | ~$0.0225 | $16 |
| RDS db.t4g.micro | ~$0.016 | $12 |

Cost intuition does not transfer across scale. That is itself a FinOps lesson
worth having learned early.

## Decision

Local `k3d`/`kind` clusters are the **default substrate**. Real AWS + GCP is
provisioned in **timeboxed bursts** (`make burst-up` → learn → `make burst-down`),
budgeted at roughly **$15–30 per weekend, 4–6 bursts total ($120–180)**.

## The part that makes this better, not merely cheaper

The local and real environments run **the same Argo repo**. If a manifest syncs
cleanly to k3d *and* to real EKS *and* to real GKE, the portability property the
entire DR strategy rests on has been demonstrated rather than assumed.

The local/real duality **is** the portability test. Most production teams do not
have an equivalent check.

## Consequences

- A budget kill-switch (AWS Budgets → SNS → Lambda teardown, plus the GCP
  equivalent) is built **before** the first burst. Non-negotiable — it is what
  stands between a forgotten NAT Gateway and a surprise bill.
- `make burst-down` must be trustworthy. Verifying a clean teardown is a first-
  class deliverable, not an afterthought.
- Things that genuinely cannot be simulated (VPN, IAM, real billing data, real
  managed-service behaviour) are explicitly deferred to burst weekends rather
  than faked locally.
- k3s conveniences (traefik, servicelb, metrics-server) are disabled locally so
  the substrate does not drift from what EKS/GKE actually provide.

## Measured, not estimated (2026-08-18)

The local substrate now exists, so the estimates in this ADR have been replaced
with real numbers from `make status` / `docker stats`:

| | Estimated | **Measured** |
| --- | --- | --- |
| Per cluster (k3d node + trimmed Argo CD) | ~850 MB | **~1.13 GB** |
| Both clusters | ~1.7 GB | **~2.27 GB** |
| Docker VM allocation | — | 3.83 GB |
| Headroom | — | **~1.55 GB** |

The per-cluster estimate was low by roughly 30%. That matters for sequencing:

| Milestone | Adds | Running total |
| --- | --- | --- |
| M1 clusters + Argo | — | 2.27 GB ✅ |
| M3 CNPG + 2× Postgres | ~0.5 GB | ~2.8 GB ✅ |
| M4 self-hosted LGTM stack | ~1.2–1.4 GB | **~4.0 GB ❌** |

**A self-hosted observability stack does not fit.** Two consequences:

1. Data replication moves ahead of observability in the roadmap — it fits, and
   it produces replication lag as a real first SLI.
2. Observability uses **Grafana Cloud's free tier** as the backend, with only
   the OTel Collector in-cluster (~200 MB instead of ~1.4 GB). This is not a
   concession: this ADR and the architecture both call for the observability
   backend to live *outside both clouds*, so that a primary-side failure does
   not take the dashboards with it. Self-hosting locally was always the
   compromise; the RAM ceiling pushes toward the better design.

Raising the Docker allocation is **not** the answer. Docker Desktop on Apple
Silicon balloons — the VM held 0.58 GB RSS against a 3.83 GB allocation — so the
cap is not what constrains it. The 8 GB host is, and it is already compressing
3.2 GB and swapping 5.26 GB. Raising the cap converts a clean in-VM OOM kill
into system-wide paging, which is strictly harder to diagnose.
