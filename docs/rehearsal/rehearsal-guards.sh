#!/bin/bash
# rehearsal-guards.sh — guards + helpers for the moveprobe namespace-move rehearsal.
# Lives OUTSIDE every repo. Plan: hermes-to-ai:docs/rehearsal/plan.md
#
# USE: start EVERY command with   source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
# and run it under bash:          bash -c 'source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh; <steps>'
# (Tool calls do not keep functions or variables between calls, and zsh does not word-split
#  unquoted variables — which is why GIT/PUSH are FUNCTIONS, not strings.)
# Written for bash 3.2 (/bin/bash on macOS): no mapfile, no associative arrays, no ${x,,}.
set -euo pipefail

# --- context: refuse to run against anything but the home cluster (exit, not return) -------------------------
# Identify the cluster by its kube-system UID, not by context NAME: the same cluster is reachable as admin@home-kubernetes
# (LAN, 10.0.10.30) and tso-talos.flyingfox-decibel.ts.net (tailnet). Verified 2026-09-23: both return this UID and see
# hermes' PV with an identical uid. A name check only proves what a kubeconfig is called.
[ "$(kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null)" = "793124f9-2b2e-4c9e-9fd0-41d27bd2d5a0" ] || { echo "WRONG CLUSTER (kube-system uid mismatch) — refusing" >&2; exit 1; }

# --- constants ------------------------------------------------------------------------------------------------
GUARDS_DIR="$HOME/.herdr/worktrees/flux-talos"
export R="$GUARDS_DIR/rehearsal-move"                               # the rehearsal worktree (branch rehearsal-move)
export APP="${APP:-moveprobe}"                                      # a re-run after teardown MUST use a new name (moveprobe2): kopia residue persists
# N5: APP comes from the caller's environment — allowlist it. (APP=hermes from a pasted snippet would make others_ready skip develop/hermes.)
case "$APP" in moveprobe|moveprobe[0-9]) ;; *) echo "APP=[$APP] is not a rehearsal app (moveprobe|moveprobeN) — refusing" >&2; exit 1 ;; esac
export OLD=rehearsal-old NEW=rehearsal-new
export HERMES_PV=pvc-12f54114-9e99-442b-bae4-53a9cb239d69           # never touched
export REH_DIR="$GUARDS_DIR/rehearsal-state"                        # stable, outside every repo
export REH_PVS="$REH_DIR/rehearsal-pvs.txt"                         # every rehearsal PV name, recorded when first seen
export REH_SILENCES="$REH_DIR/silences.txt"
mkdir -p "$REH_DIR"; touch "$REH_PVS" "$REH_SILENCES"
export AM_PORT=19093

