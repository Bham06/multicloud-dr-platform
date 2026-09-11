# Runbook — failback from GCP to AWS

**Target:** RTO < 1 hour · RPO 0 (failback is planned, so losing data is a bug)
**Status:** written 2026-09-11 from the state the M5 drill left behind, before
executing. Drill log at the bottom.

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
| _(first failback drill)_ | | < 1h | | 0 expected | |
