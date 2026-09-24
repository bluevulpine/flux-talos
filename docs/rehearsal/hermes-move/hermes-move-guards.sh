#!/bin/bash
# hermes-move-guards.sh — guards + helpers for the REAL develop -> ai move of hermes.
# Lives OUTSIDE every repo. Runbook: docs/runbooks/volsync-app-namespace-move.md
# Execution plan: docs/runbooks/hermes-ns-move-execution.md (branch hermes-to-ai)
# Adapted from rehearsal-guards.sh (the rehearsal's guards, which ran the same procedure on `moveprobe`).
#
# USE: start EVERY command with   source ~/.herdr/worktrees/flux-talos/hermes-move-guards.sh
# and run it under bash:          bash -c 'source ~/.herdr/worktrees/flux-talos/hermes-move-guards.sh; <steps>'
# (Tool calls keep neither functions nor variables between calls; zsh does not word-split unquoted variables.)
# Written for bash 3.2 (/bin/bash on macOS): no mapfile, no associative arrays, no ${x,,}.
#
# DIFFERENCES FROM THE REHEARSAL GUARDS (deliberate):
#   * There is NO PUSH function. The move goes through two pull requests, merged with `gh pr merge`. Nothing here pushes.
#   * APP is pinned to hermes and NOT read from the environment (an inherited APP=other must not redirect a guard).
#   * kn only talks to `develop` and `ai`.
#   * Exactly ONE PV may ever be patched: $HERMES_PV. It must carry the label hermes-move=1 (set by record_pv) and its claimRef namespace
#     must be develop, ai, or empty (the cleared window). Any API error is a REFUSAL (fail closed).
#   * There is no pv_delete and no Longhorn-volume delete: this move never deletes either. The reclaim policy is changed only by pv_reclaim
#     (Retain|Delete), and only after the PV checks pass.
set -euo pipefail

# --- test-mode interlock (N4): the harness exports HM_FAKE=1 and puts its fake kubectl/gh first on PATH. If anything (a nested `zsh -c` re-reading ~/.zshenv,
# a reset PATH) puts the REAL kubectl/gh ahead of the fakes, refuse BEFORE any command talks to the cluster or GitHub. (A reviewer once hit the live cluster this way.)
if [ "${HM_FAKE:-}" = 1 ]; then
  case "$(command -v kubectl 2>/dev/null)" in */hermes-move-guards-test/bin/kubectl) ;; *) echo "HM_FAKE=1 but kubectl is [$(command -v kubectl 2>/dev/null)], not the harness fake — refusing" >&2; exit 1;; esac
  case "$(command -v gh 2>/dev/null)" in */hermes-move-guards-test/bin/gh) ;; *) echo "HM_FAKE=1 but gh is [$(command -v gh 2>/dev/null)], not the harness fake — refusing" >&2; exit 1;; esac
fi

# --- context: refuse to run against anything but the home cluster (exit, not return) -------------------------
# Identify the cluster by its kube-system UID, not by context NAME: the same cluster is reachable as admin@home-kubernetes (LAN) and
# tso-talos.flyingfox-decibel.ts.net (tailnet); both return this UID. A name check only proves what a kubeconfig is called.
[ "$(kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null)" = "793124f9-2b2e-4c9e-9fd0-41d27bd2d5a0" ] || { echo "WRONG CLUSTER (kube-system uid mismatch) — refusing" >&2; exit 1; }

# --- constants ------------------------------------------------------------------------------------------------
# GUARDS_DIR is the directory THIS FILE lives in, never a caller export (a stray GUARDS_DIR/MOVE_DIR in the environment must not redirect state or the repo).
GUARDS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export R="$GUARDS_DIR/hermes-move"                                  # the worktree holding branch hermes-move (commit 1 + commit 2)
export APP=hermes OLD=develop NEW=ai                                # pinned: NOT inherited from the caller
export HERMES_PV=pvc-12f54114-9e99-442b-bae4-53a9cb239d69           # the ONE PV this file will ever touch (verified live 2026-09-24)
export MOVE_DIR="$GUARDS_DIR/hermes-move-state"                     # stable, outside every repo: baseline listing, T0/TAG/SINCE, silences (derived, NOT overridable)
# The two commits the PRs carry, and the main they were built on. Full SHAs: pr_merge refuses anything else.
export PR1_SHA=b7667471e658da525f1dd3aaa0ca1524a96d1717 PR2_SHA=b91dd0c9b94b959432ce4b0d2ec1b788d02a5dbf
export BASE_SHA=9d73a56dc1b5f90c0789690df1a29e43c7db48bc
export MOVE_SILENCES="$MOVE_DIR/silences.txt"
mkdir -p "$MOVE_DIR"; touch "$MOVE_SILENCES"
export AM_PORT=19093
export GH_REPO=bluevulpine/flux-talos                              # every gh call passes -R $GH_REPO: gh otherwise resolves the repo from the caller's cwd

# --- git: the ONLY way to commit in the worktree. No push. ----------------------------------------------------------
GIT() { git -C "$R" -c 'user.name=fizz-bot-bvn[bot]' -c 'user.email=324971095+fizz-bot-bvn[bot]@users.noreply.github.com' "$@"; }
# COMMIT "<scoped subject>" — trailers: Co-Authored-By always; Claude-Session only if CLAUDE_SESSION_URL is set in the environment.
# NOTE: lefthook pre-commit (gitleaks + yamlfmt) runs here and may REWRITE staged YAML; re-run move_gate AFTER this.
COMMIT() {
  local trailers='Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>'
  [ $# -eq 1 ] || { echo 'usage: COMMIT "<subject>"' >&2; return 1; }
  if [ -n "${CLAUDE_SESSION_URL:-}" ]; then trailers="$trailers"$'\n'"Claude-Session: $CLAUDE_SESSION_URL"; fi
  GIT commit -m "$1" -m "$trailers"
}

# --- namespaced kubectl: refuses anything but develop and ai ---------------------------------------------------
kn() {
  local ns=${1:-}; [ $# -ge 2 ] || { echo "usage: kn <ns> <kubectl args>" >&2; return 1; }; shift
  case "$ns" in
    develop|ai) kubectl -n "$ns" "$@" ;;
    *) echo "REFUSE ns=[$ns]" >&2; return 1 ;;
  esac
}

