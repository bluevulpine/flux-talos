#!/bin/bash
# Guard test harness for pinfix-guards.sh: a scratch COPY of the guards in a scratch dir (so GUARDS_DIR / R / PIN_DIR all resolve inside it), a scratch CLONE of the
# rehearsal-pin worktree whose origin is a local bare repo, and fake kubectl / flux / curl / date first on PATH with a dead KUBECONFIG.
# No real cluster, GitHub or Alertmanager call is made. Run under /bin/bash (macOS 3.2):   /bin/bash run.sh
# shellcheck disable=SC2016
# ^ the test commands are single-quoted on purpose: they are evaluated by the inner /bin/bash, after the guards are sourced.
T=${T:-/private/tmp/claude-501/gt-pin}; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Interlock: tests run ONLY under /bin/bash with the harness fakes first on PATH; PIN_FAKE=1 makes the guards themselves refuse if a real kubectl/flux/curl wins
# or the kubeconfig is not the dead one. (A nested `zsh -c` re-reads ~/.zshenv and puts the REAL kubectl first — that once hit the live cluster.)
[ -n "${BASH_VERSION:-}" ] || { echo "run under /bin/bash (never zsh)" >&2; exit 1; }
export FX=$T/fx PATH=$HERE/bin:$PATH PIN_FAKE=1 KUBECONFIG=$T/dead-kubeconfig
for _t in kubectl flux curl date; do
  case "$(command -v "$_t")" in "$HERE"/bin/"$_t") ;; *) echo "REFUSING: $_t resolves to $(command -v "$_t"), not the harness fake" >&2; exit 1;; esac
done
REAL_REPO="$(cd "$HERE/../rehearsal-pin" && pwd)"
rm -rf "$T/gd" "$FX" "$T/origin.git" "$T/decoy"; mkdir -p "$T/gd" "$FX" "$T/decoy"
printf 'apiVersion: v1\nkind: Config\nclusters: [{name: dead, cluster: {server: "https://127.0.0.1:1"}}]\ncontexts: [{name: dead, context: {cluster: dead, user: dead}}]\ncurrent-context: dead\nusers: [{name: dead, user: {}}]\n' > "$KUBECONFIG"
cp "$HERE/../pinfix-guards.sh" "$HERE/../pinfix-states.sh" "$HERE/../kn-guard.sh" "$T/gd/"
git init -q --bare "$T/origin.git"
git clone -q --branch rehearsal-pin --single-branch "$REAL_REPO" "$T/gd/rehearsal-pin"
git -C "$T/gd/rehearsal-pin" remote set-url origin "$T/origin.git"      # BEFORE anything can push: origin is the scratch bare repo, never the real one
G=$T/gd/pinfix-guards.sh; STATE=$T/gd/pinfix-state; R=$T/gd/rehearsal-pin
HPV=pvc-12f54114-9e99-442b-bae4-53a9cb239d69
PV=pvc-11111111-2222-4333-8444-555555555555; PV2=pvc-22222222-2222-4333-8444-555555555555
pass=0; fail=0
t() { # t <name> <ok|refuse> <cmd>   runs the command under /bin/bash 3.2 with the guards sourced
  local name=$1 exp=$2 cmd=$3 out rc
  : > "$FX/calls.log"
  out=$(/bin/bash -c "source $G; $cmd" 2>&1); rc=$?
  if { [ "$exp" = ok ] && [ $rc -eq 0 ]; } || { [ "$exp" = refuse ] && [ $rc -ne 0 ]; }; then pass=$((pass+1)); echo "PASS  $name  (rc=$rc)"; else fail=$((fail+1)); echo "FAIL  $name  (rc=$rc) :: $(echo "$out" | tail -5)"; fi
  LAST_OUT=$out
}
has() { # has <name> <fixed-string>   asserts LAST_OUT contains the string
  if grep -qF -- "$2" <<<"$LAST_OUT"; then pass=$((pass+1)); echo "PASS  $1"; else fail=$((fail+1)); echo "FAIL  $1 :: wanted [$2] in: $(echo "$LAST_OUT" | tail -3)"; fi
}
lacks() { if grep -qF -- "$2" <<<"$LAST_OUT"; then fail=$((fail+1)); echo "FAIL  $1 :: unexpected [$2]"; else pass=$((pass+1)); echo "PASS  $1"; fi; }
calls() { grep -cE "$1" "$FX/calls.log" || true; }
eq() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS  $1 ($2)"; else fail=$((fail+1)); echo "FAIL  $1 :: got [$2] want [$3]"; fi; }
pvjson() { # pvjson <name> <label pin|none> <claimns|-> [phase=Bound] [reclaim=Delete]
  local lbl='{}'; [ "$2" = pin ] && lbl='{"rehearsal":"pin"}'
  local cr='null'; [ "$3" != - ] && cr='{"namespace":"'"$3"'","name":"moveprobe2"}'
  jq -n --arg n "$1" --argjson l "$lbl" --argjson c "$cr" --arg ph "${4:-Bound}" --arg rp "${5:-Delete}" '{metadata:{name:$n,labels:$l},spec:{claimRef:$c,persistentVolumeReclaimPolicy:$rp},status:{phase:$ph}}' > "$FX/pv-$1.json"
}
pvc() { jq -n --arg v "$3" --arg ph "${4:-Bound}" '{metadata:{uid:"uid-1"},spec:{volumeName:$v},status:{phase:$ph}}' > "$FX/pvc-$1-$2.json"; }
record() { grep -qx "$1" "$STATE/pins.txt" || echo "$1" >> "$STATE/pins.txt"; }
silence_on()  { echo sil-x > "$STATE/silences.txt"; echo $(( $(date +%s) + 3600 )) > "$STATE/silence-until.epoch"; }
silence_off() { : > "$STATE/silences.txt"; rm -f "$STATE/silence-until.epoch"; }
commit_state() { # commit_state <state>  (writes, stages, commits via the guards; must succeed)
  /bin/bash -c "source $G; pin_state $1 && GIT add -A kubernetes/rehearsal-pin && COMMIT 'rehearsal-pin: state $1'" >/dev/null 2>&1 || { echo "SETUP FAILED: commit_state $1" >&2; exit 2; }
}
ks_all() { # ks_all <ready-status-of-hermes-ks|...>: a list of other ks with given Ready statuses, e.g. ks_all True False
  local i=0 items='[' s; for s in "$@"; do [ $i -gt 0 ] && items="$items,"; items="$items{\"metadata\":{\"namespace\":\"ns$i\",\"name\":\"k$i\"},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"$s\"}]}}"; i=$((i+1)); done
  echo "$items,{\"metadata\":{\"namespace\":\"rehearsal-new\",\"name\":\"moveprobe2\"},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"False\"}]}}]" | jq '{items:.}' > "$FX/ks-all.json"
}
ksjson() { # ksjson <attempted-sha> <Ready status>
  jq -n --arg a "refs/heads/rehearsal-pin@sha1:$1" --arg s "$2" '{status:{lastAttemptedRevision:$a,lastAppliedRevision:$a,conditions:[{type:"Ready",status:$s,reason:"R",message:"m"}]}}' > "$FX/ks-rehearsal-new-moveprobe2.json"
}
echo '{"items":[]}' > "$FX/ks-all.json"; : > "$FX/ns.txt"; : > "$FX/flux.txt"; echo '{"items":[]}' > "$FX/pvlist.json"

echo "== interlocks =="
t "sourcing with the fakes first: passes"                       ok     'true'
FAKE_UID=deadbeef t "wrong cluster UID exits (FAKE_UID)" refuse 'echo sourced-anyway'
printf '#!/bin/bash\necho -n 793124f9-2b2e-4c9e-9fd0-41d27bd2d5a0\n' > "$T/decoy/kubectl"; chmod 755 "$T/decoy/kubectl"; cp "$T/decoy/kubectl" "$T/decoy/flux"; cp "$T/decoy/kubectl" "$T/decoy/curl"
out=$(PATH="$T/decoy:$PATH" /bin/bash -c "source $G; echo sourced-anyway" 2>&1); rc=$?; if [ $rc -ne 0 ] && grep -q "not the harness fake" <<<"$out"; then pass=$((pass+1)); echo "PASS  PIN_FAKE + a REAL kubectl first on PATH refuses ($(echo "$out" | head -1))"; else fail=$((fail+1)); echo "FAIL  decoy kubectl :: $out"; fi
rm "$T/decoy/kubectl"; out=$(PATH="$T/decoy:$PATH" /bin/bash -c "source $G; echo sourced-anyway" 2>&1); rc=$?; if [ $rc -ne 0 ] && grep -q "flux is" <<<"$out"; then pass=$((pass+1)); echo "PASS  PIN_FAKE + a REAL flux first on PATH refuses"; else fail=$((fail+1)); echo "FAIL  decoy flux :: $out"; fi
rm "$T/decoy/flux"; out=$(PATH="$T/decoy:$PATH" /bin/bash -c "source $G; echo sourced-anyway" 2>&1); rc=$?; if [ $rc -ne 0 ] && grep -q "curl is" <<<"$out"; then pass=$((pass+1)); echo "PASS  PIN_FAKE + a REAL curl first on PATH refuses"; else fail=$((fail+1)); echo "FAIL  decoy curl :: $out"; fi
out=$(KUBECONFIG=$HOME/.kube/config /bin/bash -c "source $G; echo sourced-anyway" 2>&1); rc=$?; if [ $rc -ne 0 ] && grep -q "dead kubeconfig" <<<"$out"; then pass=$((pass+1)); echo "PASS  PIN_FAKE + the real KUBECONFIG refuses"; else fail=$((fail+1)); echo "FAIL  real kubeconfig :: $out"; fi
out=$(env -u KUBECONFIG /bin/bash -c "source $G; echo sourced-anyway" 2>&1); rc=$?; if [ $rc -ne 0 ]; then pass=$((pass+1)); echo "PASS  PIN_FAKE + KUBECONFIG unset refuses"; else fail=$((fail+1)); echo "FAIL  no kubeconfig :: $out"; fi

