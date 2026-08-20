#!/usr/bin/env bash
#
# Give both clusters the same Postgres application credential.
#
# Logical replication means the subscriber on gcp-secondary opens a normal
# client connection to the publisher on aws-primary. Both sides therefore need
# the same credential, and CNPG generates a different random one per cluster if
# left to itself.
#
# This is the local stand-in for External Secrets Operator: one source of
# truth, propagated to both clusters, never committed. The portability register
# records the real answer (ESO with a single source of truth) — this script is
# the same shape, minus the operator.
#
# Idempotent: generates the password once, then reuses whatever aws-primary
# already has. Re-running will not break an established subscription.
#
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME="${RUNTIME:-k3d}"
NAMESPACE=postgres
SECRET=pg-app-credentials
PRIMARY_CTX="${RUNTIME}-aws-primary"
STANDBY_CTX="${RUNTIME}-gcp-secondary"

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }

ensure_ns() {
  kubectl --context "$1" create namespace "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl --context "$1" apply -f - >/dev/null
}

ensure_ns "$PRIMARY_CTX"
ensure_ns "$STANDBY_CTX"

# Reuse the existing password if there is one — regenerating would invalidate an
# active subscription and look like a replication failure.
if password="$(kubectl --context "$PRIMARY_CTX" -n "$NAMESPACE" \
                 get secret "$SECRET" -o jsonpath='{.data.password}' 2>/dev/null)" \
   && [[ -n "$password" ]]; then
  password="$(printf '%s' "$password" | base64 -d)"
  log "Reusing the existing credential from ${PRIMARY_CTX}"
else
  # Deliberately not `tr -dc ... </dev/urandom | head -c 32`: head closes the
  # pipe, tr takes SIGPIPE, and `set -o pipefail` turns that into a silent
  # exit 141 mid-script. openssl needs no pipeline at all.
  password="$(openssl rand -hex 16)"
  log "Generated a new application credential"
fi

for ctx in "$PRIMARY_CTX" "$STANDBY_CTX"; do
  log "Applying ${SECRET} to ${ctx}"
  kubectl --context "$ctx" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET}
  namespace: ${NAMESPACE}
type: kubernetes.io/basic-auth
stringData:
  username: app
  password: ${password}
EOF
done

log "Both clusters now share the same application credential."