# --- the one PV -----------------------------------------------------------------------------------------------------
# pv_ok <pv> [require-label=1]: run before EVERY PV mutation. Requires: the name is exactly $HERMES_PV; the PV is readable (a read error is a
# REFUSAL); it carries hermes-move=1 (unless require-label=0, used only by record_pv itself); claimRef namespace is develop or ai. An EMPTY claimRef is
# REFUSED: this plan only ever re-points, and a claimRef-less PV is the R-5 "any matching claim takes it" state.
# (errexit is DISABLED inside functions called in && / || lists, so every check is explicit.)
pv_ok() {
  local pv=${1:-} need=${2:-1} j lbl cn
  if [ "$pv" != "$HERMES_PV" ]; then echo "REFUSE: [$pv] is not the hermes PV ($HERMES_PV)" >&2; return 1; fi
  if ! j=$(kubectl get pv "$pv" -o json); then echo "REFUSE: cannot read PV $pv (API error or absent)" >&2; return 1; fi
  if ! lbl=$(jq -r '.metadata.labels["hermes-move"] // ""' <<<"$j"); then return 1; fi
  if [ "$need" = 1 ] && [ "$lbl" != "1" ]; then echo "REFUSE: $pv lacks label hermes-move=1 (run record_pv first)" >&2; return 1; fi
  if ! cn=$(jq -r '.spec.claimRef.namespace // ""' <<<"$j"); then return 1; fi
  case "$cn" in develop|ai) ;; *) echo "REFUSE: $pv claimRef ns=[$cn] (must be develop or ai; empty is refused)" >&2; return 1;; esac
  echo "ok $pv (claim ns=[$cn])"
}
# record_pv: label the hermes PV hermes-move=1 (the ONE PV mutation that needs no label). Only if a live hermes PVC in develop or ai names
# exactly $HERMES_PV and that PV's claimRef namespace matches that claim's namespace.
record_pv() {
  local ns v cn
  for ns in "$OLD" "$NEW"; do
    v=$(kubectl -n "$ns" get pvc "$APP" -o json 2>/dev/null | jq -r '.spec.volumeName // ""' || true)
    [ "$v" = "$HERMES_PV" ] || continue
    cn=$(kubectl get pv "$HERMES_PV" -o json | jq -r '.spec.claimRef.namespace // ""') || return 1
    [ "$cn" = "$ns" ] || continue
    pv_ok "$HERMES_PV" 0 >/dev/null || return 1
    kubectl label pv "$HERMES_PV" hermes-move=1 --overwrite >/dev/null || return 1
    echo "$HERMES_PV"; return 0
  done
  echo "REFUSE: no $APP PVC in $OLD/$NEW names $HERMES_PV with a matching claimRef namespace" >&2; return 1
}
# The ONLY PV mutators.
pv_patch()   { local pv=$1; shift; pv_ok "$pv" >/dev/null || return 1; kubectl patch pv "$pv" "$@"; }
# pv_reclaim <pv> Retain|Delete   (Delete RE-ARMS trap 2 — only at B10, or to undo Retain while the app is untouched)
# Delete is accepted ONLY on a PV that is Bound AND whose claimRef PVC exists, is Bound and names this PV: a Released/Available PV flipped to Delete
# is reclaimed at once (PV + Longhorn volume gone).
pv_reclaim() {
  local pv=$1 pol=${2:-} j ph cn c cv cph
  case "$pol" in Retain|Delete) ;; *) echo "REFUSE: reclaim policy [$pol] must be Retain or Delete" >&2; return 1;; esac
  if [ "$pol" = Delete ]; then
    # Once $MOVE_DIR/SINCE.txt exists (written at W-9, the move has started) Delete is B10 territory: it needs the human's go-ahead, like SILENCE_OK.
    if [ -e "$MOVE_DIR/SINCE.txt" ] && [ "${B10_OK:-}" != "yes" ]; then
      echo "REFUSE: the move has started ($MOVE_DIR/SINCE.txt exists); Delete is B10 and needs B10_OK=yes (the human's go-ahead)" >&2; return 1
    fi
    pv_ok "$pv" >/dev/null || return 1
    if ! j=$(kubectl get pv "$pv" -o json); then echo "REFUSE: cannot read PV $pv" >&2; return 1; fi
    ph=$(jq -r '.status.phase // ""' <<<"$j") || return 1
    [ "$ph" = Bound ] || { echo "REFUSE: Delete needs the PV Bound, it is [$ph] — a $ph PV set to Delete is reclaimed at once" >&2; return 1; }
    cn=$(jq -r '.spec.claimRef.namespace // ""' <<<"$j") || return 1
    case "$cn" in develop|ai) ;; *) echo "REFUSE: claimRef ns [$cn]" >&2; return 1;; esac
    if ! c=$(kubectl -n "$cn" get pvc "$APP" -o json); then echo "REFUSE: claim $cn/$APP does not exist — Delete would destroy the volume" >&2; return 1; fi
    cv=$(jq -r '.spec.volumeName // ""' <<<"$c") || return 1; cph=$(jq -r '.status.phase // ""' <<<"$c") || return 1
    { [ "$cv" = "$pv" ] && [ "$cph" = Bound ]; } || { echo "REFUSE: claim $cn/$APP is [$cph] on [$cv], not Bound to $pv" >&2; return 1; }
  fi
  pv_patch "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"'"$pol"'"}}'
  kubectl get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
}
# pv_repoint <pv> <ns>: reserve the PV for <ns>/hermes (uid/resourceVersion null) — NEVER remove claimRef (any matching claim would take it).
pv_repoint() {
  local pv=$1 ns=${2:-}
  case "$ns" in develop|ai) ;; *) echo "REFUSE: repoint target ns [$ns]" >&2; return 1;; esac
  pv_patch "$pv" --type merge -p '{"spec":{"claimRef":{"namespace":"'"$ns"'","name":"'"$APP"'","uid":null,"resourceVersion":null}}}'
}
# app_pv: the PV named by the hermes PVC's spec.volumeName, RE-READ from the live PVC on EVERY call — never from a cached file [Rh-B2].
# Refuses if the develop and ai claims name different PVs, or if the name is not $HERMES_PV (a re-provisioned claim = STOP and ask).
app_pv() {
  local ns pv="" v=""
  for ns in "$OLD" "$NEW"; do
    v=$(kubectl -n "$ns" get pvc "$APP" -o json 2>/dev/null | jq -r '.spec.volumeName // ""' || true)
    [ -n "$v" ] || continue
    if [ -n "$pv" ] && [ "$v" != "$pv" ]; then echo "REFUSE: $APP claims in $OLD/$NEW name different PVs ($pv vs $v)" >&2; return 1; fi
    pv=$v
  done
  [ -n "$pv" ] || { echo "no PVC $APP with a volumeName in $OLD or $NEW right now (there is deliberately NO cached fallback)" >&2; return 1; }
  [ "$pv" = "$HERMES_PV" ] || { echo "REFUSE: the live PVC names [$pv], not $HERMES_PV — the claim was re-provisioned; STOP" >&2; return 1; }
  pv_ok "$pv" >/dev/null || return 1
  echo "$pv"
}

