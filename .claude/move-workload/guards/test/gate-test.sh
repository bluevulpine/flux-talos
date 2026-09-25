#!/bin/bash
# move_gate scenarios against the REAL commits of a move (PR1_SHA / PR2_SHA from the conf), inside a scratch `git clone --shared` of THIS repo in a fresh
# mktemp -d — the real repo's worktrees, refs and object store are never touched (m8). Meaningful once the commits exist locally (P2 done); for a finished
# move they must be in history (hermes: b7667471/b91dd0c9 are on main). The fake kubectl only supplies the kube-system UID. Uses BSD `sed -i ''` (macOS).
#   /bin/bash test/gate-test.sh [conf]
# shellcheck disable=SC1090,SC1091,SC2086,SC2015
[ -n "${BASH_VERSION:-}" ] || { echo "run under /bin/bash (never zsh)" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; GS="$(cd "$HERE/.." && pwd)"
CONF=${1:-$GS/examples/hermes.conf}; CONF=$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF"); . "$GS/confparse.sh"; parse_conf "$CONF" "APP OLD NEW PV PR1 PR2 PR1_SHA PR2_SHA BASE_SHA STATE_DIR WORKTREE GH_REPO CLUSTER_UID EXPECT_FILES EXPECT_DIRS DRIFT_PATHS REPORT_DIRS LIVE_FILES CONTROLLER" || exit 1   # conf parsed as DATA (N5)
REPO=$(git -C "$GS" rev-parse --show-toplevel) || exit 1
unset T
T=$(mktemp -d "${TMPDIR:-/tmp}/move-gate-test.XXXXXX") && T=$(cd "$T" && pwd -P) || exit 1
trap 'rm -rf "$T"' EXIT
GD=$T/gd; FX=$T/fx; mkdir -p "$GD/test" "$FX" "$GD/state"; cp "$GS/move-guards.sh" "$GS/confparse.sh" "$GS/kn-guard.sh" "$GD/"; cp -R "$GS/test/bin" "$GD/test/bin"
export FX PATH="$GD/test/bin:$PATH" HM_FAKE=1 FAKE_CLUSTER_UID=$CLUSTER_UID
git clone -q --shared --no-checkout "$REPO" "$GD/clone" || exit 1
git -C "$GD/clone" cat-file -e "$PR1_SHA^{commit}" 2>/dev/null && git -C "$GD/clone" cat-file -e "$PR2_SHA^{commit}" 2>/dev/null || { echo "commits $PR1_SHA / $PR2_SHA are not in $REPO" >&2; exit 1; }
git -C "$GD/clone" worktree add -q --detach "$GD/wt" "$PR1_SHA" || exit 1
{ for k in APP OLD NEW PV PR1 PR2 PR1_SHA PR2_SHA BASE_SHA GH_REPO CLUSTER_UID EXPECT_FILES EXPECT_DIRS REPORT_DIRS LIVE_FILES DRIFT_PATHS CONTROLLER; do [ -n "${!k:-}" ] && printf '%s="%s"\n' "$k" "${!k}"; done
  printf 'STATE_DIR="%s"\nWORKTREE="%s"\n' "$GD/state" "$GD/wt"; } > "$GD/move.conf"; export MOVE_CONF=$GD/move.conf
pass=0; fail=0
G() { # G <name> <expect PASS|FAIL> <guard call> [tail lines]
  local out rc; out=$(/bin/bash -c "source $GD/move-guards.sh; $3" 2>&1); rc=$?
  echo "### $1"; echo "$out" | tail -"${4:-6}"
  if { [ "$2" = PASS ] && [ $rc -eq 0 ]; } || { [ "$2" = FAIL ] && [ $rc -ne 0 ]; }; then pass=$((pass+1)); echo "ok (rc=$rc, expected $2)"; else fail=$((fail+1)); echo "UNEXPECTED rc=$rc (expected $2)"; fi
}
cd "$GD/wt" || exit 1
C="git -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null"
K=kubernetes/apps/$NEW/$APP
G "commit 1: $NEW 2 zero"                    PASS 'move_gate '"$NEW"' 2 zero'
G "commit 1: $NEW 2 absent (replicas)"       FAIL 'move_gate '"$NEW"' 2 absent' 4
G "commit 1: $OLD 2 (wrong ns)"              FAIL 'move_gate '"$OLD"' 2' 3
sed -i '' 's/{kind: PersistentVolumeClaim}/{name: '"$APP"', kind: PersistentVolumeClaim}/;s/{kind: ReplicationDestination}/{name: '"$APP"'-dst-local, kind: ReplicationDestination}/' $K/app/kustomization.yaml
$C commit -qam scratch; G "name-targeted patches (0 lines)" FAIL 'move_gate '"$NEW"' 2 zero' 5; $C reset -q --hard "$PR1_SHA"
sed -i '' "s/targetNamespace: $NEW/targetNamespace: $OLD/" $K/ks.yaml
$C commit -qam scratch; G "stale targetNamespace"          FAIL 'move_gate '"$NEW"' 2 zero' 6; $C reset -q --hard "$PR1_SHA"
sed -i '' "/\.\/$APP\/ks.yaml/d" kubernetes/apps/$NEW/kustomization.yaml
$C commit -qam scratch; G "ks.yaml unlisted in $NEW"       FAIL 'move_gate '"$NEW"' 2 zero' 6; $C reset -q --hard "$PR1_SHA"
# M5: the gate must check the VALUES, not just count the lines
sed -i '' "s/$PV/pvc-00000000-dead-beef-0000-000000000000/" $K/app/kustomization.yaml
$C commit -qam scratch; G "WRONG volumeName value (right count)"       FAIL 'move_gate '"$NEW"' 2 zero' 6; $C reset -q --hard "$PR1_SHA"
sed -i "" -E "s/value: $OLD([[:space:]]|$)/value: media\1/" $K/app/kustomization.yaml; git diff --quiet && echo "SCENARIO SETUP FAILED: sed changed nothing" >&2
$C commit -qam scratch; G "WRONG sourceNamespace value (right count)"  FAIL 'move_gate '"$NEW"' 2 zero' 6; $C reset -q --hard "$PR1_SHA"
echo "# x" >> $K/ks.yaml; G "uncommitted change"           FAIL 'move_gate '"$NEW"' 2 zero' 3; git checkout -q -- .
$C checkout -q --detach "$PR2_SHA"; G "commit 2: $NEW 2 absent" PASS 'move_gate '"$NEW"' 2 absent'
G "commit 2: $NEW 2 zero (replicas)"         FAIL 'move_gate '"$NEW"' 2 zero' 4
sed -i '' "s/$PV/pvc-00000000-dead-beef-0000-000000000000/" $K/app/kustomization.yaml
$C commit -qam scratch; G "commit 2 + WRONG volumeName value"          FAIL 'move_gate '"$NEW"' 2 absent' 6
echo; echo "gate scenarios: passed=$pass failed=$fail (app=$APP)"; [ "$fail" -eq 0 ]
