# Runbook — failover from AWS to GCP

**Target:** RTO < 1 hour · RPO < minutes
**Status:** exercised end to end on 2026-08-24 — **RTO 2m 07s, RPO 0 rows.**
See the drill log at the bottom, including the three defects the drill found.

> **The decision is manual. The steps are automated.**
> Automatic cross-cloud failover on an active-passive topology invites split
> brain on the data tier, which is worse than the outage it prevents. A human
> declares the disaster; everything after that is scripted.

---

## 0. Declare

Record the wall-clock time. **RTO is measured from here**, not from when the
incident started. Confirm this is a genuine primary-side failure and not a
monitoring artefact — a false failover costs more than a few minutes of triage.

## 1. Freeze the primary

Prevent the old primary accepting writes and diverging from the promoted
standby. Split brain is the failure mode that turns an outage into data loss.

## 2. Scale up the pilot light

```bash
./scripts/promote.sh gcp-secondary            # review the diff
./scripts/promote.sh gcp-secondary --apply
git commit -am "failover: promote gcp-secondary" && git push
```

**Do not hand-edit the replica count.** That is what the first drill did, and it
is why finding 3 exists: the count went 0 → 2, nothing flipped `dr.role`, and
afterwards the cluster serving every request was still labelled `standby` while
the label `primary` pointed at the dead one. Role and replica count are one
decision. `promote.sh` makes them one edit, and demotes the old primary to zero
replicas in the same commit — which is also how the old side gets fenced.

`make check` now fails if a cluster runs replicas while labelled standby, so a
half-done promotion breaks CI instead of quietly breaking the SLOs.

Argo CD on `gcp-secondary` reconciles within its poll interval. The workload is
already defined and its images are already pulled — this is why a pilot light
starts in seconds rather than minutes. If it has not appeared after a minute,
force it:

```bash
kubectl -n argocd annotate app demo-api argocd.argoproj.io/refresh=hard --overwrite
```

Verify:

```bash
make status
```

## 3. Promote the database

Check lag **before** promoting — this is the RPO decision, and it is the one
step that cannot be undone:

```bash
make db-status    # slot/worker liveness, lag, row counts, sequences
make slo-status   # burn rate and whether DRReplicationStale is firing
```

- [ ] `slot active` and `subscriber up` are both green. A stopped subscriber
      reports *zero* lag while falling arbitrarily far behind, so never read
      lag alone.
- [ ] Row counts agreeing is **not** evidence of health. With no writes in
      flight both sides agree perfectly while replication is dead — observed
      during the M4 drill.
- [ ] Lag is within RPO (target: minutes).

Then drop the subscription so the new primary stops trying to pull from a
publisher that is gone:

```sql
ALTER SUBSCRIPTION app_sub DISABLE;
ALTER SUBSCRIPTION app_sub SET (slot_name = NONE);
DROP SUBSCRIPTION app_sub;
```

**Then reset every sequence. This step is not optional.**

```bash
./scripts/check-sequences.sh              # what would break
./scripts/check-sequences.sh --apply      # repair it
```

Do not hand-write `setval` per table. A real schema has dozens of sequences;
you fix the two you remember and the third fails weeks later. The script walks
`pg_depend`, so it covers `serial`, `bigserial` and `GENERATED ... AS IDENTITY`
alike and cannot miss one.

**This step belongs here and nowhere earlier.** Repairing sequences ahead of
time does not hold: one further write on the old primary re-diverges the
standby immediately. It is only valid once writes have stopped — which is why
step 1 (freeze the primary) must genuinely have taken effect first.

Logical replication carries rows, not sequence values, and this is not
configurable: PostgreSQL 18.4's `pg_publication` has no sequence support at
all — `CREATE PUBLICATION ... FOR ALL SEQUENCES` is a syntax error.

**The failure self-heals, which is what makes it dangerous.** Sequences are
non-transactional, so every *failed* insert still burns a value. Measured on
this substrate with 1001 rows and the sequence at 1:

```
attempt 1: ERROR:  duplicate key value violates unique constraint "orders_pkey"
attempt 2: ERROR:  duplicate key value violates unique constraint "orders_pkey"
attempt 3: ERROR:  duplicate key value violates unique constraint "orders_pkey"
sequence after three failed attempts: 3
998 more failures, then success
```

