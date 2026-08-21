#!/usr/bin/env bash
#
# Find every sequence whose value has diverged from the data it is supposed to
# generate, and emit the setval statements that repair them.
#
# Logical replication carries rows, not sequence values, so on a subscriber
# every sequence-backed column is divergent by construction. Promoting without
# repairing them produces duplicate-key failures that SELF-HEAL after
# max(id) - last_value attempts — which means the incident disappears before
# anyone diagnoses it, taking the lost writes with it.
#
# Hand-writing `setval` per table does not scale and is the thing people get
# wrong: a real schema has dozens of sequences, you fix the two you remember,
# and the third fails weeks later. This walks pg_depend so nothing is missed.
#
#   ./scripts/check-sequences.sh                 # report against the standby
#   ./scripts/check-sequences.sh --apply         # repair them
#   ./scripts/check-sequences.sh --cluster aws-primary
#
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME="${RUNTIME:-k3d}"
CLUSTER="gcp-secondary"
APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)   APPLY=1; shift ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
CTX="${RUNTIME}-${CLUSTER}"
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; OFF=$'\033[0m'

psql_() { kubectl --context "$CTX" --request-timeout=30s -n postgres exec pg-1 -c postgres -- psql -U postgres -d app "$@" 2>&1; }

# Walk pg_depend for sequences owned by a column (deptype 'a' = auto), which
# covers serial/bigserial and GENERATED ... AS IDENTITY alike.
REPORT_SQL=$(cat <<'SQL'
CREATE TEMP TABLE seq_report(seq text, owner_col text, last_value bigint, max_value bigint) ON COMMIT DROP;
DO $$
DECLARE r record; sv bigint; mv bigint;
BEGIN
  FOR r IN
    SELECT ns.nspname AS sch, seq.relname AS seqname,
           tab.relname AS tabname, att.attname AS colname
    FROM pg_class seq
    JOIN pg_namespace ns ON ns.oid = seq.relnamespace
    JOIN pg_depend d  ON d.objid = seq.oid AND d.classid = 'pg_class'::regclass AND d.deptype = 'a'
    JOIN pg_class tab ON tab.oid = d.refobjid
    JOIN pg_attribute att ON att.attrelid = tab.oid AND att.attnum = d.refobjsubid
    WHERE seq.relkind = 'S'
    ORDER BY 1,2
  LOOP
    EXECUTE format('SELECT last_value FROM %I.%I', r.sch, r.seqname) INTO sv;
    EXECUTE format('SELECT COALESCE(max(%I),0) FROM %I.%I', r.colname, r.sch, r.tabname) INTO mv;
    INSERT INTO seq_report VALUES (r.sch||'.'||r.seqname, r.tabname||'.'||r.colname, sv, mv);
  END LOOP;
END $$;
SELECT seq||'|'||owner_col||'|'||last_value||'|'||max_value||'|'||
       CASE WHEN last_value < max_value THEN 'DIVERGED' ELSE 'ok' END
FROM seq_report ORDER BY seq;
SQL
)

printf '\n%s  sequences%s   %s%s%s\n\n' "$BOLD" "$OFF" "$DIM" "$CTX" "$OFF"
rows="$(psql_ -tA -c "BEGIN; ${REPORT_SQL} COMMIT;" | grep '|' || true)"

if [[ -z "$rows" ]]; then
  printf '  no sequence-backed columns found\n\n'; exit 0
fi

printf '  %-24s %-20s %10s %10s\n' "SEQUENCE" "OWNING COLUMN" "CURRENT" "MAX DATA"
diverged=0
while IFS='|' read -r seq col last max status; do
  [[ -n "$seq" ]] || continue
  if [[ "$status" == "DIVERGED" ]]; then
    printf '  %-24s %-20s %10s %10s  %sDIVERGED%s\n' "$seq" "$col" "$last" "$max" "$RED" "$OFF"
    diverged=$((diverged+1))
  else
    printf '  %-24s %-20s %10s %10s  %sok%s\n' "$seq" "$col" "$last" "$max" "$GREEN" "$OFF"
  fi
done <<< "$rows"

if (( diverged == 0 )); then
  printf '\n  %sAll sequences ahead of their data.%s Safe to accept writes.\n\n' "$GREEN" "$OFF"; exit 0
fi

# setval's third argument is is_called: true means "next value is last_value+1".
# For an empty table we want setval(seq, 1, false) so numbering restarts at 1.
FIX_SQL="$(psql_ -tA -c "BEGIN; ${REPORT_SQL} COMMIT;" \
  | grep 'DIVERGED' \
  | awk -F'|' '{printf "SELECT setval('\''%s'\'', GREATEST(%s, 1), %s);\n", $1, $4, ($4>0 ? "true" : "false")}')"

printf '\n  %s%d sequence(s) would produce duplicate-key failures on the first write.%s\n\n' "$RED" "$diverged" "$OFF"
printf '%s\n' "$FIX_SQL" | sed 's/^/      /'

if (( APPLY )); then
  printf '\n  %sApplying...%s\n' "$BOLD" "$OFF"
  psql_ -q -c "$FIX_SQL" >/dev/null
  printf '  %sRepaired.%s Re-run without --apply to confirm.\n\n' "$GREEN" "$OFF"
else
  printf '\n  %sDry run.%s Re-run with --apply to repair.\n\n' "$DIM" "$OFF"
fi
