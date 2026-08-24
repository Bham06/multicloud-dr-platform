# ADR 0006 — Evaluate SLOs outside both clouds, not just probe from there

**Status:** accepted · **Date:** 2026-08-24

## Context

ADR 0005 moved the availability *probe* out of the clusters, after the first
game day proved an in-cluster prober cannot observe its own cluster dying. It
recorded one gap explicitly and did not close it:

> The evaluator still lives inside `gcp-secondary`. The prober now survives
> either cluster dying; the thing reading it does not.

That is not a small residue. `gcp-secondary` is where failover *lands*. Losing
it loses the SLO — during exactly the event the SLO exists to measure — and the
measurements a drill produces are the drill's only output.

`platform/prometheus/SINGLE-CLUSTER` had already reasoned its way to the edge of
this: it sited the evaluator on the passive side because "the architecture
requires the observability backend to survive a primary-side failure". The
argument is right and stops one step short. Surviving a *primary*-side failure
is not the requirement; surviving *either* side is.

It also prescribed alerting on `up == 0` — which was unimplementable, because
every metric arrived by remote-write and remote-write produces no `up`.

## Decision

**The evaluator runs outside both clusters**, on the interconnect, alongside the
prober. Locally that is a `prom/prometheus` container managed by
`scripts/evaluator.sh`; at burst time it is the Grafana Cloud backend ADR 0002
already plans for. Same siting, same property.

Both collectors now remote-write to it over the interconnect. Neither side gets
an in-cluster shortcut any more, so that path is exercised identically from
both.

Generated rules move from `platform/prometheus/base/rules/` to `slo/rules/`,
next to the `slo/dr.yaml` they come from, because they are no longer a cluster
workload's configuration.

## Rationale

1. **A measurement system must outlive the failure it measures.** The prober and
   the evaluator are one chain; hardening one link and leaving the other inside
   a cluster leaves the chain as strong as its weakest link.

2. **It makes `SINGLE-CLUSTER`'s own advice implementable.** Scraping the prober
   produces a real `up`, which is what the availability SLI keys off. Pushing
   never could.

3. **It is the local stand-in for a decision already taken.** ADR 0002 puts the
   observability backend outside both clouds. This is that, at the fidelity the
   rest of the substrate runs at.

## Consequences

- **The evaluator is no longer GitOps-managed**, because it is no longer in a
  cluster for Argo to manage. Accepted, and the same tradeoff the traffic
  manager already carries. The rules it runs are still committed — `make slo`
  writes `slo/rules/dr.rules.yaml` and the script copies exactly those files —
  so "the rules a reviewer reads in a PR are the rules that actually run" still
  holds. Only delivery changed.
- **A hack goes away.** In-cluster, the rules ConfigMap needed a content hash to
  force a pod roll, because Prometheus reads rule files at startup and does not
  watch them. `evaluator.sh reload` POSTs to `/-/reload`, which is what that
  hash was imitating. `make slo` now reloads automatically.
- **`make slo-status` no longer needs a working cluster.** It read the evaluator
  through a port-forward into `gcp-secondary`; a status command that needs a
  healthy cluster to report that the cluster is unhealthy is no use during the
  failure it exists for.
- **The TSDB starts empty**, so the burn-rate history from before the move is
  gone. Short retention made that history thin anyway, and Grafana Cloud is what
  makes it real.
- **Still not closed: the replication SLO.** `replication-freshness` reads
  `cnpg_dr_subscription_*`, which still arrives by remote-write and therefore
  still has no liveness signal. It carries the same defect the availability SLO
  had, in a milder failure domain — the metrics are produced on the standby, and
  if the standby is gone there is no DR left to measure. Fixing it properly
  means scraping the collectors rather than having them push, which needs a
  scrape endpoint exposed per cluster. That is its own change.
- **Two evaluators must not run at once.** During the migration both were live
  and the substrate — already at ~75% of a 3.83 GiB VM — stalled the prober for
  minutes at a time. The freshness term in the availability SLI is what surfaced
  it, which is the term working as designed.
