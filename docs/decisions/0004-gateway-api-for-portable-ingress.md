# ADR 0004 — Gateway API with Envoy Gateway for portable ingress

**Status:** accepted · **Date:** 2026-08-18

## Context

The portability register flagged ingress as the likely first real portability
break. The default path on each cloud produces manifests that cannot move:

- **AWS:** `Ingress` + `alb.ingress.kubernetes.io/*` annotations, reconciled by
  the AWS Load Balancer Controller.
- **GCP:** `Ingress` + `cloud.google.com/*` annotations, reconciled by GKE.

The annotations are the configuration. Two clouds means two sets of manifests
for the same routing intent — precisely the divergence that makes a standby
untrustworthy.

## Decision

**Gateway API**, implemented by **Envoy Gateway running in both clusters.**

`Gateway`, `HTTPRoute` and `GatewayClass` manifests are byte-identical across
clouds and live in `apps/*/base`. Only the L4 address in front differs, and
that is a Terraform concern outside the cluster (ADR 0001).

## Rationale

1. **It solves the problem rather than routing around it.** Gateway API moved
   configuration out of annotations and into typed, portable fields. Being
   annotation-free is what makes the manifests identical, not a convention we
   have to keep enforcing by hand.

2. **One implementation in both clusters removes the last variable.** Using each
   cloud's native controller would still leave two `GatewayClass` behaviours to
   reason about. Envoy Gateway in-cluster means the data plane is the same
   binary on both sides — so a routing bug found on the primary reproduces on
   the standby.

3. **Role separation matches the platform layer.** Gateway API splits
   infrastructure (`Gateway`, platform-owned) from routing (`HTTPRoute`,
   app-owned). That is the same boundary the platform layer draws anyway, and it
   makes RBAC honest.

## Consequences

- ~150–250 MB per cluster for the Envoy Gateway control plane and proxies.
  Measured against the 3.83 GB budget in ADR 0002; fits, but it is real.
- We give up native WAF and cert-manager-free TLS integration. Certificates come
  from cert-manager in-cluster; WAF, if ever needed, terminates at the external
  traffic manager — which is outside both clouds anyway.
- Envoy Gateway is one more component to upgrade, in two places.
- `Ingress` resources are banned. The portability guard rejects
  `alb.ingress.kubernetes.io` and `cloud.google.com/` in any base.
- Locally there is no cloud load balancer, so the `Gateway` is reached by
  port-forward or NodePort. The manifests are unchanged — only what sits in
  front differs, which is exactly the property being tested.
