#!/bin/bash
# Guard test harness: a scratch COPY of the guards in a scratch dir (so GUARDS_DIR/R/MOVE_DIR all resolve inside it), a fake kubectl and a fake gh first on
# PATH. No real cluster or GitHub call is made. Run under /bin/bash (macOS 3.2):   /bin/bash run.sh
T=${T:-/private/tmp/claude-501/gt}; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Interlock (N4): tests run ONLY under /bin/bash with the harness fakes first on PATH; HM_FAKE=1 makes the guards themselves refuse if a real kubectl/gh wins.
[ -n "${BASH_VERSION:-}" ] || { echo "run under /bin/bash (never zsh: nested zsh -c re-reads ~/.zshenv and puts the REAL kubectl first)" >&2; exit 1; }
export FX=$T/fx PATH=$HERE/bin:$PATH HM_FAKE=1
case "$(command -v kubectl)" in "$HERE"/bin/kubectl) ;; *) echo "REFUSING: kubectl resolves to $(command -v kubectl), not the harness fake" >&2; exit 1;; esac
rm -rf "$T/gd" "$FX"; mkdir -p "$T/gd" "$FX"
cp "$HERE/../hermes-move-guards.sh" "$T/gd/hermes-move-guards.sh"
G=$T/gd/hermes-move-guards.sh; STATE=$T/gd/hermes-move-state
PV=pvc-12f54114-9e99-442b-bae4-53a9cb239d69
SHA1=b7667471e658da525f1dd3aaa0ca1524a96d1717; SHA2=b91dd0c9b94b959432ce4b0d2ec1b788d02a5dbf
pass=0; fail=0
t() { # t <name> <ok|refuse> <cmd>   runs the command under /bin/bash 3.2 with the guards sourced
  local name=$1 exp=$2 cmd=$3 out rc
  : > "$FX/calls.log"
  out=$(/bin/bash -c "source $G; $cmd" 2>&1); rc=$?
  if { [ "$exp" = ok ] && [ $rc -eq 0 ]; } || { [ "$exp" = refuse ] && [ $rc -ne 0 ]; }; then pass=$((pass+1)); echo "PASS  $name  (rc=$rc)"; else fail=$((fail+1)); echo "FAIL  $name  (rc=$rc) :: $out"; fi
  LAST_OUT=$out
}
mutated() { grep -cE '^(patch|label) pv' "$FX/calls.log" || true; }
gh_writes() { grep -cE '^gh pr (ready|merge)' "$FX/calls.log" || true; }
pvjson() { # pvjson <name> <label 0|1> <claimns|-> [phase=Bound]
  local lbl='{}'; [ "$2" = 1 ] && lbl='{"hermes-move":"1"}'
  local cr='null'; [ "$3" != - ] && cr='{"namespace":"'"$3"'","name":"hermes"}'
  jq -n --arg n "$1" --argjson l "$lbl" --argjson c "$cr" --arg ph "${4:-Bound}" '{metadata:{name:$n,labels:$l},spec:{claimRef:$c,persistentVolumeReclaimPolicy:"Retain"},status:{phase:$ph}}' > "$FX/pv-$1.json"
}
pvc() { jq -n --arg v "$3" --arg ph "${4:-Bound}" '{spec:{volumeName:$v},status:{phase:$ph}}' > "$FX/pvc-$1-$2.json"; }
pr() { jq -n --arg st "$2" --arg d "$3" --arg r "$4" --arg o "$5" --arg b "$6" --arg m "$7" '{state:$st,isDraft:($d=="true"),headRefName:$r,headRefOid:$o,baseRefName:$b,mergeable:$m}' > "$FX/pr-$1.json"; }