# --- assertions ------------------------------------------------------------------------------------------------
# inventory_ok <ns>: the hermes Kustomization in <ns> must have a NON-EMPTY inventory whose every entry is in <ns>. Fails closed on null.
inventory_ok() {
  local ns=${1:-}
  case "$ns" in develop|ai) ;; *) echo "REFUSE ns=[$ns]" >&2; return 1;; esac
  if kubectl -n "$ns" get kustomization.kustomize.toolkit.fluxcd.io "$APP" -o json | jq -e --arg p "${ns}_" '
    [ .status.inventory.entries[]?.id ] as $ids | ($ids | length) > 0 and ($ids | all(startswith($p)))' >/dev/null; then
    echo "inventory ok ($ns)"
  else
    echo "INVENTORY CHECK FAILED ($ns: empty, null, or contains an object outside $ns)" >&2; return 1
  fi
}
# others_ready: every Kustomization except hermes in develop/ai must be Ready. A reconcile starts by marking Ready=Unknown and a merge fires the
# Receiver (reconciles cluster-apps), so one "not True" is noise: fail at once on Ready=False, otherwise require not-True on 3 polls 20s apart.
others_ready() {
  local i bad falsy sel='select((.metadata.name=="hermes" and (.metadata.namespace=="develop" or .metadata.namespace=="ai"))|not)'
  for i in 1 2 3; do
    falsy=$(kubectl get ks -A -o json | jq -r ".items[]|$sel|select(((.status.conditions // [])|map(select(.type==\"Ready\"))|.[0].status // \"Unknown\")==\"False\")|\"\(.metadata.namespace)/\(.metadata.name)\"") || return 1
    [ -z "$falsy" ] || { echo "READY=False: $falsy" >&2; return 1; }
    bad=$(kubectl get ks -A -o json | jq -r ".items[]|$sel|select(((.status.conditions // [])|map(select(.type==\"Ready\"))|.[0].status // \"Unknown\")!=\"True\")|\"\(.metadata.namespace)/\(.metadata.name)\"") || return 1
    [ -z "$bad" ] && { echo "all other ks Ready"; return 0; }
    echo "poll $i/3: not yet Ready: $bad" >&2; [ "$i" -lt 3 ] && sleep 20
  done
  echo "NOT READY after 3 polls: $bad" >&2; return 1
}
# no_sync_in_flight <ns>: BOTH hermes RS must have an EMPTY status.lastSyncStartTime (trap 8, [Rh-12]). Fails closed on a read error.
no_sync_in_flight() {
  local ns=${1:-} rs st rc=0
  case "$ns" in develop|ai) ;; *) echo "REFUSE ns=[$ns]" >&2; return 1;; esac
  for rs in "$APP-local" "$APP-r2"; do
    if ! st=$(kn "$ns" get replicationsource.volsync.backube "$rs" -o json | jq -r '.status.lastSyncStartTime // ""'); then echo "cannot read $ns/$rs" >&2; return 1; fi
    if [ -n "$st" ]; then echo "$ns/$rs SYNC IN FLIGHT (lastSyncStartTime=$st)" >&2; rc=1; else echo "$ns/$rs idle"; fi
  done
  return $rc
}
# pending_claims: every Pending PVC cluster-wide (the --field-selector form is rejected by the API server [Rh-F]). Expect only the moving claim.
pending_claims() {
  kubectl get pvc -A -o json | jq -r '.items[]|select(.status.phase=="Pending")|"\(.metadata.namespace)/\(.metadata.name) sc=\(.spec.storageClassName)"'
}
# one_route: `kubectl get httproute -A | grep hermes` must be exactly ONE line, in the namespace given (trap 13, oldest route wins).
one_route() {
  local want=${1:-} out n
  case "$want" in develop|ai) ;; *) echo "REFUSE ns=[$want]" >&2; return 1;; esac
  out=$(kubectl get httproute -A --no-headers | awk '$2=="hermes"{print $1}') || return 1
  n=$(printf '%s\n' "$out" | grep -c . || true)
  echo "hermes routes: $n in [$(echo "$out" | tr '\n' ' ')]"
  [ "$n" -eq 1 ] && [ "$out" = "$want" ]
}
# check_backup <ns> <replicationsource> <identity> [T0]: the R-3 acceptance rule (the log is a truncated TAIL: never test for 'Creating snapshot for').
# With T0 (an RFC3339 UTC time taken AFTER the pod was gone) it also requires lastSyncTime > T0. Returns nonzero if any check fails.
check_backup() {
  local L J c s o e lst rc=0 t0=${4:-}
  J=$(kn "$1" get replicationsource.volsync.backube "$2" -o json) || return 1
  L=$(jq -r '.status.latestMoverStatus.logs // ""' <<<"$J"); lst=$(jq -r '.status.lastSyncTime // ""' <<<"$J")
  c=$(grep -c 'Created snapshot with root' <<<"$L" || true); s=$(grep -cF "Setting policy for $3:/data" <<<"$L" || true)
  o=$(grep -cF 'OPERATION_RESULT: SUCCESS' <<<"$L" || true); e=$(grep -c 'Directory is empty' <<<"$L" || true)
  echo "Created snapshot: $c (>=1)  Setting policy $3: $s (>=1)  RESULT SUCCESS: $o (>=1)  Directory is empty: $e (0)  lastSyncTime=$lst"
  [ "$c" -ge 1 ] && [ "$s" -ge 1 ] && [ "$o" -ge 1 ] && [ "$e" -eq 0 ] || { echo "check_backup FAILED for $1/$2" >&2; rc=1; }
  if [ -n "$t0" ]; then [[ "$lst" > "$t0" ]] || { echo "check_backup STALE: lastSyncTime [$lst] <= T0 [$t0]" >&2; rc=1; }; fi
  return $rc
}
# data_baseline_ok <file>: the baseline must reflect hermes' REAL layout (read live 2026-09-24): these files must exist and be NON-EMPTY — .env auth.json
# config.yaml SOUL.md state.db — and the dirs home/ and skills/ must hold files. All counts are reported. memories/ is NOT required (it is empty on the real
# volume: the sessions live in state.db) and sessions/ is not required to be large (2 files).
data_baseline_ok() {
  local f=${1:-} n esc line ok=1 d c empty=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  [ -s "$f" ] || { echo "REFUSE: baseline [$f] missing or empty" >&2; return 1; }
  for n in .env auth.json config.yaml SOUL.md state.db; do
    esc=${n//./\\.}
    line=$(grep -E "^[0-9a-f]{64}  \./${esc}\$" "$f" | head -1 || true)
    if [ -z "$line" ]; then echo "baseline LACKS $n"; ok=0
    elif [ "${line%% *}" = "$empty" ]; then echo "baseline has $n but it is EMPTY"; ok=0
    else echo "baseline has $n"; fi
  done
  for d in home skills cache sessions memories cron; do
    c=$(awk -v d="$d" 'f && $1==d{print $2} /^---COUNTS/{f=1}' "$f")
    echo "count $d=[${c:-?}]"
    case "$d" in home|skills) [ "${c:-0}" -gt 0 ] || { echo "baseline $d/ has no files"; ok=0; } ;; esac
  done
  [ "$ok" -eq 1 ]
}
# data_check <ns> <outfile> [pvc] [tries=80]: read-only content listing of a PVC in <ns> (default: the hermes app PVC; pass volsync-hermes-dst-local-dest for the
# drill) as UID 0. DAC_OVERRIDE is added because drop:[ALL] would otherwise strip root's read override on the mode-600 files (.env auth.json state.db) —
# VERIFIED live 2026-09-24: this reader read all 29,229 files, no error, ~12 s. It is a MUTATING helper (creates a Job), so:
#   * it requires HM_WINDOW=yes in the environment (set only inside the window steps W-4, W-12, W-15);
#   * it REFUSES unless the target PVC exists and is Bound (a Pending consumer would become a second consumer of the claim when it binds; nothing is applied);
#   * the wait is bounded to <=80 x 5 s (< the 600 s tool limit) and a trap installed right after the apply deletes the Job (--cascade=foreground --wait=false)
#     on EXIT INT TERM, so a killed or timed-out call cannot orphan it (an orphaned Completed/Pending pod holds pvc-protection = trap 3);
#   * after the normal delete it REQUIRES the pod (label job-name=<job>) to be gone.
# If ANY pod in <ns> mounts the PVC the Job is pinned to ITS node (RWO Multi-Attach otherwise).
# Output = names + hashes + counts only. First line of the saved file is a header:  # <job> <ns> <pvc> <utc>  (data_compare uses it). Saved only on success.
data_check() {
  local ns=${1:-} out=${2:-} pvc=${3:-$APP} tries=${4:-80} j node pin="" st="" i tmp left="" phase
  [ "${HM_WINDOW:-}" = "yes" ] || { echo "REFUSE: data_check creates a Job and only runs inside the window (HM_WINDOW=yes)" >&2; return 1; }
  [ -n "$out" ] || { echo 'usage: data_check <ns> <outfile> [pvc] [tries]' >&2; return 1; }
  case "$ns" in develop|ai) ;; *) echo "REFUSE ns=[$ns]" >&2; return 1;; esac
  case "$pvc" in hermes|volsync-hermes-dst-local-dest) ;; *) echo "REFUSE: pvc [$pvc] is not a hermes claim" >&2; return 1;; esac
  case "$tries" in ''|*[!0-9]*) echo "REFUSE: tries [$tries]" >&2; return 1;; esac
  [ "$tries" -ge 1 ] && [ "$tries" -le 80 ] || { echo "REFUSE: tries must be 1..80 (80 x 5 s stays under the 600 s tool limit)" >&2; return 1; }
  if ! phase=$(kn "$ns" get pvc "$pvc" -o json 2>/dev/null | jq -r '.status.phase // ""'); then phase=""; fi
  [ "$phase" = "Bound" ] || { echo "REFUSE: PVC $ns/$pvc is [${phase:-absent}], not Bound — no Job created" >&2; return 1; }
  j="hchk-$(date +%s)"; tmp="$MOVE_DIR/$j.out"
  node=$(kn "$ns" get pod -o json | jq -r --arg c "$pvc" '[.items[]|select(.spec.volumes[]?.persistentVolumeClaim.claimName==$c)|.spec.nodeName][0] // ""') || return 1
  [ -n "$node" ] && pin="nodeName: $node"
  kn "$ns" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: $j, labels: {hermes-move: helper}}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      $pin
      containers:
        - name: r
          image: busybox:1.37
          securityContext: {runAsUser: 0, allowPrivilegeEscalation: false, capabilities: {drop: [ALL], add: [DAC_OVERRIDE]}}
          command: [sh, -c, "cd /data && find . -type f -print0 | sort -z | xargs -0 sha256sum && echo ---COUNTS && for d in home skills cache sessions memories cron; do echo \$d \$(find \$d -type f 2>/dev/null | wc -l); done"]
          volumeMounts: [{name: d, mountPath: /data, readOnly: true}]
      volumes: [{name: d, persistentVolumeClaim: {claimName: $pvc, readOnly: true}}]
