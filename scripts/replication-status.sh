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

# This tool's entire job is to run during an incident, so it must survive one
# side being gone. It did not: with `set -e`, a failed kubectl inside a command
# substitution aborted the script at the first primary query, and the operator
# got `make: *** [db-status] Error 1` and NOTHING else — no numbers, no reason,
# from the gate the runbook tells you to consult before promoting. Found in the
# M5 game day, at exactly the moment it was needed.
q() { # q <context> <sql>
  kubectl --context "$1" --request-timeout=25s -n postgres exec pg-1 -c postgres -- \
    psql -U postgres -d app -tAc "$2" 2>/dev/null | tr -d '\r' || true
}

reachable() { kubectl --context "$1" --request-timeout=10s get --raw /readyz >/dev/null 2>&1; }

P_UP=1; S_UP=1
reachable "$PRIMARY_CTX" || P_UP=0
reachable "$STANDBY_CTX" || S_UP=0

# "unknown" and "equal" are different things, and conflating them is how a tool
# reports a healthy failover that lost data.
UNK="${DIM}?${OFF}"
pq() { if (( P_UP )); then q "$PRIMARY_CTX" "$1"; fi; }
sq() { if (( S_UP )); then q "$STANDBY_CTX" "$1"; fi; }
fmt() { [[ -n "$1" ]] && printf '%s' "$1" || printf '%s' "?"; }

p_rows=$(pq "select count(*) from orders")
s_rows=$(sq "select count(*) from orders")
p_max=$(pq  "select coalesce(max(id),0) from orders")
s_max=$(sq  "select coalesce(max(id),0) from orders")
p_seq=$(pq  "select last_value from orders_id_seq")
s_seq=$(sq  "select last_value from orders_id_seq")
slot=$(pq   "select (case when active then 'yes' else 'no' end)||'|'||coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn),0)::text from pg_replication_slots where slot_type='logical' limit 1")
sub=$(sq    "select (case when st.pid is not null then 'yes' else 'no' end)||'|'||coalesce(round(extract(epoch from (now()-st.latest_end_time))::numeric,2),0)::text from pg_subscription s left join pg_stat_subscription st on st.subid=s.oid limit 1")

# An empty result means the query failed, which must not read as "healthy".
[[ -n "$slot" ]] || slot="unknown|?"
[[ -n "$sub"  ]] || sub="unknown|?"
slot_active="${slot%%|*}"; slot_lag="${slot##*|}"
sub_up="${sub%%|*}";       sub_lag="${sub##*|}"

printf '\n%s  replication%s   %saws-primary -> gcp-secondary%s\n\n' "$BOLD" "$OFF" "$DIM" "$OFF"

if (( ! P_UP )) || (( ! S_UP )); then
  down=aws-primary; (( P_UP )) && down=gcp-secondary
  printf '  %s%sCLUSTER UNREACHABLE: %s%s\n' "$RED" "$BOLD" "$down" "$OFF"
  printf '  %sIts numbers below are unknown, not zero and not equal. Everything else\n' "$DIM"
  printf '  is the surviving side reporting on itself — which is all you get during\n'
  printf '  a real regional failure, and is enough to make the RPO call.%s\n\n' "$OFF"
fi

printf '  %-22s %14s %14s\n' "" "aws-primary" "gcp-secondary"
printf '  %-22s %14s %14s\n' "rows in orders" "$(fmt "$p_rows")" "$(fmt "$s_rows")"
printf '  %-22s %14s %14s\n' "max(id)" "$(fmt "$p_max")" "$(fmt "$s_max")"
printf '  %-22s %14s %14s' "orders_id_seq" "$(fmt "$p_seq")" "$(fmt "$s_seq")"
if [[ -n "$p_seq" && -n "$s_seq" && "$p_seq" != "$s_seq" ]]; then
  printf '   %s<- diverged%s\n' "$RED" "$OFF"
else
  printf '\n'
fi
echo

