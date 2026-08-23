#!/usr/bin/env bash
#
# Portability guard.
#
# The README states that nothing in a base may name a cloud, and that every
# component must exist on every cluster. Rules nobody enforces decay within a
# month, and portability decays *silently* — you find out during a game day,
# which is the expensive place to find out. This turns the rules into a build
# failure.
#
# Applies to apps/ and platform/ alike: a platform component missing from the
# standby is just as fatal to failover as a missing app.
#
# Checks RENDERED output rather than raw files. What matters is what actually
# gets deployed, and rendering drops comments, so prose about AWS/GCP in a
# comment does not trip the guard.
#
#   ./scripts/check-portability.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
fail_count=0
fail() { printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$*"; fail_count=$((fail_count + 1)); }
pass() { printf '  %sok%s   %s\n' "$GREEN" "$OFF" "$*"; }

# platform/* components inflate upstream Helm charts through Kustomize, matching
# what Argo's repo-server does (kustomize.buildOptions in local/argocd-values.yaml).
render() { kubectl kustomize --enable-helm "$1"; }

# CRDs are API *definitions*, not configuration. Their embedded upstream schemas
# document every Kubernetes volume type — awsElasticBlockStore, gcePersistentDisk,
# `aws:kms` — as description text. Those are not deployment decisions and must
# not be treated as portability breaks, so the cloud-name check skips CRD
# documents. Everything an operator actually configures is still checked.
strip_crds() {
  awk 'BEGIN{RS="\n---\n"} !/(^|\n)kind: CustomResourceDefinition/ {print $0 "\n---"}'
}

# Anything that ties a manifest to one cloud. Deliberately broad — a false
# positive costs a comment; a false negative costs a failed failover.
CLOUD_PATTERNS=(
  '\baws\b' '\bamazonaws\b' 'arn:aws' '\beks\b' '\.dkr\.ecr\.'
  'elasticloadbalancing' 'alb\.ingress\.kubernetes\.io' 'eks\.amazonaws\.com'
  '\bgcp\b' 'googleapis\.com' '\bgke\b' '\bgcr\.io\b' '\-docker\.pkg\.dev'
  'cloud\.google\.com/'
  '\b(us|eu|ap|sa|ca|me|af)-(east|west|north|south|central|northeast|southeast)-[0-9]\b'
  '\b(us|europe|asia|australia|northamerica|southamerica)-(east|west|north|south|central|northeast|southeast)[0-9]\b'
)

CLUSTERS=()
while IFS= read -r d; do CLUSTERS+=("$(basename "$d")"); done < <(find clusters -mindepth 1 -maxdepth 1 -type d | sort)

# A component is any apps/<name> or platform/<name> that carries a base/.
COMPONENTS=()
while IFS= read -r d; do COMPONENTS+=("$d"); done < <(find apps platform -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

printf '\n%sclusters:%s   %s\n' "$DIM" "$OFF" "${CLUSTERS[*]}"
printf '%scomponents:%s %s\n\n' "$DIM" "$OFF" "${COMPONENTS[*]}"

# ---------------------------------------------------------------------------
printf '%s1. no cloud-specific values in any base%s\n' "$YELLOW" "$OFF"
# ---------------------------------------------------------------------------
for comp in "${COMPONENTS[@]}"; do
  base="${comp}/base"
  [[ -d "$base" ]] || { fail "${comp}: no base/ directory"; continue; }
  if ! rendered="$(render "$base" 2>/dev/null | strip_crds)" || [[ -z "$rendered" ]]; then
    fail "${comp}: base does not render"$'\n'"$(printf '%s' "$rendered" | head -3 | sed 's/^/      /')"
    continue
  fi
  hits=""
  for pat in "${CLOUD_PATTERNS[@]}"; do
    match="$(printf '%s' "$rendered" | grep -inE "$pat" || true)"
    [[ -n "$match" ]] && hits+="      ${match//$'\n'/$'\n'      }"$'\n'
  done
  if [[ -n "$hits" ]]; then
    fail "${comp}: base names a cloud — portability is broken"
    printf '%s' "$hits" | sort -u
  else
    pass "${comp}: base is cloud-agnostic"
  fi
done

# ---------------------------------------------------------------------------
printf '\n%s2. no registry hostname in any base image%s\n' "$YELLOW" "$OFF"
# ---------------------------------------------------------------------------
# CI pushes every image to both ECR and Artifact Registry, and each cluster
# pulls from its own cloud. That makes the registry an OVERLAY concern: a base
# that hardcodes a registry hostname pins the workload to one cloud.
#
# Upstream charts legitimately ship fully-qualified refs, so platform/ is
# exempt — the rule exists for images we build and publish ourselves.
for comp in "${COMPONENTS[@]}"; do
  [[ "$comp" == apps/* ]] || continue
  base="${comp}/base"
  [[ -d "$base" ]] || continue
  bad=""
  while IFS= read -r img; do
    first="${img%%/*}"
    # A registry hostname is distinguishable by a dot or a port colon in the
    # first path segment. Everything else is a Docker Hub style short ref.
    if [[ "$img" == */* && ( "$first" == *.* || "$first" == *:* ) ]]; then
      bad+="      ${img}"$'\n'
    fi
  done < <(render "$base" 2>/dev/null | grep -oE '^[[:space:]]*-?[[:space:]]*image:[[:space:]]*\S+' | awk '{print $NF}' | sort -u)
  if [[ -n "$bad" ]]; then
    fail "${comp}: base pins a registry — that is an overlay concern"
    printf '%s' "$bad"
  else
    pass "${comp}: base images carry no registry"
  fi
done

# ---------------------------------------------------------------------------
printf '\n%s3. every component deploys to every cluster%s\n' "$YELLOW" "$OFF"
# ---------------------------------------------------------------------------
# A component present on the primary but missing from the standby silently will
# not come back after failover. This is the check that catches it.
#
# A component may be deliberately single-sided, but it must SAY SO. Dropping a
# SINGLE-CLUSTER file in the component directory documents the reason and makes
# the exception reviewable in a PR. Silent asymmetry still fails — the point of
# this check is to catch the overlay someone forgot, not to forbid asymmetry.
for comp in "${COMPONENTS[@]}"; do
  missing=()
  for cluster in "${CLUSTERS[@]}"; do
    [[ -d "${comp}/overlays/${cluster}" ]] || missing+=("$cluster")
  done

  if [[ -f "${comp}/SINGLE-CLUSTER" ]]; then
    present=$(( ${#CLUSTERS[@]} - ${#missing[@]} ))
    if (( present == 0 )); then
      fail "${comp}: declared single-cluster but has no overlay at all"
    else
      pass "${comp}: single-cluster by declaration — $(head -1 "${comp}/SINGLE-CLUSTER")"
    fi
    continue
  fi

  if (( ${#missing[@]} )); then
    fail "${comp}: no overlay for ${missing[*]} — would not survive failover"
    printf '       %sadd a SINGLE-CLUSTER file if this is deliberate%s\n' "$DIM" "$OFF"
  else
    pass "${comp}: present on all ${#CLUSTERS[@]} clusters"
  fi
done

# ---------------------------------------------------------------------------
printf '\n%s4. no overlay targets an unknown cluster%s\n' "$YELLOW" "$OFF"
# ---------------------------------------------------------------------------
# An overlay whose name matches no cluster is dead code: no ApplicationSet
# generator will ever select it, so it looks deployed but never is.
orphans=0
for comp in "${COMPONENTS[@]}"; do
  [[ -d "${comp}/overlays" ]] || continue
  while IFS= read -r d; do
    name="$(basename "$d")"
    known=0
    for cluster in "${CLUSTERS[@]}"; do [[ "$name" == "$cluster" ]] && known=1; done
    (( known )) || { fail "${comp}: overlay '${name}' matches no cluster in clusters/"; orphans=1; }
  done < <(find "${comp}/overlays" -mindepth 1 -maxdepth 1 -type d | sort)
done
(( orphans )) || pass "all overlays map to a real cluster"

# ---------------------------------------------------------------------------
printf '\n%s5. every overlay renders%s\n' "$YELLOW" "$OFF"
# ---------------------------------------------------------------------------
for comp in "${COMPONENTS[@]}"; do
  for cluster in "${CLUSTERS[@]}"; do
    o="${comp}/overlays/${cluster}"
    [[ -d "$o" ]] || continue
    if err="$(render "$o" 2>&1 >/dev/null)"; then
      pass "${comp}/${cluster}"
    else
      fail "${comp}/${cluster} does not render: $(printf '%s' "$err" | head -2)"
    fi
  done
done

# ---------------------------------------------------------------------------
if (( fail_count )); then
  printf '\n%s%d check(s) failed.%s\n\n' "$RED" "$fail_count" "$OFF"
  exit 1
fi
printf '\n%sPortable.%s No base names a cloud; every component reaches every cluster.\n\n' "$GREEN" "$OFF"
