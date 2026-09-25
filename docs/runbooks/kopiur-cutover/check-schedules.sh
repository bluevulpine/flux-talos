#!/bin/bash
# ============================================================================
# Schedule cron-race check (read-only). kopiur 0.10.9 re-pins nextSchedule only on
# tz/jitter change, never on a cron change, so a SnapshotSchedule whose cron was
# edited after its slot was pinned fires once at the stale slot, then self-heals.
#
# Verdicts, per schedule:
#   ok       status.nextSchedule.at is reachable from the cron: some minute in
#            (at - jitter, at] matches its hour field and, when numeric, its
#            minute field (an H minute is a hash we can't see, so any minute).
#   STALE    no such minute: the slot was pinned from a different cron.
#   STALE (obs<gen)  the controller has not observed the current spec, so the
#            slot came from an older one (this is how the W1 race looked).
#   UNKNOWN  no nextSchedule, or a cron field this script can't parse.
# Only the minute and hour fields are checked; day-of-month/month/day-of-week
# are "*" everywhere in this repo. Exit 1 if anything is not ok.
# Usage: check-schedules.sh [namespace...]   (default: all namespaces)
# ============================================================================
set -euo pipefail

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

if [[ $# -gt 0 ]]; then
    json="$(for ns in "$@"; do kubectl -n "$ns" get snapshotschedules.kopiur.home-operations.com -o json; done | jq -s '{items: map(.items) | add}')"
else
    json="$(kubectl get snapshotschedules.kopiur.home-operations.com -A -o json)"
fi

# JSON goes in on stdin, not argv: a single argv string is capped at 128 KiB on
# Linux, which the whole fleet's schedules would exceed.
printf '%s' "$json" | python3 -c "$(cat <<'PY'
import json, re, sys
from datetime import datetime, timedelta

def field(spec, top):
    """Values allowed by a cron field: '*', 'H', '*/N', 'N', 'N/S', 'a-b', 'a-b/S', lists.
    'H' is kopiur's hash (the value is not visible here), so it allows anything."""
    out = set()
    for part in spec.split(","):
        if part == "H":
            return set(range(top + 1))
        m = re.fullmatch(r"(\*|\d+(?:-\d+)?)(?:/(\d+))?", part)
        if not m:
            return None
        rng, step = m.group(1), int(m.group(2) or 1)
        if rng == "*":
            lo, hi = 0, top
        elif "-" in rng:
            lo, hi = map(int, rng.split("-"))
        else:
            lo = int(rng)
            hi = top if m.group(2) else lo
        out.update(range(lo, hi + 1, step))
    return out

def dur(s):
    """Jitter like '20m', '1h30m', '90s'; anything unparsable counts as 0, which
    can only make a verdict stricter (STALE), never hide one."""
    parts = re.findall(r"(\d+)([hms])", s or "")
    if not parts or "".join(n + u for n, u in parts) != s:
        return timedelta(0)
    unit = {"h": "hours", "m": "minutes", "s": "seconds"}
    return sum((timedelta(**{unit[u]: int(n)}) for n, u in parts), timedelta(0))

def reachable(at, jitter, minutes, hours):
    """Is there a whole-minute base slot b with at - jitter < b <= at matching the cron?"""
    b = at.replace(second=0, microsecond=0)
    while True:
        if b.hour in hours and b.minute in minutes:
            return True
        b -= timedelta(minutes=1)
        if at - b >= jitter:
            return False

bad = 0
rows = []
for it in json.load(sys.stdin)["items"]:
    ns, name = it["metadata"]["namespace"], it["metadata"]["name"]
    cron = it["spec"]["schedule"]["cron"]
    st = it.get("status") or {}
    nxt_obj = st.get("nextSchedule") or {}
    nxt = nxt_obj.get("at")
    last = (st.get("lastSchedule") or {}).get("at", "-")
    gen, ogen = it["metadata"].get("generation"), st.get("observedGeneration")
    f = cron.split()
    minutes, hours = (field(f[0], 59), field(f[1], 23)) if len(f) >= 2 else (None, None)
    if isinstance(gen, int) and isinstance(ogen, int) and ogen < gen:
        verdict = "STALE (obs<gen)"
    elif not nxt or minutes is None or hours is None:
        verdict = "UNKNOWN"
    else:
        # Python < 3.11 fromisoformat rejects 'Z' and >6 fractional digits.
        at = datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", nxt).replace("Z", "+00:00"))
        verdict = "ok" if reachable(at, dur(nxt_obj.get("jitter")), minutes, hours) else "STALE"
    bad += verdict != "ok"
    rows.append((ns, name, cron, f"{gen}/{ogen if ogen is not None else '-'}", (nxt or "-")[:19], last[:19], verdict))

hdr = ("NAMESPACE", "SCHEDULE", "CRON", "GEN/OBS", "NEXT", "LAST", "VERDICT")
w = [max(len(str(r[i])) for r in rows + [hdr]) for i in range(len(hdr))]
for r in [hdr] + sorted(rows):
    print("  ".join(str(c).ljust(w[i]) for i, c in enumerate(r)))
print(f"\n{len(rows)} schedules, {bad} not ok")
sys.exit(1 if bad else 0)
PY
)"