echo "== context / pinning =="
FAKE_UID=deadbeef t "wrong cluster UID exits"          refuse 'echo sourced-anyway'
t "APP not inherited"                                   ok     '[ "$APP" = hermes ]'
APP=other t "APP=other env is overridden"               ok     '[ "$APP" = hermes ]'
MOVE_DIR=/tmp/evil GUARDS_DIR=/tmp/evil t "MOVE_DIR/GUARDS_DIR env are NOT honoured" ok '[ "$MOVE_DIR" = "'"$STATE"'" ] && [ "$R" = "'"$T"'/gd/hermes-move" ]'
t "no PUSH function exists"                             refuse 'type PUSH'
t "no pv_delete function"                               refuse 'type pv_delete'
t "kn refuses kube-system"                              refuse 'kn kube-system get pods'
t "kn refuses media"                                    refuse 'kn media get pods'
t "kn allows develop"                                   ok     'kn develop get pods'
t "kn allows ai"                                        ok     'kn ai get pods'

echo "== PV guard =="
pvjson $PV 1 develop; pvjson pvc-OTHER 1 develop
t "patch a DIFFERENT PV refused"                        refuse "pv_patch pvc-OTHER -p '{}'"; echo "      mutations: $(mutated) (want 0)"
t "empty PV name refused"                               refuse "pv_patch '' -p '{}'"
pvjson $PV 0 develop
t "hermes PV without label refused"                     refuse "pv_patch $PV -p '{}'"; echo "      mutations: $(mutated) (want 0)"
pvjson $PV 1 develop
t "labelled hermes PV, claim=develop allowed"           ok     "pv_patch $PV -p '{}'"; echo "      mutations: $(mutated) (want 1)"
pvjson $PV 1 ai
t "claim=ai allowed"                                    ok     "pv_patch $PV -p '{}'"
pvjson $PV 1 -
t "EMPTY claimRef REFUSED (m9)"                         refuse "pv_patch $PV -p '{}'"; echo "      mutations: $(mutated) (want 0)"
pvjson $PV 1 media
t "claim=media refused"                                 refuse "pv_patch $PV -p '{}'"
pvjson $PV 1 develop
FAKE_API_ERROR=1 t "API error fails CLOSED"             refuse "pv_patch $PV -p '{}'"; echo "      mutations: $(mutated) (want 0)"
rm -f "$FX/pv-$PV.json"
t "PV absent refused"                                   refuse "pv_patch $PV -p '{}'"

echo "== pv_reclaim (M1) =="
pvjson $PV 1 develop Bound; pvc develop hermes $PV Bound
t "Retain on Bound PV ok"                               ok     "pv_reclaim $PV Retain"
t "Delete: Bound + claim Bound to this PV -> allow"     ok     "pv_reclaim $PV Delete"; echo "      mutations: $(mutated) (want 1)"
pvjson $PV 1 develop Released; pvc develop hermes $PV Bound
t "Delete on Released PV REFUSED"                       refuse "pv_reclaim $PV Delete"; echo "      mutations: $(mutated) (want 0)"
t "Retain on a Released PV allowed (harmless)"          ok     "pv_reclaim $PV Retain"
pvjson $PV 1 ai Available
t "Delete on Available PV REFUSED"                      refuse "pv_reclaim $PV Delete"; echo "      mutations: $(mutated) (want 0)"
pvjson $PV 1 develop Bound; rm -f "$FX/pvc-develop-hermes.json"
t "Delete: Bound but claim MISSING -> refuse"           refuse "pv_reclaim $PV Delete"; echo "      mutations: $(mutated) (want 0)"
pvc develop hermes $PV Pending
t "Delete: claim Pending -> refuse"                     refuse "pv_reclaim $PV Delete"
pvc develop hermes pvc-OTHER Bound
t "Delete: claim bound to ANOTHER PV -> refuse"         refuse "pv_reclaim $PV Delete"
t "bogus policy refused"                                refuse "pv_reclaim $PV Recycle"
echo "== pv_reclaim Delete after the move started (N2) =="
pvjson $PV 1 ai Bound; pvc ai hermes $PV Bound; mkdir -p "$STATE"; echo 2026-09-24T19:00:00Z > "$STATE/SINCE.txt"
t "Delete once SINCE.txt exists, no B10_OK -> REFUSED"   refuse "pv_reclaim $PV Delete"; echo "      mutations: $(mutated) (want 0)"
B10_OK=no t "Delete with B10_OK=no -> refused"           refuse "pv_reclaim $PV Delete"
B10_OK=yes t "Delete with B10_OK=yes (all other checks pass) -> allowed" ok "pv_reclaim $PV Delete"; echo "      mutations: $(mutated) (want 1)"
t "Retain still allowed after SINCE.txt"                ok     "pv_reclaim $PV Retain"
rm -f "$STATE/SINCE.txt"
t "Delete before the move started (T-1 undo) still allowed" ok "pv_reclaim $PV Delete"
pvjson $PV 1 develop; pvc develop hermes $PV
t "pv_repoint ai ok (uid/resourceVersion null)"         ok     "pv_repoint $PV ai"; grep -q '"uid":null,"resourceVersion":null' "$FX/calls.log" && grep -q '"name":"hermes"' "$FX/calls.log" && echo "      payload ok"
t "pv_repoint kube-system refused"                      refuse "pv_repoint $PV kube-system"
t "pv_repoint other PV refused"                         refuse "pv_repoint pvc-OTHER ai"