EOF
  # from here the Job exists: whatever ends this call (timeout, INT, TERM, error), it is deleted
  # shellcheck disable=SC2064
  trap "kubectl -n '$ns' delete job '$j' --cascade=foreground --wait=false >/dev/null 2>&1 || true" EXIT INT TERM
  for i in $(seq 1 "$tries"); do
    st=$(kn "$ns" get job "$j" -o json | jq -r 'if (.status.succeeded // 0) > 0 then "ok" elif (.status.failed // 0) > 0 then "failed" else "" end') || break
    [ -n "$st" ] && break; sleep 5
  done
  echo "--- data_check $ns/$pvc: job=$j pin=[$node] result=[${st:-TIMEOUT}] ---"
  kn "$ns" logs "job/$j" > "$tmp" 2>&1 || true
  wc -l < "$tmp" | sed 's/^ */lines: /'; grep -A8 -- '---COUNTS' "$tmp" || tail -5 "$tmp"
  kn "$ns" describe pod -l job-name="$j" 2>&1 | grep -E "Warning" -A3 | head -12 || true
  kn "$ns" delete job "$j" --cascade=foreground --wait=true --timeout=60s >/dev/null 2>&1 || true
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    left=$(kn "$ns" get pods -l job-name="$j" -o name 2>/dev/null || true); [ -z "$left" ] && break; sleep 5
  done
  trap - EXIT INT TERM
  [ -z "$left" ] || { echo "HELPER POD STILL PRESENT ($left) — delete it before any PVC delete (trap 3)" >&2; return 1; }
  if [ "$st" = "ok" ]; then { echo "# $j $ns $pvc $(date -u +%FT%TZ)"; cat "$tmp"; } > "$out"; rm -f "$tmp"; echo "saved $out"; return 0; fi
  return 1
}
# data_compare [--ignore-sqlite] <baseline> <after> [baseline-ns=develop]: EVERYTHING must match, state.db* included. Between B2 (W-4) and B7 (W-12) nothing
# runs against the volume (pod at 0, movers read a snapshot clone), so the SQLite files are static and are the file most likely to hold the sessions.
# --ignore-sqlite exists only for a comparison ACROSS A POD START; this plan never uses it. The baseline must carry a header from <baseline-ns>, hermes PVC,
# and be NOT older than $MOVE_DIR/T-quiesced.txt (a leftover file from an aborted window is refused); <after> must be no older than the baseline.
data_compare() {
  local ign=0 a b ens h ns pvc ut q ah aut d
  if [ "${1:-}" = "--ignore-sqlite" ]; then ign=1; shift; fi
  a=${1:-}; b=${2:-}; ens=${3:-develop}
  { [ -s "$a" ] && [ -s "$b" ]; } || { echo "REFUSE: baseline/after missing or empty" >&2; return 1; }
  h=$(head -1 "$a"); case "$h" in "# "*) ;; *) echo "REFUSE: baseline has no header line" >&2; return 1;; esac
  ns=$(awk '{print $3}' <<<"$h"); pvc=$(awk '{print $4}' <<<"$h"); ut=$(awk '{print $5}' <<<"$h")
  [ "$ns" = "$ens" ] || { echo "REFUSE: baseline is from ns [$ns], expected [$ens]" >&2; return 1; }
  [ "$pvc" = "$APP" ] || { echo "REFUSE: baseline is from pvc [$pvc], expected [$APP]" >&2; return 1; }
  [ -s "$MOVE_DIR/T-quiesced.txt" ] || { echo "REFUSE: $MOVE_DIR/T-quiesced.txt missing (written at W-3)" >&2; return 1; }
  q=$(head -1 "$MOVE_DIR/T-quiesced.txt")
  { [[ "$ut" > "$q" ]] || [[ "$ut" == "$q" ]]; } || { echo "REFUSE: baseline ($ut) is OLDER than the quiesce ($q) — stale file from another window" >&2; return 1; }
  ah=$(head -1 "$b"); case "$ah" in "# "*) ;; *) echo "REFUSE: after has no header line" >&2; return 1;; esac
  aut=$(awk '{print $5}' <<<"$ah")
  { [[ "$aut" > "$ut" ]] || [[ "$aut" == "$ut" ]]; } || { echo "REFUSE: after ($aut) is OLDER than the baseline ($ut)" >&2; return 1; }
  data_baseline_ok "$a" >/dev/null || { echo "baseline not acceptable" >&2; return 1; }
  if [ "$ign" -eq 1 ]; then
    d=$(diff <(grep -v '^#' "$a" | grep -v -E '  \./state\.db') <(grep -v '^#' "$b" | grep -v -E '  \./state\.db') || true)
  else
    d=$(diff <(grep -v '^#' "$a") <(grep -v '^#' "$b") || true)
  fi
  if [ -z "$d" ]; then if [ "$ign" -eq 1 ]; then echo "content identical (state.db* IGNORED)"; else echo "content identical (state.db* included)"; fi; return 0; fi
  echo "$d" | head -20; echo "CONTENT DIFFERS" >&2; return 1
}
# drill_snapshot_ok: trap 14a. The Longhorn snapshot BEHIND the ai RD's latestImage must EXIST and be readyToUse (VolumeSnapshot.readyToUse is not proof).
drill_snapshot_ok() {
  local vs vsc h snap ready
  vs=$(kn "$NEW" get replicationdestination.volsync.backube "$APP-dst-local" -o json | jq -r '.status.latestImage.name // ""') || return 1
  [ -n "$vs" ] || { echo "RD has no latestImage yet" >&2; return 1; }
  vsc=$(kn "$NEW" get volumesnapshot "$vs" -o json | jq -r '.status.boundVolumeSnapshotContentName // ""') || return 1
  h=$(kubectl get volumesnapshotcontent "$vsc" -o json | jq -r '.status.snapshotHandle // ""') || return 1
  snap=${h##*/}; echo "latestImage=$vs content=$vsc handle=$h"
  case "$snap" in snapshot-*) ;; *) echo "unexpected handle [$h]" >&2; return 1;; esac
  ready=$(kubectl -n longhorn-system get snapshots.longhorn.io "$snap" -o json | jq -r '.status.readyToUse // false') || { echo "Longhorn snapshot $snap NOT FOUND — the drill result is void" >&2; return 1; }
  echo "longhorn snapshot $snap readyToUse=$ready"; [ "$ready" = "true" ]
}

