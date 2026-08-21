#!/usr/bin/env bash
#
# Generate writes on the primary so replication lag is something you can watch
# rather than assume.
#
#   ./scripts/db-load.sh [rows]     default 500
#
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME="${RUNTIME:-k3d}"
ROWS="${1:-500}"
PRIMARY_CTX="${RUNTIME}-aws-primary"

printf '\033[1;36m==> Writing %s rows to orders on %s\033[0m\n' "$ROWS" "$PRIMARY_CTX"
kubectl --context "$PRIMARY_CTX" --request-timeout=60s -n postgres exec pg-1 -c postgres -- \
  psql -U postgres -d app -c \
  "INSERT INTO orders(payload) SELECT 'load-'||g FROM generate_series(1, ${ROWS}) g"
