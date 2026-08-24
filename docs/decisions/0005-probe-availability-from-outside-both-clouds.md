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

The SLI multiplies three terms, evaluated per step **inside** the subquery:

| term | answers | when absent |
| --- | --- | --- |
| `dr_probe_success{target="public"}` | did the endpoint answer? | 0 — an outage |
| `up{job="dr-edge"}` | is the prober being scraped? | **skip the step** |
| `time() - dr_probe_timestamp_seconds < 60` | is the probe loop still sweeping? | 0 — an outage |

`up` is the one term with no zero-default, and that asymmetry is load-bearing:

- `up == 0` — we were watching and the prober did not answer. **An outage.**
- `up` absent — there was no target in service discovery, so nothing was
  watching. **Not evidence of anything**, and excluded from the average.

"Not measured" is therefore not scored as error budget. It is a real condition
and gets its own alert, `DRAvailabilityUnmeasured`, in a hand-written rules file
separate from the one `make slo` regenerates.

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
   available" — but "we were not measuring" is not a failure mode of the
   service.** The old query failed towards *healthy*, which is why it lied.
   The first attempt at this fix over-corrected and defaulted every term to
   zero, including `up`: every burn-rate window then read the time before
   deployment as downtime, `ratio_rate3d` sat at 0.9932 against a perfectly
   healthy service, and the alert would have fired continuously for three days.
   An alert that is always on is exactly as useless as one that is never on.
   The distinction between *down* and *not measured* is the difference between
   the two, and an SLI that cannot express it will lie in one direction or the
   other.

4. **Probing the public endpoint removes the role question entirely.** The old
   query filtered on `dr_role="primary"` and kept measuring the demoted cluster
   after a failover, because nothing flipped the label. Whoever is serving is
   what gets measured, because that is what a user reaches.

## Consequences

- **A cold Prometheus reports nothing rather than reporting unavailable.**
  Windows that predate the prober contribute no samples, so a freshly deployed
  or restarted evaluator does not manufacture downtime. The cost is that a
  genuinely silent SLO looks identical to a healthy one from the SLI alone,
  which is what `DRAvailabilityUnmeasured` exists to catch.
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
| prober scraped but not answering (`up == 0`) | 0 |
| restored | 1 |
| before the prober existed at all | absent — step skipped |

Over a sustained outage the 5-minute error ratio climbed 0.0 → 1.0 in step with
the window, against the flat 0.000 the previous SLI produced for the same class
of event. Correcting the `up` default dropped every long window from ~0.99 to
0.1646 — and left them all equal, which is the tell that they now cover the same
real measurement period rather than padding it with absence. The residue is the
~390s of downtime deliberately caused during testing, which should be scored.
