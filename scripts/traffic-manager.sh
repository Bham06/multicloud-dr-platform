#!/usr/bin/env bash
#
# The external traffic manager — the thing that decides which cloud user
# traffic lands in, deliberately running OUTSIDE both clusters.
#
# This is the piece the portability register marks ACCEPTED/deliberate: not
# Route 53 and not Cloud DNS, because a DR mechanism that lives inside the
# primary shares a failure domain with the thing that is failing. February's
# superseded attempt put the trigger in a Cloud Function inside the primary and
# that is precisely the mistake being avoided here.
#
# Locally it is an nginx container on the dr-interconnect network — the same
# network that stands in for the AWS<->GCP VPN. It is attached to neither
# cluster, so `docker stop`ping a cluster does not touch it.
#
# TWO PIECES ARE LOCAL STAND-INS FOR CLOUD INFRASTRUCTURE, and neither is in
# Git on purpose:
#
#   1. The nginx container itself stands in for the out-of-cloud traffic
#      manager. In production this is a managed anycast edge.
#   2. A NodePort Service in each cluster stands in for the cloud L4 address
#      (NLB / GCP forwarding rule). ADR 0001 puts that address in Terraform,
#      outside the cluster, and ADR 0004 says the local Gateway is reached by
#      port-forward or NodePort for exactly this reason. Putting it in
#      apps/demo-api/base would push a local-substrate detail into manifests
#      that must apply unchanged to EKS and GKE.
#
# Both are applied imperatively, the same way local/bootstrap.sh creates the
# interconnect network. The GitOps manifests stay identical across clouds,
# which is the property the whole repo exists to protect.
#
# THERE IS NO AUTOMATIC FAILOVER HERE, and that is a design decision rather
# than an omission. nginx is configured with ONE upstream, not a health-checked
# pool: an active-passive data tier must never be failed over by a timeout.
# A human declares the disaster; `switch` is the scripted step that follows.
#
#   ./scripts/traffic-manager.sh up                     # provision + start
#   ./scripts/traffic-manager.sh status                 # who is active, who is healthy
#   ./scripts/traffic-manager.sh switch gcp-secondary   # the cutover
#   ./scripts/traffic-manager.sh probe                  # CSV to stdout until killed
#   ./scripts/traffic-manager.sh analyze probe.csv      # outage window from a probe log
#   ./scripts/traffic-manager.sh down
#
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME="${RUNTIME:-k3d}"
NETWORK="${INTERCONNECT:-dr-interconnect}"
CONTAINER="${TM_CONTAINER:-dr-traffic-manager}"
IMAGE="${TM_IMAGE:-nginx:1.27-alpine}"
PUBLIC_PORT="${TM_PORT:-8088}"
EDGE_NODEPORT="${TM_NODEPORT:-30080}"
PUBLIC_URL="http://127.0.0.1:${PUBLIC_PORT}"
# Static, because Prometheus scrapes this address from inside gcp-secondary and
# a static_config cannot chase a DHCP lease. .10 and .20 are the two clusters.
TM_ADDR="${TM_ADDR:-172.30.0.30}"
METRICS_PORT="${TM_METRICS_PORT:-9101}"
METRICS_URL="http://127.0.0.1:${METRICS_PORT}/metrics"

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YEL=$'\033[0;33m'; OFF=$'\033[0m'

SITES=(aws-primary gcp-secondary)

# Static addresses assigned by local/bootstrap.sh's setup_interconnect().
site_addr() {
  case "$1" in
    aws-primary)   echo 172.30.0.10 ;;
    gcp-secondary) echo 172.30.0.20 ;;
    *) echo "unknown site '$1' (want aws-primary or gcp-secondary)" >&2; return 2 ;;
  esac
}
ctx_for() { echo "${RUNTIME}-$1"; }

# ---------------------------------------------------------------------------
# Provisioning
# ---------------------------------------------------------------------------
ensure_edge() { # ensure_edge <site>
  local site="$1" ctx; ctx="$(ctx_for "$site")"
  kubectl --context "$ctx" --request-timeout=25s apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: demo-api-edge
  namespace: demo-api
  annotations:
    dr.local/stand-in: "cloud L4 address (NLB / GCP forwarding rule) — see ADR 0001"
spec:
  type: NodePort
  selector:
    app: demo-api
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: ${EDGE_NODEPORT}
EOF
  printf '  %s edge ready on %s:%s\n' "$site" "$(site_addr "$site")" "$EDGE_NODEPORT"
}