# --- pull requests: literal numbers only, head pinned ---------------------------------------------------------------------
# Never run a bare `gh pr merge`: with no number it merges the PR of the current branch. Use pr_merge.
# pr_mergeable <n> <sha> [tries=12]: OPEN, MERGEABLE, head == <sha>; retries UNKNOWN (GitHub recomputes asynchronously, e.g. PR 2 right after PR 1 merged).
pr_mergeable() {
  local n=${1:-} sha=${2:-} tries=${3:-12} i j m o st
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "REFUSE: PR number [$n] must be a literal number" >&2; return 1; }
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "REFUSE: [$sha] is not a full 40-hex SHA" >&2; return 1; }
  for i in $(seq 1 "$tries"); do
    j=$(gh pr view "$n" -R "$GH_REPO" --json state,mergeable,headRefOid) || return 1
    st=$(jq -r '.state' <<<"$j"); m=$(jq -r '.mergeable' <<<"$j"); o=$(jq -r '.headRefOid' <<<"$j")
    [ "$o" = "$sha" ] || { echo "PR #$n head is [$o], expected $sha" >&2; return 1; }
    [ "$st" = OPEN ] || { echo "PR #$n is $st" >&2; return 1; }
    if [ "$m" = UNKNOWN ]; then echo "PR #$n mergeable=UNKNOWN (attempt $i/$tries)"; sleep 5; continue; fi
    if [ "$m" = MERGEABLE ]; then echo "PR #$n OPEN MERGEABLE $o"; return 0; fi
    echo "PR #$n mergeable=[$m]" >&2; return 1
  done
  echo "PR #$n still UNKNOWN after $tries tries" >&2; return 1
}
# drift_check: nothing that the move touches or depends on may have changed on origin/main since the commits were built (BASE_SHA).
drift_check() {
  local out
  git -C "$R" fetch -q origin main || { echo "REFUSE: git fetch failed" >&2; return 1; }
  # Only what can change how the (minimal) move renders or textually collide with it. Comment-only follow-ups (hindsight, ev-charge-tracker, kopiur,
  # kopiur-migration.md, ai/namespace.yaml) are NOT in commit 1 and are deliberately not watched.
  out=$(git -C "$R" diff --stat "$BASE_SHA" origin/main -- kubernetes/apps/develop/hermes kubernetes/apps/develop/kustomization.yaml kubernetes/apps/ai/hermes \
        kubernetes/apps/ai/kustomization.yaml kubernetes/components/volsync-claim kubernetes/components/volsync-backup kubernetes/components/kopiur \
        kubernetes/components/common kubernetes/flux/cluster/ks.yaml kubernetes/apps/volsync-system) || return 1
  if [ -n "$out" ]; then echo "DRIFT since $BASE_SHA:" >&2; echo "$out" >&2; return 1; fi
  echo "no drift on origin/main in the paths the move touches"
}
# w0b <pr1> <pr2>: the pre-quiesce check (BEFORE hermes goes down): no drift, both PRs OPEN + MERGEABLE with the expected heads.
w0b() { drift_check && pr_mergeable "${1:-}" "$PR1_SHA" 12 && pr_mergeable "${2:-}" "$PR2_SHA" 12; }
# pr_merge <n> <sha>: the ONLY merge path. Number must be a literal integer; sha the full head; the PR must be base main, head branch hermes-move-pr1/pr2
# with the SHA that branch is pinned to; PR 2 additionally requires PR 1 to be MERGED. Marks a draft ready, then merges with a merge commit, head pinned.
pr_merge() {
  local n=${1:-} sha=${2:-} j ref base st draft oid want merged
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "REFUSE: PR number [$n] must be a literal number" >&2; return 1; }
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "REFUSE: [$sha] is not a full 40-hex SHA" >&2; return 1; }
  j=$(gh pr view "$n" -R "$GH_REPO" --json state,isDraft,headRefName,headRefOid,baseRefName) || return 1
  ref=$(jq -r '.headRefName' <<<"$j"); base=$(jq -r '.baseRefName' <<<"$j"); st=$(jq -r '.state' <<<"$j"); draft=$(jq -r '.isDraft' <<<"$j"); oid=$(jq -r '.headRefOid' <<<"$j")
  [ "$base" = main ] || { echo "REFUSE: PR #$n base is [$base]" >&2; return 1; }
  [ "$st" = OPEN ] || { echo "REFUSE: PR #$n is $st" >&2; return 1; }
  case "$ref" in hermes-move-pr1) want=$PR1_SHA;; hermes-move-pr2) want=$PR2_SHA;; *) echo "REFUSE: PR #$n head branch [$ref] is not a hermes move branch" >&2; return 1;; esac
  { [ "$oid" = "$sha" ] && [ "$sha" = "$want" ]; } || { echo "REFUSE: head [$oid] / given [$sha] / pinned [$want] disagree" >&2; return 1; }
  if [ "$ref" = hermes-move-pr2 ]; then
    merged=$(gh pr list -R "$GH_REPO" --head hermes-move-pr1 --state merged --json number --jq length) || return 1
    [ "$merged" = 1 ] || { echo "REFUSE: PR 1 (hermes-move-pr1) is not merged yet — PR 2 must never go first" >&2; return 1; }
  fi
  if [ "$draft" = true ]; then gh pr ready "$n" -R "$GH_REPO" || return 1; fi
  gh pr merge "$n" -R "$GH_REPO" --merge --match-head-commit "$sha"
}