After `max(id) - last_value` attempts the collisions stop and writes start
succeeding. Alerting sees a burst of errors that recovers on its own, no root
cause survives, and every one of those attempts was a lost write. A clean,
permanent failure would be *safer* — it would still be broken when someone
came to look.

- [ ] Every sequence in the schema reset, not just `orders_id_seq`
- [ ] Point the app at the promoted endpoint

## 4. Cut traffic over

```bash
make traffic-status                      # who is serving, and is each side up
make traffic-switch SITE=gcp-secondary   # the cutover
```

The traffic manager runs **outside both clusters** — locally an nginx container
on the interconnect network, in production a managed edge. Not Route 53 and not
Cloud DNS: the thing deciding where traffic goes must not die with the thing it
is redirecting away from.

It has **one upstream and no health-checked pool.** That is deliberate. A pool
with automatic failover would move traffic on a timeout, and an active-passive
data tier that fails over on a timeout gets split brain. A human declares; this
step is what follows.

- [ ] `make traffic-switch SITE=gcp-secondary`
- [ ] Confirm from the *response*, not the proxy's config: `demo-api` echoes
      `WHOAMI_NAME`, so a reply says which cluster produced it. Where the
      traffic manager believes it is sending you is not evidence.
- [ ] Real RTO includes DNS TTL + connection drain + warm-up. The local drill
      measures reload and drain only — **there is no DNS in the loop here, so
      the measured number excludes propagation.** A real cutover adds the record
      TTL on top, and that term will likely dominate everything else in this
      runbook.

## 5. Verify

- [ ] Writes succeed **and read back** on the promoted side
- [ ] `make traffic-status` shows the promoted side serving
- [ ] The hostnames in the responses are real pods on the promoted cluster —
      check them against `kubectl get pods`
- [ ] `make slo-status`. The availability SLO is now measured from outside both
      clouds (ADR 0005) and will have registered the outage. A cold Prometheus
      reports unavailable for its first five minutes — absence counts as an
      outage by design — so give it that long before reading the number.

## 6. Stop the clock

Record actual RTO and RPO. **Compare against target and write down the delta.**
A drill that does not produce a number produces nothing.

---

## Failback

Failback is **harder than failover** and is usually where these projects come
undone: replication now runs GCP → AWS, which is not the direction the original
topology was built for. Do not treat it as "the same steps, reversed." It gets
its own runbook and its own drill.

## Drill log

| Date | Type | RTO target | RTO actual | RPO actual | Notes |
| --- | --- | --- | --- | --- | --- |
| 2026-08-24 | Total loss of primary, local | < 1h | **2m 07s** | **0 rows** | First drill. Three defects found — all in the tooling, none in the failover itself. All three fixed same day. |

### 2026-08-24 — first game day

**Scenario.** `docker kill` on the `aws-primary` node: the whole cluster gone at
once, no graceful shutdown. Kill, not stop, because a region does not drain
politely and a clean Postgres checkpoint on the way out would have flattered the
RPO number. Writes were in flight throughout, one commit every 500 ms
(`./scripts/db-load.sh --stream`) — without them both sides would have agreed
perfectly and the drill would have measured an RPO of zero that meant nothing.

**Timeline** (`./scripts/traffic-manager.sh analyze` over a 4 Hz probe):

| | | elapsed |
| --- | --- | --- |
| 08:01:41.860 | primary killed | |
| 08:01:41.779 | last 200 from `aws-primary` | −0.1s |
| 08:01:42.742 | **declared — RTO clock starts** | 0 |
| 08:02:00.475 | `replicas: 0 -> 2` pushed | +17.7s |
| 08:02:18.065 | 2/2 ready on `gcp-secondary` | +35.3s |
| 08:03:21.023 | subscription dropped | +98.3s |
| 08:03:28.172 | sequences repaired | +105.4s |
| 08:03:49.499 | **first 200 from `gcp-secondary` — restored** | **+126.8s** |

**RTO: 2m 07s** against a 1-hour target — 3.5% of budget. User-visible outage
127.7s across 79 consecutively failed probes.

**RPO: 0 rows.** Measured after recovering the old primary and diffing: both
sides ended on 104 drill rows, `max(id)` 1910, last write `08:01:41.674`.
Nothing was lost. The honest caveat is resolution — the write cadence was
500 ms, so this drill cannot resolve an RPO finer than that; the real bound is
the subscriber lag measured just before the kill, 0.13s.

