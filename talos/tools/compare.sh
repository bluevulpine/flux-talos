#!/usr/bin/env bash
# Compare a rendered topf output directory with the talhelper baseline, per node.
# Migration verification tool; delete with talconfig.yaml in Phase 7.
#
#   compare.sh <baseline_dir> <render_dir> [--hash]
#
# baseline files: home-kubernetes-<node>.yaml (talhelper) or <node>.yaml
# render files:   <node>.yaml (topf render)
# Default mode masks secrets: use it for a render made with synthetic secrets.
# --hash        HMACs secrets with a random per-run key shared by both sides: use it for a
#               render made with the REAL secrets. Prints only masked/HMAC'd values.
# Exit status 0 only if every node was compared and none differs.
set -euo pipefail

NODES=(jormungandr1 jormungandr2 jormungandr3 freyja01 jormungandr4 brokkr01 brokkr02 brokkr03)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORM="$HERE/norm.py"

[[ $# -ge 2 ]] || { echo "usage: $0 <baseline_dir> <render_dir> [--hash]" >&2; exit 2; }
BASE="$1"; RENDER="$2"; MODE="${3:-}"
[[ -d "$BASE" && -d "$RENDER" ]] || { echo "error: not a directory: $BASE or $RENDER" >&2; exit 2; }
if [[ "$MODE" == "--hash" ]]; then NORM_KEY="$(openssl rand -hex 16)"; export NORM_KEY; fi

# A node file we do not know about is a node we would silently not compare.
for f in "$RENDER"/*.yaml; do
  n="$(basename "$f" .yaml)"
  printf '%s\n' "${NODES[@]}" | grep -qx "$n" || { echo "error: unexpected rendered node '$n'" >&2; exit 1; }
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
for n in "${NODES[@]}"; do
  b="$BASE/home-kubernetes-$n.yaml"; [[ -f "$b" ]] || b="$BASE/$n.yaml"
  r="$RENDER/$n.yaml"
  [[ -f "$b" && -f "$r" ]] || { echo "error: missing baseline or render for $n" >&2; exit 1; }
  python3 "$NORM" "$b" > "$tmp/a"; python3 "$NORM" "$r" > "$tmp/b"
  na=$(wc -l < "$tmp/a"); nb=$(wc -l < "$tmp/b")
  (( na > 0 && nb > 0 )) || { echo "error: $n normalised to zero lines" >&2; exit 1; }
  nd=$(diff "$tmp/a" "$tmp/b" | grep -c '^[<>]' || true)
  printf '%-13s baseline=%s render=%s differing=%s\n' "$n" "$na" "$nb" "$nd"
  if (( nd > 0 )); then
    fail=1
    # `|| true`: head closing the pipe early would otherwise trip pipefail and abort the report.
    { diff "$tmp/a" "$tmp/b" | grep '^[<>]' | sed 's/^</BASE /;s/^>/TOPF /' | cut -c1-200 | head -"${DIFFMAX:-25}"; } || true
  fi
  python3 "$NORM" --order "$b" > "$tmp/oa"; python3 "$NORM" --order "$r" > "$tmp/ob"
  cmp -s "$tmp/oa" "$tmp/ob" || echo "  note: $n document ORDER differs from the baseline (leaf comparison ignores order)"
done
(( fail == 0 )) && echo "OK: all ${#NODES[@]} nodes equivalent" || { echo "FAIL: differences found" >&2; exit 1; }