# --- pre-merge gate ---------------------------------------------------------------------------------------------
# move_gate <ns> <want> [replicas]: run AFTER COMMIT (lefthook/yamlfmt may have rewritten files) and BEFORE opening/merging a PR. Requires ALL of:
#   1. the kubernetes tree in $R is committed (covers both namespace kustomization.yaml files);
#   2. the app build has exactly <want> lines matching volumeName|sourceNamespace (2 = commit 1 / commit 2 into ai; 1 = rollback into develop);
#   3. EVERY metadata.namespace in the app build equals <ns>;
#   4. the PARENT build (cluster-apps, literally the runbook command) has exactly ONE child Kustomization named hermes, equal to
#      "<ns> hermes ./kubernetes/apps/<ns>/hermes/app <ns>";
#   5. optional [replicas] = zero | absent : the HelmRelease's controllers.hermes.replicas is 0 (commit 1) / not set (commit 2).
move_gate() {
  local ns=${1:-} want=${2:-} rep=${3:-} built out n nss parent expect r ok=0
  case "$ns" in develop|ai) ;; *) echo "GATE: bad namespace [$ns]" >&2; return 1;; esac
  case "$want" in 0|1|2) ;; *) echo "GATE: want must be 0, 1 or 2" >&2; return 1;; esac
  case "$rep" in ""|zero|absent) ;; *) echo "GATE: replicas must be zero|absent" >&2; return 1;; esac
  if [ -n "$(GIT status --porcelain -- kubernetes)" ]; then echo "GATE FAIL: uncommitted changes under kubernetes — COMMIT first (the gate checks COMMITTED files)" >&2; return 1; fi
  if ! built=$(cd "$R" && flux build ks "$APP" -n "$ns" --path "./kubernetes/apps/$ns/$APP/app" \
        --kustomization-file "./kubernetes/apps/$ns/$APP/ks.yaml" --dry-run); then echo "GATE FAIL: app build failed" >&2; return 1; fi
  out=$(grep -n -E "volumeName|sourceNamespace" <<<"$built" || true); echo "$out"
  n=$(printf '%s\n' "$out" | grep -c . || true)
  [ "$n" -eq "$want" ] || { echo "GATE FAIL: $n volumeName/sourceNamespace lines, want $want" >&2; ok=1; }
  nss=$(yq -N 'select(.kind)|.metadata.namespace // "NONE"' <<<"$built" | sort -u)
  [ "$nss" = "$ns" ] || { echo "GATE FAIL: namespaces in the app build = [$(echo "$nss" | tr '\n' ' ')], want only [$ns]" >&2; ok=1; }
  if [ -n "$rep" ]; then
    r=$(yq -N 'select(.kind=="HelmRelease")|.spec.values.controllers.hermes.replicas // "absent"' <<<"$built")
    case "$rep" in zero) [ "$r" = "0" ] || { echo "GATE FAIL: replicas=[$r], want 0" >&2; ok=1; } ;;
                   absent) [ "$r" = "absent" ] || { echo "GATE FAIL: replicas=[$r], want unset" >&2; ok=1; } ;; esac
    echo "replicas: $r"
  fi
  if ! parent=$(cd "$R" && flux build ks cluster-apps -n flux-system --path ./kubernetes/apps \
        --kustomization-file ./kubernetes/flux/cluster/ks.yaml --dry-run \
        | yq -N 'select(.kind=="Kustomization")|[.metadata.namespace,.metadata.name,.spec.path,.spec.targetNamespace]|join(" ")'); then
    echo "GATE FAIL: parent build failed" >&2; return 1; fi
  echo "parent children: $(grep -c . <<<"$parent" || true)"; grep -F " $APP " <<<"$parent" || true
  expect="$ns $APP ./kubernetes/apps/$ns/$APP/app $ns"
  [ "$(grep -c -F " $APP " <<<"$parent" || true)" -eq 1 ] || { echo "GATE FAIL: need exactly ONE child Kustomization named $APP" >&2; ok=1; }
  grep -qxF "$expect" <<<"$parent" || { echo "GATE FAIL: parent child != [$expect]" >&2; ok=1; }
  [ "$ok" -eq 0 ] && { echo "GATE PASS"; return 0; }
  echo "GATE FAIL — DO NOT MERGE" >&2; return 1
}