echo "== pinning =="
t "APP is moveprobe2"                                           ok     '[ "$APP" = moveprobe2 ]'
APP=hermes t "APP=hermes from the environment is overridden"    ok     '[ "$APP" = moveprobe2 ]'
APP=moveprobe t "APP=moveprobe (kopia-residue app) is overridden" ok   '[ "$APP" = moveprobe2 ]'
GUARDS_DIR=/tmp/evil PIN_DIR=/tmp/evil t "GUARDS_DIR/PIN_DIR env are NOT honoured" ok '[ "$PIN_DIR" = "'"$STATE"'" ] && [ "$R" = "'"$R"'" ]'
t "no pv_patch function"                                        refuse 'type pv_patch'
t "pv_repoint exists but there is no generic PV patch helper"   ok     'type pv_repoint >/dev/null'
t "kn refuses kube-system"                                      refuse 'kn kube-system get pods'
t "kn refuses ai (hermes lives there now)"                      refuse 'kn ai get pods'
t "kn refuses develop"                                          refuse 'kn develop get pods'
t "kn refuses media"                                            refuse 'kn media get pods'
t "kn refuses no arguments"                                     refuse 'kn rehearsal-new'
t "kn allows rehearsal-old"                                     ok     'kn rehearsal-old get pods'
t "kn allows rehearsal-new"                                     ok     'kn rehearsal-new get pods'
echo "== kn: the M1 bypasses (each REACHED kubectl before the fix) =="
pvjson $HPV pin rehearsal-new
t "M1a: kn rehearsal-new delete pv <hermes PV>"                 refuse "kn rehearsal-new delete pv $HPV"; eq "  kubectl delete calls" "$(calls '^-n rehearsal-new delete')" 0
t "M1b: kn rehearsal-new patch pv <hermes PV>"                  refuse "kn rehearsal-new patch pv $HPV -p '{}'"; eq "  kubectl patch calls" "$(calls '^-n rehearsal-new patch')" 0
t "M1c: kn rehearsal-new --namespace ai delete pvc hermes (last -n wins)" refuse "kn rehearsal-new --namespace ai delete pvc hermes"; eq "  calls" "$(calls 'delete pvc hermes')" 0
t "M1d: kn rehearsal-new -n longhorn-system delete volumes.longhorn.io <pv>" refuse "kn rehearsal-new -n longhorn-system delete volumes.longhorn.io $HPV"; eq "  calls" "$(calls 'longhorn')" 0
echo "== kn: more bypass shapes =="
t "namespace flag AFTER the verb: get pods -n ai"               refuse 'kn rehearsal-new get pods -n ai'
t "namespace flag glued: get pods -nai"                         refuse 'kn rehearsal-new get pods -nai'
t "namespace flag with =: --namespace=ai"                       refuse 'kn rehearsal-new get pods --namespace=ai'
t "-A refused"                                                  refuse 'kn rehearsal-new get pods -A'
t "--all-namespaces refused"                                    refuse 'kn rehearsal-new get pods --all-namespaces'
t "--context refused"                                           refuse 'kn rehearsal-new get pods --context other'
t "--kubeconfig refused"                                        refuse 'kn rehearsal-new get pods --kubeconfig /x'
t "--server refused"                                            refuse 'kn rehearsal-new get pods --server https://x'
t "--as refused"                                                refuse 'kn rehearsal-new get pods --as system:admin'
t "--raw refused"                                               refuse 'kn rehearsal-new get --raw /api'
t "verb exec refused"                                           refuse 'kn rehearsal-new exec deploy/moveprobe2 -- id'
t "verb create refused"                                         refuse 'kn rehearsal-new create job x'
t "verb edit refused"                                           refuse 'kn rehearsal-new edit pvc moveprobe2'
t "verb port-forward refused"                                   refuse 'kn rehearsal-new port-forward pod/x 80'
t "verb rollout refused"                                        refuse 'kn rehearsal-new rollout restart deploy/moveprobe2'
for k in pv persistentvolume persistentvolumes ns namespace namespaces node nodes crd customresourcedefinition clusterrole clusterrolebinding volumes.longhorn.io snapshots.longhorn.io settings.longhorn.io storageclass storageclasses volumesnapshotcontent volumesnapshotcontents secret secrets; do
  t "kind [$k] refused"                                         refuse "kn rehearsal-new get $k"
done
t "comma list smuggling a foreign kind: get pvc,pv"             refuse 'kn rehearsal-new get pvc,pv'
t "kind/name smuggling a foreign kind: delete pvc/a pv/b"       refuse 'kn rehearsal-new delete pvc/a pv/b'
t "mixed: get pod,ns"                                           refuse 'kn rehearsal-new get pod,ns'
t "delete -f file refused"                                      refuse 'kn rehearsal-new delete -f /tmp/x.yaml'
t "apply -f file refused"                                       refuse 'kn rehearsal-new apply -f /tmp/x.yaml'
t "apply -k refused"                                            refuse 'kn rehearsal-new apply -k /tmp/x'
t "apply without -f - refused"                                  refuse 'kn rehearsal-new apply'
t "apply -f - carrying a PersistentVolume refused"              refuse "printf 'apiVersion: v1\nkind: PersistentVolume\nmetadata: {name: x}\n' | kn rehearsal-new apply -f -"
t "apply -f - carrying a Namespace refused"                     refuse "printf 'apiVersion: v1\nkind: Namespace\nmetadata: {name: x}\n' | kn rehearsal-new apply -f -"
t "apply -f - Job that names a namespace refused"               refuse "printf 'apiVersion: batch/v1\nkind: Job\nmetadata: {name: x, namespace: ai}\n' | kn rehearsal-new apply -f -"
t "apply -f - Job + a second (PV) document refused"             refuse "printf 'kind: Job\nmetadata: {name: x}\n---\nkind: PersistentVolume\nmetadata: {name: y}\n' | kn rehearsal-new apply -f -"
t "apply -f - a plain JSON Job is allowed (the guards' KN_APPLY_KINDS is batch/v1/Job)" ok "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"metadata\":{\"name\":\"x\"}}' | kn rehearsal-new apply -f -"
t "apply -f - the same Job as YAML is refused (JSON only)"        refuse "printf 'apiVersion: batch/v1\nkind: Job\nmetadata: {name: x}\n' | kn rehearsal-new apply -f -"
echo "== kn: what the plan actually runs must still pass =="
t "get ks,hr,pod,pvc,rs,rd"                                     ok     'kn rehearsal-new get ks,hr,pod,pvc,replicationsource.volsync.backube,replicationdestination.volsync.backube'
t "get pod -o jsonpath"                                         ok     "kn rehearsal-new get pod -o jsonpath='{.items[0].status.phase}'"
t "get events --field-selector … -o json"                       ok     'kn rehearsal-new get events --field-selector involvedObject.name=moveprobe2 -o json'
t "get events --sort-by"                                        ok     'kn rehearsal-new get events --sort-by=.lastTimestamp'
t "scale deploy/x --replicas=0"                                 ok     'kn rehearsal-new scale deploy/moveprobe2 --replicas=0'
t "wait --for=delete pod -l … --timeout"                        ok     'kn rehearsal-new wait --for=delete pod -l app.kubernetes.io/name=moveprobe2 --timeout=120s'
t "patch pvc -p (JSON that contains no flag)"                   ok     "kn rehearsal-new patch pvc moveprobe2 -p '{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"2Gi\"}}}}'"
t "patch replicationsource --type merge -p"                     ok     "kn rehearsal-new patch replicationsource.volsync.backube moveprobe2-local --type merge -p '{\"spec\":{}}'"
t "annotate pvc <key>=<value> (a '/' inside an assignment is not a kind)" ok 'kn rehearsal-new annotate pvc moveprobe2 kustomize.toolkit.fluxcd.io/prune=disabled'
t "delete pvc --wait=true --timeout"                            ok     'kn rehearsal-new delete pvc moveprobe2 --wait=true --timeout=120s'
t "delete replicationdestination…"                              ok     'kn rehearsal-new delete replicationdestination.volsync.backube moveprobe2-dst-local --wait=true'
t "delete ks moveprobe2"                                        ok     'kn rehearsal-new delete ks moveprobe2 --wait=true --timeout=300s'
t "delete pod -l …"                                             ok     'kn rehearsal-new delete pod -l app.kubernetes.io/name=moveprobe2 --wait=true'
t "logs job/x"                                                  ok     'kn rehearsal-new logs job/ro-1'
t "get volumesnapshot <n> -o jsonpath"                          ok     "kn rehearsal-new get volumesnapshot vs1 -o jsonpath='{.status.x}'"
t "KN_NAMESPACES empty => everything refused (fail closed)"     refuse 'KN_NAMESPACES="" kn rehearsal-new get pods'

