#!/usr/bin/env bash
#
# Portability guard.
#
# The README states that nothing in apps/*/base may name a cloud. A rule nobody
# enforces decays within a month, and portability decays *silently* — you find
# out during a game day, which is the expensive place to find out. This turns
# the rule into a build failure.
#
# Checks the RENDERED output rather than raw files: what matters is what
# actually gets deployed, and rendering drops comments so prose about AWS/GCP
# in a comment does not trip the guard.
#
#   ./scripts/check-portability.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
fail_count=0

fail() { printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$*"; fail_count=$((fail_count + 1)); }
pass() { printf '  %sok%s   %s\n' "$GREEN" "$OFF" "$*"; }

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

APPS=()
while IFS= read -r d; do APPS+=("$(basename "$d")"); done < <(find apps -mindepth 1 -maxdepth 1 -type d | sort)

printf '\n%sclusters:%s %s\n' "$DIM" "$OFF" "${CLUSTERS[*]}"
printf '%sapps:%s     %s\n\n' "$DIM" "$OFF" "${APPS[*]}"

# ---------------------------------------------------------------------------
printf '%s1. no cloud-specific values in any base%s\n' "$YELLOW" "$OFF"
# ---------------------------------------------------------------------------
for app in "${APPS[@]}"; do
  base="apps/${app}/base"
  [[ -d "$base" ]] || { fail "${app}: no base/ directory"; continue; }

  if ! rendered="$(kubectl kustomize "$base" 2>&1)"; then
    fail "${app}: base does not render"$'\n'"${rendered}"
    continue
  fi

  hits=""
  for pat in "${CLOUD_PATTERNS[@]}"; do
    if match="$(printf '%s' "$rendered" | grep -inE "$pat" || true)"; then
      [[ -n "$match" ]] && hits+="      ${match//$'\n'/$'\n'      }"$'\n'
    fi
  done

  if [[ -n "$hits" ]]; then
    fail "${app}: base names a cloud — portability is broken"
    # One line can match several patterns; report it once.
    printf '%s' "$hits" | sort -u
  else
    pass "${app}: base is cloud-agnostic"
  fi
done

# ---------------------------------------------------------------------------
printf '\n%s2. no registry hostname in any base image%s\n' "$YELLOW" "$OFF"
# ---------------------------------------------------------------------------
# CI pushes every image to both ECR and Artifact Registry, and each cluster
# pulls from its own cloud. That makes the registry an OVERLAY concern: a base
# that hardcodes a registry hostname pins the workload to one cloud.
# A bare ref like `traefik/whoami:v1.12.0` is fine — the overlay supplies the
# registry via kustomize's `images:` transformer.
for app in "${APPS[@]}"; do
  base="apps/${app}/base"
  [[ -d "$base" ]] || continue
  bad=""
  while IFS= read -r img; do
    first="${img%%/*}"
    # A registry hostname is distinguishable by a dot or a port colon in the
    # first path segment. Everything else is a Docker Hub style short ref.
    if [[ "$img" == */* && ( "$first" == *.* || "$first" == *:* ) ]]; then
      bad+="      ${img}"$'\n'
    fi
  done < <(kubectl kustomize "$base" 2>/dev/null | grep -oE '^[[:space:]]*-?[[:space:]]*image:[[:space:]]*\S+' | awk '{print $NF}' | sort -u)
  if [[ -n "$bad" ]]; then
    fail "${app}: base pins a registry — that is an overlay concern"
    printf '%s' "$bad"
  else
    pass "${app}: base images carry no registry"
  fi
done

# ---------------------------------------------------------------------------
printf '\n%s3. every app deploys to every cluster%s\n' "$YELLOW" "$OFF"
# ---------------------------------------------------------------------------
# An app present on the primary but missing from the standby is a workload that
# silently will not come back after failover. This is the check that catches it.
for app in "${APPS[@]}"; do
  missing=()
  for cluster in "${CLUSTERS[@]}"; do
    [[ -d "apps/${app}/overlays/${cluster}" ]] || missing+=("$cluster")
  done
  if (( ${#missing[@]} )); then
    fail "${app}: no overlay for ${missing[*]} — would not survive failover"
  else
    pass "${app}: present on all ${#CLUSTERS[@]} clusters"
  fi
done

# ---------------------------------------------------------------------------
printf '\n%s4. no overlay targets an unknown cluster%s\n' "$YELLOW" "$OFF"
# ---------------------------------------------------------------------------
# An overlay whose name matches no cluster is dead code: no ApplicationSet
# generator will ever select it, so it looks deployed but never is.
orphans=0
for app in "${APPS[@]}"; do
  [[ -d "apps/${app}/overlays" ]] || continue
  while IFS= read -r d; do
    name="$(basename "$d")"
    known=0
    for cluster in "${CLUSTERS[@]}"; do [[ "$name" == "$cluster" ]] && known=1; done
    (( known )) || { fail "${app}: overlay '${name}' matches no cluster in clusters/"; orphans=1; }
  done < <(find "apps/${app}/overlays" -mindepth 1 -maxdepth 1 -type d | sort)
done
(( orphans )) || pass "all overlays map to a real cluster"

# ---------------------------------------------------------------------------
printf '\n%s5. every overlay renders%s\n' "$YELLOW" "$OFF"
# ---------------------------------------------------------------------------
for app in "${APPS[@]}"; do
  for cluster in "${CLUSTERS[@]}"; do
    o="apps/${app}/overlays/${cluster}"
    [[ -d "$o" ]] || continue
    if err="$(kubectl kustomize "$o" 2>&1 >/dev/null)"; then
      pass "${app}/${cluster}"
    else
      fail "${app}/${cluster} does not render: ${err}"
    fi
  done
done

# ---------------------------------------------------------------------------
if (( fail_count )); then
  printf '\n%s%d check(s) failed.%s\n\n' "$RED" "$fail_count" "$OFF"
  exit 1
fi
printf '\n%sPortable.%s Base names no cloud; every app reaches every cluster.\n\n' "$GREEN" "$OFF"
