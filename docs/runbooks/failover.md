# Runbook — failover from AWS to GCP

**Target:** RTO < 1 hour · RPO < minutes
**Status:** skeleton — steps 3–6 land in milestones 4–5. Steps 1–2 work today.

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
# Edit apps/demo-api/overlays/gcp-secondary/kustomization.yaml
#   replicas: count: 0  ->  count: 2
git commit -am "failover: promote gcp-secondary" && git push
```

Argo CD on `gcp-secondary` reconciles within its poll interval. The workload is
already defined and its images are already pulled — this is why a pilot light
starts in seconds rather than minutes.

Verify:

```bash
make status
```

## 3. Promote the database _(milestone 4)_

- [ ] Confirm replication lag is within RPO **before** promoting
- [ ] Promote the Cloud SQL replica to standalone
- [ ] Verify sequences and extensions survived (a classic logical-replication gap)
- [ ] Point the app at the promoted endpoint

## 4. Cut traffic over _(milestone 5)_

- [ ] Update the external traffic manager — **not** Route 53, which shares a
      failure domain with the thing that failed
- [ ] Real RTO includes DNS TTL + connection drain + warm-up. Measure it; do not
      assume it.

## 5. Verify

- [ ] SLIs green on the promoted side
- [ ] Writes succeed and persist
- [ ] No traffic still reaching the old primary

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
| _(first drill: milestone 5)_ | | < 1h | | | |