echo "== PV guard =="
pvjson $PV pin rehearsal-new; pvjson pvc-OTHER pin rehearsal-new; record $PV
t "reclaim on an UNLISTED PV refused"                           refuse "PIN_WINDOW=yes pv_reclaim pvc-OTHER Retain"; eq "  mutations" "$(calls '^patch pv')" 0
t "reclaim without PIN_WINDOW refused"                          refuse "pv_reclaim $PV Retain"; eq "  mutations" "$(calls '^patch pv')" 0
t "reclaim with a bogus policy refused"                         refuse "PIN_WINDOW=yes pv_reclaim $PV Recycle"
t "reclaim empty PV name refused"                               refuse "PIN_WINDOW=yes pv_reclaim '' Retain"
t "reclaim Retain on a listed+labelled PV allowed"              ok     "PIN_WINDOW=yes pv_reclaim $PV Retain"; eq "  mutations" "$(calls '^patch pv')" 1
t "reclaim Delete on a listed+labelled PV allowed"              ok     "PIN_WINDOW=yes pv_reclaim $PV Delete"
pvjson $HPV pin rehearsal-new; record $HPV
t "hermes PV refused even if listed AND labelled"               refuse "PIN_WINDOW=yes pv_reclaim $HPV Retain"; eq "  mutations" "$(calls '^patch pv')" 0
t "hermes PV refused by pv_delete"                              refuse "PIN_WINDOW=yes pv_delete $HPV"; eq "  deletes" "$(calls 'delete (pv|volumes)')" 0
pvjson $PV none rehearsal-new
t "listed PV without the rehearsal=pin label refused"           refuse "PIN_WINDOW=yes pv_reclaim $PV Retain"; eq "  mutations" "$(calls '^patch pv')" 0
pvjson $PV pin ai
t "claimRef in ai refused"                                      refuse "PIN_WINDOW=yes pv_reclaim $PV Retain"
pvjson $PV pin media
t "claimRef in media refused"                                   refuse "PIN_WINDOW=yes pv_reclaim $PV Retain"
pvjson $PV pin -
t "EMPTY claimRef REFUSED even for a listed+labelled PV (m8)"    refuse "PIN_WINDOW=yes pv_reclaim $PV Retain"; eq "  mutations" "$(calls '^patch pv')" 0
pvjson $PV pin rehearsal-new
FAKE_API_ERROR=1 t "API error fails CLOSED"                     refuse "PIN_WINDOW=yes pv_reclaim $PV Retain"; eq "  mutations" "$(calls '^patch pv')" 0
rm -f "$FX/pv-$PV.json"
t "listed PV that is gone reports gone (ok)"                    ok     "rehearsal_pv_ok $PV"; has "  says gone" "gone: $PV"
pvjson $PV pin rehearsal-new
echo "== pv_reclaim Delete needs a Bound PV (m1) =="
pvjson $PV pin rehearsal-new Released Retain
t "Delete on a RELEASED PV refused (would be reclaimed at once)" refuse "PIN_WINDOW=yes pv_reclaim $PV Delete"; eq "  mutations" "$(calls '^patch pv')" 0
pvjson $PV pin rehearsal-new Available Retain
t "Delete on an AVAILABLE PV refused"                            refuse "PIN_WINDOW=yes pv_reclaim $PV Delete"; eq "  mutations" "$(calls '^patch pv')" 0
pvjson $PV pin rehearsal-new Bound Retain
t "Delete on a BOUND PV allowed"                                 ok     "PIN_WINDOW=yes pv_reclaim $PV Delete"; eq "  mutations" "$(calls '^patch pv')" 1
pvjson $PV pin rehearsal-new Released Delete
t "Retain on a Released PV is harmless and allowed"              ok     "PIN_WINDOW=yes pv_reclaim $PV Retain"
pvjson $PV pin rehearsal-new
echo "== pv_delete ordering =="
t "pv_delete needs PIN_WINDOW"                                  refuse "pv_delete $PV"; eq "  deletes" "$(calls 'delete (pv|volumes)')" 0
t "pv_delete: PV deleted, THEN the Longhorn volume"             ok     "PIN_WINDOW=yes pv_delete $PV"
eq "  delete pv before longhorn" "$(grep -E 'delete (pv|volumes)' "$FX/calls.log" | awk '/longhorn/{print "lh"; next} {print "pv"}' | paste -sd, -)" "pv,lh"
pvjson $PV pin rehearsal-new
FAKE_PV_STAYS=1 t "pv_delete: PV still present -> NO Longhorn delete" refuse "PIN_WINDOW=yes pv_delete $PV"; eq "  longhorn deletes" "$(calls 'delete volumes')" 0
pvjson $PV pin rehearsal-new
FAKE_DELETE_FAIL=1 t "pv_delete: PV delete fails -> NO Longhorn delete" refuse "PIN_WINDOW=yes pv_delete $PV"; eq "  longhorn deletes" "$(calls 'delete volumes')" 0
rm -f "$FX/pv-$PV.json"
t "pv_delete: PV already gone -> only the leftover Longhorn volume" ok "PIN_WINDOW=yes pv_delete $PV"; eq "  pv deletes" "$(calls 'delete pv')" 0; eq "  longhorn deletes" "$(calls 'delete volumes')" 1

echo "== pv_repoint =="
pvjson $PV pin rehearsal-new Released Retain; : > "$FX/calls.log"
t "pv_repoint needs PIN_WINDOW"                                 refuse "pv_repoint $PV"; eq "  mutations" "$(calls '^patch pv')" 0
t "pv_repoint a Released PV: re-points to rehearsal-new/moveprobe2" ok "PIN_WINDOW=yes pv_repoint $PV"
eq "  patch names rehearsal-new" "$(calls 'patch pv .*"namespace":"rehearsal-new","name":"moveprobe2","uid":null,"resourceVersion":null')" 1
eq "  never a claimRef REMOVAL" "$(calls 'op.*remove')" 0
pvjson $PV pin rehearsal-new Available Retain;  t "pv_repoint an Available PV ok"       ok     "PIN_WINDOW=yes pv_repoint $PV"
pvjson $PV pin rehearsal-new Bound Retain;      t "pv_repoint a BOUND PV refused"       refuse "PIN_WINDOW=yes pv_repoint $PV"; eq "  mutations" "$(calls '^patch pv')" 0
pvjson pvc-OTHER pin rehearsal-new Released Retain; t "pv_repoint an UNLISTED PV refused" refuse "PIN_WINDOW=yes pv_repoint pvc-OTHER"; eq "  mutations" "$(calls '^patch pv')" 0
pvjson $HPV pin rehearsal-new Released Retain; record $HPV; t "pv_repoint the HERMES PV refused" refuse "PIN_WINDOW=yes pv_repoint $HPV"; eq "  mutations" "$(calls '^patch pv')" 0
pvjson $PV pin rehearsal-new Released Retain
t "pv_repoint IGNORES extra arguments: the claim is the pinned constant" ok "PIN_WINDOW=yes pv_repoint $PV ai hermes"; eq "  patch still names rehearsal-new/moveprobe2, never ai/hermes" "$(calls '"namespace":"rehearsal-new","name":"moveprobe2"')" 1; eq "  nothing names ai" "$(calls '"namespace":"ai"')" 0
rm -f "$FX/pv-$HPV.json" "$FX/pv-pvc-OTHER.json"; pvjson $PV pin rehearsal-new
echo "== slot_clear =="
FAKE_NOW_MIN=30 t "slot_clear: :30 is clear"                    ok     'slot_clear'
FAKE_NOW_MIN=47 t "slot_clear: :47 refused"                     refuse 'slot_clear'
FAKE_NOW_MIN=45 t "slot_clear: :45 refused"                     refuse 'slot_clear'
FAKE_NOW_MIN=49 t "slot_clear: :49 refused"                     refuse 'slot_clear'
FAKE_NOW_MIN=50 t "slot_clear: :50 is clear"                    ok     'slot_clear'
FAKE_NOW_HOUR=06 FAKE_NOW_MIN=44 t "slot_clear: 06:44 (r2 slot) refused" refuse 'slot_clear'
FAKE_NOW_HOUR=07 FAKE_NOW_MIN=44 t "slot_clear: 07:44 is clear" ok     'slot_clear'
FAKE_NOW_MIN=20 t "slot_clear 20: :20 + 20 min ends at :40 -> clear (m6)" ok 'slot_clear 20'
FAKE_NOW_MIN=30 t "slot_clear 20: :30 + 20 min crosses :47 -> refused (m6)" refuse 'slot_clear 20'
FAKE_NOW_MIN=52 t "slot_clear 20: :52 is past the slot -> clear"  ok     'slot_clear 20'
FAKE_NOW_HOUR=06 FAKE_NOW_MIN=30 t "slot_clear 20 in hour 06: 06:30 + 20 crosses 06:43 -> refused" refuse 'slot_clear 20'
t "slot_clear with a non-number look-ahead refused"             refuse 'slot_clear abc'

