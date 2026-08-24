#!/usr/bin/env bash
#
# SLO burn rate, error budget and firing alerts.
#
# Prometheus runs on the passive side (platform/prometheus/SINGLE-CLUSTER), so
# this port-forwards into gcp-secondary rather than reading a local endpoint.
#
#   ./scripts/slo-status.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME="${RUNTIME:-k3d}"
CTX="${RUNTIME}-gcp-secondary"
PORT="${PORT:-19090}"

kubectl --context "$CTX" -n prometheus port-forward svc/prometheus-server "${PORT}:80" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 25); do
  curl -sf "localhost:${PORT}/-/ready" >/dev/null 2>&1 && break
  sleep 1
done

PORT="$PORT" python3 <<'PY'
import json, os, urllib.parse, urllib.request

PORT = os.environ["PORT"]
BOLD, DIM, RED, GRN, YEL, OFF = "\033[1m", "\033[2m", "\033[0;31m", "\033[0;32m", "\033[0;33m", "\033[0m"

def query(expr):
    url = f"http://localhost:{PORT}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    try:
        return json.load(urllib.request.urlopen(url, timeout=10))["data"]["result"]
    except Exception:
        return []

def by_slo(expr):
    out = {}
    for m in query(expr):
        name = m["metric"].get("sloth_slo")
        try:
            v = float(m["value"][1])
        except (TypeError, ValueError):
            continue
        # A stale series from a previous rule version can linger alongside the
        # current one. Prefer any real number over NaN.
        if name not in out or out[name] != out[name]:
            out[name] = v
    return out

print(f"\n{BOLD}  SLOs{OFF}  {DIM}(evaluated on k3d-gcp-secondary){OFF}\n")

obj    = by_slo("slo:objective:ratio")
err5m  = by_slo("slo:sli_error:ratio_rate5m")
burn   = by_slo("slo:current_burn_rate:ratio")
budget = by_slo("slo:period_error_budget_remaining:ratio")

# How much of the SLO period does the evaluator actually have data for?
#
# slo:period_error_budget_remaining averages over the SLO period (30d). This
# Prometheus is a short-retention evaluator, so early on that window is almost
# entirely empty and the budget is a correct calculation over data that does
# not exist. Printing it anyway produces a permanently-red column, and a gate
# that is always red is a gate everyone learns to ignore — which is exactly the
# gate the M5 game day depends on.
#
# So: measure coverage, and refuse to print a budget that is not yet earned.
period_days = by_slo("slo:time_period:days")
samples     = by_slo("count_over_time(slo:sli_error:ratio_rate5m[30d])")
interval_s  = 15  # rule group evaluation interval

def coverage(name):
    days, n = period_days.get(name), samples.get(name)
    if not days or n is None:
        return None
    return (n * interval_s) / (days * 86400)

COVERAGE_FLOOR = 0.90

if not obj:
    print("  no SLO recording rules have produced data yet")
    print(f"  {DIM}Sloth's shortest window is 5m — allow a few minutes after deploy{OFF}")
else:
    insufficient = []
    print(f"  {'SLO':<26}{'TARGET':>8}{'ERR 5m':>10}{'BURN':>9}{'BUDGET LEFT':>14}")
    for name in sorted(obj):
        e, b, bl = err5m.get(name), burn.get(name), budget.get(name)
        cov = coverage(name)
        fmt = lambda v, s: s.format(v) if v is not None and v == v else "-"

        # Suppress the budget until there is enough history to mean anything.
        if cov is not None and cov < COVERAGE_FLOOR:
            bls, flag = f"{DIM}n/a{OFF}", ""
            insufficient.append((name, cov))
        else:
            bls = fmt(bl, "{:.1%}")
            flag = ""
            if bl is not None and bl == bl and bl < 0:
                flag = f" {RED}<- budget exhausted{OFF}"

        if b is not None and b == b and b > 1 and not flag:
            flag = f" {YEL}<- burning{OFF}"

        pad = 14 + (len(bls) - len(bls.replace(DIM, "").replace(OFF, "")))
        print(f"  {name:<26}{obj[name]*100:>7.1f}%"
              f"{fmt(e, '{:.2%}'):>10}{fmt(b, '{:.2f}x'):>9}{bls:>{pad}}{flag}")

    if insufficient:
        worst = min(c for _, c in insufficient)
        days = list(period_days.values())[0] if period_days else 30
        print()
        print(f"  {DIM}Budget shown as n/a: the evaluator holds {worst*100:.2f}% of the "
              f"{days:.0f}d SLO period.{OFF}")
        print(f"  {DIM}Burn rate and the short-window error ratios are the signals to "
              f"trust here.{OFF}")

print()
firing = query('ALERTS{alertstate="firing"}')
if firing:
    print(f"  {RED}FIRING{OFF}")
    for m in firing:
        lb = m["metric"]
        print(f"    {RED}{lb.get('alertname','?'):<24}{OFF} "
              f"severity={lb.get('severity','-'):<7} slo={lb.get('sloth_slo','-')}")
else:
    print(f"  {GRN}No alerts firing.{OFF}")
print()
PY
