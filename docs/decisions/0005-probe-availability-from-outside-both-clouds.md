# ADR 0005 — Probe availability from outside both clouds

**Status:** accepted · **Date:** 2026-08-24

## Context

The first failover game day (2026-08-24) killed the primary cluster outright.
The public endpoint was hard down for 127 seconds across 79 consecutively failed
requests. The availability SLO reported a **0.00% error ratio for the entire
window** and `DemoAPIUnavailable` never fired. Verified afterwards with
`query_range` across the outage: 0.000 at every step.

The SLO was not misconfigured. It was measuring something that could not
observe the event:

1. **The prober lived inside the thing it probed.** The `httpcheck` receiver
   measuring the active side ran in that same cluster. When the cluster died,
   the prober died with it, so the metric stopped being *produced* rather than
   going to zero.
2. **Its metrics arrived by remote-write, which carries no liveness signal.** A
   collector that stops pushing is indistinguishable from one with nothing new
   to say. There is no `up` for a push source. `SINGLE-CLUSTER` already
   prescribed alerting on `up == 0`; nothing was producing an `up`.
3. **Prometheus staleness then served the last known value — `1`, healthy — for
   five minutes** after the cluster had ceased to exist.
4. **`or on() vector(0)` sat outside `avg_over_time`,** so the fallback only
   fired when the *entire* window was empty. `avg_over_time` skips missing
   points rather than counting them, so partial absence raised the average of
   whatever remained.

Any one of these alone would have been enough to hide the outage.

## Decision

**Availability is probed from outside both clouds, and the probe is scraped
rather than pushed.**

The prober runs in the external traffic manager — attached to neither cluster,
on the interconnect — and probes the public endpoint: the same path a user
takes. Prometheus scrapes it over the interconnect at a static address supplied
by the overlay.

The SLI multiplies three terms, each defaulting to zero **inside** the subquery:

| term | answers |
| --- | --- |
| `dr_probe_success{target="public"}` | did the endpoint answer? |
| `up{job="dr-edge"}` | is the prober reachable and being scraped? |
| `time() - dr_probe_timestamp_seconds < 60` | is the probe loop still sweeping? |

## Rationale

1. **A probe that shares a failure domain with its target is not a probe.** This
   is the same principle the README already applies to the failover trigger —
   "the DR mechanism must not share a failure domain with the thing that is
   failing" — applied one layer down. February's superseded attempt made this
   mistake with a Cloud Function inside the primary; the observability layer had
   quietly repeated it.

2. **Scraping produces a liveness signal; pushing does not.** A scrape target
   that stops answering gets `up == 0` written immediately, with no staleness
   window. This is the only term that closes the five-minute blind spot, and it
   is unavailable to any push-based source.

3. **Every failure mode of the measurement chain must resolve to "not
   available".** The old query failed towards *healthy*, which is why it lied.
   Defaulting each term to zero inside the subquery means missing data is
   counted as an outage rather than skipped.

4. **Probing the public endpoint removes the role question entirely.** The old
   query filtered on `dr_role="primary"` and kept measuring the demoted cluster
   after a failover, because nothing flipped the label. Whoever is serving is
   what gets measured, because that is what a user reaches.

## Consequences

- **A cold Prometheus reports unavailable for five minutes.** The window
  predates the data, and absence is counted as an outage by design. This is the
  conservative direction and it is not a bug; it was observed converging
  0.8 → 0.2 → 0.1 → 0 over the five minutes after a restart.
- **The evaluator still lives inside `gcp-secondary`.** The prober now survives
  either cluster dying; the thing reading it does not. Losing the cluster that
  hosts Prometheus still loses the SLO. Moving the backend outside both clouds
  is the Grafana Cloud plan already recorded in ADR 0002, and this ADR does not
  close that gap.
- **One more static address in an overlay.** The job name lives in the base and
  the address in the overlay, matching how the collector's remote-write endpoint
  is already split.
- **The in-cluster `httpcheck` metrics still exist** and are still labelled by
  role. They are no longer the availability SLI — they are a per-side signal,
  and `make check` now enforces that the role label matches which side is
  actually running the workload.

## Evidence

Demonstrated, not assumed — the previous SLI had only ever reported healthy:

| state | SLI term |
| --- | --- |
| healthy | 1 |
| endpoint pointed at a site with zero pods | 0 |
| prober itself stopped | 0 |
| restored | 1 |

Over a sustained outage the 5-minute error ratio climbed 0.0 → 1.0 in step with
the window, against the flat 0.000 the previous SLI produced for the same class
of event.