# The freshness signal that does NOT depend on the primary existing. This is the
# RPO decision during a real outage: how old is the newest row we actually hold,
# and how long since the publisher last said anything.
if (( S_UP )); then
  age=$(sq "select coalesce(round(extract(epoch from (now()-max(created_at)))::numeric,1)::text,'-') from orders")
  contact=$(sq "select coalesce(round(extract(epoch from (now()-st.latest_end_time))::numeric,1)::text,'-') from pg_subscription s left join pg_stat_subscription st on st.subid=s.oid limit 1")
  printf '  %-22s %ss  %snewest row the standby holds%s\n' "standby data age" "$(fmt "$age")" "$DIM" "$OFF"
  if [[ -z "$contact" || "$contact" == "-" ]]; then
    printf '  %-22s %snone%s  %sno subscription on this side — it is promoted, or never subscribed%s\n\n' \
      "last publisher contact" "$YEL" "$OFF" "$DIM" "$OFF"
  else
    printf '  %-22s %ss  %ssince the publisher last sent anything%s\n\n' \
      "last publisher contact" "$contact" "$DIM" "$OFF"
  fi
fi

# The slot lives on the PRIMARY. If the primary did not answer, its state is
# unknown — printing INACTIVE would be inventing a fact from silence, which is
# the same mistake as printing "healthy" from silence, just pointed the other
# way. A DR tool that fabricates either direction cannot be trusted mid-incident.
if (( ! P_UP )); then
  printf '  slot        %sunknown%s  — the primary did not answer; its slot state cannot be read\n' "$YEL" "$OFF"
elif [[ "$slot_active" == "yes" ]]; then
  printf '  slot        %sactive%s   lag %s bytes\n' "$GREEN" "$OFF" "$slot_lag"
else
  printf '  slot        %sINACTIVE%s  — publisher is retaining WAL for a subscriber that is not reading it\n' "$RED" "$OFF"
fi

if (( ! S_UP )); then
  printf '  subscriber  %sunknown%s  — the standby did not answer\n' "$YEL" "$OFF"
elif [[ "$sub_up" == "yes" ]]; then
  printf '  subscriber  %sup%s       lag %ss\n' "$GREEN" "$OFF" "$sub_lag"
elif [[ "$sub_up" == "unknown" ]]; then
  # No subscription row at all. Expected on a promoted node — the failover
  # drops it — and alarming anywhere else.
  printf '  subscriber  %snone%s     — no subscription exists here (promoted, or never configured)\n' "$YEL" "$OFF"
else
  printf '  subscriber  %sDOWN%s     — the standby is silently falling behind\n' "$RED" "$OFF"
fi

if [[ -z "$p_rows" || -z "$s_rows" ]]; then
  printf '\n  %sCannot compare%s — one side did not answer. Judge the standby on its own\n' "$YEL" "$OFF"
  printf '  data age above, never on row counts matching.\n'
elif [[ "$p_rows" == "$s_rows" ]]; then
  printf '\n  %sIn sync%s — %s rows on both sides.\n' "$GREEN" "$OFF" "$p_rows"
  printf '  %sRow equality is not a health check: with no writes in flight both sides\n' "$DIM"
  printf '  agree perfectly while replication is dead. Read the slot and subscriber\n'
  printf '  lines above.%s\n' "$OFF"
else
  printf '\n  %sDivergent%s — %s rows on the primary, %s on the standby.\n' "$YEL" "$OFF" "$p_rows" "$s_rows"
fi

# ---------------------------------------------------------------------------
# The trap that makes a failover look successful and then corrupt on write.
# ---------------------------------------------------------------------------
# The question is NOT whether the two sequences differ — they always do, because
# logical replication does not carry sequence values. It is whether the standby's
# sequence is behind the standby's OWN data, which is what actually collides on
# the first write. Comparing the two sequences to each other looked correct
# before a failover, when they happened to coincide, and produced a
# self-contradictory false alarm immediately after one ("still at 1912 while its
# table already holds ids up to 1912"). check-sequences.sh had it right; this
# script had quietly reimplemented it wrong.
if [[ -n "$s_seq" && -n "$s_max" ]] && (( s_seq < s_max )); then
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