# --- bounded waits (every loop is bounded; a tool call dies at 600s) -------------------------------------------------
# wait_manual <ns> <rs> <tag> [tries=40]: wait (10s steps) until status.lastManualSync == <tag>. Returns 1 on timeout. (Necessary, NOT sufficient: trap 8.)
# Loop audit (every loop in this file is bounded below the 600 s tool limit): wait_manual <=40 x 10 s = 400 s (refused above 50); wait_pv_phase <=100 x 3 s = 300 s;
# wait_running <=110 x 5 s = 550 s; data_check <=80 x 5 s + 60 s pod check; pr_mergeable <=12 x 5 s (w0b: two of them = 120 s); others_ready 3 x 20 s.
wait_manual() {
  local ns=$1 rs=$2 tag=$3 tries=${4:-40} i cur=""
  case "$tries" in ''|*[!0-9]*) echo "REFUSE: tries [$tries]" >&2; return 1;; esac
  [ "$tries" -le 50 ] || { echo "REFUSE: wait_manual tries $tries x 10 s exceeds the 600 s tool limit" >&2; return 1; }
  for i in $(seq 1 "$tries"); do
    cur=$(kn "$ns" get replicationsource.volsync.backube "$rs" -o json | jq -r '.status.lastManualSync // ""') || return 1
    [ "$cur" = "$tag" ] && { echo "$rs lastManualSync=$tag"; return 0; }
    sleep 10
  done
  echo "TIMEOUT: $ns/$rs lastManualSync=[$cur] != $tag" >&2; return 1
}
# wait_pv_phase <pv> <phase> [tries=100]: wait (3s steps) for the hermes PV's phase; bounded.
wait_pv_phase() {
  local pv=$1 want=$2 tries=${3:-100} i cur=""
  case "$tries" in ''|*[!0-9]*) echo "REFUSE: tries [$tries]" >&2; return 1;; esac
  [ "$tries" -le 150 ] || { echo "REFUSE: wait_pv_phase tries $tries x 3 s exceeds the tool limit" >&2; return 1; }
  pv_ok "$pv" >/dev/null || return 1
  for i in $(seq 1 "$tries"); do
    cur=$(kubectl get pv "$pv" -o json | jq -r '.status.phase // ""') || return 1
    [ "$cur" = "$want" ] && { echo "$pv $want"; return 0; }
    sleep 3
  done
  echo "TIMEOUT: $pv phase=[$cur] != $want" >&2; return 1
}
# wait_running <ns> [tries=100]: wait (5s steps) for the hermes pod to be Running+Ready. <=110 iterations (5 s each + the kubectl call < 600 s).
wait_running() {
  local ns=$1 tries=${2:-100} i r
  case "$tries" in ''|*[!0-9]*) echo "REFUSE: tries [$tries]" >&2; return 1;; esac
  [ "$tries" -le 110 ] || { echo "REFUSE: wait_running tries $tries x 5 s exceeds the 600 s tool limit (max 110)" >&2; return 1; }
  for i in $(seq 1 "$tries"); do
    r=$(kn "$ns" get pod -l app.kubernetes.io/name="$APP" -o json | jq -r '[.items[]|select(.status.phase=="Running" and ((.status.containerStatuses // [])|all(.ready)))]|length') || return 1
    [ "$r" -ge 1 ] && { echo "$APP Running in $ns"; return 0; }
    sleep 5
  done
  echo "TIMEOUT: no Running $APP pod in $ns" >&2; return 1
}
# background watchers: PIDs recorded so they can be killed
watch_start() { local name=$1; shift; "$@" > "$MOVE_DIR/$name.log" 2>&1 & echo $! > "$MOVE_DIR/watch-$name.pid"; echo "watching $name (pid $(cat "$MOVE_DIR/watch-$name.pid")) -> $MOVE_DIR/$name.log"; }
watch_stop_all() { local f; for f in "$MOVE_DIR"/watch-*.pid; do [ -f "$f" ] || continue; kill "$(cat "$f")" 2>/dev/null || true; rm -f "$f"; done; echo "watchers stopped"; }

