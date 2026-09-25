#!/bin/bash
# ============================================================================
# Schedule cron-race check (read-only). kopiur 0.10.9 re-pins nextSchedule only on
# tz/jitter change, never on a cron change, so a SnapshotSchedule created with
# the component's default cron fires once at the stale slot and then self-heals.
# This checks every schedule's status.nextSchedule.at lands in an hour its
# spec.schedule.cron allows. `jitter` is a forward window, so a slot up to
# <jitter> past the end of an allowed hour also counts (marked "spill").
# Usage: check-schedules.sh [namespace...]   (default: all namespaces)
# ============================================================================
set -euo pipefail

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

if [[ $# -gt 0 ]]; then
    json="$(for ns in "$@"; do kubectl -n "$ns" get snapshotschedules.kopiur.home-operations.com -o json; done | jq -s '{items: map(.items) | add}')"
else
    json="$(kubectl get snapshotschedules.kopiur.home-operations.com -A -o json)"
fi

python3 - "$json" <<'PY'
import json, re, sys
from datetime import datetime, timedelta, timezone

def hours(field):
    """Hours allowed by a cron hour field: '*', '*/N', 'N', 'a,b', 'a-b'."""
    out = set()
    for part in field.split(","):
        m = re.fullmatch(r"(\*|\d+(?:-\d+)?)(?:/(\d+))?", part)
        if not m:
            return None
        rng, step = m.group(1), int(m.group(2) or 1)
        lo, hi = (0, 23) if rng == "*" else (tuple(map(int, rng.split("-"))) if "-" in rng else (int(rng), int(rng) if not m.group(2) else 23))
        out.update(range(lo, hi + 1, step))
    return out

def dur(s):
    m = re.fullmatch(r"(\d+)([smh])", s or "0s")
    unit = {"s": "seconds", "m": "minutes", "h": "hours"}
    return timedelta(**{unit[m.group(2)]: int(m.group(1))}) if m else timedelta(0)

bad = 0
rows = []
for it in json.loads(sys.argv[1])["items"]:
    ns, name = it["metadata"]["namespace"], it["metadata"]["name"]
    cron = it["spec"]["schedule"]["cron"]
    st = it.get("status", {})
    nxt = (st.get("nextSchedule") or {}).get("at")
    last = (st.get("lastSchedule") or {}).get("at", "-")
    gen, ogen = it["metadata"].get("generation"), st.get("observedGeneration", "-")
    allowed = hours(cron.split()[1])
    if not nxt or allowed is None:
        verdict = "UNKNOWN"
    else:
        at = datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", nxt))
        back = at - dur((st.get("nextSchedule") or {}).get("jitter"))
        if at.hour in allowed:
            verdict = "ok"
        elif back.hour in allowed:
            verdict = "ok (spill)"
        else:
            verdict = "STALE"
    bad += verdict not in ("ok", "ok (spill)")
    rows.append((ns, name, cron, f"{gen}/{ogen}", (nxt or "-")[:19], last[:19], verdict))

hdr = ("NAMESPACE", "SCHEDULE", "CRON", "GEN/OBS", "NEXT", "LAST", "VERDICT")
w = [max(len(str(r[i])) for r in rows + [hdr]) for i in range(len(hdr))]
for r in [hdr] + sorted(rows):
    print("  ".join(str(c).ljust(w[i]) for i, c in enumerate(r)))
print(f"\n{len(rows)} schedules, {bad} not ok")
sys.exit(1 if bad else 0)
PY
