# Portability register

Every AWS-specific dependency, and what happens to it during failover to GCP.

**This is the highest-value artifact in the project.** An entry without a verdict
is an undiscovered DR blocker. Teams that skip this step find the gaps during
their first game day, which is the expensive place to find them.

Every row carries one of three verdicts. "We'll figure it out later" is not one
of them:

| Verdict | Meaning |
| --- | --- |
| **PORTABLE** | A GCP equivalent exists and the abstraction is already in place. |
| **ABSTRACTED** | Cloud-specific, but hidden behind an interface the app does not see. |
| **ACCEPTED** | Does not fail over. Consciously accepted, with the consequence written down. |

Enforced by `scripts/check-portability.sh`, which fails the build if anything in
`apps/*/base` names a cloud, or if an app is missing from any cluster.

---

## Compute & orchestration

| Dependency | AWS | GCP counterpart | Verdict | Notes |
| --- | --- | --- | --- | --- |
| Kubernetes control plane | EKS | GKE | **PORTABLE** | Same manifests; only the overlay differs. Verified continuously by the local/real duality (ADR 0002). |
| Container registry | ECR | Artifact Registry | **ABSTRACTED** | CI pushes every image to both. Each cluster pulls from its own cloud — no shared failure domain in the DR path, and no cross-cloud egress on pod start. The image reference is an **overlay** concern: a registry hostname in a base is a portability break and the guard rejects it. |
| Node autoscaling | Karpenter / ASG | GKE autoscaler | **ABSTRACTED** | Node config lives in Terraform, never in app manifests. |
| Ingress | ALB + AWS LB Controller | GCLB + GKE Ingress | **PORTABLE** | **Neither.** Gateway API with Envoy Gateway in both clusters — see [ADR 0004](decisions/0004-gateway-api-for-portable-ingress.md). The `Gateway` and `HTTPRoute` manifests are byte-identical across clouds; only the L4 address in front differs. |

## Data

| Dependency | AWS | GCP counterpart | Verdict | Notes |
| --- | --- | --- | --- | --- |
| Primary relational DB | RDS/Aurora Postgres | Cloud SQL Postgres | **ABSTRACTED** | Logical replication over the VPN. The app resolves a Service name, never a cloud endpoint, so promotion does not require an app change. Sharp edges: failback is manual, and **DDL does not replicate** — schema changes must be applied to both sides deliberately. Sequences need explicit handling on promotion. |
| Object storage | S3 | GCS | **ABSTRACTED** | Storage Transfer Service. App code is restricted to the S3-compatible subset (GET/PUT/DELETE/list); no presigned-URL semantics, no S3 Select, no bucket notifications. Locally simulated with MinIO on both sides. |
| Cache | ElastiCache Redis | Memorystore | **ACCEPTED** | Not replicated. **Consequence:** failover starts with a cold cache — expect a latency spike and elevated DB load in the first minutes. This is a deliberate trade; replicating cache across clouds costs continuous egress to protect data that is by definition reconstructible. The SLO burn during that window is budgeted for, not a surprise. |

## Identity & secrets

| Dependency | AWS | GCP counterpart | Verdict | Notes |
| --- | --- | --- | --- | --- |
| Workload identity | IRSA | GKE Workload Identity | **ABSTRACTED** | Both project a token into a ServiceAccount. App code must not read instance metadata directly — that is a silent portability break the guard cannot catch, so it is on the review checklist. |
| Secrets | Secrets Manager | Secret Manager | **ABSTRACTED** | External Secrets Operator in both clusters, with **one** source of truth. Secrets are never replicated cloud-to-cloud: two writable copies of a credential is a rotation bug waiting to happen. |
| Encryption keys | KMS | Cloud KMS | **ACCEPTED** | **Envelope encryption does not fail over.** Data encrypted under an AWS KMS key is unreadable on GCP — no amount of replication changes this. **Consequence:** anything that must survive failover is encrypted with a key whose material exists in both clouds, or is not envelope-encrypted at all. This one bites hard and late; it is the single most likely cause of a failover that appears to work and then cannot read its own data. |

## Observability & operations

| Dependency | AWS | GCP counterpart | Verdict | Notes |
| --- | --- | --- | --- | --- |
| Metrics/logs/traces | CloudWatch | Cloud Operations | **PORTABLE** | OTel Collector everywhere; the backend is swappable by design and lives outside both clouds. |
| DNS / traffic failover | Route 53 | Cloud DNS | **ACCEPTED** (deliberate) | **Neither.** The failover trigger lives outside both clouds, or the DR mechanism shares a failure domain with the thing that is failing. Note February's prior attempt put the trigger *inside* the primary — exactly this mistake. |

---

## Open questions

- [ ] Does the workload read EC2/GCE instance metadata anywhere? (Silent break; the guard cannot see it.)
- [ ] Are there hardcoded region strings outside the overlays?
- [ ] Does any IAM policy grant access that has no GCP equivalent?
- [ ] What is the actual, measured size of the S3 dataset to replicate?
- [ ] Which data is envelope-encrypted today, and does its key exist in both clouds?