# --- Alertmanager silences (CREATE ONLY WITH THE HUMAN'S GO-AHEAD; scoped to hermes; auto-expire) ---------------------------------
# Refuses to run unless SILENCE_OK=yes is in the environment — the human's go-ahead, given per window.
# Matchers (Alertmanager fully anchors regexes; label names: VolSync series carry obj_namespace/obj_name, pods carry namespace/pod, Flux's provider
# labels carry namespace/name/kind/reason — notification-controller alertmanager provider, verified on the rehearsal):
#   1. obj_namespace=~develop|ai  AND obj_name=~hermes-.*                      (VolSyncVolumeOutOfSync on hermes-local / hermes-r2)
#   2. namespace=~develop|ai      AND name=~hermes.*                           (Flux error events for the hermes Kustomization/HelmRelease/OCIRepository)
#   3. namespace=~develop|ai      AND pod=~(volsync-(src|dst)-)?hermes.*       (VolSyncMoverStuck, pod-level kube-prometheus alerts)
am_open()  {
  kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager "$AM_PORT":9093 >/dev/null 2>&1 &
  echo $! > "$MOVE_DIR/am-pf.pid"; trap am_close EXIT; sleep 3
}
am_close() { if [ -f "$MOVE_DIR/am-pf.pid" ]; then kill "$(cat "$MOVE_DIR/am-pf.pid")" 2>/dev/null || true; rm -f "$MOVE_DIR/am-pf.pid"; fi; }
# am_post <label1> <regex1> <label2> <regex2>: one silence with two anchored regex matchers; the id is recorded for am_unsilence.
am_post() {
  local body id start=$1 end=$2
  body=$(jq -n --arg n1 "$3" --arg v1 "$4" --arg n2 "$5" --arg v2 "$6" --arg s "$start" --arg e "$end" \
    '{matchers:[{name:$n1,value:$v1,isRegex:true,isEqual:true},{name:$n2,value:$v2,isRegex:true,isEqual:true}],startsAt:$s,endsAt:$e,createdBy:"hermes-move",comment:"hermes develop->ai move (auto-expires; removed by am_unsilence)"}')
  id=$(curl -fsS --retry 5 --retry-delay 1 --retry-connrefused -X POST -H 'Content-Type: application/json' -d "$body" "http://127.0.0.1:$AM_PORT/api/v2/silences" | jq -r '.silenceID')
  echo "$id" >> "$MOVE_SILENCES"; echo "silence $id  $3=~$4 & $5=~$6"
}
am_silence() {
  local start end
  [ "${SILENCE_OK:-}" = "yes" ] || { echo "REFUSE: silences need the human's go-ahead (SILENCE_OK=yes)" >&2; return 1; }
  start=$(date -u +%FT%TZ); end=$(date -u -v+"${AM_HOURS:-3}"H +%FT%TZ 2>/dev/null || date -u -d "+${AM_HOURS:-3} hours" +%FT%TZ)
  am_open
  am_post "$start" "$end" obj_namespace 'develop|ai' obj_name 'hermes-.*'
  am_post "$start" "$end" namespace 'develop|ai' name 'hermes.*'
  am_post "$start" "$end" namespace 'develop|ai' pod '(volsync-(src|dst)-)?hermes.*'
  am_close
}
am_unsilence() {
  local id; am_open
  while read -r id; do
    [ -n "$id" ] || continue
    curl -fsS --retry 5 --retry-delay 1 --retry-connrefused -X DELETE "http://127.0.0.1:$AM_PORT/api/v2/silence/$id" && echo "expired $id"
  done < "$MOVE_SILENCES"
  : > "$MOVE_SILENCES"; am_close
}
