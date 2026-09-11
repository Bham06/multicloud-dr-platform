# Runbook — failback from GCP to AWS

**Target:** RTO < 1 hour · RPO 0 (failback is planned, so losing data is a bug)
**Status:** exercised 2026-09-11 — **RTO 51s, user-visible outage 25s, RPO 0.**
Nine defects found, four of them in the runbook or tooling as written. Drill log
at the bottom.

> **Failback is not failover reversed.** Failover is an emergency with a
> degraded starting point you did not choose. Failback is elective: you pick the
> moment, nothing is on fire, and there is therefore **no excuse for losing a
> single row**. An RPO above zero here is a defect, not a tradeoff.

The failover runbook says this is "usually where these projects come undone".
Two structural problems were found before running a single step, and both would
have stopped a real failback dead.

---

## 0. Preconditions — read these before starting

### The standby must be reachable as a publisher

`platform/postgres/overlays/gcp-secondary` patches `pg_hba` to accept the peer
CIDR, with a comment saying it is "kept symmetrical with the primary so this
side can publish after a failover reverses the roles. A standby that cannot
become a publisher makes failback impossible."

The reasoning is right and the implementation stopped half way. `pg-interconnect`
— the NodePort that actually exposes Postgres across the interconnect — existed
only in the `aws-primary` overlay:

```
k3d-aws-primary      pg-interconnect  NodePort  5432:30432/TCP
k3d-gcp-secondary    (absent)
```

Measured from the would-be subscriber: `172.30.0.20:30432 NOT reachable`.
Authentication was ready; nothing was listening. **Failback was impossible** and
nothing reported it, because nothing exercises the reverse direction until the
day you need it.

- [ ] `pg-interconnect` exists on **both** clusters

### Do not trust the control plane about replication

The CNPG `Subscription` CR reports `applied: true` with `observedGeneration: 1`
permanently after its first successful reconcile. The M5 drill dropped the
subscription with SQL, as step 3 of the failover runbook instructs. Seventeen
days later:

```
pg_subscription                     0 rows
kubectl get subscriptions           APPLIED  true
argocd app postgres                 Synced / Healthy
```

Every layer of the GitOps chain reported healthy while replication did not
exist. The controller applied the spec once, the spec never changed, and it
considers itself finished — it does not reconcile the database object back.

- [ ] Replication state confirmed from `pg_subscription` / `pg_replication_slots`
      via `make db-status`, **never** from Argo or `kubectl get subscriptions`

## 1. Establish what actually diverged

Counts are not evidence. Checksum the overlapping range:

```sql
SELECT md5(string_agg(id||'|'||payload||'|'||created_at, E'\n' ORDER BY id))
  FROM orders WHERE id <= :highest_id_on_the_old_primary;
```

At the time of writing:

| | aws-primary (old primary) | gcp-secondary (current) |
| --- | --- | --- |
| rows | 1910 | 1912 |
| max(id) | 1910 | 1912 |
| `orders_id_seq` | 1934 | 1912 |
| md5 over `id <= 1910` | `79d6280…` | `79d6280…` |

The old primary is a **byte-identical prefix**: it is missing exactly the two
post-promotion writes and holds nothing the current primary lacks. That is only
true because it was fenced before anything wrote to it again.

- [ ] Checksums match over the overlapping range
- [ ] The old primary holds **no** rows the current primary lacks

**If that last check fails, stop.** Those rows were accepted after the split and
a re-seed destroys them. Extract them first; merging divergent writes is a data
problem, not a runbook step.

## 2. Re-seed, don't reconcile

Two options once the divergence is known:

| | re-seed (`copy_data = true`) | reconcile (`copy_data = false`) |
| --- | --- | --- |
| cost | full table copy | insert the missing rows only |
| depends on | nothing | having *proven* byte-identity |
| failure mode | slow | a silent gap if writes land between backfill and slot start |

**Default to re-seed.** Not because reconcile is wrong here — with a proven
2-row prefix divergence it is provably safe — but because the runbook has to
encode the procedure that is safe when you *cannot* prove byte-identity, which
is the normal case at real data volumes and after a partition rather than a
clean kill. Reconcile is an optimisation to reach for when a full copy will not
fit inside RTO, and it needs the slot created *before* the backfill so the
starting LSN is pinned.

Re-seeding **discards the old primary's copy of the table.** That is safe only
because of the check in step 1.

- [ ] Decision recorded, with the reason

