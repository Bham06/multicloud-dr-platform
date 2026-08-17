# Portability register

Every AWS-specific dependency, and what happens to it during failover to GCP.

**This is the highest-value artifact in the project.** An entry without a verdict
is an undiscovered DR blocker. Teams that skip this step find the gaps during
their first game day, which is the expensive place to find them.

Every row must carry one of three verdicts. "We'll figure it out later" is not
one of them:

| Verdict | Meaning |
| --- | --- |
| **PORTABLE** | A GCP equivalent exists and the abstraction is already in place. |
| **ABSTRACTED** | Cloud-specific, but hidden behind an interface the app does not see. |
| **ACCEPTED** | Does not fail over. Consciously accepted, with the consequence written down. |

---

## Compute & orchestration

| Dependency | AWS | GCP counterpart | Verdict | Notes |
| --- | --- | --- | --- | --- |
| Kubernetes control plane | EKS | GKE | PORTABLE | Same manifests; only the overlay differs. |
| Container registry | ECR | Artifact Registry | TBD | Decide: replicate images, or single registry both clusters pull from. Single registry is simpler but is a shared failure domain. |
| Node autoscaling | Karpenter / ASG | GKE autoscaler | ABSTRACTED | Node-level config lives in Terraform, never in app manifests. |
| Ingress | ALB + AWS LB Controller | GCLB + GKE Ingress | TBD | **Likely the first real portability break.** ALB annotations are AWS-only. Candidate fix: ingress-nginx on both, so the ingress layer is identical and only the L4 in front differs. |

## Data

| Dependency | AWS | GCP counterpart | Verdict | Notes |
| --- | --- | --- | --- | --- |
| Primary relational DB | RDS/Aurora Postgres | Cloud SQL Postgres | TBD | Logical replication over the VPN. Sharp edges: failback is manual, and DDL does not replicate — schema changes must be applied to both sides deliberately. |
| Object storage | S3 | GCS | TBD | Storage Transfer Service. Verify: does app code use S3-specific APIs, or only the portable subset? |
| Cache | ElastiCache Redis | Memorystore | TBD | If cache loss is tolerable, this is ACCEPTED and needs no replication. Decide explicitly. |

## Identity & secrets

| Dependency | AWS | GCP counterpart | Verdict | Notes |
| --- | --- | --- | --- | --- |
| Workload identity | IRSA | GKE Workload Identity | ABSTRACTED | Both project to a ServiceAccount token; app code must not read instance metadata directly. |
| Secrets | Secrets Manager | Secret Manager | TBD | Do **not** replicate secrets across clouds. Use External Secrets Operator with a defined source of truth. |
| Encryption keys | KMS | Cloud KMS | TBD | Envelope encryption is not portable. Data encrypted with an AWS KMS key is unreadable on GCP — this one bites hard and late. |

## Observability & operations

| Dependency | AWS | GCP counterpart | Verdict | Notes |
| --- | --- | --- | --- | --- |
| Metrics/logs/traces | CloudWatch | Cloud Operations | PORTABLE | OTel Collector everywhere; backend is swappable by design. |
| DNS / traffic failover | Route 53 | Cloud DNS | ACCEPTED (deliberate) | **Neither.** The failover trigger must live outside both clouds, or the DR mechanism shares a failure domain with the thing that is failing. |

---

## Open questions

- [ ] Does the workload read EC2/GCE instance metadata anywhere? (Silent portability break.)
- [ ] Are there hardcoded region strings outside the overlays?
- [ ] Does any IAM policy grant access that has no GCP equivalent?
- [ ] What is the actual, measured size of the S3 dataset to replicate?