echo "== no_consumers (m3) =="
echo '{"items":[]}' > "$FX/pods-rehearsal-new.json"
t "no_consumers: no pod -> ok"                                  ok     'no_consumers'
echo '{"items":[{"metadata":{"name":"ro-1"},"status":{"phase":"Succeeded"},"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"moveprobe2"}}]}}]}' > "$FX/pods-rehearsal-new.json"
t "no_consumers: a COMPLETED helper pod still references the claim -> FAIL" refuse 'no_consumers'; has "  names the pod" "ro-1"
echo '{"items":[{"metadata":{"name":"other"},"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"other-claim"}}]}}]}' > "$FX/pods-rehearsal-new.json"
t "no_consumers: a pod on ANOTHER claim is fine"                ok     'no_consumers'
rm -f "$FX/pods-rehearsal-new.json"
echo "== fx diff (m4) =="
t "fx diff ks moveprobe2 is allowed and read-only (no window needed)" ok 'fx diff ks moveprobe2 -n rehearsal-new --path ./x --kustomization-file ./y'
t "fx diff of another ks refused"                               refuse 'fx diff ks cluster-apps -n flux-system --path ./x'
t "fx diff hermes in ai refused"                                refuse 'fx diff ks hermes -n ai --path ./x'
echo "== hermes_owners (m10) =="
jq -n '{metadata:{managedFields:[{manager:"b",operation:"Update",fieldsV1:{"f:metadata":{"f:annotations":{}}}},{manager:"a",operation:"Apply",fieldsV1:{"f:spec":{"f:volumeName":{}}}}]}}' > "$FX/pvc-ai-hermes.json"
t "hermes_owners prints canonical, sorted ownership"            ok     'hermes_owners'; has "  sorted (a before b)" '[{"m":"a","op":"Apply"'
t "hermes_owners only GETs"                                     ok     'hermes_owners >/dev/null'; eq "  non-get calls on ai" "$(grep -c '^-n ai [^g]' "$FX/calls.log" || true)" 0

echo "== record_pv / app_pv =="
: > "$STATE/pins.txt"; rm -f "$FX"/pv-*.json "$FX"/pvc-*.json
pvjson $PV none rehearsal-new; pvc rehearsal-new moveprobe2 $PV
t "app_pv records + labels a new PV whose claimRef matches"     ok     'app_pv'; has "  prints the PV" "$PV"; eq "  label calls" "$(calls '^label pv')" 1
eq "  recorded" "$(grep -cx $PV "$STATE/pins.txt")" 1
rm -f "$FX/pvc-rehearsal-new-moveprobe2.json"
t "app_pv with NO PVC refuses (no cached fallback)"             refuse 'app_pv'
pvc rehearsal-new moveprobe2 $HPV
t "app_pv refuses a claim that names the HERMES PV"             refuse 'app_pv'
pvjson $PV2 none rehearsal-old; pvc rehearsal-new moveprobe2 $PV2
t "record_pv refuses a PV whose claimRef ns != the claim's"     refuse "record_pv rehearsal-new moveprobe2"
t "record_pv refuses ns=ai"                                     refuse "record_pv ai hermes"
pvc rehearsal-new moveprobe2 $PV; pvjson $PV pin rehearsal-new
t "app_pv re-reads the live PVC every call (PV changes -> new answer)" ok "app_pv"
pvjson $PV2 pin rehearsal-new; pvc rehearsal-new moveprobe2 $PV2
t "app_pv follows a re-provisioned claim to the new PV"         ok     'app_pv'; has "  returns the NEW pv" "$PV2"

echo "== states =="
pvjson $PV pin rehearsal-new; record $PV; pvc rehearsal-new moveprobe2 $PV
t "pin_state unknown state refused"                             refuse 'pin_state bogus'
t "pin_state s1 pins the LIVE bound PV"                         ok     'pin_state s1'; has "  cap 1Gi" "cap=1Gi"
eq "  volumeName in the file" "$(grep -c "value: $PV" "$R/kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/app/kustomization.yaml")" 1
eq "  RD sourceNamespace in the file" "$(grep -c 'value: rehearsal-old' "$R/kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/app/kustomization.yaml")" 1
t "pin_state s1 with a DIFFERENT PV refused"                    refuse "pin_state s1 $PV2"
t "pin_state s1 refuses the hermes PV"                          refuse "pin_state s1 $HPV"
t "pin_render s1 refuses the hermes PV"                         refuse "pin_render s1 $HPV"
t "pin_render s1 refuses a malformed PV name"                   refuse "pin_render s1 not-a-pv"
t "pin_render fix takes no PV"                                  refuse "pin_render fix $PV"
t "pin_state fix-cap2 sets VOLSYNC_CAPACITY 2Gi"                ok     'pin_state fix-cap2'; eq "  ks.yaml" "$(grep -c 'VOLSYNC_CAPACITY: 2Gi' "$R/kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/ks.yaml")" 1
t "pin_state fix-vn writes the fake volumeName"                 ok     'pin_state fix-vn'; eq "  fake pv" "$(grep -c 'pvc-00000000-0000-4000-8000-000000000000' "$R/kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/app/kustomization.yaml")" 1
t "pin_state back to base restores 1Gi"                         ok     'pin_state base'; eq "  ks.yaml" "$(grep -c 'VOLSYNC_CAPACITY: 1Gi' "$R/kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/ks.yaml")" 1
GIT_CLEAN=$(git -C "$R" status --porcelain -- kubernetes | wc -l | tr -d ' '); eq "  base render == the committed fixture (worktree clean)" "$GIT_CLEAN" 0
bad=0; for s in base control s1 fix fix-cap2 fix-meta fix-vn fixprune; do
  /bin/bash -c "source $G; pin_state $s" >/dev/null 2>&1 || bad=1
  (cd "$R" && yamlfmt -lint kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/app/kustomization.yaml kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/ks.yaml >/dev/null 2>&1) || { bad=1; echo "  yamlfmt dirty: $s"; }
done; eq "yamlfmt -lint clean for all 8 states" "$bad" 0
git -C "$R" checkout -q -- kubernetes

echo "== s1 with NO live claim (the real-shape S1 deletes it first) =="
rm -f "$FX/pvc-rehearsal-new-moveprobe2.json"; pvjson $PV pin rehearsal-new Released Retain; record $PV
t "pin_state s1 with no live claim and no PV argument refused"  refuse 'pin_state s1'
t "pin_state s1 pins the RETAINED Released PV passed in"        ok     "pin_state s1 $PV"; eq "  file names it" "$(grep -c "value: $PV" "$R/kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/app/kustomization.yaml")" 1
pvjson $PV pin rehearsal-new Bound Retain
t "no live claim + a BOUND PV refused (someone else owns it)"   refuse "pin_state s1 $PV"
pvjson $PV pin rehearsal-new Released Retain
t "no live claim + an UNLISTED PV refused"                      refuse "pin_state s1 pvc-33333333-2222-4333-8444-555555555555"
t "no live claim + the hermes PV refused"                       refuse "pin_state s1 $HPV"
git -C "$R" checkout -q -- kubernetes; pvc rehearsal-new moveprobe2 $PV Bound; pvjson $PV pin rehearsal-new