## 3. Reverse the direction in Git

Publisher and subscriber are declarative, so this is a file move, not SQL:

```
platform/postgres/overlays/aws-primary/publication.yaml    -> gcp-secondary/
platform/postgres/overlays/gcp-secondary/subscription.yaml -> aws-primary/
```

The subscription's `externalClusterName` and the `externalClusters` patch both
have to point the other way, at `172.30.0.10` → `172.30.0.20`.

Drop the stale objects on the old primary first — they are not pruned by moving
the files, because the CR being deleted does not drop the database object any
more reliably than the CR being created keeps it:

```sql
-- on aws-primary, which is about to become the subscriber
DROP PUBLICATION IF EXISTS app_pub;
SELECT pg_drop_replication_slot('app_sub');   -- inactive since the failover
```

**That slot matters.** It has been `reserved` and inactive since the drill,
retaining WAL. It is harmless only because nothing has written to that database
since; the moment this cluster takes writes again it accumulates WAL with no
consumer, and that is how a primary fills its disk.

- [ ] Old publication and orphaned slot dropped
- [ ] Files moved, addresses reversed, pushed

## 4. Verify replication carries data — in the database

The CR will say `applied: true` whether or not any of this worked.

```bash
make db-status      # slot active, subscriber up, lag
```

Then prove it moves rows rather than assuming it:

```bash
./scripts/db-load.sh --stream 0.5      # on the NEW publisher
```

- [ ] `slot active` **and** `subscriber up`
- [ ] Row count on the subscriber rises while the stream runs
- [ ] Lag inside target

## 4b. Quiesce and drain — this is what buys RPO 0

Failover cannot do this: in a disaster the primary is already gone and whatever
had not replicated is simply lost. Failback is elective, so the writes can be
stopped deliberately and replication allowed to catch up before anything is
promoted. **This step is the entire reason RPO 0 is achievable here**, and it was
missing from the first draft of this runbook.

```bash
# 1. stop writes at the source — in a real system, drain the app, not the loader
# 2. wait for the subscriber to catch up
make db-status      # watch 'last publisher contact' and the subscriber lag fall
```

- [ ] Writes stopped at the current primary
- [ ] Subscriber lag reached ~0 **after** the last write
- [ ] `max(id)` and row counts identical on both sides
- [ ] Only then proceed

Promoting before the drain completes converts a planned migration into an
unplanned data-loss event, and it will not be obvious afterwards: the counts
settle, both sides look consistent, and the rows that never arrived are simply
absent with nothing pointing at them.

## 5. Cut back

Only once replication is proven, and in this order:

```bash
./scripts/promote.sh aws-primary --apply   # roles, replicas, collector drRole
git commit -am "failback: promote aws-primary" && git push
make traffic-switch SITE=aws-primary
```

`promote.sh` demotes the current primary to zero replicas in the same commit,
which is what fences it. `make check` fails if role and replica count disagree.

- [ ] Responses say `Name: aws-primary` — from the pod, not the proxy's opinion
- [ ] `make check` passes

## 6. Repair sequences on the promoted side

Same trap as failover, and it applies in this direction too:

```bash
./scripts/check-sequences.sh --cluster aws-primary
./scripts/check-sequences.sh --cluster aws-primary --apply
```

Note the asymmetry worth knowing: a sequence **ahead** of its data is harmless,
a sequence **behind** it produces duplicate-key failures that self-heal and
destroy their own evidence. `check-sequences.sh` uses `GREATEST`, so it only
ever moves a sequence forward.

- [ ] Every sequence at or above its column's max
- [ ] A write succeeds on the promoted side

## 7. Stop the clock

- [ ] RTO recorded from the probe log, not estimated
- [ ] **RPO must be 0.** This was planned work; anything else is a defect

---

## Drill log

| Date | Type | RTO target | RTO actual | RPO actual | Notes |
| --- | --- | --- | --- | --- | --- |
| 2026-09-11 | Planned failback GCP→AWS | < 1h | **51s** | **0** | First failback. Nine findings; the drill itself lost 167 rows on the first attempt and had to be restarted. |

### 2026-09-11 — first failback drill

**Timeline** (cutover clock; the preceding re-seed and verification are excluded
because they are not downtime):