echo "== record_pv / app_pv =="
pvjson $PV 0 develop; pvc develop hermes $PV
t "record_pv labels the PV"                             ok     'record_pv'; grep -q "label pv $PV hermes-move=1" "$FX/calls.log" && echo "      label call ok"
pvc develop hermes pvc-OTHER; pvjson pvc-OTHER 0 develop
t "record_pv refuses a PVC naming another PV"           refuse 'record_pv'; echo "      mutations: $(mutated) (want 0)"
pvjson $PV 1 develop; pvc develop hermes $PV; rm -f "$FX/pvc-ai-hermes.json"
t "app_pv returns the hermes PV"                        ok     'app_pv'
pvc develop hermes pvc-OTHER
t "app_pv refuses a re-provisioned PV"                  refuse 'app_pv'
pvc develop hermes $PV; pvc ai hermes pvc-OTHER
t "app_pv refuses develop/ai disagreement"              refuse 'app_pv'
rm -f "$FX/pvc-develop-hermes.json" "$FX/pvc-ai-hermes.json"; mkdir -p "$STATE"; echo $PV > "$STATE/app-pv-hermes.txt"
t "app_pv with NO claim refuses (cache ignored)"        refuse 'app_pv'
pvc ai hermes $PV Pending; pvjson $PV 1 ai
t "app_pv finds a pre-bound Pending claim in ai"        ok     'app_pv'

