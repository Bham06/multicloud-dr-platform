#!/usr/bin/env bash
#
# Stand up the local substrate: two independent clusters, each running its own
# Argo CD, each pulling its own overlay from Git.
#
# These two clusters stand in for EKS (aws-primary) and GKE (gcp-secondary).
# The same manifests must apply cleanly here AND against the real clusters that
# `make burst-up` provisions — that equivalence IS the portability test.
#
#   RUNTIME=k3d ./local/bootstrap.sh          # default, lighter
#   RUNTIME=kind ./local/bootstrap.sh
#   ./local/bootstrap.sh aws-primary          # just one cluster
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

RUNTIME="${RUNTIME:-k3d}"

# Installed via Helm rather than `kubectl apply -f <raw.githubusercontent URL>`:
# that URL is rate-limited (observed HTTP 429), which would fail the bootstrap
# non-deterministically. The chart also lets us trim components declaratively.
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.3.3}"   # -> Argo CD v3.5.1

CLUSTERS=("${@:-}")
if [[ -z "${CLUSTERS[0]}" ]]; then
  CLUSTERS=(aws-primary gcp-secondary)
fi

# ---------------------------------------------------------------------------
# Where Argo pulls from. Argo runs inside a container, so a host path will not
# work — the repo has to be reachable over the network.
# ---------------------------------------------------------------------------
REPO_URL="${REPO_URL:-$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)}"
if [[ -z "$REPO_URL" ]]; then
  cat >&2 <<'EOF'
ERROR: no Git remote found and REPO_URL is unset.

Argo CD pulls desired state over the network; it cannot read your working copy.
Either push this repo and set an origin:

    gh repo create multicloud-dr --private --source=. --remote=origin --push

...or point at an existing remote:

    REPO_URL=https://github.com/<you>/multicloud-dr.git ./local/bootstrap.sh
EOF
  exit 1
fi

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# Cluster creation
# ---------------------------------------------------------------------------
create_k3d() {
  local name="$1"
  if k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${name}\""; then
    log "k3d cluster '${name}' already exists — skipping create"
    return
  fi
  log "Creating k3d cluster '${name}'"
  # traefik/servicelb/metrics-server are k3s conveniences that neither EKS nor
  # GKE gives you. Disabling them keeps the local substrate honest (and saves
  # ~150MB per cluster).
  k3d cluster create "$name" \
    --servers 1 --agents 0 \
    --no-lb \
    --k3s-arg "--disable=traefik@server:*" \
    --k3s-arg "--disable=servicelb@server:*" \
    --k3s-arg "--disable=metrics-server@server:*" \
    --wait
}

create_kind() {
  local name="$1"
  if kind get clusters 2>/dev/null | grep -qx "$name"; then
    log "kind cluster '${name}' already exists — skipping create"
    return
  fi
  log "Creating kind cluster '${name}'"
  kind create cluster --name "$name" --config "local/kind/${name}.yaml" --wait 120s
}

context_for() {
  case "$RUNTIME" in
    k3d)  echo "k3d-$1" ;;
    kind) echo "kind-$1" ;;
    *)    echo "unsupported RUNTIME '$RUNTIME' (want k3d or kind)" >&2; exit 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Argo CD
# ---------------------------------------------------------------------------
install_argocd() {
  local ctx="$1"

  log "[$ctx] Installing Argo CD (chart ${ARGOCD_CHART_VERSION})"
  # --wait blocks until every workload is Ready, so no separate rollout polling.
  helm --kube-context "$ctx" upgrade --install argocd argo/argo-cd \
    --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd --create-namespace \
    --values platform/argocd/values.yaml \
    --wait --timeout 10m
}

apply_root() {
  local ctx="$1" cluster="$2"
  log "[$ctx] Applying root ApplicationSet (repo: $REPO_URL)"
  # The committed YAML stays portable; the concrete repo URL is injected here.
  sed "s|__REPO_URL__|${REPO_URL}|g" "clusters/${cluster}/apps.yaml" \
    | kubectl --context "$ctx" apply -f -
}

# ---------------------------------------------------------------------------
log "Ensuring the argo Helm repo is present"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

for cluster in "${CLUSTERS[@]}"; do
  case "$RUNTIME" in
    k3d)  create_k3d  "$cluster" ;;
    kind) create_kind "$cluster" ;;
    *)    echo "unsupported RUNTIME '$RUNTIME' (want k3d or kind)" >&2; exit 1 ;;
  esac

  ctx="$(context_for "$cluster")"
  install_argocd "$ctx"
  apply_root "$ctx" "$cluster"
done

log "Done. Expected steady state:"
cat <<EOF

  aws-primary    demo-api  2/2 running   (active)
  gcp-secondary  demo-api  0/0 running   (pilot light — Deployment exists, scaled to zero)

Check it:

  make status

Admin password for either cluster:

  kubectl --context $(context_for aws-primary) -n argocd \\
    get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

EOF