| | | elapsed |
| --- | --- | --- |
| 19:36:02 | cutover begins — clock starts | 0 |
| 19:36:20 | `promote.sh` committed and pushed | +18.2s |
| 19:36:28 | last 200 from `gcp-secondary` | +26.0s |
| 19:36:37 | 2/2 ready on `aws-primary` | +35.5s |
| 19:36:53 | **first 200 from `aws-primary` — restored** | **+51.0s** |

**RPO 0**, verified by checksum rather than counts: the hash over `id <= 2242`
taken at the quiesce gate is byte-identical to the same range on the promoted
side afterwards.

Outage 25.0s against the failover's 127.7s — as expected, since a planned
cutover skips the declare, the diagnosis and the RPO decision entirely.

### Findings

**1. The standby could not publish at all.** `pg-interconnect` existed only in
the `aws-primary` overlay while `gcp-secondary` carried the matching `pg_hba`
rule, so the standby was authenticated for a role it could not physically
perform. Measured before the fix: `172.30.0.20:30432 NOT reachable`. Failback
was impossible and nothing reported it, because nothing exercises the reverse
direction until the day you need it. The Service now lives in the base so the
symmetry is structural.

**2. The `Subscription` CR reports the result of its last reconcile and never
re-checks.** After the M5 drill dropped the subscription in SQL — as the
failover runbook instructs — `pg_subscription` had zero rows for seventeen days
while the CR said `applied: true`, `kubectl` said `APPLIED true`, and Argo said
`Synced / Healthy`. The spec had not changed, so the controller considered
itself finished. Forcing it to act means **deleting the CR**, not editing it.

**3. Argo reports `Synced / Healthy` over a failed subscription.** When the CR
was recreated and genuinely failed — `could not create replication slot
"app_sub": already exists` — the Application stayed green. Argo does not
consider CNPG `Subscription.status.applied` in its health assessment.

**4. `db-status` had the replication direction hardcoded.** It read the slot
from `aws-primary` and the subscription from `gcp-secondary`. After the
reversal it therefore queried the slot on the subscriber and the subscription on
the publisher, found neither, and reported **"slot INACTIVE / subscriber none"
over a link that was streaming with 0.47s of lag.** A DR tool reporting healthy
replication as dead is the wrong direction to fail in. It now asks the databases
which way they are pointing. The same hardcoding was in the data-age readout and
in the sequence warning, which was checking the publisher's sequence when the
sequence at risk belongs to whichever side is about to be promoted.

**5. `db-load.sh` had the target cluster hardcoded**, so a load run after the
reversal would have written to the *subscriber*, diverging the table that had
just been re-seeded from it and manufacturing the split brain the drill exists
to avoid.

**6. The quiesce was not a quiesce, and the drill lost 167 rows because of it.**
`db-load.sh --stream` ends in `exec kubectl …`, which *replaces* the shell, so
`pkill -f "db-load.sh"` matches nothing. The wrapper died, the server-side
`psql \watch` loop kept inserting, and the run was declared quiesced anyway.
The subscription was then dropped on the side being promoted while writes were
still flowing: **167 rows across 63 seconds stranded on the old primary with no
replication left to carry them.** Promoting there would have been a planned
migration with a non-zero RPO, which this runbook defines as a defect. The drill
was restarted from a fresh re-seed.

The authoritative stop is server-side — `pg_terminate_backend` on the writing
session — and the only acceptable evidence is the row count holding still across
several consecutive reads.

**7. A checksum against a moving source proves nothing.** The first gate did
match, 2075 against 2075, and was worthless: the source was still accepting
writes, so it compared a snapshot of a target that moved immediately afterwards.
Quiesce first, *then* compare. Order is the whole content of the step.

**8. `ALTER SUBSCRIPTION … SET (slot_name = NONE)` orphans the slot on the
publisher.** The failover runbook uses that dance to drop a subscription whose
publisher is gone, which is right there and leaves an orphan here: the next
subscription of the same name fails with `replication slot "app_sub" already
exists`. Drop it on the publisher as part of the same step.

**9. `promote.sh`'s atomic swap costs avoidable downtime on a planned cutover.**
It scales the target up and the source down in one commit, so the source reached
zero replicas at 19:36:29 and the target was not ready until 19:36:37. For a
*failover* that is correct — fencing the old primary immediately is the point.
For a planned failback the order can be reversed: bring the target up, move
traffic, then scale the source down, which reduces the outage to the proxy
reload. Not changed, because the failover case matters more and one flag that
alters fencing behaviour is a dangerous thing to add; recorded as a known cost.