echo "== helpers =="
rs() { jq -n --arg s "$3" --arg l "$4" --arg t "$5" '{status:{lastSyncStartTime:$s,lastSyncTime:$l,latestMoverStatus:{logs:$t}}}' > "$FX/rs-$1-$2.json"; }
GOOD=$'... Created snapshot with root abc\nSetting policy for hermes@develop:/data\nOPERATION_RESULT: SUCCESS'
rs develop hermes-local "" 2026-09-24T18:35:00Z "$GOOD"; rs develop hermes-r2 "" 2026-09-24T18:35:30Z "$GOOD"
t "no_sync_in_flight: both idle"                        ok     'no_sync_in_flight develop'
rs develop hermes-r2 2026-09-24T18:36:00Z 2026-09-24T18:35:30Z "$GOOD"
t "no_sync_in_flight: one in flight refused"            refuse 'no_sync_in_flight develop'
t "no_sync_in_flight: bad ns refused"                   refuse 'no_sync_in_flight kube-system'
t "check_backup ok, T0 before lastSyncTime"             ok     'check_backup develop hermes-local hermes@develop 2026-09-24T18:30:00Z'
t "check_backup STALE when lastSyncTime <= T0"          refuse 'check_backup develop hermes-local hermes@develop 2026-09-24T18:40:00Z'
t "check_backup wrong identity refused"                 refuse 'check_backup develop hermes-local hermes@ai'
rs develop hermes-local "" 2026-09-24T18:35:00Z $'Directory is empty skipping backup\nOPERATION_RESULT: FAILURE'
t "check_backup empty-source refused"                   refuse 'check_backup develop hermes-local hermes@develop'
t "check_backup ns media refused"                       refuse 'check_backup media hermes-local hermes@media'
printf 'NAMESPACE NAME HOSTNAMES AGE\ndevelop hermes ["h"] 19d\n' > "$FX/httproute.txt"
t "one_route: one in develop"                           ok     'one_route develop'
t "one_route: wrong ns refused"                         refuse 'one_route ai'
printf 'NAMESPACE NAME HOSTNAMES AGE\ndevelop hermes ["h"] 19d\nai hermes ["h"] 1m\n' > "$FX/httproute.txt"
t "one_route: two routes refused"                       refuse 'one_route ai'
t "am_silence without SILENCE_OK refused"               refuse 'am_silence'
[ "$(grep -c port-forward "$FX/calls.log")" = 0 ] && echo "      (no port-forward opened) ok"

echo "== data baseline / compare (M2, m1, m11) =="
HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; EMPTYH=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
mk() { # mk <file> <ns> <pvc> <utc> [state.db hash] — the REAL layout: memories is 0, sessions 2
  { echo "# hchk-1 $2 $3 $4"; for f in .env auth.json config.yaml SOUL.md; do echo "$HASH  ./$f"; done; echo "${5:-$HASH}  ./state.db"; echo "$HASH  ./state.db-wal"; echo "$HASH  ./home/a"; echo "$HASH  ./skills/s"
    echo ---COUNTS; echo home 25159; echo skills 346; echo cache 555; echo sessions 2; echo memories 0; echo cron 7; } > "$1"
}
mkdir -p "$STATE"; echo 2026-09-24T18:31:00Z > "$STATE/T-quiesced.txt"
mk "$T/base.txt" develop hermes 2026-09-24T18:32:00Z
t "baseline_ok: real layout (memories=0) accepted"      ok     "data_baseline_ok $T/base.txt"
grep -v 'SOUL.md' "$T/base.txt" > "$T/b1.txt"
t "baseline_ok: missing SOUL.md refused"                refuse "data_baseline_ok $T/b1.txt"
sed "s/^$HASH  .\/state.db\$/$EMPTYH  .\/state.db/" "$T/base.txt" > "$T/b2.txt"
t "baseline_ok: EMPTY state.db refused"                 refuse "data_baseline_ok $T/b2.txt"
sed 's/^skills 346/skills 0/' "$T/base.txt" > "$T/b3.txt"
t "baseline_ok: skills=0 refused"                       refuse "data_baseline_ok $T/b3.txt"
mk "$T/after.txt" develop hermes 2026-09-24T18:40:00Z
t "compare: identical accepted"                         ok     "data_compare $T/base.txt $T/after.txt"
mk "$T/after-db.txt" develop hermes 2026-09-24T18:40:00Z zzzz
t "compare: CHANGED state.db is DETECTED (M2)"          refuse "data_compare $T/base.txt $T/after-db.txt"
t "compare --ignore-sqlite ignores state.db"            ok     "data_compare --ignore-sqlite $T/base.txt $T/after-db.txt"
grep -v 'skills/s' "$T/after.txt" > "$T/after-miss.txt"
t "compare: missing file detected"                      refuse "data_compare $T/base.txt $T/after-miss.txt"
mk "$T/base-old.txt" develop hermes 2026-09-24T17:00:00Z
t "compare: baseline OLDER than T-quiesced refused"     refuse "data_compare $T/base-old.txt $T/after.txt"
mk "$T/base-ai.txt" ai hermes 2026-09-24T18:32:00Z
t "compare: baseline from another ns refused"           refuse "data_compare $T/base-ai.txt $T/after.txt"
tail -n +2 "$T/base.txt" > "$T/base-nohdr.txt"
t "compare: baseline without header refused"            refuse "data_compare $T/base-nohdr.txt $T/after.txt"
mk "$T/after-older.txt" develop hermes 2026-09-24T18:00:00Z
t "compare: after older than baseline refused"          refuse "data_compare $T/base.txt $T/after-older.txt"
rm -f "$STATE/T-quiesced.txt"
t "compare: no T-quiesced.txt refused"                  refuse "data_compare $T/base.txt $T/after.txt"
echo 2026-09-24T18:31:00Z > "$STATE/T-quiesced.txt"