write_conf() { # write_conf <active-site>
  local site="$1" addr; addr="$(site_addr "$site")"
  cat <<EOF
# active-site: ${site}
events {}
http {
  log_format drill '\$time_iso8601 \$status \$upstream_addr \$request_time';
  access_log /dev/stdout drill;
  error_log  /dev/stderr warn;

  server {
    listen 8080;

    # ONE upstream, named explicitly. Not a health-checked pool — see the
    # header: automatic cross-cloud failover invites split brain on the data
    # tier, which is worse than the outage it prevents.
    location / {
      proxy_pass http://${addr}:${EDGE_NODEPORT};
      proxy_connect_timeout 2s;
      proxy_read_timeout    5s;
      proxy_set_header Host              \$host;
      proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    }
  }

  # The outside-in availability signal, scraped by Prometheus over the
  # interconnect. It exists because the first game day proved the in-cluster
  # probe cannot see the outage that matters: the httpcheck receiver measuring
  # the active side ran INSIDE the active side, so when that cluster died the
  # prober died with it and the SLO reported 0.00% errors through a 127-second
  # total outage. A probe that shares a failure domain with its target is not a
  # probe.
  server {
    listen ${METRICS_PORT};
    access_log off;
    location = /metrics {
      default_type "text/plain; version=0.0.4; charset=utf-8";
      alias /var/lib/dr/metrics;
    }
    location = /health { return 200 "ok\n"; }
  }
}
EOF
}