# --- git: the ONLY way to commit/push in the rehearsal worktree --------------------------------------------------
GIT() { git -C "$R" -c 'user.name=fizz-bot-bvn[bot]' -c 'user.email=324971095+fizz-bot-bvn[bot]@users.noreply.github.com' "$@"; }
# PUSH takes NO arguments and can only push this one refspec.
PUSH() {
  [ $# -eq 0 ] || { echo "PUSH takes no arguments — refusing" >&2; return 1; }
  [ "$(git -C "$R" branch --show-current)" = "rehearsal-move" ] || { echo "not on rehearsal-move — refusing" >&2; return 1; }
  git -C "$R" push origin rehearsal-move:refs/heads/rehearsal-move
}
# COMMIT "<scoped subject>" — trailers: always Co-Authored-By; Claude-Session ONLY if CLAUDE_SESSION_URL is set in the environment
# (a hard-coded URL named a DIFFERENT session's id in the rehearsal's commits). Example: CLAUDE_SESSION_URL=https://claude.ai/code/session_<id>
# NOTE: lefthook pre-commit (gitleaks + yamlfmt) runs here and may REWRITE staged YAML; re-run the flux build gate AFTER this.
COMMIT() {
  local trailers='Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>'
  [ $# -eq 1 ] || { echo 'usage: COMMIT "<subject>"' >&2; return 1; }
  if [ -n "${CLAUDE_SESSION_URL:-}" ]; then trailers="$trailers"$'\n'"Claude-Session: $CLAUDE_SESSION_URL"; fi
  GIT commit -m "$1" -m "$trailers"
}

# --- namespaced kubectl: refuses anything but the two scratch namespaces --------------------------------------
kn() {
  local ns=${1:-}; [ $# -ge 2 ] || { echo "usage: kn <ns> <kubectl args>" >&2; return 1; }; shift
  case "$ns" in
    rehearsal-old|rehearsal-new) kubectl -n "$ns" "$@" ;;
    *) echo "REFUSE ns=[$ns]" >&2; return 1 ;;
  esac
}

# --- PV bookkeeping and guards -----------------------------------------------------------------------------------
# record_pv <ns> <pvc>: PV bound to a PVC in a scratch namespace -> recorded in $REH_PVS, labelled rehearsal=move, name printed.
record_pv() {
  local ns=$1 pvc=$2 pv cn
  pv=$(kn "$ns" get pvc "$pvc" -o json | jq -r '.spec.volumeName // ""')
  [ -n "$pv" ] || { echo "PVC $ns/$pvc has no volume yet" >&2; return 1; }
  cn=$(kubectl get pv "$pv" -o json | jq -r '.spec.claimRef.namespace // ""')
  [ "$cn" = "$ns" ] || { echo "REFUSE: $pv claimRef ns=[$cn] != $ns" >&2; return 1; }
  [ "$pv" != "$HERMES_PV" ] || { echo "REFUSE: hermes PV" >&2; return 1; }
  grep -qx "$pv" "$REH_PVS" || echo "$pv" >> "$REH_PVS"
  kubectl label pv "$pv" rehearsal=move --overwrite >/dev/null
  echo "$pv"
}
# adopt_pv <pv>: for teardown enumeration ONLY — records a PV whose claimRef namespace is rehearsal-*.
adopt_pv() {
  local pv=$1 cn
  cn=$(kubectl get pv "$pv" -o json | jq -r '.spec.claimRef.namespace // ""')
  case "$cn" in rehearsal-old|rehearsal-new) ;; *) echo "REFUSE adopt: $pv claimRef ns=[$cn]" >&2; return 1;; esac
  [ "$pv" != "$HERMES_PV" ] || { echo "REFUSE: hermes PV" >&2; return 1; }
  grep -qx "$pv" "$REH_PVS" || echo "$pv" >> "$REH_PVS"
  kubectl label pv "$pv" rehearsal=move --overwrite >/dev/null
}
# rehearsal_pv_ok <pv>: run before EVERY PV patch/delete. Requires: not hermes, in $REH_PVS, labelled rehearsal=move, and
# claimRef namespace in rehearsal-* — or EMPTY (a released-and-cleared PV such as the S8 bait), which is accepted ONLY because
# the list + label checks passed. Null-safe. N4: a READ ERROR is a REFUSAL; "gone" is printed ONLY on a confirmed empty
# --ignore-not-found result. (errexit is DISABLED inside functions called in && / || lists, so every check is explicit.)
rehearsal_pv_ok() {
  local pv=${1:-} out j cn lbl
  if [ -z "$pv" ] || [ "$pv" = "$HERMES_PV" ]; then echo "REFUSE: empty or hermes PV" >&2; return 1; fi
  if ! grep -qx "$pv" "$REH_PVS"; then echo "REFUSE: $pv not in $REH_PVS" >&2; return 1; fi
  if ! out=$(kubectl get pv "$pv" --ignore-not-found -o name); then echo "REFUSE: cannot read PV $pv (API error)" >&2; return 1; fi
  if [ -z "$out" ]; then echo "gone: $pv"; return 0; fi
  if ! j=$(kubectl get pv "$pv" -o json); then echo "REFUSE: cannot read PV $pv (API error)" >&2; return 1; fi
  if ! lbl=$(jq -r '.metadata.labels.rehearsal // ""' <<<"$j"); then return 1; fi
  if [ "$lbl" != "move" ]; then echo "REFUSE: $pv lacks label rehearsal=move" >&2; return 1; fi
  if ! cn=$(jq -r '.spec.claimRef.namespace // ""' <<<"$j"); then return 1; fi
  case "$cn" in rehearsal-old|rehearsal-new|"") ;; *) echo "REFUSE: $pv claimRef ns=[$cn]" >&2; return 1;; esac
  echo "ok $pv (claim ns=[$cn])"
}
# The ONLY PV mutators. pv_delete: the Longhorn volume is deleted ONLY after the PV is confirmed gone (delete succeeded and a
# --ignore-not-found read returns empty), all checked explicitly.
pv_patch()  { local pv=$1; shift; rehearsal_pv_ok "$pv" >/dev/null || return 1; kubectl patch pv "$pv" "$@"; }
pv_delete() {
  local pv=$1 st out
  if ! st=$(rehearsal_pv_ok "$pv"); then return 1; fi
  case "$st" in
    gone:*) : ;;                                                    # confirmed absent: only a leftover Longhorn volume may remain
    *)
      if ! kubectl delete pv "$pv" --ignore-not-found --timeout=240s; then echo "pv delete failed — NOT deleting the Longhorn volume" >&2; return 1; fi
      if ! out=$(kubectl get pv "$pv" --ignore-not-found -o name); then echo "cannot confirm PV gone — NOT deleting the Longhorn volume" >&2; return 1; fi
      if [ -n "$out" ]; then echo "PV $pv still present — NOT deleting the Longhorn volume" >&2; return 1; fi ;;
  esac
  kubectl -n longhorn-system delete volumes.longhorn.io "$pv" --ignore-not-found
}
# pv_repoint <pv> <ns> <name>: reserve a PV for one claim (uid/resourceVersion null) — never remove claimRef.
pv_repoint() { pv_patch "$1" --type merge -p '{"spec":{"claimRef":{"namespace":"'"$2"'","name":"'"$3"'","uid":null,"resourceVersion":null}}}'; }