echo "== data_check (N1, N4) =="
pvc develop hermes $PV Bound; pvc ai volsync-hermes-dst-local-dest x Bound; pvc ai hermes $PV Bound
grep -v '^#' "$T/base.txt" > "$FX/joblogs.txt"
t "data_check WITHOUT HM_WINDOW refused, nothing applied" refuse "data_check develop $T/x.out"; [ "$(grep -c ' apply ' "$FX/calls.log")" = 0 ] && echo "      no apply reached kubectl"
HM_WINDOW=yes t "data_check refuses a non-hermes pvc"   refuse "data_check develop $T/x.out some-other-pvc"
HM_WINDOW=yes t "data_check refuses ns media"           refuse "data_check media $T/x.out"
HM_WINDOW=yes t "data_check refuses tries=81"           refuse "data_check develop $T/x.out hermes 81"
rm -f "$FX/pvc-develop-hermes.json"
HM_WINDOW=yes t "data_check: claim MISSING -> refuse"   refuse "data_check develop $T/x.out"; [ "$(grep -c ' apply ' "$FX/calls.log")" = 0 ] && echo "      no apply reached kubectl"
pvc develop hermes $PV Pending
HM_WINDOW=yes t "data_check: claim PENDING -> refuse"   refuse "data_check develop $T/x.out"; [ "$(grep -c ' apply ' "$FX/calls.log")" = 0 ] && echo "      no apply reached kubectl"
pvc develop hermes $PV Bound
HM_WINDOW=yes t "data_check happy path saves listing WITH header" ok "data_check develop $T/saved.out"
head -1 "$T/saved.out" | grep -qE '^# hchk-[0-9]+ develop hermes 20' && echo "      header ok: $(head -1 "$T/saved.out")"
HM_WINDOW=yes t "data_check on the RD dest pvc"         ok     "data_check ai $T/saved2.out volsync-hermes-dst-local-dest"
grep -q -- '--cascade=foreground' "$FX/calls.log" && echo "      job deleted with --cascade=foreground"
HM_WINDOW=yes FAKE_POD_LEFT=1 t "data_check: lingering helper pod is an ERROR (m8)" refuse "data_check develop $T/saved3.out"
HM_WINDOW=yes FAKE_JOB_STATE=pending t "data_check TIMEOUT (1 try) -> failure AND Job delete issued" refuse "data_check develop $T/saved4.out hermes 1"
grep -q 'delete job hchk-' "$FX/calls.log" && echo "      Job delete issued on timeout"
[ ! -e "$T/saved4.out" ] && echo "      nothing saved on timeout"
# trap on kill: start data_check with a Job that never completes, SIGTERM the shell, the trap must delete the Job
: > "$FX/calls.log"
( HM_WINDOW=yes FAKE_JOB_STATE=pending /bin/bash -c "source $G; data_check develop $T/saved5.out hermes 40" >/dev/null 2>&1 & echo $! > "$T/kill.pid"; wait ) &
sleep 3; kill -TERM "$(cat "$T/kill.pid")" 2>/dev/null; sleep 7
if grep -q 'delete job hchk-.*--cascade=foreground --wait=false' "$FX/calls.log"; then pass=$((pass+1)); echo "PASS  trap fires on SIGTERM: Job deleted (--cascade=foreground --wait=false)"; else fail=$((fail+1)); echo "FAIL  trap did not delete the Job on SIGTERM :: $(cat "$FX/calls.log")"; fi
grep -q ' apply ' "$FX/calls.log" && echo "      (the Job had been applied before the kill)"