echo "== COMMIT =="
/bin/bash -c "source $G; pin_state control" >/dev/null 2>&1; GIT_ADD() { git -C "$R" add -A kubernetes/rehearsal-pin; }; GIT_ADD
t "COMMIT without the scope prefix refused"                     refuse "COMMIT 'move stuff'"
t "COMMIT with the scope prefix ok"                             ok     "COMMIT 'rehearsal-pin: state control'"
eq "  author is the bot" "$(git -C "$R" log -1 --format=%an)" "fizz-bot-bvn[bot]"
eq "  email is the bot's noreply" "$(git -C "$R" log -1 --format=%ae)" "324971095+fizz-bot-bvn[bot]@users.noreply.github.com"
eq "  Co-Authored-By trailer" "$(git -C "$R" log -1 --format=%B | grep -c '^Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>$')" 1
eq "  Claude-Session trailer" "$(git -C "$R" log -1 --format=%B | grep -c '^Claude-Session: https://claude.ai/code/session_01AA9xxfsX3xSg8xher3SAKa$')" 1
eq "  repo-local git identity NOT rewritten" "$(git -C "$R" config --local --get user.name || echo unset)" unset
git -C "$R" checkout -q -b elsewhere
t "COMMIT off-branch refused"                                   refuse "COMMIT 'rehearsal-pin: x'"
git -C "$R" checkout -q rehearsal-pin; git -C "$R" branch -q -D elsewhere

echo "== pin_gate =="
t "control state: PASS"                                         ok     'pin_gate control'; has "  writes the gated HEAD" "GATE PASS (control)"
eq "  gated-head == HEAD" "$(cat "$STATE/gated-head.txt")" "$(git -C "$R" rev-parse HEAD)"
t "claiming the wrong state (fix) on a control commit: FAIL"    refuse 'pin_gate fix'; eq "  gated token removed" "$([ -e "$STATE/gated-head.txt" ] && echo present || echo absent)" absent
t "unknown state refused"                                       refuse 'pin_gate bogus'
echo "# stray" >> "$R/kubernetes/rehearsal-pin/README.md"
t "uncommitted change under kubernetes/rehearsal-pin: FAIL"     refuse 'pin_gate control'; has "  says COMMIT first" "COMMIT first"
git -C "$R" checkout -q -- kubernetes
commit_state s1
t "s1: PASS (volumeName == live PV, sourceNamespace, no annotation)" ok 'pin_gate s1'; has "  saw the pin" "volumeName: $PV"
rm -f "$FX/pvc-rehearsal-new-moveprobe2.json"; pvjson $PV pin rehearsal-new Released Retain
/bin/bash -c "source $G; pin_state s1 $PV && GIT add -A kubernetes/rehearsal-pin && COMMIT 'rehearsal-pin: state s1 (no live claim)'" >/dev/null 2>&1
t "s1 gate with NO live claim: PASS when given the Released PV" ok "pin_gate s1 $PV"
t "s1 gate with NO live claim and no PV argument: FAIL"        refuse 'pin_gate s1'
pvjson $PV pin rehearsal-new Bound Retain; t "s1 gate with no live claim and a Bound PV: FAIL" refuse "pin_gate s1 $PV"
pvjson $PV pin rehearsal-new; pvc rehearsal-new moveprobe2 $PV
commit_state fix
t "fix: PASS (annotation, NO volumeName, NO sourceNamespace)"   ok     'pin_gate fix'; lacks "  no volumeName line" "volumeName"
t "fix state gated as s1: FAIL"                                 refuse 'pin_gate s1'
commit_state fix-cap2;  t "fix-cap2: PASS"                       ok     'pin_gate fix-cap2'
commit_state fix-meta;  t "fix-meta: PASS"                       ok     'pin_gate fix-meta'
commit_state fix-vn;    t "fix-vn: PASS (exactly one volumeName, no sourceNamespace)" ok 'pin_gate fix-vn'
commit_state fixprune;  t "fixprune: PASS (ssa + prune)"         ok     'pin_gate fixprune'
commit_state base;      t "base: PASS"                           ok     'pin_gate base'
pvc rehearsal-new moveprobe2 $PV2; pvjson $PV2 pin rehearsal-new; record $PV2
commit_state s1
# the live PV changes AFTER the commit -> the gate must notice
pvc rehearsal-new moveprobe2 $PV; pvjson $PV pin rehearsal-new
t "s1 committed for PV2 but the live PV is $PV: FAIL"           refuse 'pin_gate s1'
pvc rehearsal-new moveprobe2 $PV2
t "s1 committed for PV2 and live PV2: PASS"                     ok     'pin_gate s1'
# hand edits that a lefthook rewrite or a slip could produce
KF=$R/kubernetes/rehearsal-pin/rehearsal-new/moveprobe2
commit_state fix
sed -i.bak 's/^# STATE: fix /# STATE: fix /; /IfNotPresent/d' "$KF/app/kustomization.yaml"; rm -f "$KF/app/kustomization.yaml.bak"; git -C "$R" add -A kubernetes; git -C "$R" -c user.name=x -c user.email=x@x commit -q -m "rehearsal-pin: tampered fix"
t "state header says fix but the annotation is gone: FAIL"      refuse 'pin_gate fix'
git -C "$R" reset -q --hard HEAD~1
sed -i.bak 's/targetNamespace: rehearsal-new/targetNamespace: rehearsal-old/' "$KF/ks.yaml"; rm -f "$KF/ks.yaml.bak"; git -C "$R" add -A kubernetes; git -C "$R" -c user.name=x -c user.email=x@x commit -q -m "rehearsal-pin: stale targetNamespace"
t "stale targetNamespace: FAIL"                                 refuse 'pin_gate fix'
git -C "$R" reset -q --hard HEAD~1
sed -i.bak 's#/rehearsal-new/moveprobe2/app#/rehearsal-old/moveprobe2/app#' "$KF/ks.yaml"; rm -f "$KF/ks.yaml.bak"; git -C "$R" add -A kubernetes; git -C "$R" -c user.name=x -c user.email=x@x commit -q -m "rehearsal-pin: stale path"
t "stale child path: FAIL"                                      refuse 'pin_gate fix'
git -C "$R" reset -q --hard HEAD~1
sed -i.bak '/moveprobe2\/ks.yaml/d' "$R/kubernetes/rehearsal-pin/rehearsal-new/kustomization.yaml"; rm -f "$R/kubernetes/rehearsal-pin/rehearsal-new/kustomization.yaml.bak"; git -C "$R" add -A kubernetes; git -C "$R" -c user.name=x -c user.email=x@x commit -q -m "rehearsal-pin: ks unlisted"
t "child ks.yaml not listed in the namespace kustomization: FAIL" refuse 'pin_gate fix'
git -C "$R" reset -q --hard HEAD~1
sed -i.bak 's/VOLSYNC_CAPACITY: 1Gi/VOLSYNC_CAPACITY: 5Gi/' "$KF/ks.yaml"; rm -f "$KF/ks.yaml.bak"; git -C "$R" add -A kubernetes; git -C "$R" -c user.name=x -c user.email=x@x commit -q -m "rehearsal-pin: capacity"
t "committed capacity != the state's: FAIL"                     refuse 'pin_gate fix'
git -C "$R" reset -q --hard HEAD~1
t "after the resets the tree is a clean fix again: PASS"        ok     'pin_gate fix'

echo "== PUSH =="
HEAD_NOW=$(git -C "$R" rev-parse HEAD)
t "PUSH with an argument refused"                               refuse "PIN_WINDOW=yes PUSH origin main"
silence_off
t "PUSH without PIN_WINDOW refused"                             refuse 'PUSH'
t "PUSH without a recorded silence refused"                     refuse 'PIN_WINDOW=yes PUSH'
echo sil-x > "$STATE/silences.txt"; echo $(( $(date +%s) - 10 )) > "$STATE/silence-until.epoch"
t "PUSH with an EXPIRED silence refused"                        refuse 'PIN_WINDOW=yes PUSH'; has "  says expired" "expired"
silence_on
rm -f "$STATE/gated-head.txt"
t "PUSH of an ungated HEAD refused"                             refuse 'PIN_WINDOW=yes PUSH'; eq "  origin has no branch" "$(git -C "$T/origin.git" branch --list | wc -l | tr -d ' ')" 0
/bin/bash -c "source $G; pin_gate fix" >/dev/null 2>&1
git -C "$R" checkout -q -b elsewhere
t "PUSH off-branch refused"                                     refuse 'PIN_WINDOW=yes PUSH'
git -C "$R" checkout -q rehearsal-pin; git -C "$R" branch -q -D elsewhere
t "PUSH of a gated HEAD with window+silence: pushes"            ok     'PIN_WINDOW=yes PUSH'
eq "  origin/rehearsal-pin == HEAD" "$(git -C "$T/origin.git" rev-parse refs/heads/rehearsal-pin)" "$HEAD_NOW"
eq "  origin has exactly one branch" "$(git -C "$T/origin.git" branch --list | wc -l | tr -d ' ')" 1
git -C "$R" commit -q --allow-empty -m "rehearsal-pin: newer, ungated" --author 'x <x@x>' 2>/dev/null || git -C "$R" -c user.name=x -c user.email=x@x commit -q --allow-empty -m "rehearsal-pin: newer, ungated"
t "PUSH of a NEWER, ungated HEAD refused"                       refuse 'PIN_WINDOW=yes PUSH'
git -C "$R" reset -q --hard "$HEAD_NOW"
t "push_delete_branch needs PIN_WINDOW"                         refuse 'push_delete_branch'
t "push_delete_branch takes no arguments"                       refuse 'PIN_WINDOW=yes push_delete_branch main'
t "push_delete_branch deletes exactly rehearsal-pin"            ok     'PIN_WINDOW=yes push_delete_branch'
eq "  origin has no branch left" "$(git -C "$T/origin.git" branch --list | wc -l | tr -d ' ')" 0

