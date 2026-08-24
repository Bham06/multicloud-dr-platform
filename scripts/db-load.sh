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
PRIMARY_CTX="${RUNTIME}-aws-primary"

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
