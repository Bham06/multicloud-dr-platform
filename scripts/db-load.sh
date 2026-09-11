#!/usr/bin/env bash
#
# Generate writes on the primary so replication lag is something you can watch
# rather than assume.
#
#   ./scripts/db-load.sh [rows]         one bulk transaction, default 500
#   ./scripts/db-load.sh --stream [gap] continuous, one commit per row
#
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME="${RUNTIME:-k3d}"
ROWS="${1:-500}"

# Write to whichever cluster is actually the publisher, not to a hardcoded one.
# This said aws-primary, which was true until the first failback reversed the
# direction — after which a load run would have written to the SUBSCRIBER,
# diverging the table that had just been re-seeded from it and manufacturing
# the split brain the drill exists to avoid. The writable side is the one that
# is not subscribing, and the databases know which that is.
sub_on() { # sub_on <cluster>
  kubectl --context "${RUNTIME}-$1" --request-timeout=15s -n postgres exec pg-1 -c postgres -- \
    psql -U postgres -d app -tAc "select count(*) from pg_subscription" 2>/dev/null | tr -d '\r'
}
PRIMARY_CTX=""
for c in aws-primary gcp-secondary; do
  n="$(sub_on "$c")"
  [[ "$n" == "0" ]] && PRIMARY_CTX="${RUNTIME}-${c}"
done
if [[ -z "$PRIMARY_CTX" ]]; then
  echo "Refusing to write: could not identify a cluster that is not subscribing." >&2
  echo "Both sides subscribing, or neither reachable. Check 'make db-status'." >&2
  exit 1
fi

# --stream exists for the game day. A bulk INSERT gives every row the same
# created_at and finishes long before anything fails, so at the moment the
# primary dies there is nothing in flight — both sides agree perfectly and the
# drill measures an RPO of zero that means nothing. Real RPO is only visible if
# writes are still arriving when the lights go out.
#
# One commit per row, paced by psql's \watch over a single long-lived
# connection: no kubectl exec per row, which this substrate could not sustain.
if [[ "${1:-}" == "--stream" ]]; then
  GAP="${2:-0.5}"
  printf '\033[1;36m==> Streaming writes to orders on %s every %ss (Ctrl-C to stop)\033[0m\n' \
    "$PRIMARY_CTX" "$GAP"
  exec kubectl --context "$PRIMARY_CTX" -n postgres exec -i pg-1 -c postgres -- \
    psql -U postgres -d app -tA <<SQL
INSERT INTO orders(payload) VALUES ('drill-'||clock_timestamp());
\watch i=${GAP}
SQL
fi

printf '\033[1;36m==> Writing %s rows to orders on %s\033[0m\n' "$ROWS" "$PRIMARY_CTX"
kubectl --context "$PRIMARY_CTX" --request-timeout=60s -n postgres exec pg-1 -c postgres -- \
  psql -U postgres -d app -c \
  "INSERT INTO orders(payload) SELECT 'load-'||g FROM generate_series(1, ${ROWS}) g"