echo "== fx whitelist =="
t "fx get is read-only and needs no window"                     ok     'fx get ks -A'
t "fx reconcile needs PIN_WINDOW"                               refuse 'fx reconcile ks rehearsal-apps -n flux-system'
silence_off
t "fx reconcile needs a silence"                                refuse 'PIN_WINDOW=yes fx reconcile ks rehearsal-apps -n flux-system'
silence_on
t "fx reconcile source git rehearsal ok"                        ok     'PIN_WINDOW=yes fx reconcile source git rehearsal -n flux-system'
t "fx reconcile ks rehearsal-apps ok"                           ok     'PIN_WINDOW=yes fx reconcile ks rehearsal-apps -n flux-system'
t "fx reconcile ks moveprobe2 -n rehearsal-new ok"              ok     'PIN_WINDOW=yes fx reconcile ks moveprobe2 -n rehearsal-new'
t "fx suspend ks moveprobe2 ok"                                 ok     'PIN_WINDOW=yes fx suspend ks moveprobe2 -n rehearsal-new'
t "fx resume hr moveprobe2 ok"                                  ok     'PIN_WINDOW=yes fx resume hr moveprobe2 -n rehearsal-new'
t "fx suspend the parent ok"                                    ok     'PIN_WINDOW=yes fx suspend ks rehearsal-apps -n flux-system'
t "fx reconcile cluster-apps REFUSED"                           refuse 'PIN_WINDOW=yes fx reconcile ks cluster-apps -n flux-system'
t "fx reconcile home-kubernetes source REFUSED"                 refuse 'PIN_WINDOW=yes fx reconcile source git home-kubernetes -n flux-system'
t "fx suspend hermes in ai REFUSED"                             refuse 'PIN_WINDOW=yes fx suspend ks hermes -n ai'
t "fx resume all REFUSED"                                       refuse 'PIN_WINDOW=yes fx resume ks --all -n rehearsal-new'
t "fx delete verb REFUSED"                                      refuse 'PIN_WINDOW=yes fx delete ks moveprobe2 -n rehearsal-new'

echo "== assertions =="
jq -n '{status:{inventory:{entries:[{id:"_rehearsal-new__Namespace"},{id:"rehearsal-new_moveprobe2_kustomize.toolkit.fluxcd.io_Kustomization"}]}}}' > "$FX/ks-flux-system-rehearsal-apps.json"
t "inventory_ok: only rehearsal-* objects"                      ok     'inventory_ok'
jq -n '{status:{inventory:{entries:[{id:"rehearsal-new_x_apps_Deployment"},{id:"ai_hermes_apps_Deployment"}]}}}' > "$FX/ks-flux-system-rehearsal-apps.json"
t "inventory_ok: a non-rehearsal object FAILS"                  refuse 'inventory_ok'
jq -n '{status:{}}' > "$FX/ks-flux-system-rehearsal-apps.json"
t "inventory_ok: empty/null inventory FAILS CLOSED"             refuse 'inventory_ok'
ks_all True True;   t "others_ready: all Ready (rehearsal ks excluded)" ok     'PIN_POLL=0 others_ready'
ks_all True False;  t "others_ready: Ready=False fails at once"        refuse 'PIN_POLL=0 others_ready'
ks_all True Unknown; t "others_ready: persistent Unknown fails after 3 polls" refuse 'PIN_POLL=0 others_ready'
jq -n --arg h $HPV '{metadata:{uid:"H1"},spec:{volumeName:$h},status:{phase:"Bound"}}' > "$FX/pvc-ai-hermes.json"
jq -n '{status:{phase:"Bound"},spec:{persistentVolumeReclaimPolicy:"Delete"}}' > "$FX/pv-$HPV.json"
t "hermes_snapshot"                                             ok     'hermes_snapshot'; SNAP=$LAST_OUT; has "  has uid|pv|claim-phase only" "H1|$HPV|Bound"; lacks "  no PV phase/reclaim in it (m7)" "Delete"
t "hermes_same: unchanged"                                      ok     "hermes_same '$SNAP'"
jq -n --arg h $HPV '{metadata:{uid:"H2"},spec:{volumeName:$h},status:{phase:"Bound"}}' > "$FX/pvc-ai-hermes.json"
t "hermes_same: a re-created claim (new uid) FAILS"             refuse "hermes_same '$SNAP'"
t "hermes helpers only ever GET (no write verb on ai/hermes)"   ok     'hermes_snapshot >/dev/null'; eq "  non-get calls" "$(grep -cvE '^(-n ai get|get pv|get ns)' "$FX/calls.log" || true)" 0
rm -f "$FX"/pv-*.json "$FX"/pvc-*.json
t "preflight_clean: nothing left"                               ok     'preflight_clean'
echo "namespace/rehearsal-old" > "$FX/ns.txt"; sed -i.bak 's/^namespace\/rehearsal-old/rehearsal-old   Active   3d/' "$FX/ns.txt"; rm -f "$FX/ns.txt.bak"
t "preflight_clean: a leftover rehearsal-* namespace FAILS"     refuse 'preflight_clean'; : > "$FX/ns.txt"
echo "kustomization.kustomize.toolkit.fluxcd.io/rehearsal-apps  True" > "$FX/flux.txt"
t "preflight_clean: a leftover Flux object FAILS"               refuse 'preflight_clean'; : > "$FX/flux.txt"
jq -n '{items:[{metadata:{name:"pvc-old",labels:{rehearsal:"move"}},spec:{claimRef:{namespace:"x"}}}]}' > "$FX/pvlist.json"
t "preflight_clean: a PV labelled rehearsal=move FAILS"         refuse 'preflight_clean'; echo '{"items":[]}' > "$FX/pvlist.json"
git -C "$R" push -q origin "$HEAD_NOW:refs/heads/rehearsal-pin"
t "preflight_clean: a leftover REMOTE branch FAILS"             refuse 'preflight_clean'; git -C "$T/origin.git" branch -q -D rehearsal-pin
git -C "$R" remote set-url origin "$T/no-such-origin.git"
t "preflight_clean: an UNREADABLE remote FAILS CLOSED (not 'no branch')" refuse 'preflight_clean'; has "  says how to check by hand" "git ls-remote"
git -C "$R" remote set-url origin "$T/origin.git"

