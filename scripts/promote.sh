#!/usr/bin/env bash
#
# Promote one cluster to primary and demote every other, in one edit.
#
# This exists because the first game day flipped a replica count and nothing
# else. The failover worked, and the SLO that depended on the role label went on
# measuring the cluster that had just died — reporting perfect availability
# through a total outage. The lesson is not "remember the other file": it is
# that role and replica count are one decision and must not be two edits.
#
# Rewrites, for every app overlay:
#   replicas.count      the promoted site takes over the previous primary's count
#   dr.role label       primary / standby
#   DR_ROLE literal     primary / standby
#
# Line-targeted rather than a YAML round-trip on purpose: the comments in these
# overlays carry the reasoning, and a reformat would drop them.
#
#   ./scripts/promote.sh gcp-secondary            # show the diff, change nothing
#   ./scripts/promote.sh gcp-secondary --apply
#
set -euo pipefail
cd "$(dirname "$0")/.."

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; OFF=$'\033[0m'

SITE="${1:-}"
APPLY=0
[[ "${2:-}" == "--apply" ]] && APPLY=1
if [[ -z "$SITE" ]]; then
  echo "usage: ./scripts/promote.sh <cluster> [--apply]" >&2; exit 2
fi
[[ -d "clusters/${SITE}" ]] || { echo "unknown cluster '${SITE}' — not in clusters/" >&2; exit 2; }

APPLY="$APPLY" SITE="$SITE" python3 - <<'PY'
import os, pathlib, re, sys

site, apply = os.environ["SITE"], os.environ["APPLY"] == "1"
BOLD, DIM, RED, GREEN, OFF = "\033[1m", "\033[2m", "\033[0;31m", "\033[0;32m", "\033[0m"

# apps/ AND platform/. The first version of this script globbed only apps/, so
# the Deployment labels flipped and the collector's drRole literal did not —
# and the collector is what stamps dr_role onto every metric it exports. Half a
# fix for finding 3, which is the kind of thing that reads as fixed until the
# next drill.
overlays = sorted(
    list(pathlib.Path("apps").glob("*/overlays/*/kustomization.yaml"))
    + list(pathlib.Path("platform").glob("*/overlays/*/kustomization.yaml"))
)
if not overlays:
    sys.exit("no overlays found")

def role_of(text):
    m = re.search(r"^\s*dr\.role:\s*(\S+)", text, re.M)
    return m.group(1) if m else None

def count_of(text):
    m = re.search(r"^(\s*)count:\s*(\d+)", text, re.M)
    return int(m.group(2)) if m else None

# The promoted side inherits whatever the current primary was running, rather
# than a hardcoded 2 — the drill's replica count is not a constant of the app.
serving = {}
for f in overlays:
    if f.parts[0] != "apps":
        continue
    t = f.read_text()
    app = f.parts[1]
    if role_of(t) == "primary":
        serving[app] = count_of(t)

changed = []
for f in overlays:
    app, cluster = f.parts[1], f.parts[3]
    text = old = f.read_text()
    want_role = "primary" if cluster == site else "standby"
    want_count = (serving.get(app) or 2) if want_role == "primary" else 0

    text = re.sub(r"^(\s*dr\.role:\s*)\S+", lambda m: m.group(1) + want_role, text, flags=re.M)
    text = re.sub(r"^(\s*-\s*DR_ROLE=)\S+",  lambda m: m.group(1) + want_role, text, flags=re.M)
    text = re.sub(r"^(\s*-\s*drRole=)\S+",   lambda m: m.group(1) + want_role, text, flags=re.M)
    # Only apps carry a replica count; platform placement is deliberate and is
    # not something a promotion may rewrite.
    if f.parts[0] == "apps":
        text = re.sub(r"^(\s*count:\s*)\d+", lambda m: m.group(1) + str(want_count), text, flags=re.M)

    if text != old:
        changed.append((f, old, text))
        if apply:
            f.write_text(text)

if not changed:
    print(f"\n  {GREEN}already correct{OFF} — {site} is primary and every other cluster is standby\n")
    sys.exit(0)

print(f"\n{BOLD}  promote {site}{OFF}{DIM}   (everything else becomes standby){OFF}\n")
for f, old, new in changed:
    print(f"  {BOLD}{f}{OFF}")
    for o, n in zip(old.splitlines(), new.splitlines()):
        if o != n:
            print(f"    {RED}- {o.strip()}{OFF}")
            print(f"    {GREEN}+ {n.strip()}{OFF}")
    print()

if apply:
    print(f"  {GREEN}Applied.{OFF} Commit and push — Argo reconciles from Git, not from this file.\n")
else:
    print(f"  {DIM}Dry run.{OFF} Re-run with --apply.\n")
PY