**Detection is not measured here.** The operator caused the failure and declared
0.9s later. Real MTTD — alert fires, someone is paged, someone decides — is not
in this number and is likely to be the largest term in a real incident.

**What worked.** The pilot light is genuinely fast: 35s from declare to two
ready pods, because the workload was already reconciled and its image already
pulled. The sequence repair worked exactly as designed — `check-sequences.sh`
found `orders_id_seq` at 1001 against data at 1910, repaired it, and the first
post-promotion insert took id 1911 with no collision.

### Findings

**1. The RPO gate died at the moment it was needed.** `make db-status` — the
command step 3 tells you to run before promoting — exited with
`make: *** [db-status] Error 1` and no output at all, because `set -e` plus a
failed `kubectl` inside a command substitution aborted it on the first query
against the dead primary. Cost roughly a minute mid-drill and forced the RPO
call to be made by hand against the standby. Fixed in `927fdba`, along with
three defects that fix exposed: unknown rendered as equal, a sequence warning
comparing the wrong pair of numbers, and `slot INACTIVE` asserted from silence.

**2. The availability SLO did not notice a total outage.** *(fixed — ADR 0005)*
It reported a flat 0.00% error ratio for the entire 127s, and
`DemoAPIUnavailable` never fired. Verified by `query_range` across the window:
0.000 at every step. Two causes, both structural:

- *The probe shares a failure domain with what it probes.* The `httpcheck`
  receiver measuring the active side runs **inside** the active side. When that
  cluster died the prober died with it, so the metric stopped being produced
  rather than going to zero. This is the same shared-failure-domain mistake the
  README calls out for the failover trigger, repeated one layer down in
  observability.
- *Absence is averaged away, not counted as failure.* The `or on() vector(0)`
  guard only fires when the **entire** 5m subquery window is empty;
  `avg_over_time` silently skips missing points, so partial absence just raises
  the average of whatever remains. Prometheus staleness then served the last
  known value — `1`, healthy — for five minutes after the cluster stopped
  existing.

**3. The role label never flips, so the SLO follows the wrong cluster.**
*(fixed)* `slo/dr.yaml` filtered availability on `dr_role="primary"` and its own
comment said the label "flips in Git as part of the failover change, so the SLO
follows the traffic." Nothing in this runbook flipped it. After the drill,
`dr_role="primary"` still resolved to the demoted `aws-primary` and
`gcp-secondary` — serving 100% of traffic — was still labelled `standby`. The
design was right and the procedure never executed it.

### How 2 and 3 were closed

**Finding 2 — ADR 0005.** The probe moved into the external traffic manager,
which is attached to neither cluster, and Prometheus now *scrapes* it instead of
receiving a push. That distinction is the fix: a scrape target that stops
answering gets `up == 0` written immediately, while a collector that stops
pushing produces nothing at all and lets staleness serve its last healthy value.
The SLI multiplies endpoint health, prober liveness and probe freshness, each
defaulting to zero inside the subquery, so every failure mode of the measurement
chain resolves to "not available". Demonstrated across four states — healthy 1,
endpoint dead 0, prober dead 0, restored 1 — and the 5-minute error ratio
climbed 0.0 → 1.0 over a sustained outage, against the flat 0.000 the old SLI
produced for the same event.

**Finding 3 — `promote.sh` plus a guard.** Role and replica count are now one
edit rather than two, and the old primary is demoted to zero replicas in the
same commit, which is how that side gets fenced. `make check` fails if a cluster
runs replicas while labelled standby, or if more than one claims primary — the
guard was written against the live post-drill repo, where it caught the real
mistake rather than a synthetic one.

**Still open, and not closed by either fix:** the evaluator itself lives inside
`gcp-secondary`. The prober now survives either cluster dying; Prometheus does
not. Losing the cluster that hosts it still loses the SLO. That is the Grafana
Cloud move already recorded in ADR 0002.

**Post-drill state.** The environment was left promoted, not failed back:
`gcp-secondary` serving with 2 replicas and a writable database, `aws-primary`
restarted and *also* writable with no replication between them. That is a split
brain and it is deliberate — it is the starting position the failback drill
needs. Do not resume normal work against this substrate without fencing one
side first.
