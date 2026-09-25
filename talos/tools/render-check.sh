#!/usr/bin/env bash
# Offline self-test of the topf patch tree. Needs NO real secret and NO cluster access.
#
#   talos/tools/render-check.sh [baseline_dir]
#
# Builds a throwaway fixture (synthetic age key, synthetic PKI bundle, synthetic data values;
# the cleartext of talos/topf.yaml is reused so the node list cannot drift), renders all 8
# nodes with topf, and checks:
#   * every node renders, and `talosctl validate --mode metal` accepts it
#   * each node's installer image carries its own schematic, and none is the extension-less default
#   * no unsubstituted ${...} placeholder reached a render
#   * the guard in patches/all/00-guard.yaml.tpl rejects an unknown host, a role flip, and a node
#     with no schematicId
#   * (optional) with a baseline dir, the render is equivalent to it (masked comparison)
# Migration verification tool; delete with talconfig.yaml in Phase 7 (or keep as the regression test).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALOS="$(cd "$HERE/.." && pwd)"
TOPF="${TOPF:-$TALOS/../.bin/topf}"
BASELINE="${1:-}"
for c in age-keygen sops yq talosctl python3; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 2; }; done
[[ -x "$TOPF" ]] || { echo "topf not found at $TOPF" >&2; exit 2; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export SOPS_AGE_KEY_FILE="$tmp/key"
age-keygen -o "$SOPS_AGE_KEY_FILE" 2>/dev/null
pub="$(grep 'public key' "$SOPS_AGE_KEY_FILE" | awk '{print $NF}')"
pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

mkfix() { # $1 dir, $2 optional yq expression applied to the node config
  mkdir -p "$1"; ln -sfn "$TALOS/schematics" "$1/schematics"
  talosctl gen secrets -o "$1/secrets.plain.yaml" >/dev/null 2>&1
  sops -e --config /dev/null --age "$pub" "$1/secrets.plain.yaml" > "$1/secrets.sops.yaml"; rm -f "$1/secrets.plain.yaml"
  yq "del(.sops) | .data = {\"tsAuthKey\":\"SYNTH-TS\",\"volumeKey\":\"SYNTH-VOL\",\"domain\":\"synthetic.invalid\"} | .patchesDir = \"$TALOS/patches\" | ${2:-.}" "$TALOS/topf.yaml" > "$1/topf.yaml"
}
render() { (cd "$1" && "$TOPF" render -o "$2" </dev/null 2>&1) | sed 's/\x1b\[[0-9;]*m//g'; }

echo "== full render"
mkfix "$tmp/fx"
if render "$tmp/fx" "$tmp/out" >"$tmp/render.log"; then :; fi
n=$(ls "$tmp/out"/*.yaml 2>/dev/null | wc -l | tr -d ' ')
[[ "$n" == 8 ]] && ok "8 nodes rendered" || { bad "expected 8 rendered nodes, got $n"; head -3 "$tmp/render.log" | cut -c1-200; }

echo "== validate, schematic, placeholders"
for f in "$tmp/out"/*.yaml; do
  h="$(basename "$f" .yaml)"
  talosctl validate --mode metal --config "$f" >/dev/null 2>&1 && ok "$h valid (metal)" || bad "$h failed talosctl validate"
  want=a6c707bf; [[ "$h" == freyja01 ]] && want=647d4118; [[ "$h" == brokkr* ]] && want=b915cd23
  img="$(grep -m1 'image: factory.talos.dev/metal-installer/' "$f" | sed 's#.*metal-installer/##')"
  [[ "$img" == "$want"* ]] && ok "$h installer schematic ${want}…" || bad "$h installer image is ${img:0:8}…, want ${want}…"
  [[ "$img" == 37656798* ]] && bad "$h got the DEFAULT extension-less schematic"
  grep -q '\${' "$f" && bad "$h render contains an unsubstituted \${...}" || true
done
grep -rn '\${' "$TALOS/patches" "$TALOS/schematics" >/dev/null 2>&1 && bad 'a literal ${...} exists under patches/ or schematics/' || ok 'no ${...} under patches/ or schematics/'

echo "== guard must reject bad input"
expect_fail() { # name yq-expr grep-pattern
  mkfix "$tmp/g" "$2"; rm -rf "$tmp/gout"
  # capture first: `render | grep -q` would trip pipefail (grep exits early, SIGPIPE upstream)
  out="$(render "$tmp/g" "$tmp/gout" || true)"
  if grep -q "$3" <<<"$out"; then ok "$1"; else bad "$1 (guard did not fire)"; fi; rm -rf "$tmp/g"
}
expect_fail "unknown host is rejected" '.nodes += [{"host":"brokkr04","ip":"10.0.10.99","role":"worker","schematicId":"@schematics/amd.yaml"}]' "unknown node"
expect_fail "unknown prefix is rejected" '.nodes += [{"host":"odin01","ip":"10.0.10.98","role":"worker","schematicId":"@schematics/amd.yaml"}]' "unknown node"
expect_fail "a role flip is rejected" '(.nodes[] | select(.host=="jormungandr1") | .role) = "control-plane"' "is expected to be"
expect_fail "a node with no schematicId is rejected" 'del(.nodes[] | select(.host=="brokkr01") | .schematicId)' "has no schematicId"

if [[ -n "$BASELINE" ]]; then
  echo "== equivalence to baseline (masked; synthetic secrets are not compared)"
  "$HERE/compare.sh" "$BASELINE" "$tmp/out" >"$tmp/cmp.log" 2>&1 && ok "render equivalent to $BASELINE" || { bad "render differs from baseline"; grep -v note: "$tmp/cmp.log" | head -8; }
fi

echo; echo "passed=$pass failed=$fail"
(( fail == 0 ))