echo "== ks / backups / waits =="
S=abcdef1234567890abcdef1234567890abcdef12
ksjson "$S" True;  t "wait_ks_outcome: Ready=True at the sha -> 0" ok  "wait_ks_outcome $S 2"
ksjson "$S" False; t "wait_ks_outcome: Ready=False at the sha -> 2 (stall)" refuse "PIN_POLL_S=0 wait_ks_outcome $S 2"; has "  says False" "Ready=False"
ksjson "deadbee1234567890abcdef1234567890abcdef1" True
t "wait_ks_outcome: a DIFFERENT attempted sha -> timeout"       refuse "PIN_POLL_S=0 wait_ks_outcome $S 2"; has "  says TIMEOUT" "TIMEOUT"
t "wait_ks_outcome: bad argument refused"                       refuse 'wait_ks_outcome xyz'
ksjson "$S" False; t "ks_report prints Ready + revisions"       ok     'ks_report'; has "  Ready=False" "Ready=False"; has "  attempted" "attempted=refs/heads/rehearsal-pin@sha1:$S"
mkrs() { jq -n --arg st "$1" '{status:{lastSyncStartTime:$st,lastSyncTime:"2000-01-01T00:00:00Z",lastManualSync:"old",latestMoverStatus:{logs:""}}}' > "$FX/rs-rehearsal-new-$2.json"; }
printf 'Created snapshot with root abc\nSetting policy for moveprobe2@rehearsal-new:/data\nOPERATION_RESULT: SUCCESS, EXIT_CODE: 0\n' > "$FX/moverlogs.txt"
mkrs "" moveprobe2-local; mkrs "" moveprobe2-r2
t "backup_now needs PIN_WINDOW"                                 refuse 'backup_now pin-a'
silence_off; t "backup_now needs a silence"                     refuse 'PIN_WINDOW=yes backup_now pin-a'; silence_on
t "backup_now refuses a tag without the pin- prefix"            refuse 'PIN_WINDOW=yes backup_now seed-1'
mkrs "2026-09-24T10:47:00Z" moveprobe2-local
FAKE_NOW_MIN=30 t "backup_now refuses while a sync is IN FLIGHT (trap 8)" refuse 'PIN_WINDOW=yes backup_now pin-a'; has "  says in flight" "in flight"; eq "  no RS patched" "$(calls '^-n rehearsal-new patch replicationsource')" 0
mkrs "" moveprobe2-local
FAKE_NOW_MIN=47 t "backup_now refuses inside the :47 local slot" refuse 'PIN_WINDOW=yes backup_now pin-a'; has "  says slot" ":47"
FAKE_NOW_MIN=30 t "backup_now: both RS complete, log accepted"  ok     'PIN_WINDOW=yes PIN_POLL_M=0 backup_now pin-a'; has "  identity checked" "Setting policy moveprobe2@rehearsal-new"
printf 'Setting policy for moveprobe2@rehearsal-new:/data\n== Directory is empty skipping backup ===\nOPERATION_RESULT: FAILURE, EXIT_CODE: 0\n' > "$FX/moverlogs.txt"; mkrs "" moveprobe2-local; mkrs "" moveprobe2-r2
FAKE_NOW_MIN=30 t "backup_now: the empty-source green-but-bogus log is REJECTED" refuse 'PIN_WINDOW=yes PIN_POLL_M=0 backup_now pin-a'
printf 'Created snapshot with root abc\nSetting policy for moveprobe2@rehearsal-old:/data\nOPERATION_RESULT: SUCCESS\n' > "$FX/moverlogs.txt"; mkrs "" moveprobe2-local; mkrs "" moveprobe2-r2
FAKE_NOW_MIN=30 t "backup_now: a log for the WRONG identity is REJECTED" refuse 'PIN_WINDOW=yes PIN_POLL_M=0 backup_now pin-a'
printf 'Created snapshot with root abc\nSetting policy for moveprobe2@rehearsal-new:/data\nOPERATION_RESULT: SUCCESS\n' > "$FX/moverlogs.txt"; mkrs "" moveprobe2-local; mkrs "" moveprobe2-r2
FAKE_RS_STUCK=1 FAKE_NOW_MIN=30 t "backup_now: a sync that never stamps the tag times out (bounded)" refuse 'PIN_WINDOW=yes PIN_POLL_M=0 backup_now pin-a'; has "  says TIMEOUT" "TIMEOUT"
jq -n '{metadata:{name:"moveprobe2-local"},spec:{},status:{latestMoverStatus:{logs:"Created snapshot with root a\nSetting policy for moveprobe2@rehearsal-new:/data\nOPERATION_RESULT: SUCCESS\n"}}}' > "$FX/rs-rehearsal-new-cb.json"
t "check_backup accepts the R-3 rule"                           ok     'check_backup rehearsal-new cb moveprobe2@rehearsal-new'
t "check_backup refuses a namespace outside the scratch pair"   refuse 'check_backup ai cb moveprobe2@ai'
jq -n '{status:{phase:"x"}}' > "$FX/pv-$PV.json"; pvjson $PV pin rehearsal-new; record $PV
t "wait_pv_phase: matches"                                      ok     "wait_pv_phase $PV Bound 2"
t "wait_pv_phase: bounded timeout"                              refuse "PIN_POLL_P=0 wait_pv_phase $PV Released 3"; has "  says TIMEOUT" "TIMEOUT"
t "wait_pv_phase refuses an unlisted PV"                        refuse 'wait_pv_phase pvc-OTHER Bound 1'
echo '{"items":[{"status":{"phase":"Running","containerStatuses":[{"ready":true}]}}]}' > "$FX/pods-rehearsal-new.json"
t "wait_running: Running+Ready"                                 ok     'wait_running rehearsal-new 2'
echo '{"items":[{"status":{"phase":"Pending"}}]}' > "$FX/pods-rehearsal-new.json"
t "wait_running: bounded timeout"                               refuse 'PIN_POLL_R=0 wait_running rehearsal-new 2'
rm -f "$FX/pods-rehearsal-new.json"

echo "== ro_run / data_check =="
pvc rehearsal-new moveprobe2 $PV Bound; printf 'marker.txt: OK\nstarts=2\n' > "$FX/joblogs.txt"
t "ro_run needs PIN_WINDOW"                                     refuse "ro_run moveprobe2 'ls'"
silence_off; t "ro_run needs a silence"                         refuse "PIN_WINDOW=yes ro_run moveprobe2 'ls'"; silence_on
t "ro_run refuses a PVC that is not a moveprobe2 claim"         refuse "PIN_WINDOW=yes ro_run hermes 'ls'"
pvc rehearsal-new moveprobe2 $PV Pending
t "ro_run refuses a PVC that is not Bound (no second consumer)" refuse "PIN_WINDOW=yes ro_run moveprobe2 'ls'"; eq "  no Job applied" "$(calls '^-n rehearsal-new apply')" 0
pvc rehearsal-new moveprobe2 $PV Bound
t "ro_run: applies a READ-ONLY uid-0 Job and prints its log"    ok     "PIN_POLL_J=0 PIN_WINDOW=yes ro_run moveprobe2 'ls'"; has "  log shown" "starts=2"
eq "  runAsUser 0" "$(grep -c '"runAsUser":0' "$FX/last-apply.yaml")" 1; eq "  readOnly mount+claim" "$(grep -o '"readOnly":true' "$FX/last-apply.yaml" | wc -l | tr -d ' ')" 2
eq "  Job deleted afterwards" "$(calls '^-n rehearsal-new delete job')" 1
FAKE_JOB_STATE=failed t "ro_run: a failed Job returns non-zero (and is still deleted)" refuse "PIN_POLL_J=0 PIN_WINDOW=yes ro_run moveprobe2 'ls'"; eq "  Job deleted" "$(calls '^-n rehearsal-new delete job')" 1
t "data_check: sha256sum -c + starts.log"                       ok     'PIN_POLL_J=0 PIN_WINDOW=yes data_check'; eq "  the command was applied" "$(grep -c 'sha256sum -c SHA256SUMS' "$FX/last-apply.yaml")" 1
echo '{"items":[{"spec":{"nodeName":"brokkr02","volumes":[{"persistentVolumeClaim":{"claimName":"moveprobe2"}}]}}]}' > "$FX/pods-rehearsal-new.json"
t "ro_run pins the Job to the node of the pod that mounts the PVC" ok "PIN_POLL_J=0 PIN_WINDOW=yes ro_run moveprobe2 'ls'"; eq "  nodeName" "$(grep -c '"nodeName":"brokkr02"' "$FX/last-apply.yaml")" 1
rm -f "$FX/pods-rehearsal-new.json"

echo "== ro_run cleanup (m2) =="
pvc rehearsal-new moveprobe2 $PV Bound; silence_on; : > "$FX/calls.log"
FAKE_JOB_STATE=pending PIN_POLL_J=1 PIN_WINDOW=yes /bin/bash -c "source $G; ro_run moveprobe2 ls" >"$FX/bg.out" 2>&1 &
BGPID=$!; sleep 3; kill -TERM $BGPID 2>/dev/null; wait $BGPID 2>/dev/null; RC=$?
eq "  killed with SIGTERM mid-wait: exit status is 130 (handler ran + exit)" "$RC" 130
eq "  the helper Job was deleted by the trap, with foreground cascade" "$(calls 'delete job ro-.* --cascade=foreground --wait=false')" 1
: > "$FX/calls.log"
t "ro_run normal path deletes the Job with --cascade=foreground" ok "PIN_POLL_J=0 PIN_WINDOW=yes ro_run moveprobe2 'ls'"; eq "  foreground delete" "$(calls 'delete job ro-.* --cascade=foreground --wait=true')" 1
FAKE_JOBPOD_LEFT=1 t "ro_run: the helper POD still present after the delete -> non-zero (it holds pvc-protection)" refuse "PIN_POLL_J=0 PIN_WINDOW=yes ro_run moveprobe2 'ls'"; has "  says pvc-protection" "pvc-protection"

