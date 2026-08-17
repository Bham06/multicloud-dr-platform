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