echo "== interlocks (N4) =="
out=$(HM_FAKE=1 PATH=/usr/bin:/bin:/opt/homebrew/bin:$HOME/.local/bin /bin/bash -c "source $G" 2>&1); rc=$?
if [ $rc -ne 0 ] && grep -q 'not the harness fake' <<<"$out"; then pass=$((pass+1)); echo "PASS  real kubectl first + HM_FAKE=1 -> guards exit before any call (rc=$rc): $(head -1 <<<"$out")"; else fail=$((fail+1)); echo "FAIL  interlock did not fire :: $out"; fi
out=$(HM_FAKE=1 PATH=$HERE/bin:$PATH /bin/bash -c "PATH=$HERE/bin/../../nonexistent:/usr/bin:/bin; source $G" 2>&1); rc=$?
[ $rc -ne 0 ] && { pass=$((pass+1)); echo "PASS  gh/kubectl missing from the fake dir -> refused (rc=$rc)"; } || { fail=$((fail+1)); echo "FAIL  reset-PATH case not refused"; }

echo "== pull requests (M3, M5) =="
pr 1913 OPEN true hermes-move-pr1 $SHA1 main MERGEABLE; pr 1914 OPEN true hermes-move-pr2 $SHA2 main MERGEABLE
echo 0 > "$FX/merged-pr1.txt"
t "pr_merge: no number refused"                         refuse "pr_merge '' $SHA1";      echo "      gh writes: $(gh_writes) (want 0)"
t "pr_merge: non-numeric refused"                       refuse "pr_merge abc $SHA1"
t "pr_merge: short SHA refused"                         refuse "pr_merge 1913 b7667471"
t "pr_merge: wrong SHA refused"                         refuse "pr_merge 1913 $SHA2";    echo "      gh writes: $(gh_writes) (want 0)"
t "pr_merge: PR 2 before PR 1 REFUSED"                  refuse "pr_merge 1914 $SHA2";    echo "      gh writes: $(gh_writes) (want 0)"
pr 1915 OPEN false some-other-branch $SHA1 main MERGEABLE
t "pr_merge: foreign branch refused"                    refuse "pr_merge 1915 $SHA1"
pr 1916 OPEN false hermes-move-pr1 $SHA1 develop MERGEABLE
t "pr_merge: base != main refused"                      refuse "pr_merge 1916 $SHA1"
pr 1917 MERGED false hermes-move-pr1 $SHA1 main MERGEABLE
t "pr_merge: already merged refused"                    refuse "pr_merge 1917 $SHA1"
t "pr_merge: PR 1 draft -> ready then merge, head pinned" ok   "pr_merge 1913 $SHA1"
grep -q "gh pr ready 1913" "$FX/calls.log" && grep -q "gh pr merge 1913 --merge --match-head-commit $SHA1" "$FX/calls.log" && echo "      ready + merge --merge --match-head-commit ok"
grep '^gh ' "$FX/calls.log" | grep -v -- '-R bluevulpine/flux-talos' | grep -q . && { fail=$((fail+1)); echo "FAIL  a gh call lacked -R bluevulpine/flux-talos"; } || { pass=$((pass+1)); echo "PASS  every gh call in pr_merge carries -R bluevulpine/flux-talos ($(grep -c '^gh ' "$FX/calls.log") calls)"; }
echo 1 > "$FX/merged-pr1.txt"
t "pr_merge: PR 2 after PR 1 merged ok"                 ok     "pr_merge 1914 $SHA2"
t "pr_mergeable: MERGEABLE + head ok"                   ok     "pr_mergeable 1913 $SHA1 1"
pr 1913 OPEN true hermes-move-pr1 $SHA1 main UNKNOWN
t "pr_mergeable: UNKNOWN retried then gives up"         refuse "pr_mergeable 1913 $SHA1 2"
pr 1913 OPEN true hermes-move-pr1 $SHA1 main CONFLICTING
t "pr_mergeable: CONFLICTING refused"                   refuse "pr_mergeable 1913 $SHA1 1"
pr 1913 OPEN true hermes-move-pr1 $SHA2 main MERGEABLE
t "pr_mergeable: head moved refused"                    refuse "pr_mergeable 1913 $SHA1 1"
pr 1913 OPEN true hermes-move-pr1 $SHA1 main MERGEABLE