echo "== bootstrap_apply =="
t "bootstrap_apply needs PIN_WINDOW"                            refuse 'bootstrap_apply'
silence_off; t "bootstrap_apply needs a silence"                refuse 'PIN_WINDOW=yes bootstrap_apply'; silence_on
t "bootstrap_apply applies exactly the two CRs"                 ok     'PIN_WINDOW=yes bootstrap_apply'; eq "  one apply call with both files" "$(calls '^apply -f .*gitrepository.yaml -f .*rehearsal-apps.yaml')" 1
BD=$R/kubernetes/rehearsal-pin-bootstrap
cp "$BD/gitrepository.yaml" "$T/gr.bak"; echo '  # ${SECRET_DOMAIN}' >> "$BD/gitrepository.yaml"
t "bootstrap_apply refuses a file containing \${ (envsubst trap)" refuse 'PIN_WINDOW=yes bootstrap_apply'; eq "  nothing applied" "$(calls '^apply')" 0
cp "$T/gr.bak" "$BD/gitrepository.yaml"; sed -i.bak 's/refs\/heads\/rehearsal-pin/refs\/heads\/main/' "$BD/gitrepository.yaml"; rm -f "$BD/gitrepository.yaml.bak"
t "bootstrap_apply refuses a GitRepository that tracks main"    refuse 'PIN_WINDOW=yes bootstrap_apply'; eq "  nothing applied" "$(calls '^apply')" 0
cp "$T/gr.bak" "$BD/gitrepository.yaml"; sed -i.bak 's#path: ./kubernetes/rehearsal-pin#path: ./kubernetes/apps#' "$BD/rehearsal-apps.yaml"; rm -f "$BD/rehearsal-apps.yaml.bak"
t "bootstrap_apply refuses a parent whose path is ./kubernetes/apps" refuse 'PIN_WINDOW=yes bootstrap_apply'; eq "  nothing applied" "$(calls '^apply')" 0
git -C "$R" checkout -q -- kubernetes

echo "== silences =="
silence_off
t "am_silence refuses without SILENCE_OK"                       refuse 'am_silence'; eq "  no POST" "$(calls '^curl')" 0
SILENCE_OK=yes t "am_silence refuses AM_HOURS=99"               refuse 'AM_HOURS=99 am_silence'
SILENCE_OK=yes t "am_silence creates three recorded silences"   ok     'PIN_AM_WAIT=0 AM_HOURS=6 am_silence'
eq "  three POSTs" "$(calls '^curl .*POST')" 3; eq "  three ids recorded" "$(wc -l < "$STATE/silences.txt" | tr -d ' ')" 3
eq "  matchers are scoped to rehearsal-.*" "$(grep -c 'rehearsal-\.\*' "$FX/calls.log")" 2
eq "  and the third names only the two scratch CRs" "$(grep -c 'rehearsal-apps|rehearsal' "$FX/calls.log")" 1
eq "  no matcher can name ai/develop/hermes" "$(grep -cE '"value":"(ai|develop|hermes)' "$FX/calls.log")" 0
eq "  until-epoch written (6h)" "$(( ( $(cat "$STATE/silence-until.epoch") - $(date +%s) ) / 3600 ))" 6
eq "  port-forward pid file cleaned up" "$([ -e "$STATE/am-pf.pid" ] && echo left || echo clean)" clean
t "silence recorded + unexpired satisfies need_silence"         ok     'need_silence x'
t "am_unsilence deletes each id and clears the record"          ok     'PIN_AM_WAIT=0 am_unsilence'; eq "  three DELETEs" "$(calls '^curl .*DELETE')" 3; eq "  record cleared" "$(wc -c < "$STATE/silences.txt" | tr -d ' ')" 0
eq "  until-epoch removed" "$([ -e "$STATE/silence-until.epoch" ] && echo left || echo gone)" gone

echo "== verify_clean =="
rm -f "$FX"/pv-*.json; : > "$STATE/pins.txt"; record $PV
t "verify_clean: nothing left -> 0"                             ok     'verify_clean'
pvjson $PV pin rehearsal-new
t "verify_clean: a recorded PV still present FAILS"             refuse 'verify_clean'
rm -f "$FX/pv-$PV.json"; touch "$FX/lh-$PV.txt"
t "verify_clean: a leftover Longhorn volume FAILS"              refuse 'verify_clean'
rm -f "$FX/lh-$PV.txt"; silence_on
t "verify_clean: a recorded silence FAILS"                      refuse 'verify_clean'
silence_off; echo 1 > "$STATE/watch-x.pid"
t "verify_clean: a recorded watcher FAILS"                      refuse 'verify_clean'; rm -f "$STATE/watch-x.pid"
t "verify_clean: clean again -> 0"                              ok     'verify_clean'

echo "== pvc_state =="
jq -n '{metadata:{uid:"u1",annotations:{"kustomize.toolkit.fluxcd.io/ssa":"IfNotPresent"},labels:{},managedFields:[{manager:"kustomize-controller",operation:"Apply",fieldsV1:{"f:spec":{"f:volumeName":{},"f:accessModes":{}},"f:metadata":{"f:labels":{}}}}]},spec:{volumeName:"pv",resources:{requests:{storage:"1Gi"}},storageClassName:"sc"},status:{phase:"Bound",capacity:{storage:"1Gi"}}}' > "$FX/pvc-rehearsal-new-moveprobe2.json"
t "pvc_state prints uid, ssa and the field owners"              ok     'pvc_state'; has "  uid" '"uid":"u1"'; has "  ssa annotation" '"ssa":"IfNotPresent"'; has "  owner manager" '"m":"kustomize-controller"'; has "  owned spec fields" '"f:volumeName"'
eq "  --show-managed-fields was passed to kubectl" "$(calls 'get pvc moveprobe2 --show-managed-fields')" 1

echo "== s1_equiv =="
OWN='[{"manager":"kustomize-controller","operation":"Apply","fieldsV1":{"f:spec":{"f:accessModes":{},"f:dataSourceRef":{},"f:resources":{},"f:storageClassName":{},"f:volumeName":{}},"f:metadata":{"f:labels":{}}}},{"manager":"kube-controller-manager","operation":"Update","fieldsV1":{"f:metadata":{"f:annotations":{}}}},{"manager":"kube-controller-manager","operation":"Update","subresource":"status","fieldsV1":{}}]'
jq -n --argjson m "$OWN" '{metadata:{uid:"u",managedFields:$m},spec:{},status:{}}' > "$FX/pvc-ai-hermes.json"
jq -n --argjson m "$OWN" '{metadata:{uid:"u",managedFields:($m|reverse)},spec:{},status:{}}' > "$FX/pvc-rehearsal-new-moveprobe2.json"
t "s1_equiv: identical ownership (order-insensitive) -> equal"  ok     's1_equiv'; has "  says EQUAL" "owners EQUAL"
DYN='[{"manager":"kustomize-controller","operation":"Apply","fieldsV1":{"f:spec":{"f:accessModes":{},"f:dataSourceRef":{},"f:resources":{},"f:storageClassName":{},"f:volumeName":{}},"f:metadata":{"f:labels":{}}}},{"manager":"kube-controller-manager","operation":"Update","fieldsV1":{"f:spec":{"f:volumeName":{}},"f:metadata":{"f:annotations":{}}}},{"manager":"kube-controller-manager","operation":"Update","subresource":"status","fieldsV1":{}}]'
jq -n --argjson m "$DYN" '{metadata:{uid:"u",managedFields:$m},spec:{},status:{}}' > "$FX/pvc-rehearsal-new-moveprobe2.json"
t "s1_equiv: a dynamically-provisioned-then-pinned claim (KCM also owns volumeName) DIFFERS" refuse 's1_equiv'; has "  says DIFFER" "owners DIFFER"
t "s1_equiv only reads ai/hermes (get)"                         ok     's1_equiv >/dev/null 2>&1 || true'; eq "  non-get calls on ai" "$(grep -c '^-n ai [^g]' "$FX/calls.log" || true)" 0

echo "== kn-guard.test.sh (the shared kn's own suite, run against the copy the guards source) =="
KNOUT=$(/bin/bash "$HERE/../kn-guard.test.sh" "$T/gd/kn-guard.sh" 2>&1); KNRC=$?
KNP=$(sed -nE 's/^KN-GUARD TESTS: [0-9]+ +PASS: ([0-9]+).*/\1/p' <<<"$KNOUT"); KNF=$(sed -nE 's/^KN-GUARD TESTS: [0-9]+ +PASS: [0-9]+ +FAIL: ([0-9]+).*/\1/p' <<<"$KNOUT")
echo "  kn-guard.test.sh: pass=${KNP:-?} fail=${KNF:-?} (rc=$KNRC)"; grep '^FAIL' <<<"$KNOUT" | head -5
pass=$((pass + ${KNP:-0})); fail=$((fail + ${KNF:-1}))
echo
echo "TESTS: $((pass+fail))   PASS: $pass   FAIL: $fail"
[ "$fail" -eq 0 ]
