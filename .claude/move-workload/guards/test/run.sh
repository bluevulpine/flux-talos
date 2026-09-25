#!/bin/bash
# shellcheck disable=SC2016,SC2086,SC2034,SC1090,SC2015,SC1091  # test commands are deliberately single-quoted strings; ids are trusted fixtures; conf path is dynamic
# Guard test harness, parameterised by a per-move config:   /bin/bash run.sh [conf]      (default: ../examples/hermes.conf)
# It copies the guards + the fake kubectl/gh into a FRESH mktemp -d (an inherited $T is ignored and nothing outside that directory is ever deleted), writes
# a scratch conf carrying the SAME app values but scratch paths, and puts the fakes first on PATH. No real cluster or GitHub call is made, and the real
# repository is never touched (the drift tests use a scratch bare repo + clone).
# Run under /bin/bash (macOS 3.2), never zsh: a nested `zsh -c` re-reads ~/.zshenv and puts the REAL kubectl ahead of the fake.
[ -n "${BASH_VERSION:-}" ] || { echo "run under /bin/bash (never zsh)" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; GUARDS_SRC="$(cd "$HERE/.." && pwd)"
CONF=${1:-$GUARDS_SRC/examples/hermes.conf}; [ -f "$CONF" ] || { echo "no such conf: $CONF" >&2; exit 1; }
CONF=$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")
# load the app values into THIS shell (the harness is not the guards; the guards themselves never read the caller's env). NOT exported: an env-reading guard must fail the tests.
# N5: parsed as DATA with the same parser the guards use (the README has the operator run this against the REAL conf: nothing in it may be executed)
. "$GUARDS_SRC/confparse.sh"
_K="APP OLD NEW PV PR1 PR2 PR1_SHA PR2_SHA BASE_SHA STATE_DIR WORKTREE GH_REPO CLUSTER_UID EXPECT_FILES EXPECT_DIRS DRIFT_PATHS REPORT_DIRS LIVE_FILES CONTROLLER"
parse_conf "$CONF" "$_K" || exit 1
unset T   # never trust an inherited T (m8: `T=$HOME` used to be rm -rf'd)
T=$(mktemp -d "${TMPDIR:-/tmp}/move-guards-test.XXXXXX") && T=$(cd "$T" && pwd -P) || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
GD=$T/gd; FX=$T/fx; STATE=$GD/state; WT=$GD/wt
mkdir -p "$GD/test" "$FX" "$STATE"
cp "$GUARDS_SRC/move-guards.sh" "$GUARDS_SRC/confparse.sh" "$GUARDS_SRC/kn-guard.sh" "$GD/"; cp -R "$GUARDS_SRC/test/bin" "$GD/test/bin"
export FX PATH="$GD/test/bin:$PATH" HM_FAKE=1 FAKE_CLUSTER_UID=$CLUSTER_UID
[ "$(command -v kubectl)" = "$GD/test/bin/kubectl" ] || { echo "REFUSING: kubectl resolves to $(command -v kubectl), not the harness fake" >&2; exit 1; }
MC=$GD/move.conf
write_conf() { # write_conf <file> — the app values from the conf, scratch paths
  { for k in APP OLD NEW PV PR1 PR2 PR1_SHA PR2_SHA BASE_SHA GH_REPO CLUSTER_UID EXPECT_FILES EXPECT_DIRS REPORT_DIRS LIVE_FILES DRIFT_PATHS CONTROLLER; do
      [ -n "${!k:-}" ] && printf '%s="%s"\n' "$k" "${!k}"; done
    printf 'STATE_DIR="%s"\nWORKTREE="%s"\n' "$STATE" "$WT"; } > "$1"
}
write_conf "$MC"
export MOVE_CONF=$MC
G=$GD/move-guards.sh
PV0=$PV; SHA1=$PR1_SHA; SHA2=$PR2_SHA; P1=$PR1; P2=$PR2; OLDNS=$OLD; NEWNS=$NEW; A=$APP
F1=${EXPECT_FILES%% *}; D1=${EXPECT_DIRS%% *}; LF=${LIVE_FILES%% *}; RD=${REPORT_DIRS%% *}
[ -n "$LF" ] || { echo "harness needs LIVE_FILES in the conf" >&2; exit 1; }
echo "harness: APP=$A $OLDNS->$NEWNS PV=$PV0 files=[$EXPECT_FILES] dirs=[$EXPECT_DIRS] conf=$CONF"
pass=0; fail=0
t() { # t <name> <ok|refuse> <cmd>   runs the command under /bin/bash 3.2 with the guards sourced
  local name=$1 exp=$2 cmd=$3 out rc
  : > "$FX/calls.log"
  out=$(/bin/bash -c "source $G; $cmd" 2>&1); rc=$?
  if { [ "$exp" = ok ] && [ $rc -eq 0 ]; } || { [ "$exp" = refuse ] && [ $rc -ne 0 ]; }; then pass=$((pass+1)); echo "PASS  $name  (rc=$rc)"; else fail=$((fail+1)); echo "FAIL  $name  (rc=$rc) :: $out"; fi
  LAST_OUT=$out
}
chk() { # chk <name> <shell test string>  — a side-condition assertion (counted)
  if eval "$2"; then pass=$((pass+1)); echo "PASS  $1"; else fail=$((fail+1)); echo "FAIL  $1"; fi
}
mutated() { grep -cE '^(patch|label) pv' "$FX/calls.log" || true; }
gh_writes() { grep -cE '^gh pr (ready|merge)' "$FX/calls.log" || true; }
reached() { grep -vc '^get ns kube-system' "$FX/calls.log" || true; }   # calls that got past the guards to the fake (the cluster-identity probe is not one)
pvjson() { # pvjson <name> <label 0|1> <claimns|-> [phase=Bound] [policy=Retain]
  local lbl='{}'; [ "$2" = 1 ] && lbl='{"'"$A"'-move":"1"}'
  local cr='null'; [ "$3" != - ] && cr='{"namespace":"'"$3"'","name":"'"$A"'"}'
  jq -n --arg n "$1" --argjson l "$lbl" --argjson c "$cr" --arg ph "${4:-Bound}" --arg pol "${5:-Retain}" '{metadata:{name:$n,labels:$l},spec:{claimRef:$c,persistentVolumeReclaimPolicy:$pol},status:{phase:$ph}}' > "$FX/pv-$1.json"
}
pvc() { jq -n --arg v "$3" --arg ph "${4:-Bound}" '{spec:{volumeName:$v},status:{phase:$ph}}' > "$FX/pvc-$1-$2.json"; }
pr() { jq -n --arg st "$2" --arg d "$3" --arg r "$4" --arg o "$5" --arg b "$6" --arg m "$7" '{state:$st,isDraft:($d=="true"),headRefName:$r,headRefOid:$o,baseRefName:$b,mergeable:$m}' > "$FX/pr-$1.json"; }
conf_with() { # conf_with <KEY> <value> -> path of a copy of the scratch conf with that key overridden/removed
  local f=$GD/conf.$1; grep -v "^$1=" "$MC" > "$f"; [ -n "${2:-}" ] && printf '%s="%s"\n' "$1" "$2" >> "$f"; echo "$f"; }
RETAIN_P='{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
repoint_p() { echo '{"spec":{"claimRef":{"namespace":"'"$1"'","name":"'"$A"'","uid":null,"resourceVersion":null}}}'; }

echo "== config validation (all safety-critical values come from MOVE_CONF, which is parsed as DATA) =="
out=$(env -u MOVE_CONF /bin/bash -c "source $G" 2>&1); rc=$?; chk "no MOVE_CONF -> exit before any call ($rc)" '[ $rc -ne 0 ] && grep -q MOVE_CONF <<<"$out"'
out=$(MOVE_CONF=/nonexistent /bin/bash -c "source $G" 2>&1); rc=$?; chk "missing conf file refused" '[ $rc -ne 0 ]'
for spec in "PR1_SHA:abc123" "OLD:$NEWNS" "APP:Bad_App" "APP:x;rm-rf" "PV:pvc-nope" "CLUSTER_UID:notauuid" "PR1:12ab" "STATE_DIR:relative/dir" "EXPECT_FILES:" "DRIFT_PATHS:-rf" "EXPECT_DIRS:../etc" "GH_REPO:noslash"; do
  k=${spec%%:*}; v=${spec#*:}; c=$(conf_with "$k" "$v")
  out=$(MOVE_CONF=$c /bin/bash -c "source $G" 2>&1); rc=$?; chk "conf $k=[$v] refused" '[ $rc -ne 0 ] && grep -q "REFUSE (config" <<<"$out"'
done
c=$(conf_with PR2 "$P1"); out=$(MOVE_CONF=$c /bin/bash -c "source $G" 2>&1); rc=$?; chk "PR1 == PR2 refused" '[ $rc -ne 0 ]'
for k in APP PV PR1_SHA CLUSTER_UID STATE_DIR WORKTREE; do c=$(conf_with "$k" ""); out=$(MOVE_CONF=$c /bin/bash -c "source $G" 2>&1); rc=$?; chk "conf without $k refused" '[ $rc -ne 0 ]'; done
# m4: the config is never executed
MARK=$T/conf-code-ran
for bad in "touch $MARK" "APP=\"\$(touch $MARK)\"" "PV=\"pvc-\`touch $MARK\`\"" "SNEAKY=\"x\"" "APP=\"$A\"" "export FOO=1" "APP=$A"; do
  { cat "$MC"; echo "$bad"; } > "$GD/conf.bad"
  out=$(MOVE_CONF=$GD/conf.bad /bin/bash -c "source $G" 2>&1); rc=$?
  chk "conf line [$bad] refused (unknown key / duplicate / not KEY=\"value\"), not executed" '[ $rc -ne 0 ] && [ ! -e "$MARK" ]'
done
{ echo 'APP="$(touch '"$MARK"')"'; grep -v '^APP=' "$MC"; } > "$GD/conf.bad"
out=$(MOVE_CONF=$GD/conf.bad /bin/bash -c "source $G" 2>&1); rc=$?; chk "conf value with \$( ) refused and NOT executed" '[ $rc -ne 0 ] && [ ! -e "$MARK" ]'
# m4: exported shell functions must not shadow jq/kubectl inside the guards
out=$(env 'BASH_FUNC_jq%%=() {  echo SHADOWED-JQ; }' 'BASH_FUNC_kubectl%%=() {  echo SHADOWED-KUBECTL; }' /bin/bash -c "source $G; type jq; jq -n 1" 2>&1); rc=$?
chk "exported jq/kubectl functions are dropped at load (jq is not a function)" '! grep -q "SHADOWED" <<<"$out" && ! grep -q "jq is a function" <<<"$out"'

echo "== context / pinning =="
FAKE_UID=deadbeef t "wrong cluster UID exits"           refuse 'echo sourced-anyway'
t "APP not inherited"                                    ok     '[ "$APP" = '"$A"' ]'
APP=other t "APP=other env is overridden"                ok     '[ "$APP" = '"$A"' ]'
OLD=evil NEW=evil PV=pvc-evil t "OLD/NEW/PV env are NOT honoured" ok '[ "$OLD" = '"$OLDNS"' ] && [ "$NEW" = '"$NEWNS"' ] && [ "$PV" = '"$PV0"' ]'
MOVE_DIR=/tmp/evil GUARDS_DIR=/tmp/evil STATE_DIR=/tmp/evil R=/tmp/evil WORKTREE=/tmp/evil PR1_SHA=$SHA2 t "MOVE_DIR/STATE_DIR/GUARDS_DIR/R/WORKTREE/PR1_SHA env are NOT honoured" ok '[ "$MOVE_DIR" = "'"$STATE"'" ] && [ "$R" = "'"$WT"'" ] && [ "$PR1_SHA" = '"$SHA1"' ]'
t "config values are readonly"                           refuse 'APP=zzz'
t "no PUSH function exists"                              refuse 'type PUSH'
t "no pv_delete function"                                refuse 'type pv_delete'

echo "== kn (M3): read-only, namespace-pinned, screened =="
t "kn allows get in OLD"                                 ok     "kn $OLDNS get pods"
t "kn allows get in NEW"                                 ok     "kn $NEWNS get pods"
t "kn allows get pod,pvc lists with -l and -o json"      ok     "kn $OLDNS get pod,pvc -l app=x -o json"
t "kn allows logs -p (previous)"                         ok     "kn $OLDNS logs -p job/x"
t "kn refuses kube-system as ns"                         refuse 'kn kube-system get pods'
t "kn refuses an unrelated ns"                           refuse 'kn media get pods'
for bad in "-n kube-system" "--namespace=kube-system" "--namespace kube-system" "-A" "--all-namespaces" "--context=other-cluster" "--kubeconfig=/other" "--server=https://x" "--token=x" "--as=admin" "--raw=/api"; do
  t "kn $OLDNS get pods $bad -> refused" refuse "kn $OLDNS get pods $bad"; chk "      calls past the guard: $(reached) (want 0)" '[ "$(reached)" = 0 ]'
done
for k in pv persistentvolume ns namespace nodes crd clusterrole storageclass volumesnapshotcontent validatingwebhookconfiguration pv/x pod,pv; do
  t "kn get $k (cluster-scoped) -> refused" refuse "kn $OLDNS get $k"; chk "      calls past the guard: $(reached) (want 0)" '[ "$(reached)" = 0 ]'
done
t "kn -n x-old delete pod x -n kube-system -> refused"   refuse "kn $OLDNS delete pod x -n kube-system"; chk "      calls past the guard: $(reached) (want 0)" '[ "$(reached)" = 0 ]'
t "kn scale (not in this guard's verbs) refused"          refuse "kn $OLDNS scale deploy x --replicas=0"
t "kn exec refused (hard-deny verb)"                     refuse "kn $OLDNS exec pod/x -- sh"
t "kn apply -f <file> refused (only 'apply -f -')"       refuse "kn $OLDNS apply -f /tmp/x"
t "kn get -f refused"                                    refuse "kn $OLDNS get -f /tmp/x.yaml"
echo "-- N2: combined / attached short flags, secrets and unlisted kinds (previously reached kubectl) --"
for bad in "get secrets -RA -o yaml" "get secrets -Rnkube-system" "logs -pnkube-system pod/x" "get pods -A=true" "get pods -shttps://evil:6443" "get pods -Rshttps://evil:6443" "get pods -wA" "get secret -o yaml" "describe secrets" "get clusterissuers" "get clustersecretstores"; do
  t "N2: kn $OLDNS $bad -> refused" refuse "kn $OLDNS $bad"; chk "      calls past the guard: $(reached) (want 0)" '[ "$(reached)" = 0 ]'
done
t "kn delete of an allow-listed kind in OLD is allowed (a documented write, e.g. the helper Job)" ok "kn $OLDNS delete job x --cascade=foreground"
t "kn patch of an allow-listed kind in OLD is allowed"   ok     "kn $OLDNS patch replicationsource.volsync.backube x --type merge -p '{}'"
echo '{"spec":{}}' > "$FX/ks-$OLDNS-x.json"
t "kn get the Flux Kustomization by its full name"       ok     "kn $OLDNS get kustomization.kustomize.toolkit.fluxcd.io x -o json"; rm -f "$FX/ks-$OLDNS-x.json"
t "kn cannot PATCH the Flux Kustomization by its full name (controller kind: read/delete only)" refuse "kn $OLDNS patch kustomization.kustomize.toolkit.fluxcd.io x --type merge -p '{}'"
t "kn config (KN_NAMESPACES/KN_VERBS/KN_KINDS) is readonly" refuse 'KN_NAMESPACES="media"'
t "kn cannot be widened through the environment (KUBERNETES_MASTER)" refuse "KUBERNETES_MASTER=https://evil kn $OLDNS get pods"
echo "-- the vendored guard is byte-identical to the shared source, and its own suites pass --"
chk "kn-guard.sh sha256 matches kn-guard.sha256 (vendored unchanged)" '(cd "$GUARDS_SRC" && shasum -a 256 -c kn-guard.sha256 >/dev/null 2>&1)'
out=$(/bin/bash "$GUARDS_SRC/kn-guard.test.sh" 2>&1); rc=$?; echo "      $(tail -1 <<<"$out")"; chk "kn-guard.test.sh (its own refuse/allow suite) passes" '[ $rc -eq 0 ]'
out=$(/bin/bash "$GUARDS_SRC/kn-guard.mutation.sh" 2>&1); rc=$?; echo "      $(tail -1 <<<"$out")"; chk "kn-guard.mutation.sh: every weakened guard is killed by the suite" '[ $rc -eq 0 ]'

echo "== PV guard (N1/N4): there is NO generic PV patcher; payloads are built in code =="
t "pv_patch does not exist (N1/N4: the public re-point/Retain payload door is gone)" refuse 'type pv_patch'
t "_pv_apply does not exist"                             refuse 'type _pv_apply'
pvjson $PV0 1 $OLDNS Released; pvc $NEWNS $A $PV0 Pending
t "BOM + two JSON docs as a 'policy' argument REFUSED (no payload argument exists)" refuse "pv_reclaim $PV0 \$'\\xef\\xbb\\xbf{\"spec\":{\"persistentVolumeReclaimPolicy\":\"Delete\"}}\\n{\"spec\":{\"persistentVolumeReclaimPolicy\":\"Retain\"}}'"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
t "a payload smuggled in as pv_repoint's namespace REFUSED" refuse "pv_repoint $PV0 '$NEWNS\",\"x\":\"y'"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
pvjson $PV0 1 $OLDNS; pvjson pvc-OTHER 1 $OLDNS
t "reclaim on a DIFFERENT PV refused"                    refuse "pv_reclaim pvc-OTHER Retain"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
t "empty PV name refused"                                refuse "pv_reclaim '' Retain"
pvjson $PV0 0 $OLDNS
t "move PV without label refused"                        refuse "pv_reclaim $PV0 Retain"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
pvjson $PV0 1 $OLDNS
t "labelled PV, claim=OLD, Retain allowed"               ok     "pv_reclaim $PV0 Retain"; chk "      mutations: 1" '[ "$(mutated)" = 1 ]'
pvjson $PV0 1 $NEWNS
t "claim=NEW Retain allowed"                             ok     "pv_reclaim $PV0 Retain"
pvjson $PV0 1 -
t "EMPTY claimRef REFUSED"                               refuse "pv_reclaim $PV0 Retain"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
pvjson $PV0 1 media
t "claim in a foreign namespace refused"                 refuse "pv_reclaim $PV0 Retain"
pvjson $PV0 1 $OLDNS; jq '.spec.claimRef.name="someone-elses"' "$FX/pv-$PV0.json" > "$FX/pv.tmp" && mv "$FX/pv.tmp" "$FX/pv-$PV0.json"
t "claimRef in OLD but naming ANOTHER claim REFUSED (m6)" refuse "pv_reclaim $PV0 Retain"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
pvjson $PV0 1 $OLDNS
FAKE_API_ERROR=1 t "API error fails CLOSED"              refuse "pv_reclaim $PV0 Retain"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
rm -f "$FX/pv-$PV0.json"
t "PV absent refused"                                    refuse "pv_reclaim $PV0 Retain"
pvjson $PV0 1 $OLDNS
t "N14: a changed kube-system UID after load refuses the mutation" refuse "FAKE_UID=deadbeef pv_reclaim $PV0 Retain"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
t "N14: pv_repoint re-verifies the cluster too"          refuse "FAKE_UID=deadbeef pv_repoint $PV0 $NEWNS"

echo "== pv_reclaim =="
pvjson $PV0 1 $OLDNS Bound; pvc $OLDNS $A $PV0 Bound
t "Retain on Bound PV ok"                                ok     "pv_reclaim $PV0 Retain"
t "Delete: Bound + claim Bound to this PV (claim in OLD) -> allow" ok "pv_reclaim $PV0 Delete"; chk "      mutations: 1" '[ "$(mutated)" = 1 ]'
pvjson $PV0 1 $OLDNS Released; pvc $OLDNS $A $PV0 Bound
t "Delete on Released PV REFUSED"                        refuse "pv_reclaim $PV0 Delete"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
t "Retain on a Released PV allowed (harmless)"           ok     "pv_reclaim $PV0 Retain"
pvjson $PV0 1 $NEWNS Available
t "Delete on Available PV REFUSED"                       refuse "pv_reclaim $PV0 Delete"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
pvjson $PV0 1 $OLDNS Bound; rm -f "$FX/pvc-$OLDNS-$A.json"
t "Delete: Bound but claim MISSING -> refuse"            refuse "pv_reclaim $PV0 Delete"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
pvc $OLDNS $A $PV0 Pending
t "Delete: claim Pending -> refuse"                      refuse "pv_reclaim $PV0 Delete"
pvc $OLDNS $A pvc-OTHER Bound
t "Delete: claim bound to ANOTHER PV -> refuse"          refuse "pv_reclaim $PV0 Delete"
t "bogus policy refused"                                 refuse "pv_reclaim $PV0 Recycle"
echo "== pv_reclaim Delete: B10 (claim in NEW, or the move started) =="
pvjson $PV0 1 $NEWNS Bound; pvc $NEWNS $A $PV0 Bound; rm -f "$STATE/SINCE.txt"
t "Delete with the claim in NEW and NO SINCE.txt, no B10_OK -> REFUSED (state-file independent)" refuse "pv_reclaim $PV0 Delete"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
echo 2026-09-24T19:00:00Z > "$STATE/SINCE.txt"
t "Delete once SINCE.txt exists, no B10_OK -> REFUSED"    refuse "pv_reclaim $PV0 Delete"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
B10_OK=no t "Delete with B10_OK=no -> refused"           refuse "pv_reclaim $PV0 Delete"
B10_OK=yes t "Delete with B10_OK=yes (all other checks pass) -> allowed" ok "pv_reclaim $PV0 Delete"; chk "      mutations: 1" '[ "$(mutated)" = 1 ]'
t "Retain still allowed after SINCE.txt"                 ok     "pv_reclaim $PV0 Retain"
rm -f "$STATE/SINCE.txt"
pvjson $PV0 1 $OLDNS Bound; pvc $OLDNS $A $PV0 Bound
t "Delete before the move started (T-1 undo, claim in OLD) still allowed" ok "pv_reclaim $PV0 Delete"
echo "== pv_repoint (m6): preconditions =="
pvjson $PV0 1 $OLDNS Released; rm -f "$FX/pvc-$OLDNS-$A.json"; pvc $NEWNS $A $PV0 Pending
t "pv_repoint NEW: Released + Retain + claim Pending on this PV -> ok" ok "pv_repoint $PV0 $NEWNS"
chk "      payload: uid/resourceVersion null, name=$A, ns=$NEWNS" 'grep -q "\"uid\":null,\"resourceVersion\":null" "$FX/calls.log" && grep -q "\"name\":\"$A\"" "$FX/calls.log" && grep -q "\"namespace\":\"$NEWNS\"" "$FX/calls.log"'
rm -f "$FX/pvc-$NEWNS-$A.json"
t "pv_repoint NEW: target claim absent -> ok"            ok     "pv_repoint $PV0 $NEWNS"
pvjson $PV0 1 $OLDNS Available
t "pv_repoint: Available PV -> ok"                       ok     "pv_repoint $PV0 $NEWNS"
pvjson $PV0 1 $OLDNS Bound
t "pv_repoint: Bound PV REFUSED"                         refuse "pv_repoint $PV0 $NEWNS"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
pvjson $PV0 1 $OLDNS Released Delete
t "pv_repoint: PV reclaim Delete REFUSED"                refuse "pv_repoint $PV0 $NEWNS"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
pvjson $PV0 1 $OLDNS Released; pvc $NEWNS $A $PV0 Bound
t "pv_repoint: target claim already Bound REFUSED"       refuse "pv_repoint $PV0 $NEWNS"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
pvc $NEWNS $A pvc-OTHER Pending
t "pv_repoint: target claim Pending on ANOTHER PV REFUSED" refuse "pv_repoint $PV0 $NEWNS"
pvc $NEWNS $A $PV0 Pending
FAKE_PVC_ERROR=1 t "pv_repoint: claim read error (not NotFound) fails CLOSED" refuse "pv_repoint $PV0 $NEWNS"; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
t "pv_repoint kube-system refused"                       refuse "pv_repoint $PV0 kube-system"
t "pv_repoint other PV refused"                          refuse "pv_repoint pvc-OTHER $NEWNS"
rm -f "$FX/pvc-$NEWNS-$A.json"

echo "== record_pv / app_pv =="
pvjson $PV0 0 $OLDNS; pvc $OLDNS $A $PV0
t "record_pv labels the PV"                              ok     'record_pv'
chk "      label call is ${A}-move=1" 'grep -q "label pv $PV0 $A-move=1" "$FX/calls.log"'
pvc $OLDNS $A pvc-OTHER; pvjson pvc-OTHER 0 $OLDNS
t "record_pv refuses a PVC naming another PV"            refuse 'record_pv'; chk "      mutations: 0" '[ "$(mutated)" = 0 ]'
pvjson $PV0 1 $OLDNS; pvc $OLDNS $A $PV0; rm -f "$FX/pvc-$NEWNS-$A.json"
t "app_pv returns the move PV"                           ok     'app_pv'
pvc $OLDNS $A pvc-OTHER
t "app_pv refuses a re-provisioned PV"                   refuse 'app_pv'
pvc $OLDNS $A $PV0; pvc $NEWNS $A pvc-OTHER
t "app_pv refuses OLD/NEW disagreement"                  refuse 'app_pv'
rm -f "$FX/pvc-$OLDNS-$A.json" "$FX/pvc-$NEWNS-$A.json"; echo $PV0 > "$STATE/app-pv-$A.txt"
t "app_pv with NO claim refuses (cache ignored)"         refuse 'app_pv'
pvc $NEWNS $A $PV0 Pending; pvjson $PV0 1 $NEWNS
t "app_pv finds a pre-bound Pending claim in NEW"        ok     'app_pv'
rm -f "$FX/pvc-$NEWNS-$A.json"

echo "== helpers =="
rs() { jq -n --arg s "$3" --arg l "$4" --arg t "$5" '{status:{lastSyncStartTime:$s,lastSyncTime:$l,latestMoverStatus:{logs:$t}}}' > "$FX/rs-$1-$2.json"; }
GOOD=$'... Created snapshot with root abc\nSetting policy for '"$A@$OLDNS"$':/data\nOPERATION_RESULT: SUCCESS'
rs $OLDNS $A-local "" 2026-09-24T18:35:00Z "$GOOD"; rs $OLDNS $A-r2 "" 2026-09-24T18:35:30Z "$GOOD"
t "no_sync_in_flight: both idle"                         ok     "no_sync_in_flight $OLDNS"
rs $OLDNS $A-r2 2026-09-24T18:36:00Z 2026-09-24T18:35:30Z "$GOOD"
t "no_sync_in_flight: one in flight refused"             refuse "no_sync_in_flight $OLDNS"
t "no_sync_in_flight: bad ns refused"                    refuse 'no_sync_in_flight kube-system'
rs $OLDNS $A-r2 "" 2026-09-24T18:35:30Z "$GOOD"
echo "== rs_trigger (m9) =="
t "rs_trigger: both idle -> patches with the fixed payload" ok "rs_trigger $OLDNS $A-local pre-move-1790000000"
chk "      payload is the fixed merge patch" 'grep -q "patch replicationsource.volsync.backube $A-local --type merge -p {\"spec\":{\"trigger\":{\"manual\":\"pre-move-1790000000\"}}}" "$FX/calls.log"'
t "rs_trigger: another RS name refused"                  refuse "rs_trigger $OLDNS other-local pre-move-1"
t "rs_trigger: bad tag refused"                          refuse "rs_trigger $OLDNS $A-local 'x\",\"y'"
t "rs_trigger: foreign ns refused"                       refuse "rs_trigger media $A-local pre-move-1"
rs $OLDNS $A-r2 2026-09-24T18:36:00Z 2026-09-24T18:35:30Z "$GOOD"
t "rs_trigger: THAT source has a sync in flight -> refused, no patch" refuse "rs_trigger $OLDNS $A-r2 pre-move-1"; chk "      no patch issued" '! grep -q "^-n $OLDNS patch" "$FX/calls.log"'
t "rs_trigger: the other source idle -> ok (patching one starts its sync; the pair is checked with no_sync_in_flight before)" ok "rs_trigger $OLDNS $A-local pre-move-1"
rs $OLDNS $A-r2 "" 2026-09-24T18:35:30Z "$GOOD"
t "check_backup ok, T0 before lastSyncTime"              ok     "check_backup $OLDNS $A-local $A@$OLDNS 2026-09-24T18:30:00Z"
t "check_backup STALE when lastSyncTime <= T0"           refuse "check_backup $OLDNS $A-local $A@$OLDNS 2026-09-24T18:40:00Z"
t "check_backup wrong identity refused"                  refuse "check_backup $OLDNS $A-local $A@$NEWNS"
rs $OLDNS $A-local "" 2026-09-24T18:35:00Z $'Directory is empty skipping backup\nOPERATION_RESULT: FAILURE'
t "check_backup empty-source refused"                    refuse "check_backup $OLDNS $A-local $A@$OLDNS"
t "check_backup ns media refused"                        refuse "check_backup media $A-local $A@media"
rs $OLDNS $A-local "" 2026-09-24T18:35:00Z "$GOOD"
printf 'NAMESPACE NAME HOSTNAMES AGE\n%s %s ["h"] 19d\n' "$OLDNS" "$A" > "$FX/httproute.txt"
t "one_route: one in OLD"                                ok     "one_route $OLDNS"
t "one_route: wrong ns refused"                          refuse "one_route $NEWNS"
printf 'NAMESPACE NAME HOSTNAMES AGE\n%s %s ["h"] 19d\n%s %s ["h"] 1m\n%s other ["o"] 1d\n' "$OLDNS" "$A" "$NEWNS" "$A" "$NEWNS" > "$FX/httproute.txt"
t "one_route: two routes refused"                        refuse "one_route $NEWNS"
printf 'NAMESPACE NAME HOSTNAMES AGE\n%s %s-other ["h"] 1d\n%s %s ["h"] 1m\n' "$OLDNS" "$A" "$NEWNS" "$A" > "$FX/httproute.txt"
t "one_route: a similarly-named route is not counted"    ok     "one_route $NEWNS"
: > "$FX/calls.log"; t "am_silence without SILENCE_OK refused" refuse 'am_silence'
chk "      (no port-forward opened)" '[ "$(grep -c port-forward "$FX/calls.log")" = 0 ]'
for h in 999 0 abc 7; do SILENCE_OK=yes AM_HOURS=$h t "am_silence AM_HOURS=$h refused (1..6), no port-forward" refuse 'am_silence'; chk "      (no port-forward opened)" '[ "$(grep -c port-forward "$FX/calls.log")" = 0 ]'; done
t "COMMIT without MOVE_COAUTHOR refused"                 refuse 'COMMIT "scope: subject"'

echo "== hardening (N5, N6, N10, N12, N14, N15, m3) =="
MARK2=$T/conf-code-ran-2
{ cat "$MC"; echo "touch $MARK2"; } > "$GD/conf.code"
t "N5: the parser the harness uses refuses a conf with a command line" refuse ". $GD/confparse.sh; parse_conf $GD/conf.code 'APP OLD NEW'"
chk "      and executed nothing" '[ ! -e "$MARK2" ]'
printf 'STATE_DIR="$HOME/x"\n' > "$GD/conf.home"
out=$(HOME=/tmp/attacker /bin/bash -c ". $GD/confparse.sh; parse_conf $GD/conf.home STATE_DIR; echo \$STATE_DIR")
chk "N10: a leading \$HOME in the conf comes from the passwd database, not the (attacker) environment [$out]" '[ "$out" != "/tmp/attacker/x" ] && [ "${out%/x}" != "$out" ]'
printf "shopt -s expand_aliases\nalias jq='echo ALIASED-JQ'\n" > "$T/aliasenv"
out=$(BASH_ENV="$T/aliasenv" /bin/bash -c "source $G; type jq; pv_ok $PV0" 2>&1)
chk "N10: BASH_ENV aliases are dropped at load (jq is not an alias)" '! grep -q "alias" <<<"$out" && ! grep -q ALIASED <<<"$out"'
mkdir -p "$T/globdir"; : > "$T/globdir/a.txt"; : > "$T/globdir/ab"
for v in "*" "a?" "[a]b" "a.txt *"; do
  c=$(conf_with EXPECT_FILES "$v"); out=$(cd "$T/globdir" && MOVE_CONF=$c /bin/bash -c "source $G" 2>&1); rc=$?
  chk "N6: EXPECT_FILES=[$v] refused on the RAW string (a glob must not depend on the cwd)" '[ $rc -ne 0 ] && grep -q "no globs" <<<"$out"'
done
for k in EXPECT_DIRS DRIFT_PATHS REPORT_DIRS LIVE_FILES; do c=$(conf_with $k "a*b"); out=$(cd "$T/globdir" && MOVE_CONF=$c /bin/bash -c "source $G" 2>&1); rc=$?; chk "N6: $k with a glob refused" '[ $rc -ne 0 ]'; done
t "N14: MOVE_DIR is readonly"                            refuse 'MOVE_DIR=/tmp/x'
t "N14: R is readonly"                                   refuse 'R=/tmp/x'
t "N14: MOVE_LABEL is readonly"                          refuse 'MOVE_LABEL=x'
t "N14: KN_VERBS (kn's verb list) is readonly"           refuse 'KN_VERBS="get delete exec"'
t "N14: the silence matchers are readonly"               refuse '_SIL_POD=.*'
t "N14: MOVE_DIR reassignment cannot redirect pr_merge's state files" refuse 'MOVE_DIR=/tmp/x; pr_merge 1 2'
t "N12: every kubectl call carries --request-timeout"    ok     '_cluster_ok'
chk "      request-timeout present on the identity probe" 'grep -q -- "--request-timeout=20s" "$FX/calls.log"'
for bad in "feat: x" "fix(api): x" "chore!: x" "docs: x" "refactor(a)!: x" "ci: x"; do MOVE_COAUTHOR='Test Model <t@example.com>' t "N15: COMMIT [$bad] REFUSED (Conventional Commits prefix)" refuse "COMMIT '$bad'"; chk "      refused BY the prefix check, not incidentally" 'grep -q "Conventional Commits" <<<"$LAST_OUT"'; done
for bad in "no colon here" ": empty scope" "scope:nospace" "scope: "; do MOVE_COAUTHOR='Test Model <t@example.com>' t "N15: COMMIT [$bad] REFUSED (not '<scope>: <description>')" refuse "COMMIT '$bad'"; chk "      refused BY the format check" 'grep -q "must look like" <<<"$LAST_OUT"'; done
printf 'sm() { local re="^($1)\$"; [[ $2 =~ $re ]]; }\n' > "$T/sm.sh"
t "m3: obj_name matcher matches $A-local"                ok     "source $T/sm.sh; sm \"\$_SIL_OBJ\" $A-local"
t "m3: obj_name matcher matches $A-r2 and $A-dst-local"  ok     "source $T/sm.sh; sm \"\$_SIL_OBJ\" $A-r2 && sm \"\$_SIL_OBJ\" $A-dst-local"
t "m3: obj_name matcher does NOT match a sibling $A-foo"  refuse "source $T/sm.sh; sm \"\$_SIL_OBJ\" $A-foo"
t "m3: obj_name matcher does NOT match $A-foo-local"     refuse "source $T/sm.sh; sm \"\$_SIL_OBJ\" $A-foo-local"
t "m3: name matcher matches exactly $A"                  ok     "source $T/sm.sh; sm \"\$_SIL_NAME\" $A"
t "m3: name matcher does NOT match a sibling $A-foo"     refuse "source $T/sm.sh; sm \"\$_SIL_NAME\" $A-foo"
t "m3: pod matcher matches a Deployment pod"             ok     "source $T/sm.sh; sm \"\$_SIL_POD\" $A-7d9f8c6b5-x2x4z"
t "m3: pod matcher matches a mover pod"                  ok     "source $T/sm.sh; sm \"\$_SIL_POD\" volsync-src-$A-local-abcde"
t "m3: pod matcher does NOT match a sibling $A-foo"      refuse "source $T/sm.sh; sm \"\$_SIL_POD\" $A-foo"
t "m3: pod matcher does NOT match a sibling's mover pod" refuse "source $T/sm.sh; sm \"\$_SIL_POD\" volsync-src-$A-foo-local-abcde"

echo "== data baseline / compare (M6, m5) =="
HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; HASHB=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; EMPTYH=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
JOBN=0
mk() { # mk <file> <ns> <pvc> <utc> [live-file hash] [extra ./$LF.important-backup hash] — synthesised from the conf's EXPECT_FILES / EXPECT_DIRS / REPORT_DIRS; unique job id per call
  JOBN=$((JOBN+1))
  { echo "# hchk-$JOBN $2 $3 $4"; for f in $EXPECT_FILES; do if [ "$f" = "$LF" ]; then echo "${5:-$HASH}  ./$f"; else echo "$HASH  ./$f"; fi; done
    echo "$HASH  ./$LF-wal"; [ -n "${6:-}" ] && echo "$6  ./$LF.important-backup"; for d in $EXPECT_DIRS; do echo "$HASH  ./$d/a"; done
    echo ---COUNTS; for d in $EXPECT_DIRS; do echo "$d 346"; done; for d in $REPORT_DIRS; do echo "$d 0"; done; } > "$1"
}
echo 2026-09-24T18:31:00Z > "$STATE/T-quiesced.txt"
mk "$T/base.txt" $OLDNS $A 2026-09-24T18:32:00Z
t "baseline_ok: the conf's layout accepted"              ok     "data_baseline_ok $T/base.txt"
grep -v "  \./$F1\$" "$T/base.txt" > "$T/b1.txt"
t "baseline_ok: missing EXPECT_FILES entry ($F1) refused" refuse "data_baseline_ok $T/b1.txt"
sed "s/^$HASH  .\/$LF\$/$EMPTYH  .\/$LF/" "$T/base.txt" > "$T/b2.txt"
t "baseline_ok: EMPTY $LF refused"                       refuse "data_baseline_ok $T/b2.txt"
sed "s/^$D1 346/$D1 0/" "$T/base.txt" > "$T/b3.txt"
t "baseline_ok: EXPECT_DIRS entry ($D1) with 0 files refused" refuse "data_baseline_ok $T/b3.txt"
if [ -n "$RD" ]; then t "baseline_ok: an EMPTY REPORT_DIRS entry ($RD) is only reported" ok "data_baseline_ok $T/base.txt"; else chk "      (no REPORT_DIRS in this conf)" true; fi
mk "$T/after.txt" $OLDNS $A 2026-09-24T18:40:00Z
t "compare: identical accepted (after in OLD: no W12-PASS)" ok   "data_compare $T/base.txt $T/after.txt"
chk "      no W12-PASS for an OLD-ns after listing" '[ ! -e "$STATE/W12-PASS" ]'
mk "$T/after-db.txt" $OLDNS $A 2026-09-24T18:40:00Z $HASHB
t "compare: CHANGED live file ($LF) is DETECTED"         refuse "data_compare $T/base.txt $T/after-db.txt"
t "compare --ignore-live ignores the live file"          ok     "data_compare --ignore-live $T/base.txt $T/after-db.txt"
mk "$T/base-x.txt" $OLDNS $A 2026-09-24T18:32:00Z "" $HASH; mk "$T/after-x.txt" $OLDNS $A 2026-09-24T18:40:00Z "" $HASHB
t "compare --ignore-live does NOT ignore ./$LF.important-backup (anchored pattern, m5)" refuse "data_compare --ignore-live $T/base-x.txt $T/after-x.txt"
grep -v "/$D1/" "$T/after.txt" > "$T/after-miss.txt"
t "compare: missing file detected"                       refuse "data_compare $T/base.txt $T/after-miss.txt"
mk "$T/base-old.txt" $OLDNS $A 2026-09-24T17:00:00Z
t "compare: baseline OLDER than T-quiesced refused"      refuse "data_compare $T/base-old.txt $T/after.txt"
mk "$T/base-ai.txt" $NEWNS $A 2026-09-24T18:32:00Z
t "compare: baseline from another ns refused"            refuse "data_compare $T/base-ai.txt $T/after.txt"
tail -n +2 "$T/base.txt" > "$T/base-nohdr.txt"
t "compare: baseline without header refused"             refuse "data_compare $T/base-nohdr.txt $T/after.txt"
mk "$T/after-older.txt" $OLDNS $A 2026-09-24T18:00:00Z
t "compare: after older than baseline refused"           refuse "data_compare $T/base.txt $T/after-older.txt"
mk "$T/after-same-ts.txt" $OLDNS $A 2026-09-24T18:32:00Z
t "compare: after with the SAME timestamp refused (strictly newer, m5)" refuse "data_compare $T/base.txt $T/after-same-ts.txt"
t "compare: the baseline compared with ITSELF refused (m5)" refuse "data_compare $T/base.txt $T/base.txt"
mk "$T/after-media.txt" media $A 2026-09-24T18:40:00Z
t "compare: after from ns media refused (m5)"            refuse "data_compare $T/base.txt $T/after-media.txt"
mk "$T/after-otherpvc.txt" $OLDNS some-other-pvc 2026-09-24T18:40:00Z
t "compare: after from another pvc refused (m5)"         refuse "data_compare $T/base.txt $T/after-otherpvc.txt"
rm -f "$STATE/T-quiesced.txt"
t "compare: no T-quiesced.txt refused"                   refuse "data_compare $T/base.txt $T/after.txt"
echo 2026-09-24T18:31:00Z > "$STATE/T-quiesced.txt"
c=$(conf_with LIVE_FILES ""); MOVE_CONF=$c t "compare --ignore-live refused when LIVE_FILES is empty" refuse "data_compare --ignore-live $T/base.txt $T/after-db.txt"
mk "$T/after-new.txt" $NEWNS $A 2026-09-24T18:41:00Z
t "compare: identical, after from NEW/$A -> W12-PASS"     ok     "data_compare $T/base.txt $T/after-new.txt"
chk "      W12-PASS written with both sha256 lines" '[ -s "$STATE/W12-PASS" ] && grep -q "^baseline $T/base.txt [0-9a-f]\{64\}$" "$STATE/W12-PASS" && grep -q "^after $T/after-new.txt [0-9a-f]\{64\}$" "$STATE/W12-PASS"'
mk "$T/after-new-db.txt" $NEWNS $A 2026-09-24T18:42:00Z $HASHB
t "compare: a DIFFERING NEW/$A listing is refused and REMOVES W12-PASS" refuse "data_compare $T/base.txt $T/after-new-db.txt"
chk "      W12-PASS removed" '[ ! -e "$STATE/W12-PASS" ]'
t "compare --ignore-live never records W12-PASS"          ok     "data_compare --ignore-live $T/base.txt $T/after-new-db.txt"
chk "      no W12-PASS after --ignore-live" '[ ! -e "$STATE/W12-PASS" ]'

echo "== data_check =="
pvc $OLDNS $A $PV0 Bound; pvc $NEWNS volsync-$A-dst-local-dest x Bound; pvc $NEWNS $A $PV0 Bound
grep -v '^#' "$T/base.txt" > "$FX/joblogs.txt"
t "data_check WITHOUT HM_WINDOW refused, nothing applied" refuse "data_check $OLDNS $T/x.out"; chk "      no apply reached kubectl" '[ "$(grep -c " apply " "$FX/calls.log")" = 0 ]'
HM_WINDOW=yes t "data_check refuses a non-app pvc"       refuse "data_check $OLDNS $T/x.out some-other-pvc"
HM_WINDOW=yes t "data_check refuses ns media"            refuse "data_check media $T/x.out"
HM_WINDOW=yes t "data_check refuses tries=61"            refuse "data_check $OLDNS $T/x.out $A 61"
HM_WINDOW=yes t "data_check refuses tries=0"             refuse "data_check $OLDNS $T/x.out $A 0"
rm -f "$FX/pvc-$OLDNS-$A.json"
HM_WINDOW=yes t "data_check: claim MISSING -> refuse"    refuse "data_check $OLDNS $T/x.out"; chk "      no apply reached kubectl" '[ "$(grep -c " apply " "$FX/calls.log")" = 0 ]'
pvc $OLDNS $A $PV0 Pending
HM_WINDOW=yes t "data_check: claim PENDING -> refuse"    refuse "data_check $OLDNS $T/x.out"; chk "      no apply reached kubectl" '[ "$(grep -c " apply " "$FX/calls.log")" = 0 ]'
pvc $OLDNS $A $PV0 Bound
HM_WINDOW=yes t "data_check happy path saves listing WITH header" ok "data_check $OLDNS $T/saved.out"
chk "      header ok: $(head -1 "$T/saved.out" 2>/dev/null)" 'head -1 "$T/saved.out" | grep -qE "^# hchk-[0-9]+ $OLDNS $A 20"'
HM_WINDOW=yes t "data_check on the RD dest pvc"          ok     "data_check $NEWNS $T/saved2.out volsync-$A-dst-local-dest"
chk "      job deleted with --cascade=foreground" 'grep -q -- "--cascade=foreground" "$FX/calls.log"'
HM_WINDOW=yes FAKE_POD_LEFT=1 t "data_check: lingering helper pod is an ERROR" refuse "data_check $OLDNS $T/saved3.out"
HM_WINDOW=yes FAKE_JOB_STATE=pending t "data_check TIMEOUT (1 try) -> failure AND Job delete issued" refuse "data_check $OLDNS $T/saved4.out $A 1"
chk "      Job delete issued on timeout, nothing saved" 'grep -q "delete job hchk-" "$FX/calls.log" && [ ! -e "$T/saved4.out" ]'
: > "$FX/calls.log"
( HM_WINDOW=yes FAKE_JOB_STATE=pending /bin/bash -c "source $G; data_check $OLDNS $T/saved5.out $A 40" >/dev/null 2>&1 & echo $! > "$T/kill.pid"; wait ) &
sleep 3; kill -TERM "$(cat "$T/kill.pid")" 2>/dev/null; sleep 4
chk "trap fires on SIGTERM: Job deleted (--cascade=foreground --wait=false)" 'grep -q "delete job hchk-.*--cascade=foreground --wait=false" "$FX/calls.log"'
chk "N9: the data_check process is GONE after SIGTERM (the trap exits, it does not keep polling)" '! kill -0 "$(cat "$T/kill.pid")" 2>/dev/null'
# m1: the Job itself must be self-limiting even if the client is SIGKILLed. Run the real function against a kubectl that captures the applied manifest.
mkdir -p "$T/capbin"; cat > "$T/capbin/kubectl" <<CAP
#!/bin/bash
for a in "\$@"; do [ "\$a" = apply ] && cat > "$FX/applied.yaml"; done
exec "$GD/test/bin/kubectl" "\$@"
CAP
chmod +x "$T/capbin/kubectl"; cp "$GD/test/bin/gh" "$T/capbin/gh"
mkdir -p "$T/capgd/test"; cp "$G" "$GD/confparse.sh" "$GD/kn-guard.sh" "$T/capgd/"; ln -sf "$T/capbin" "$T/capgd/test/bin"
HM_WINDOW=yes PATH="$T/capgd/test/bin:$PATH" /bin/bash -c "source $T/capgd/move-guards.sh; data_check $OLDNS $T/saved6.out" >/dev/null 2>&1
chk "the applied Job (kn-guard sends canonical JSON) carries activeDeadlineSeconds and ttlSecondsAfterFinished (m1)" 'jq -e ".spec.activeDeadlineSeconds == 420 and .spec.ttlSecondsAfterFinished == 60" "$FX/applied.yaml" >/dev/null'
chk "the applied Job label is ${A}-move and its script counts the conf's dirs" 'jq -e --arg k "$A-move" ".metadata.labels[\$k] == \"helper\"" "$FX/applied.yaml" >/dev/null && grep -q "for d in $EXPECT_DIRS" "$FX/applied.yaml"'

echo "== interlocks =="
out=$(PATH="$GD/test/bin:/usr/bin:/bin" /bin/bash -c "source $G" 2>&1); rc=$?
chk "a missing dependency (jq/yq/git not on PATH) is refused cleanly at load (rc=$rc)" '[ $rc -ne 0 ] && grep -q "require" <<<"$out"'

out=$(HM_FAKE=1 PATH=/usr/bin:/bin:/opt/homebrew/bin:$HOME/.local/bin /bin/bash -c "source $G" 2>&1); rc=$?
chk "real kubectl first + HM_FAKE=1 -> guards exit before any call (rc=$rc)" '[ $rc -ne 0 ] && grep -q "not the harness fake" <<<"$out"'
out=$(HM_FAKE=1 /bin/bash -c "PATH=$GD/nonexistent:/usr/bin:/bin; source $G" 2>&1); rc=$?
chk "kubectl/gh missing from the fake dir -> refused (rc=$rc)" '[ $rc -ne 0 ]'

echo "== pull requests (M1, M4, M6): the merge preconditions live IN pr_merge =="
prep_pr1() { # the W-8 world: PV Retain+Bound to OLD/app, OLD HR suspended, OLD ks running, deploy at 0, no pods, quiesce + T0 on record, both RS accepted after T0
  pvjson $PV0 1 $OLDNS Bound Retain; pvc $OLDNS $A $PV0 Bound; rm -f "$FX/pvc-$NEWNS-$A.json"
  echo '{"spec":{"suspend":true}}' > "$FX/hr-$OLDNS-$A.json"; echo '{"spec":{}}' > "$FX/ks-$OLDNS-$A.json"; echo '{"items":[{"spec":{"replicas":0}}]}' > "$FX/deploys-$OLDNS.json"; rm -f "$FX/pods-$OLDNS.json"
  echo 2026-09-24T18:00:00Z > "$STATE/T0.txt"; echo 2026-09-24T17:59:00Z > "$STATE/T-quiesced.txt"
  rs $OLDNS $A-local "" 2026-09-24T18:05:00Z "$GOOD"; rs $OLDNS $A-r2 "" 2026-09-24T18:06:00Z "$GOOD"
  pr $P1 OPEN true $A-move-pr1 $SHA1 main MERGEABLE; pr $P2 OPEN true $A-move-pr2 $SHA2 main MERGEABLE; echo 0 > "$FX/merged-pr1.txt"; rm -f "$STATE/SINCE.txt" "$STATE/W12-PASS"
}
prep_pr1
t "pr_merge: no number refused"                          refuse "pr_merge '' $SHA1";      chk "      gh writes: 0" '[ "$(gh_writes)" = 0 ]'
t "pr_merge: non-numeric refused"                        refuse "pr_merge abc $SHA1"
t "pr_merge: a number that is not this move's PR refused" refuse "pr_merge 99999 $SHA1"
t "pr_merge: short SHA refused"                          refuse "pr_merge $P1 ${SHA1%??????????????????????????????}"
t "pr_merge: wrong SHA refused"                          refuse "pr_merge $P1 $SHA2";     chk "      gh writes: 0" '[ "$(gh_writes)" = 0 ]'
t "pr_merge: PR 2 before PR 1 REFUSED"                   refuse "pr_merge $P2 $SHA2";     chk "      gh writes: 0" '[ "$(gh_writes)" = 0 ]'
pr $P1 OPEN false some-other-branch $SHA1 main MERGEABLE
t "pr_merge: foreign branch refused"                     refuse "pr_merge $P1 $SHA1"
pr $P1 OPEN false $A-move-pr1 $SHA1 develop MERGEABLE
t "pr_merge: base != main refused"                       refuse "pr_merge $P1 $SHA1"
pr $P1 MERGED false $A-move-pr1 $SHA1 main MERGEABLE
t "pr_merge: already merged refused"                     refuse "pr_merge $P1 $SHA1"
pr $P1 OPEN false $A-move-pr2 $SHA1 main MERGEABLE
t "pr_merge: PR1 number with the PR2 branch refused"     refuse "pr_merge $P1 $SHA1"
prep_pr1
echo "-- M1: PR 1 refuses unless the world is in the W-8 state --"
pvjson $PV0 1 $OLDNS Bound Delete
t "PR 1 with the PV reclaim = Delete -> REFUSED, 0 gh writes"  refuse "pr_merge $P1 $SHA1"; chk "      gh writes: 0" '[ "$(gh_writes)" = 0 ]'; chk "      no SINCE.txt" '[ ! -e "$STATE/SINCE.txt" ]'
pvjson $PV0 1 $OLDNS Released Retain
t "PR 1 with the PV Released -> REFUSED"                 refuse "pr_merge $P1 $SHA1"; chk "      gh writes: 0" '[ "$(gh_writes)" = 0 ]'
pvjson $PV0 1 $NEWNS Bound Retain
t "PR 1 with the PV already claimed by NEW -> REFUSED"   refuse "pr_merge $P1 $SHA1"
pvjson $PV0 0 $OLDNS Bound Retain
t "PR 1 with the PV unlabelled -> REFUSED"               refuse "pr_merge $P1 $SHA1"
pvjson $PV0 1 $OLDNS Bound Retain
echo '{"spec":{"suspend":false}}' > "$FX/hr-$OLDNS-$A.json"
t "PR 1 with the OLD HelmRelease NOT suspended -> REFUSED" refuse "pr_merge $P1 $SHA1"; chk "      gh writes: 0" '[ "$(gh_writes)" = 0 ]'
echo '{"spec":{"suspend":true}}' > "$FX/hr-$OLDNS-$A.json"
echo '{"spec":{"suspend":true}}' > "$FX/ks-$OLDNS-$A.json"
t "PR 1 with the OLD Kustomization still suspended (trap 6) -> REFUSED" refuse "pr_merge $P1 $SHA1"; chk "      gh writes: 0" '[ "$(gh_writes)" = 0 ]'
echo '{"spec":{}}' > "$FX/ks-$OLDNS-$A.json"
echo '{"items":[{"spec":{"replicas":1}}]}' > "$FX/deploys-$OLDNS.json"
t "PR 1 with deploy replicas=1 -> REFUSED"               refuse "pr_merge $P1 $SHA1"
echo '{"items":[{"spec":{"replicas":0}},{"spec":{"replicas":1}}]}' > "$FX/deploys-$OLDNS.json"
t "PR 1 with ONE of two labelled deployments still running -> REFUSED (N13)" refuse "pr_merge $P1 $SHA1"
echo '{"items":[]}' > "$FX/deploys-$OLDNS.json"
t "PR 1 with NO labelled deployment found -> REFUSED (N13: cannot prove replicas 0)" refuse "pr_merge $P1 $SHA1"
echo '{"items":[{"spec":{"replicas":0}}]}' > "$FX/deploys-$OLDNS.json"
rs $OLDNS $A-local 2026-09-24T18:05:30Z 2026-09-24T18:05:00Z "$GOOD"
t "PR 1 with a sync in flight at merge time -> REFUSED (N13)" refuse "pr_merge $P1 $SHA1"; chk "      gh writes: 0" '[ "$(gh_writes)" = 0 ]'
rs $OLDNS $A-local "" 2026-09-24T18:05:00Z "$GOOD"
t "N8: SINCE.txt unwritable (a directory) -> PR 1 REFUSED even inside an && list, 0 gh writes" refuse "mkdir -p \$MOVE_DIR/SINCE.txt; pr_merge $P1 $SHA1 && echo merged"; chk "      gh writes: 0" '[ "$(gh_writes)" = 0 ]'; rm -rf "$STATE/SINCE.txt"
echo '{"items":[{"metadata":{"name":"hchk-left"},"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"'"$A"'"}}]}}]}' > "$FX/pods-$OLDNS.json"
t "PR 1 with a pod (even Completed) still mounting the claim -> REFUSED" refuse "pr_merge $P1 $SHA1"
rm -f "$FX/pods-$OLDNS.json"
mv "$STATE/T-quiesced.txt" "$STATE/tq.bak"
t "PR 1 without T-quiesced.txt -> REFUSED"               refuse "pr_merge $P1 $SHA1"
mv "$STATE/tq.bak" "$STATE/T-quiesced.txt"
mv "$STATE/T0.txt" "$STATE/t0.bak"
t "PR 1 without T0.txt (W-5 not done) -> REFUSED"        refuse "pr_merge $P1 $SHA1"
mv "$STATE/t0.bak" "$STATE/T0.txt"
rs $OLDNS $A-r2 "" 2026-09-24T17:00:00Z "$GOOD"
t "PR 1 with a STALE r2 backup (lastSyncTime <= T0) -> REFUSED" refuse "pr_merge $P1 $SHA1"; chk "      gh writes: 0" '[ "$(gh_writes)" = 0 ]'
rs $OLDNS $A-r2 "" 2026-09-24T18:06:00Z $'Directory is empty skipping backup\nOPERATION_RESULT: FAILURE'
t "PR 1 with an empty-source r2 backup -> REFUSED"       refuse "pr_merge $P1 $SHA1"
rs $OLDNS $A-r2 "" 2026-09-24T18:06:00Z "$GOOD"
t "PR 1 (draft) in the W-8 state -> ready then merge, head pinned" ok "pr_merge $P1 $SHA1"
chk "      ready + merge --merge --match-head-commit ok" 'grep -q "gh pr ready $P1" "$FX/calls.log" && grep -q "gh pr merge $P1 -R $GH_REPO --merge --match-head-commit $SHA1" "$FX/calls.log"'
chk "      pr_merge WROTE SINCE.txt itself (no manual step)" '[ -s "$STATE/SINCE.txt" ]'
chk "      every gh call carries -R $GH_REPO ($(grep -c '^gh ' "$FX/calls.log") calls)" '! grep "^gh " "$FX/calls.log" | grep -qv -- "-R $GH_REPO"'
pvjson $PV0 1 $NEWNS Bound Delete; pvc $NEWNS $A $PV0 Bound
t "after an allowed PR 1 merge, pv_reclaim Delete needs B10_OK (SINCE.txt exists)" refuse "pv_reclaim $PV0 Delete"
echo "-- M4/M6: PR 2 refuses unless PR 1 really merged AND the W-12 content match is on record --"
touch -t 202601010000 "$STATE/SINCE.txt"
pvjson $PV0 1 $NEWNS Bound Retain; pvc $NEWNS $A $PV0 Bound
echo 1 > "$FX/merged-pr1.txt"; pr $P1 OPEN true $A-move-pr1 $SHA1 main MERGEABLE; pr $P2 OPEN true $A-move-pr2 $SHA2 main MERGEABLE
t "PR 2 with PR 1 still OPEN but a historic merged $A-move-pr1 branch -> REFUSED (M4)" refuse "pr_merge $P2 $SHA2"; chk "      gh writes: 0" '[ "$(gh_writes)" = 0 ]'
pr $P1 MERGED false $A-move-pr1 $SHA2 main MERGEABLE
t "PR 2 with PR 1 MERGED but at a different head SHA -> REFUSED" refuse "pr_merge $P2 $SHA2"
pr $P1 MERGED false $A-move-pr1 $SHA1 main MERGEABLE
t "PR 2 without W12-PASS -> REFUSED (M6), 0 gh writes"   refuse "pr_merge $P2 $SHA2"; chk "      gh writes: 0" '[ "$(gh_writes)" = 0 ]'
FUT=2099-01-01T00:00:00Z   # W-12 listings must be newer than SINCE.txt (written with the real clock by pr_merge)
mk "$T/w12-base.txt" $OLDNS $A 2026-09-24T18:32:00Z; mk "$T/w12-after.txt" $NEWNS $A $FUT
echo 2026-09-24T18:31:00Z > "$STATE/T-quiesced.txt"
echo forged > "$STATE/W12-PASS"; touch "$STATE/W12-PASS"
t "N3: PR 2 with a FORGED marker (no baseline/after lines) -> REFUSED" refuse "pr_merge $P2 $SHA2"; chk "      gh writes: 0" '[ "$(gh_writes)" = 0 ]'
printf 'baseline %s %s\nbaseline %s %s\nafter %s %s\n' "$T/w12-base.txt" "$(shasum -a 256 "$T/w12-base.txt" | cut -d' ' -f1)" "$T/w12-base.txt" "$(shasum -a 256 "$T/w12-base.txt" | cut -d' ' -f1)" "$T/w12-after.txt" "$(shasum -a 256 "$T/w12-after.txt" | cut -d' ' -f1)" > "$STATE/W12-PASS"; touch "$STATE/W12-PASS"
t "N3: PR 2 with TWO baseline lines -> REFUSED"          refuse "pr_merge $P2 $SHA2"
mk "$T/n1.txt" $NEWNS $A 2026-09-24T18:40:00Z; mk "$T/n2.txt" $NEWNS $A 2026-09-24T18:45:00Z; rm -f "$STATE/W12-PASS"
t "N3: data_compare NEW-vs-NEW (ens=NEW) is accepted as a comparison ..." ok "data_compare $T/n1.txt $T/n2.txt $NEWNS"
chk "      ... but writes NO W12-PASS" '[ ! -e "$STATE/W12-PASS" ]'
t "N3: PR 2 after only a NEW-vs-NEW comparison -> REFUSED" refuse "pr_merge $P2 $SHA2"
t "N3: data_compare with baseline ns=media REFUSED"      refuse "data_compare $T/w12-base.txt $T/w12-after.txt media"
t "W-12: data_compare OLD baseline vs NEW/$A -> W12-PASS" ok     "data_compare $T/w12-base.txt $T/w12-after.txt"
mk "$T/w12-old-after.txt" $NEWNS $A 2026-09-24T18:50:00Z
printf 'baseline %s %s\nafter %s %s\n' "$T/w12-base.txt" "$(shasum -a 256 "$T/w12-base.txt" | cut -d' ' -f1)" "$T/w12-old-after.txt" "$(shasum -a 256 "$T/w12-old-after.txt" | cut -d' ' -f1)" > "$STATE/W12-PASS"; touch "$STATE/W12-PASS"
t "N3: a W-12 after-listing OLDER than SINCE (taken before PR 1 merged) -> REFUSED" refuse "pr_merge $P2 $SHA2"
t "W-12 again"                                           ok     "data_compare $T/w12-base.txt $T/w12-after.txt"
touch -t 202601010000 "$STATE/W12-PASS"
t "PR 2 with W12-PASS OLDER than SINCE.txt -> REFUSED"   refuse "pr_merge $P2 $SHA2"
touch "$STATE/W12-PASS"
echo tamper >> "$T/w12-after.txt"
t "PR 2 with the after listing changed since W12-PASS -> REFUSED" refuse "pr_merge $P2 $SHA2"
mk "$T/w12-after.txt" $NEWNS $A $FUT; t "W-12 once more" ok "data_compare $T/w12-base.txt $T/w12-after.txt"
pvjson $PV0 1 $OLDNS Released Retain
t "PR 2 with the PV not Bound to NEW -> REFUSED"         refuse "pr_merge $P2 $SHA2"
pvjson $PV0 1 $NEWNS Bound Delete
t "PR 2 with the PV reclaim Delete -> REFUSED"           refuse "pr_merge $P2 $SHA2"
pvjson $PV0 1 $NEWNS Bound Retain
t "PR 2 with PR 1 merged, W12-PASS on record, PV Retain+Bound to NEW -> ok" ok "pr_merge $P2 $SHA2"
pr $P1 OPEN true $A-move-pr1 $SHA1 main MERGEABLE
t "pr_mergeable: MERGEABLE + head ok"                    ok     "pr_mergeable $P1 $SHA1 1"
pr $P1 OPEN true $A-move-pr1 $SHA1 main UNKNOWN
t "pr_mergeable: UNKNOWN retried then gives up"          refuse "pr_mergeable $P1 $SHA1 2"
pr $P1 OPEN true $A-move-pr1 $SHA1 main CONFLICTING
t "pr_mergeable: CONFLICTING refused"                    refuse "pr_mergeable $P1 $SHA1 1"
pr $P1 OPEN true $A-move-pr1 $SHA2 main MERGEABLE
t "pr_mergeable: head moved refused"                     refuse "pr_mergeable $P1 $SHA1 1"
pr $P1 OPEN true $A-move-pr1 $SHA1 main MERGEABLE
t "pr_mergeable: a SHA that is not the pinned one refused (m6)" refuse "pr_mergeable $P1 $SHA2 1"
for n in 0 abc 13 1000; do t "pr_mergeable tries=[$n] refused (m2)" refuse "pr_mergeable $P1 $SHA1 '$n'"; done

echo "== wait-loop bounds (600 s tool limit; deadline-bound) =="
t "wait_running 101 refused (>100)"                      refuse "wait_running $NEWNS 101"
t "wait_running 0 refused"                               refuse "wait_running $NEWNS 0"
t "wait_running non-numeric refused"                     refuse "wait_running $NEWNS abc"
t "wait_manual 51 refused (>50 x 10 s)"                  refuse "wait_manual $OLDNS $A-local tag 51"
t "wait_pv_phase 151 refused"                            refuse "wait_pv_phase $PV0 Released 151"

echo "== drift_check / base_check / w0b (scratch repo; every DRIFT_PATHS entry is exercised) =="
git init -q --bare "$GD/origin.git"; git clone -q "$GD/origin.git" "$WT" 2>/dev/null
GC="git -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null"
( cd "$WT" && git checkout -q -b main && for p in $DRIFT_PATHS; do mkdir -p "$p" && echo a > "$p/x"; done && mkdir -p kubernetes/apps/zz-unrelated/app && echo a > kubernetes/apps/zz-unrelated/app/y \
  && git add -A && $GC commit -q -m base && git push -q origin main && git rev-parse HEAD > "$T/base.sha" \
  && git checkout -q -b move && echo m > move.txt && git add -A && $GC commit -q -m move1 && git rev-parse HEAD > "$T/c1.sha" && git checkout -q main )
BASE=$(cat "$T/base.sha"); C1=$(cat "$T/c1.sha")
setkey() { sed -i.bak "s/^$1=.*/$1=\"$2\"/" "$MC"; rm -f "$MC.bak"; }
setkey BASE_SHA "$BASE"; setkey PR1_SHA "$C1"; pr $P1 OPEN true $A-move-pr1 $C1 main MERGEABLE
t "base_check: BASE_SHA is the parent of PR1_SHA"        ok     'base_check'
t "drift_check: no drift passes"                         ok     'drift_check'
t "w0b passes with a right base, no drift and two good PRs" ok  'w0b'
setkey BASE_SHA "$C1"
t "base_check: a BASE_SHA that is not PR1_SHA's parent REFUSED (m7)" refuse 'base_check'
t "drift_check with a wrong BASE_SHA REFUSED (would hide drift)"     refuse 'drift_check'
setkey BASE_SHA "$BASE"; setkey PR1_SHA "$SHA1"
t "base_check: PR1_SHA not present locally REFUSED"      refuse 'base_check'
setkey PR1_SHA "$C1"
( cd "$WT" && git checkout -q --orphan alt && git rm -rq --cached . && echo a > alt.txt && git add alt.txt && $GC commit -q -m a0 && git rev-parse HEAD > "$T/a0.sha" && echo b >> alt.txt && $GC commit -qam a1 && git rev-parse HEAD > "$T/a1.sha"; git checkout -qf main )
setkey BASE_SHA "$(cat "$T/a0.sha")"; setkey PR1_SHA "$(cat "$T/a1.sha")"
t "N13: BASE_SHA == PR1_SHA^ but NOT an ancestor of origin/main -> REFUSED" refuse 'base_check'
setkey BASE_SHA "$BASE"; setkey PR1_SHA "$C1"
( cd "$WT" && echo b >> kubernetes/apps/zz-unrelated/app/y && $GC commit -qam unrelated && git push -q origin main )
t "drift_check: an UNRELATED change on main passes"      ok     'drift_check'
for p in $DRIFT_PATHS; do
  ( cd "$WT" && echo b >> "$p/x" && $GC commit -qam "touch $p" && git push -q origin main )
  t "drift_check: a change under $p is DETECTED"         refuse 'drift_check'
  ( cd "$WT" && $GC revert --no-edit HEAD >/dev/null && git push -q origin main )
done
t "drift_check: clean again after the reverts"           ok     'drift_check'
( cd "$WT" && echo b >> "$(echo $DRIFT_PATHS | awk '{print $1}')/x" && $GC commit -qam bump && git push -q origin main )
t "w0b fails on drift even with good PRs"                refuse 'w0b'
git -C "$WT" checkout -q main; echo z > "$WT/kubernetes/apps/zz-unrelated/app/y"
( cd "$WT" && git add -A && MOVE_COAUTHOR='Test Model <t@example.com>' /bin/bash -c "source $G; COMMIT 'scope: subject'" >/dev/null 2>&1 )
chk "COMMIT with MOVE_COAUTHOR writes the trailer, bot author" 'git -C "$WT" log -1 --format=%B | grep -q "^Co-Authored-By: Test Model <t@example.com>$" && [ "$(git -C "$WT" log -1 --format=%an)" = "fizz-bot-bvn[bot]" ]'

echo; echo "final: passed=$pass failed=$fail   (app=$A)"
[ "$fail" -eq 0 ]