echo "== wait-loop bounds (600 s tool limit) =="
t "wait_running 111 refused (>110)"                     refuse "wait_running ai 111"
t "wait_running non-numeric refused"                    refuse "wait_running ai abc"
t "wait_manual 51 refused (>50 x 10 s)"                 refuse "wait_manual develop hermes-local tag 51"
t "wait_pv_phase 151 refused"                           refuse "wait_pv_phase $PV Released 151"

echo "== drift_check / w0b (scratch repo) =="
D=$T/gd; git init -q --bare "$D/origin.git"; git clone -q "$D/origin.git" "$D/hermes-move" 2>/dev/null
( cd "$D/hermes-move" && git checkout -q -b main && mkdir -p kubernetes/apps/develop/hermes kubernetes/flux/cluster kubernetes/components/common kubernetes/apps/ai/hindsight/app && echo a > kubernetes/apps/ai/hindsight/app/helmrelease.yaml && echo a > kubernetes/apps/develop/hermes/x && echo a > kubernetes/flux/cluster/ks.yaml && echo a > kubernetes/components/common/y && git add -A \
  && git -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null commit -q -m base && git push -q origin main && git rev-parse HEAD > "$T/base.sha" )
sed -i.bak "s/^export BASE_SHA=.*/export BASE_SHA=$(cat "$T/base.sha")/" "$G"; rm -f "$G.bak"
t "drift_check: no drift passes"                        ok     'drift_check'
t "w0b passes with no drift and two good PRs"           ok     "w0b 1913 1914"
( cd "$D/hermes-move" && echo b >> kubernetes/apps/ai/hindsight/app/helmrelease.yaml && git -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null commit -qam hindsight && git push -q origin main )
t "drift_check: an UNRELATED hindsight change now PASSES (v2)" ok 'drift_check'
( cd "$D/hermes-move" && echo b >> kubernetes/apps/develop/hermes/x && git -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null commit -qam bump && git push -q origin main )
t "drift_check: a hermes bump on main is DETECTED"      refuse 'drift_check'
t "w0b fails on drift even with good PRs"               refuse "w0b 1913 1914"
rebase_to_head() { sed -i.bak "s/^export BASE_SHA=.*/export BASE_SHA=$(git -C "$D/hermes-move" rev-parse HEAD)/" "$G"; rm -f "$G.bak"; }
GC="git -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null"
( cd "$D/hermes-move" && git pull -q origin main 2>/dev/null; true ); rebase_to_head
t "drift_check: clean again after re-basing the scratch BASE" ok 'drift_check'
( cd "$D/hermes-move" && echo b >> kubernetes/flux/cluster/ks.yaml && $GC commit -qam cluster-ks && git push -q origin main ); t "drift_check: a change to kubernetes/flux/cluster/ks.yaml is DETECTED (N6)" refuse 'drift_check'
rebase_to_head
( cd "$D/hermes-move" && echo b >> kubernetes/components/common/y && $GC commit -qam common && git push -q origin main ); t "drift_check: a change under kubernetes/components/common is DETECTED (N6)" refuse 'drift_check'

echo; echo "final: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