# --- assertions ------------------------------------------------------------------------------------------------
# inventory_ok: rehearsal-apps inventory must be NON-EMPTY and contain only rehearsal-* objects (+ the two Namespaces). Fails closed on null.
inventory_ok() {
  if kubectl -n flux-system get ks rehearsal-apps -o json | jq -e '
    [ .status.inventory.entries[]?.id ] as $ids
    | ($ids | length) > 0
    and ($ids | all(test("^(rehearsal-(old|new)_|_rehearsal-(old|new)__Namespace$)")))' >/dev/null; then
    echo "inventory ok"
  else
    echo "INVENTORY CHECK FAILED (empty, null, or contains a non-rehearsal object)" >&2; return 1
  fi
}
# others_ready: every Kustomization outside rehearsal-* (and rehearsal-apps) must be Ready. N8: a reconcile starts by marking Ready=Unknown, and a push
# fires the Receiver (reconciles cluster-apps), so a single "not True" is noise. Fail at once on Ready=False; otherwise require not-True on 3 polls 20s apart.
others_ready() {
  local i bad falsy
  for i in 1 2 3; do
    falsy=$(kubectl get ks -A -o json | jq -r '.items[]|select((.metadata.namespace|test("^rehearsal-"))|not)|select(.metadata.name!="rehearsal-apps")
            |select(((.status.conditions // [])|map(select(.type=="Ready"))|.[0].status // "Unknown")=="False")|"\(.metadata.namespace)/\(.metadata.name)"') || return 1
    [ -z "$falsy" ] || { echo "READY=False: $falsy" >&2; return 1; }
    bad=$(kubectl get ks -A -o json | jq -r '.items[]|select((.metadata.namespace|test("^rehearsal-"))|not)|select(.metadata.name!="rehearsal-apps")
            |select(((.status.conditions // [])|map(select(.type=="Ready"))|.[0].status // "Unknown")!="True")|"\(.metadata.namespace)/\(.metadata.name)"') || return 1
    [ -z "$bad" ] && { echo "all other ks Ready"; return 0; }
    echo "poll $i/3: not yet Ready: $bad" >&2; [ "$i" -lt 3 ] && sleep 20
  done
  echo "NOT READY after 3 polls: $bad" >&2; return 1
}
# check_backup <ns> <replicationsource> <identity>: the R-3 acceptance rule. Returns nonzero if any count is wrong.
check_backup() {
  local L c s o e rc=0
  L=$(kn "$1" get replicationsource.volsync.backube "$2" -o json | jq -r '.status.latestMoverStatus.logs // ""')
  c=$(grep -c 'Created snapshot with root' <<<"$L" || true); s=$(grep -cF "Setting policy for $3:/data" <<<"$L" || true)
  o=$(grep -cF 'OPERATION_RESULT: SUCCESS' <<<"$L" || true); e=$(grep -c 'Directory is empty' <<<"$L" || true)
  echo "Created snapshot: $c (>=1)  Setting policy $3: $s (>=1)  RESULT SUCCESS: $o (>=1)  Directory is empty: $e (0)"
  [ "$c" -ge 1 ] && [ "$s" -ge 1 ] && [ "$o" -ge 1 ] && [ "$e" -eq 0 ] || { echo "check_backup FAILED for $1/$2" >&2; rc=1; }
  return $rc
}
# data_check <ns>: read-only content + continuity check. If the app pod exists the Job is pinned to ITS node (RWO Longhorn
# Multi-Attach otherwise); with the app at 0 it runs anywhere. Waits for complete OR failed, ALWAYS prints logs, always deletes the Job
# (a Completed pod blocks PVC deletion).
data_check() {
  local ns=$1 j node pin="" st="" i
  j="chk-$(date +%s)"
  node=$(kn "$ns" get pod -l app.kubernetes.io/name="$APP" -o json | jq -r '(.items[0].spec.nodeName) // ""')
  [ -n "$node" ] && pin="nodeName: $node"
  kn "$ns" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: $j, labels: {rehearsal: helper}}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      $pin
      securityContext: {runAsNonRoot: true, runAsUser: 10000, fsGroup: 10000, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: r
          image: busybox:1.37
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          command: [sh, -c, "cd /data && sha256sum -c SHA256SUMS && echo starts=\$(wc -l < starts.log) && cat starts.log"]
          volumeMounts: [{name: d, mountPath: /data, readOnly: true}]
      volumes: [{name: d, persistentVolumeClaim: {claimName: $APP, readOnly: true}}]
EOF
  for i in $(seq 1 60); do
    st=$(kn "$ns" get job "$j" -o json | jq -r 'if (.status.succeeded // 0) > 0 then "ok" elif (.status.failed // 0) > 0 then "failed" else "" end')
    [ -n "$st" ] && break; sleep 5
  done
  echo "--- data_check $ns: job=$j pin=[${node}] result=[${st:-TIMEOUT}] ---"
  kn "$ns" logs "job/$j" 2>&1 || true
  kn "$ns" describe pod -l job-name="$j" 2>&1 | grep -E "Warning|Events" -A3 | head -12 || true
  kn "$ns" delete job "$j" --wait=true >/dev/null 2>&1 || true
  [ "$st" = "ok" ]
}

# --- pre-merge gate ---------------------------------------------------------------------------------------------
# move_gate <target-ns> <want>: run AFTER COMMIT (lefthook/yamlfmt may have rewritten the files) and BEFORE PUSH. Requires ALL of:
#   1. the WHOLE rehearsal tree is committed (porcelain on kubernetes/rehearsal is empty — covers both namespace kustomization.yaml files);
#   2. the app build has exactly <want> lines matching volumeName|sourceNamespace (2 = forward move, 1 = rollback into the series' own ns, 0 = baseline/no-op);
#   3. EVERY metadata.namespace in the app build equals <target-ns>            (catches a stale targetNamespace);
#   4. the PARENT build (rehearsal-apps) contains exactly ONE child Kustomization named $APP, in <target-ns>, with
#      spec.path == ./kubernetes/rehearsal/<ns>/$APP/app and spec.targetNamespace == <target-ns>
#      (catches: ks.yaml not added to the new namespace kustomization, not removed from the old one, stale path/targetNamespace).
move_gate() {
  local ns=${1:-} want=${2:-} built out n nss parent expect ok=0
  case "$ns" in rehearsal-old|rehearsal-new) ;; *) echo "GATE: bad namespace [$ns]" >&2; return 1;; esac
  case "$want" in 0|1|2) ;; *) echo "GATE: want must be 0, 1 or 2" >&2; return 1;; esac
  if [ -n "$(GIT status --porcelain -- kubernetes/rehearsal)" ]; then echo "GATE FAIL: uncommitted changes under kubernetes/rehearsal — COMMIT first (the gate checks COMMITTED files)" >&2; return 1; fi
  if ! built=$(cd "$R" && flux build ks "$APP" -n "$ns" --path "./kubernetes/rehearsal/$ns/$APP/app" \
        --kustomization-file "./kubernetes/rehearsal/$ns/$APP/ks.yaml" --dry-run); then echo "GATE FAIL: app build failed" >&2; return 1; fi
  out=$(grep -n -E "volumeName|sourceNamespace" <<<"$built" || true); echo "$out"
  n=$(printf '%s\n' "$out" | grep -c . || true)
  [ "$n" -eq "$want" ] || { echo "GATE FAIL: $n volumeName/sourceNamespace lines, want $want" >&2; ok=1; }
  nss=$(yq -N 'select(.kind)|.metadata.namespace // "NONE"' <<<"$built" | sort -u)
  [ "$nss" = "$ns" ] || { echo "GATE FAIL: namespaces in the app build = [$(echo "$nss" | tr '\n' ' ')], want only [$ns]" >&2; ok=1; }
  if ! parent=$(cd "$R" && flux build ks rehearsal-apps -n flux-system --path ./kubernetes/rehearsal \
        --kustomization-file ./kubernetes/rehearsal-bootstrap/rehearsal-apps.yaml --dry-run \
        | yq -N 'select(.kind=="Kustomization")|[.metadata.namespace,.metadata.name,.spec.path,.spec.targetNamespace]|join(" ")'); then
    echo "GATE FAIL: parent build failed" >&2; return 1; fi
  echo "parent children: $(grep -c . <<<"$parent" || true)"; grep -F " $APP " <<<"$parent" || true
  expect="$ns $APP ./kubernetes/rehearsal/$ns/$APP/app $ns"
  [ "$(grep -c -F " $APP " <<<"$parent" || true)" -eq 1 ] || { echo "GATE FAIL: need exactly ONE child Kustomization named $APP" >&2; ok=1; }
  grep -qxF "$expect" <<<"$parent" || { echo "GATE FAIL: parent child != [$expect]" >&2; ok=1; }
  [ "$ok" -eq 0 ] && { echo "GATE PASS"; return 0; }
  echo "GATE FAIL — DO NOT PUSH" >&2; return 1
}

# --- bounded waits (every loop is bounded; a tool call dies at 600s) -------------------------------------------------
# wait_manual <ns> <rs> <tag> [tries=50]: wait (10s steps) until status.lastManualSync == <tag>. Returns 1 on timeout.
wait_manual() {
  local ns=$1 rs=$2 tag=$3 tries=${4:-50} i cur
  for i in $(seq 1 "$tries"); do
    cur=$(kn "$ns" get replicationsource.volsync.backube "$rs" -o json | jq -r '.status.lastManualSync // ""') || return 1
    [ "$cur" = "$tag" ] && { echo "$rs lastManualSync=$tag"; return 0; }
    sleep 10
  done
  echo "TIMEOUT: $ns/$rs lastManualSync=[$cur] != $tag" >&2; return 1
}
# wait_pv_phase <pv> <phase> [tries=100]: wait (3s steps) for a PV phase; bounded.
wait_pv_phase() {
  local pv=$1 want=$2 tries=${3:-100} i cur
  rehearsal_pv_ok "$pv" >/dev/null || return 1
  for i in $(seq 1 "$tries"); do
    cur=$(kubectl get pv "$pv" -o json | jq -r '.status.phase // ""') || return 1
    [ "$cur" = "$want" ] && { echo "$pv $want"; return 0; }
    sleep 3
  done
  echo "TIMEOUT: $pv phase=[$cur] != $want" >&2; return 1
}
# wait_running <ns> [tries=60]: wait (5s steps) for the app pod to be Running+Ready.
wait_running() {
  local ns=$1 tries=${2:-60} i r
  for i in $(seq 1 "$tries"); do
    r=$(kn "$ns" get pod -l app.kubernetes.io/name="$APP" -o json | jq -r '[.items[]|select(.status.phase=="Running" and ((.status.containerStatuses // [])|all(.ready)))]|length') || return 1
    [ "$r" -ge 1 ] && { echo "$APP Running in $ns"; return 0; }
    sleep 5
  done
  echo "TIMEOUT: no Running $APP pod in $ns" >&2; return 1
}
# app_pv: the PV of $APP's PVC, RE-READ from the PVC's spec.volumeName on EVERY call — never from a cached file (B-2: a cached name went stale after the PVC was
# re-provisioned and the guard then protected a nonexistent PV while the live one was unrecorded). A pre-bound PVC that is still Pending has spec.volumeName set,
# so this also works in the Released window of B6. If the PV is new it is recorded+labelled (record_pv, claimRef ns must equal the PVC's ns); if already recorded it is
# only verified with rehearsal_pv_ok (its claimRef may still name the OLD namespace while the NEW claim waits). Refuses if OLD and NEW claims name different PVs.
# A legacy $REH_DIR/app-pv-*.txt file is ignored.
app_pv() {
  local ns pv="" v=""
  for ns in "$OLD" "$NEW"; do
    v=$(kubectl -n "$ns" get pvc "$APP" -o json 2>/dev/null | jq -r '.spec.volumeName // ""' || true)
    [ -n "$v" ] || continue
    if [ -n "$pv" ] && [ "$v" != "$pv" ]; then echo "REFUSE: $APP claims in $OLD/$NEW name different PVs ($pv vs $v)" >&2; return 1; fi
    pv=$v
  done
  [ -n "$pv" ] || { echo "no PVC $APP with a volumeName in $OLD or $NEW right now (there is deliberately NO cached fallback)" >&2; return 1; }
  if ! grep -qx "$pv" "$REH_PVS"; then          # first sight of this PV: record+label it from a claim whose namespace matches its claimRef
    local rec=1
    for ns in "$OLD" "$NEW"; do
      [ "$(kubectl -n "$ns" get pvc "$APP" -o json 2>/dev/null | jq -r '.spec.volumeName // ""' || true)" = "$pv" ] || continue
      if record_pv "$ns" "$APP" >/dev/null 2>&1; then rec=0; break; fi
    done
    [ "$rec" -eq 0 ] || { echo "cannot record $pv (its claimRef namespace matches neither claim)" >&2; return 1; }
  fi
  rehearsal_pv_ok "$pv" >/dev/null || return 1
  echo "$pv"
}
# background watchers: PIDs recorded so they can be killed (N12)
watch_start() { local name=$1; shift; "$@" > "$REH_DIR/$name.log" 2>&1 & echo $! > "$REH_DIR/watch-$name.pid"; echo "watching $name (pid $(cat "$REH_DIR/watch-$name.pid")) -> $REH_DIR/$name.log"; }
watch_stop_all() { local f; for f in "$REH_DIR"/watch-*.pid; do [ -f "$f" ] || continue; kill "$(cat "$f")" 2>/dev/null || true; rm -f "$f"; done; echo "watchers stopped"; }

# --- Alertmanager silences (the ONE authorised change outside rehearsal-*; never edit Alert CRs) ------------------
# Flux's alertmanager provider labels (VERIFIED, notification-controller v1.9.1 alertmanager.go:109-116): alertname, severity, reason, kind, name, namespace, reportingcontroller.
# VolSync series carry obj_namespace/obj_name (namespace= is the exporter's). Alertmanager fully anchors regex matchers.
am_open()  {
  kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager "$AM_PORT":9093 >/dev/null 2>&1 &
  echo $! > "$REH_DIR/am-pf.pid"; trap am_close EXIT; sleep 3      # trap: a failing curl must not leak the port-forward
}
am_close() { if [ -f "$REH_DIR/am-pf.pid" ]; then kill "$(cat "$REH_DIR/am-pf.pid")" 2>/dev/null || true; rm -f "$REH_DIR/am-pf.pid"; fi; }
# am_silence: three silences ($AM_HOURS, default 8h): namespace=~rehearsal-.* ; obj_namespace=~rehearsal-.* ; name=~rehearsal-apps|rehearsal. Re-run if the rehearsal spills over.
am_silence() {
  local start end body id m
  start=$(date -u +%FT%TZ); end=$(date -u -v+"${AM_HOURS:-8}"H +%FT%TZ 2>/dev/null || date -u -d "+${AM_HOURS:-8} hours" +%FT%TZ)
  am_open
  for m in 'namespace|rehearsal-.*' 'obj_namespace|rehearsal-.*' 'name|rehearsal-apps|rehearsal'; do
    body=$(jq -n --arg n "${m%%|*}" --arg v "${m#*|}" --arg s "$start" --arg e "$end" \
      '{matchers:[{name:$n,value:$v,isRegex:true,isEqual:true}],startsAt:$s,endsAt:$e,createdBy:"rehearsal",comment:"moveprobe rehearsal (auto-expires; removed in teardown)"}')
    id=$(curl -fsS --retry 5 --retry-delay 1 --retry-connrefused -X POST -H 'Content-Type: application/json' -d "$body" "http://127.0.0.1:$AM_PORT/api/v2/silences" | jq -r '.silenceID')
    echo "$id" >> "$REH_SILENCES"; echo "silence $id  ${m%%|*}=~${m#*|}"
  done
  am_close
}
am_unsilence() {
  local id; am_open
  while read -r id; do
    [ -n "$id" ] || continue
    curl -fsS --retry 5 --retry-delay 1 --retry-connrefused -X DELETE "http://127.0.0.1:$AM_PORT/api/v2/silence/$id" && echo "expired $id"
  done < "$REH_SILENCES"
  : > "$REH_SILENCES"; am_close
}

# --- S8 helpers: Block-mode bait/thief/wanted PVCs and one-shot Jobs (rehearsal namespaces only) -------------------
# Block volumeMode: a production Filesystem claim can never match a Block PV. Jobs run as uid 0 (baseline allows it; a non-root reader would depend on
# the kubelet applying fsGroup to a raw block device — unverified).
s8_pvc() {   # <ns> <name>
  kn "$1" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $2, labels: {rehearsal: helper}}
spec: {accessModes: [ReadWriteOnce], volumeMode: Block, storageClassName: longhorn-1-replica-local, resources: {requests: {storage: 1Gi}}}
YAML
}
s8_job() {   # <ns> <job> <pvc> <write|read>
  local cmd
  if [ "$4" = write ]; then cmd="printf 'bait-marker-1234' | dd of=/dev/blk bs=512 count=1 conv=sync 2>/dev/null; dd if=/dev/blk bs=17 count=1 2>/dev/null; echo"
  else cmd="dd if=/dev/blk bs=17 count=1 2>/dev/null; echo"; fi
  kn "$1" apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: $2, labels: {rehearsal: helper}}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: w
          image: busybox:1.37
          securityContext: {runAsUser: 0, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          command: [sh, -c, "$cmd"]
          volumeDevices: [{name: b, devicePath: /dev/blk}]
      volumes: [{name: b, persistentVolumeClaim: {claimName: $3}}]
YAML
}
s8_wait() {  # <ns> <job> [tries=40]: bounded; prints result + logs
  local ns=$1 j=$2 tries=${3:-40} i st=""
  for i in $(seq 1 "$tries"); do
    st=$(kn "$ns" get job "$j" -o json | jq -r 'if (.status.succeeded // 0) > 0 then "ok" elif (.status.failed // 0) > 0 then "failed" else "" end') || return 1
    [ -n "$st" ] && break; sleep 5
  done
  echo "--- $ns/$j result=[${st:-TIMEOUT}] ---"; kn "$ns" logs "job/$j" 2>&1 || true
  [ "$st" = ok ]
}

# --- ro_run <ns> <pvc> "<shell command>": read-only uid-0 Job on a PVC (N13). Runs the command in /data, pinned to the node of any pod that already
# mounts <pvc> (RWO), waits for succeeded OR failed, ALWAYS prints logs, always deletes the Job. Use for baseline listings, the B5b restore drill (a restored
# root:root tree is unreadable to uid 10000) and `ls -ln` ownership records. Keep <shell command> free of a leading `cd` and of newlines.
ro_run() {
  local ns=$1 pvc=$2 cmd=$3 j node pin="" st="" i cj
  j="ro-$(date +%s)"
  node=$(kn "$ns" get pod -o json | jq -r --arg c "$pvc" '[.items[]|select(.spec.volumes[]?.persistentVolumeClaim.claimName==$c)|.spec.nodeName][0] // ""')
  [ -n "$node" ] && pin="nodeName: $node"
  cj=$(jq -Rn --arg c "cd /data && $cmd" '$c')
  kn "$ns" apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: $j, labels: {rehearsal: helper}}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      $pin
      containers:
        - name: r
          image: busybox:1.37
          securityContext: {runAsUser: 0, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          command: [sh, -c, $cj]
          volumeMounts: [{name: d, mountPath: /data, readOnly: true}]
      volumes: [{name: d, persistentVolumeClaim: {claimName: $pvc, readOnly: true}}]
YAML
  for i in $(seq 1 60); do
    st=$(kn "$ns" get job "$j" -o json | jq -r 'if (.status.succeeded // 0) > 0 then "ok" elif (.status.failed // 0) > 0 then "failed" else "" end') || break
    [ -n "$st" ] && break; sleep 5
  done
  echo "--- ro_run $ns/$pvc: job=$j pin=[$node] result=[${st:-TIMEOUT}] ---"
  kn "$ns" logs "job/$j" 2>&1 || true
  kn "$ns" delete job "$j" --wait=true >/dev/null 2>&1 || true
  [ "$st" = ok ]
}
