#!/usr/bin/env bash
#
# One view of replication health across both clusters.
#
# Built for the M5 game day: before promoting anything you need to know
# whether lag is inside RPO, and afterwards you need to know whether the
# promotion actually carried the data.
#
#   ./scripts/replication-status.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME="${RUNTIME:-k3d}"
PRIMARY_CTX="${RUNTIME}-aws-primary"
STANDBY_CTX="${RUNTIME}-gcp-secondary"
BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YEL=$'\033[0;33m'; OFF=$'\033[0m'

q() { # q <context> <sql>
  kubectl --context "$1" --request-timeout=25s -n postgres exec pg-1 -c postgres -- \
    psql -U postgres -d app -tAc "$2" 2>/dev/null | tr -d '\r'
}

p_rows=$(q "$PRIMARY_CTX" "select count(*) from orders")
s_rows=$(q "$STANDBY_CTX" "select count(*) from orders")
p_max=$(q  "$PRIMARY_CTX" "select coalesce(max(id),0) from orders")
s_max=$(q  "$STANDBY_CTX" "select coalesce(max(id),0) from orders")
p_seq=$(q  "$PRIMARY_CTX" "select last_value from orders_id_seq")
s_seq=$(q  "$STANDBY_CTX" "select last_value from orders_id_seq")
slot=$(q   "$PRIMARY_CTX" "select (case when active then 'yes' else 'no' end)||'|'||coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn),0)::text from pg_replication_slots where slot_type='logical' limit 1")
sub=$(q    "$STANDBY_CTX" "select (case when st.pid is not null then 'yes' else 'no' end)||'|'||coalesce(round(extract(epoch from (now()-st.latest_end_time))::numeric,2),0)::text from pg_subscription s left join pg_stat_subscription st on st.subid=s.oid limit 1")

# An empty result means the query failed, which must not read as "healthy".
[[ -n "$slot" ]] || slot="unknown|?"
[[ -n "$sub"  ]] || sub="unknown|?"
slot_active="${slot%%|*}"; slot_lag="${slot##*|}"
sub_up="${sub%%|*}";       sub_lag="${sub##*|}"

printf '\n%s  replication%s   %saws-primary -> gcp-secondary%s\n\n' "$BOLD" "$OFF" "$DIM" "$OFF"
printf '  %-22s %14s %14s\n' "" "aws-primary" "gcp-secondary"
printf '  %-22s %14s %14s\n' "rows in orders" "$p_rows" "$s_rows"
printf '  %-22s %14s %14s\n' "max(id)" "$p_max" "$s_max"
printf '  %-22s %14s %14s' "orders_id_seq" "$p_seq" "$s_seq"
if [[ "$p_seq" != "$s_seq" ]]; then printf '   %s<- diverged%s\n' "$RED" "$OFF"; else printf '\n'; fi
echo

if [[ "$slot_active" == "yes" ]]; then
  printf '  slot        %sactive%s   lag %s bytes\n' "$GREEN" "$OFF" "$slot_lag"
else
  printf '  slot        %sINACTIVE%s  — publisher is retaining WAL for a subscriber that is not reading it\n' "$RED" "$OFF"
fi
if [[ "$sub_up" == "yes" ]]; then
  printf '  subscriber  %sup%s       lag %ss\n' "$GREEN" "$OFF" "$sub_lag"
else
  printf '  subscriber  %sDOWN%s     — the standby is silently falling behind\n' "$RED" "$OFF"
fi

if [[ "$p_rows" == "$s_rows" ]]; then
  printf '\n  %sIn sync%s — %s rows on both sides.\n' "$GREEN" "$OFF" "$p_rows"
else
  printf '\n  %sDivergent%s — %s rows on the primary, %s on the standby.\n' "$YEL" "$OFF" "$p_rows" "$s_rows"
fi

# ---------------------------------------------------------------------------
# The trap that makes a failover look successful and then corrupt on write.
# ---------------------------------------------------------------------------
if [[ "$p_seq" != "$s_seq" ]]; then
  cat <<EOF

  ${RED}${BOLD}Sequence divergence — this breaks failover.${OFF}
  Logical replication carries rows, not sequence values. The standby's
  orders_id_seq is still at ${s_seq} while its table already holds ids up to
  ${s_max}. Promote it as-is and the first INSERT tries id=$((s_seq + 1)),
  colliding with a row that replication already delivered.

  The promotion step must run:
      SELECT setval('orders_id_seq', (SELECT max(id) FROM orders));

  This is why failover is a runbook and not a replica count.
EOF
fi
echo