# Written into the container and run there, so the probe reaches the cluster
# edges directly over the interconnect rather than through the host.
write_probe() {
  cat <<EOF
#!/bin/sh
# Outside-in prober. Runs in the traffic manager, which is attached to neither
# cluster: killing either one cannot stop this from reporting.
INTERVAL=\${DR_PROBE_INTERVAL:-5}
OUT=/var/lib/dr/metrics

probe() { wget -q -T 4 -O /dev/null "\$1" 2>/dev/null && echo 1 || echo 0; }

while :; do
  # The public endpoint is the user's actual path in: through this proxy, to
  # whichever site it currently points at. That is the SLI.
  pub=\$(probe http://127.0.0.1:8080/)
  aws=\$(probe http://$(site_addr aws-primary):${EDGE_NODEPORT}/health)
  gcp=\$(probe http://$(site_addr gcp-secondary):${EDGE_NODEPORT}/health)
  active=\$(sed -n 's/^# active-site: //p' /etc/nginx/nginx.conf)

  {
    echo "# HELP dr_probe_success Outside-in probe: 1 if the target answered."
    echo "# TYPE dr_probe_success gauge"
    echo "dr_probe_success{target=\"public\"} \$pub"
    echo "dr_probe_success{target=\"aws-primary\"} \$aws"
    echo "dr_probe_success{target=\"gcp-secondary\"} \$gcp"
    echo "# HELP dr_traffic_active Which site the traffic manager is pointed at."
    echo "# TYPE dr_traffic_active gauge"
    for s in aws-primary gcp-secondary; do
      if [ "\$s" = "\$active" ]; then v=1; else v=0; fi
      echo "dr_traffic_active{site=\"\$s\"} \$v"
    done
    echo "# HELP dr_probe_timestamp_seconds Unix time of the last completed sweep."
    echo "# TYPE dr_probe_timestamp_seconds gauge"
    echo "dr_probe_timestamp_seconds \$(date +%s)"
  } > \$OUT.tmp && mv \$OUT.tmp \$OUT

  sleep \$INTERVAL
done
EOF
}

cmd_up() {
  local active="${1:-aws-primary}"
  site_addr "$active" >/dev/null

  docker network inspect "$NETWORK" >/dev/null 2>&1 || {
    echo "interconnect network '$NETWORK' missing — run make up first" >&2; exit 1; }

  printf '\n%s==> provisioning cloud-side edges%s\n' "$BOLD" "$OFF"
  for s in "${SITES[@]}"; do ensure_edge "$s"; done

  printf '\n%s==> starting traffic manager (active: %s)%s\n' "$BOLD" "$active" "$OFF"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  # The command blocks until the config and probe are installed, so nginx never
  # runs on the stock config and the probe is part of the container's own
  # lifecycle rather than something exec'd in afterwards that a restart loses.
  docker run -d --name "$CONTAINER" \
      --network "$NETWORK" --ip "$TM_ADDR" \
      -p "${PUBLIC_PORT}:8080" \
      -p "${METRICS_PORT}:${METRICS_PORT}" \
      --memory 64m \
      --entrypoint /bin/sh \
      "$IMAGE" -c 'mkdir -p /var/lib/dr
                   while [ ! -f /var/lib/dr/ready ]; do sleep 0.2; done
                   /var/lib/dr/probe.sh &
                   exec nginx -g "daemon off;"' >/dev/null

  write_probe | docker exec -i "$CONTAINER" sh -c 'cat > /var/lib/dr/probe.sh && chmod +x /var/lib/dr/probe.sh'
  write_conf "$active" | docker exec -i "$CONTAINER" sh -c 'cat > /etc/nginx/nginx.conf'
  if ! docker exec "$CONTAINER" nginx -t >/dev/null 2>&1; then
    docker exec "$CONTAINER" nginx -t || true
    echo "${RED}config rejected - traffic manager not started${OFF}" >&2; return 1
  fi
  docker exec "$CONTAINER" touch /var/lib/dr/ready

  for _ in $(seq 1 40); do
    curl -sf --max-time 2 "http://127.0.0.1:${METRICS_PORT}/health" >/dev/null 2>&1 && break
    sleep 0.5
  done
  cmd_status
}

install_conf() { # install_conf <site>
  write_conf "$1" | docker exec -i "$CONTAINER" sh -c 'cat > /etc/nginx/nginx.conf'
  # Validate before reloading. A bad config makes `nginx -s reload` a no-op and
  # the traffic manager keeps happily serving the OLD site — a cutover that
  # silently did not happen is the worst outcome available here.
  if ! docker exec "$CONTAINER" nginx -t >/dev/null 2>&1; then
    docker exec "$CONTAINER" nginx -t || true
    echo "${RED}config rejected - traffic NOT moved${OFF}" >&2; return 1
  fi
  docker exec "$CONTAINER" nginx -s reload
  sleep 1
}

cmd_down() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 && echo "removed $CONTAINER" || echo "$CONTAINER not running"
  echo "${DIM}NodePort edges left in place; they cost nothing and survive a restart.${OFF}"
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
configured_site() {
  docker exec "$CONTAINER" head -1 /etc/nginx/nginx.conf 2>/dev/null | sed -n 's/^# active-site: //p'
}

# Who actually answers. whoami echoes WHOAMI_NAME from the overlay, so this is
# the serving pod identifying itself — not the proxy reporting its own intent.
serving_site() {
  curl -s --max-time 4 "$PUBLIC_URL/" 2>/dev/null | sed -n 's/^Name: //p' | tr -d '\r'
}

# Health of one site, checked from INSIDE the interconnect, because the k3d
# node addresses are not routable from the macOS host.
site_health() { # site_health <site>
  local addr; addr="$(site_addr "$1")"
  docker exec "$CONTAINER" wget -q -T 3 -O /dev/null "http://${addr}:${EDGE_NODEPORT}/health" 2>/dev/null \
    && echo up || echo down
}

cmd_status() {
  if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    printf '\n  %straffic manager not running%s — ./scripts/traffic-manager.sh up\n\n' "$RED" "$OFF"; return 1
  fi
  local cfg served
  cfg="$(configured_site)"; served="$(serving_site)"

  printf '\n%s  traffic manager%s   %s%s (outside both clusters)%s\n\n' "$BOLD" "$OFF" "$DIM" "$PUBLIC_URL" "$OFF"
  printf '  %-16s %s%s -> %s:%s%s\n' "scraped at" "$DIM" "$METRICS_URL" "$TM_ADDR" "$METRICS_PORT" "$OFF"
  printf '  %-16s %s\n' "configured" "${cfg:-unknown}"
  if [[ -z "$served" ]]; then
    printf '  %-16s %sno answer%s\n' "serving" "$RED" "$OFF"
  elif [[ "$served" == "$cfg" ]]; then
    printf '  %-16s %s%s%s\n' "serving" "$GREEN" "$served" "$OFF"
  else
    printf '  %-16s %s%s%s  %s<- disagrees with config; a reload may have failed%s\n' \
      "serving" "$YEL" "$served" "$OFF" "$RED" "$OFF"
  fi
  echo
  for s in "${SITES[@]}"; do
    local h; h="$(site_health "$s")"
    local mark="$GREEN"; [[ "$h" == up ]] || mark="$RED"
    printf '  %-16s %s%-5s%s %s%s:%s%s\n' "$s" "$mark" "$h" "$OFF" "$DIM" "$(site_addr "$s")" "$EDGE_NODEPORT" "$OFF"
  done
  echo
}

# ---------------------------------------------------------------------------
# The cutover
# ---------------------------------------------------------------------------
cmd_switch() { # cmd_switch <site>
  local site="${1:?usage: switch <aws-primary|gcp-secondary>}" from
  site_addr "$site" >/dev/null
  from="$(configured_site)"
  if [[ "$from" == "$site" ]]; then
    echo "already pointed at $site"; return 0
  fi
  printf '\n%s==> cutting traffic over: %s -> %s%s\n' "$BOLD" "${from:-unknown}" "$site" "$OFF"
  # A graceful reload: in-flight requests on the old upstream are allowed to
  # finish. That drain is part of real RTO, so it is not skipped here.
  install_conf "$site"
  cmd_status
}

# ---------------------------------------------------------------------------
# Measurement
# ---------------------------------------------------------------------------
# One CSV line per sample: epoch,iso8601,http_code,serving_site,seconds.
# Redirect to a file and leave it running across the whole drill — the outage
# window is the gap in this log, and a drill that does not produce a number
# produces nothing.
cmd_probe() {
  local interval="${1:-0.25}"
  echo "epoch,iso,code,site,latency"
  python3 - "$PUBLIC_URL" "$interval" <<'PY'
import subprocess, sys, time, datetime
url, interval = sys.argv[1], float(sys.argv[2])
while True:
    t0 = time.time()
    try:
        out = subprocess.run(
            ["curl", "-s", "--max-time", "3", "-w", "\n%{http_code}", url],
            capture_output=True, text=True, timeout=5).stdout
        body, _, code = out.rpartition("\n")
        site = next((l[6:].strip() for l in body.splitlines() if l.startswith("Name: ")), "")
    except Exception:
        code, site = "000", ""
    t = time.time()
    iso = datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat(timespec="milliseconds")
    print(f"{t:.3f},{iso},{code},{site},{t-t0:.3f}", flush=True)
    time.sleep(max(0.0, interval - (time.time() - t0)))
PY
}

# Turn a probe log into the numbers the drill log wants.
cmd_analyze() { # cmd_analyze <csv>
  local csv="${1:?usage: analyze <probe.csv>}"
  python3 - "$csv" <<'PY'
import csv, sys, datetime
rows = list(csv.DictReader(open(sys.argv[1])))
rows = [r for r in rows if r.get("epoch")]
if not rows:
    sys.exit("probe log is empty")

def ok(r): return r["code"] == "200" and r["site"]
def ts(r): return float(r["epoch"])
def iso(e): return datetime.datetime.fromtimestamp(e, datetime.timezone.utc).isoformat(timespec="milliseconds")

# Collapse the sample stream into runs of "who was serving". Every failure is
# one DOWN run regardless of status code: a dead upstream alternates 502 and
# 504 sample by sample, and splitting on the code shatters a single two-minute
# outage into sixty one-line rows that hide the number you came for. The codes
# seen are kept and shown alongside the run.
runs, cur = [], None
for r in rows:
    state = r["site"] if ok(r) else "DOWN"
    if cur and cur["state"] == state:
        cur["end"], cur["n"] = ts(r), cur["n"] + 1
        cur["codes"].add(r["code"])
    else:
        cur = {"state": state, "start": ts(r), "end": ts(r), "n": 1, "codes": {r["code"]}}
        runs.append(cur)

print(f"\n  probe: {len(rows)} samples over {ts(rows[-1])-ts(rows[0]):.1f}s"
      f"  ({iso(ts(rows[0]))} -> {iso(ts(rows[-1]))})\n")
print(f"  {'state':<22} {'from':<26} {'secs':>8} {'samples':>8}")
for r in runs:
    # A run's span is measured to the first sample of the NEXT run, not to its
    # own last sample: the outage did not end when we last observed it failing.
    nxt = runs[runs.index(r) + 1]["start"] if r is not runs[-1] else r["end"]
    label = r["state"]
    if label == "DOWN":
        label += " (" + "/".join(sorted(r["codes"])) + ")"
    print(f"  {label:<22} {iso(r['start']):<26} {nxt - r['start']:>8.1f} {r['n']:>8}")

succ = [r for r in rows if ok(r)]
if succ:
    first_site, last_site = succ[0]["site"], succ[-1]["site"]
    if first_site != last_site:
        last_old = max(ts(r) for r in succ if r["site"] == first_site)
        first_new = min(ts(r) for r in succ if r["site"] == last_site)
        print(f"\n  last 200 from {first_site:<16} {iso(last_old)}")
        print(f"  first 200 from {last_site:<15} {iso(first_new)}")
        print(f"\n  user-visible outage: {first_new-last_old:.1f}s"
              f"  ({(first_new-last_old)/60:.2f} min)\n")
    else:
        print(f"\n  no cutover seen — every success came from {first_site}\n")
else:
    print("\n  no successful samples at all\n")
PY
}

case "${1:-status}" in
  up)      shift; cmd_up "$@" ;;
  down)    cmd_down ;;
  status)  cmd_status ;;
  switch)  shift; cmd_switch "$@" ;;
  probe)   shift; cmd_probe "$@" ;;
  analyze) shift; cmd_analyze "$@" ;;
  *) sed -n '/^#   \.\//,/^#$/p' "$0" | sed 's/^# \{0,1\}//' ; exit 2 ;;
esac
