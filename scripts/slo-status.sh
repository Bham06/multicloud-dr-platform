#!/usr/bin/env bash
#
# SLO burn rate, error budget and firing alerts.
#
# Prometheus runs on the passive side (see platform/prometheus/SINGLE-CLUSTER),
# so this port-forwards into gcp-secondary rather than reading a local endpoint.
#
#   ./scripts/slo-status.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME="${RUNTIME:-k3d}"
CTX="${RUNTIME}-gcp-secondary"
PORT=19090
BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YEL=$'\033[0;33m'; OFF=$'\033[0m'

kubectl --context "$CTX" -n prometheus port-forward svc/prometheus-server "${PORT}:80" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do
  curl -sf "localhost:${PORT}/-/ready" >/dev/null 2>&1 && break
  sleep 1
done

q() { curl -sG --data-urlencode "query=$1" "localhost:${PORT}/api/v1/query" 2>/dev/null; }

printf '\n%s  SLOs%s  %s(evaluated on %s)%s\n\n' "$BOLD" "$OFF" "$DIM" "$CTX" "$OFF"

q 'slo:objective:ratio' | python3 -c '
import sys, json, subprocess, urllib.parse, urllib.request

def query(expr):
    url = "http://localhost:'"$PORT"'/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    try:
        return json.load(urllib.request.urlopen(url, timeout=10))["data"]["result"]
    except Exception:
        return []

objectives = {m["metric"]["sloth_slo"]: float(m["value"][1]) for m in query("slo:objective:ratio")}
budget     = {m["metric"]["sloth_slo"]: float(m["value"][1]) for m in query("slo:period_error_budget_remaining:ratio")}
burn       = {m["metric"]["sloth_slo"]: float(m["value"][1]) for m in query("slo:current_burn_rate:ratio")}
sli5m      = {m["metric"]["sloth_slo"]: float(m["value"][1]) for m in query("slo:sli_error:ratio_rate5m")}

if not objectives:
    print("  no SLO recording rules have produced data yet")
    print("  (Sloth windows start at 5m — give it a few minutes after first deploy)")
else:
    print(f"  {\x27SLO\x27:<26}{\x27TARGET\x27:>8}{\x27ERR 5m\x27:>10}{\x27BURN\x27:>9}{\x27BUDGET LEFT\x27:>14}")
    for name in sorted(objectives):
        tgt = objectives[name] * 100
        err = sli5m.get(name)
        br  = burn.get(name)
        bl  = budget.get(name)
        errs = f"{err*100:.2f}%" if err is not None else "-"
        brs  = f"{br:.2f}x"      if br  is not None else "-"
        bls  = f"{bl*100:.1f}%"  if bl  is not None else "-"
        flag = ""
        if br is not None and br > 1: flag = " \033[0;33m<- burning\033[0m"
        if bl is not None and bl < 0: flag = " \033[0;31m<- budget exhausted\033[0m"
        print(f"  {name:<26}{tgt:>7.1f}%{errs:>10}{brs:>9}{bls:>14}{flag}")
' 2>/dev/null || printf '  %sPrometheus not reachable%s\n' "$RED" "$OFF"

echo
firing="$(q 'ALERTS{alertstate="firing"}' | python3 -c '
import sys, json
try:
    r = json.load(sys.stdin)["data"]["result"]
except Exception:
    r = []
for m in r:
    lb = m["metric"]
    print(f"{lb.get(\x27alertname\x27,\x27?\x27)}|{lb.get(\x27severity\x27,\x27-\x27)}|{lb.get(\x27sloth_slo\x27,\x27-\x27)}")
' 2>/dev/null || true)"

if [[ -n "$firing" ]]; then
  printf '  %sFIRING%s\n' "$RED" "$OFF"
  while IFS='|' read -r name sev slo; do
    [[ -n "$name" ]] && printf '    %s%-24s%s severity=%-7s slo=%s\n' "$RED" "$name" "$OFF" "$sev" "$slo"
  done <<< "$firing"
else
  printf '  %sNo alerts firing.%s\n' "$GREEN" "$OFF"
fi
echo
