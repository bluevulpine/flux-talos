#!/bin/bash
# move-guards.sh — guards + helpers for moving ONE VolSync+Longhorn app between two namespaces (docs/runbooks/volsync-app-namespace-move.md).
# Generalised from the hermes move's hermes-move-guards.sh. Nothing app-specific is hard-coded: every per-move value comes from ONE config file.
#
# USE:   MOVE_CONF=/abs/path/move.conf /bin/bash -c 'source .../move-guards.sh; <steps>'    (or: MOVE_CONF=... hm '<guard call>')
# Keep move.conf OUTSIDE every repo (it holds the live PV name and the PR SHAs). See move.conf.example for every key.
# Written for bash 3.2 (/bin/bash on macOS): no mapfile, no associative arrays, no ${x,,}.
#
# SAFETY PROPERTIES (each is unit-tested in test/run.sh):
#   * Safety-critical values (APP OLD NEW PV PR1 PR2 PR*_SHA BASE_SHA STATE_DIR WORKTREE CLUSTER_UID ...) are read ONLY from $MOVE_CONF. They are
#     unset first, so an inherited APP=other / STATE_DIR=/tmp/evil cannot redirect a guard, then validated and made readonly.
#   * There is NO push function. The move goes through two pull requests merged with pr_merge. Nothing here pushes.
#   * kn is the vendored shared allow-list guard (kn-guard.sh, unchanged): namespaces $OLD/$NEW only, verb + kind + flag allow-lists (no secrets, no cluster-scoped
#     kinds, no combined/attached short flags, no -A/--context/--server/…). There is NO generic PV patcher: a PV is written only in record_pv / pv_reclaim / pv_repoint, with payloads built in code;
#     each re-runs pv_ok ($PV, labelled ${APP}-move=1, claimRef $OLD|$NEW/$APP, never empty) and re-verifies the cluster UID. Any API error is a REFUSAL (fail closed).
#     `hm`/`eval` can still run raw kubectl: these guards are not a sandbox.
#   * pv_reclaim Delete needs the PV Bound AND its claim Bound to it, and — once $STATE_DIR/SINCE.txt exists (W-9) — B10_OK=yes (the human's go-ahead).
#   * pr_merge: literal PR number equal to the configured one, full 40-hex SHA equal to the pinned one, head branch ${APP}-move-pr1|pr2, base main, PR 2 only after PR 1.
#   * data_check creates a Job, so it needs HM_WINDOW=yes, a Bound claim, a bounded wait, and a trap that deletes the Job. HM_FAKE interlock: see below.
set -euo pipefail
# N10: aliases (e.g. BASH_ENV with `alias jq=...`) would shadow commands inside every guard body, and `unset -f` does not touch them.
unalias -a 2>/dev/null || true; shopt -u expand_aliases
# m4: exported shell functions (BASH_FUNC_x%%) would shadow jq/kubectl/gh/git INSIDE the guards and defeat every check. Drop every function that came in
# from the environment before this file defines its own. (PATH itself is still trusted: see README "Safety model".)
for _f in $(compgen -A function); do unset -f "$_f"; done

# --- location: the directory THIS FILE lives in (never a caller export) -------------------------------------------------------------
GUARDS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- test-mode interlock: the harness exports HM_FAKE=1 and puts $GUARDS_DIR/test/bin first on PATH. If a nested `zsh -c` (re-reads ~/.zshenv)
# or a reset PATH puts the REAL kubectl/gh ahead of the fakes, refuse BEFORE any command reaches the cluster or GitHub. (A reviewer once hit the live cluster this way.)
if [ "${HM_FAKE:-}" = 1 ]; then
  for _t in kubectl gh; do
    [ "$(command -v "$_t" 2>/dev/null)" = "$GUARDS_DIR/test/bin/$_t" ] || { echo "HM_FAKE=1 but $_t is [$(command -v "$_t" 2>/dev/null)], not the harness fake — refusing" >&2; exit 1; }
  done
fi

# --- dependencies: jq (everywhere, and kn-guard's `apply -f -`), python3 (kn-guard's strict-JSON check of that manifest), yq (mikefarah v4: move_gate) and git. Refuse cleanly rather than fail mid-window.
for _t in jq yq git python3; do command -v "$_t" >/dev/null 2>&1 || { echo "REFUSE: the guards require '$_t' on PATH (jq, yq v4, git and python3 are dependencies; kn-guard refuses apply without jq or python3)" >&2; exit 1; }; done
# --- config: MOVE_CONF is the ONE input; every other value is unset, then read from it, validated, and frozen ---------------------
[ -n "${MOVE_CONF:-}" ] && [ -f "$MOVE_CONF" ] || { echo "REFUSE: MOVE_CONF must name a readable per-move config file (see move.conf.example); got [${MOVE_CONF:-}]" >&2; exit 1; }
_KEYS="APP OLD NEW PV PR1 PR2 PR1_SHA PR2_SHA BASE_SHA STATE_DIR WORKTREE GH_REPO CLUSTER_UID EXPECT_FILES EXPECT_DIRS DRIFT_PATHS REPORT_DIRS LIVE_FILES CONTROLLER"
for _k in $_KEYS MOVE_DIR R GUARDS_ROOT; do unset "$_k"; done
# m4/N5: the config is DATA, not code — parsed by confparse.sh (shared with the harnesses): only `KEY="value"` lines, known keys, each once, no $ ` \ or "
# in a value (a leading $HOME/ is expanded from the passwd database, not the environment). Nothing in the file is executed.
# shellcheck source=confparse.sh
. "$GUARDS_DIR/confparse.sh"
parse_conf "$MOVE_CONF" "$_KEYS" || exit 1
_match() { [[ $1 =~ $2 ]] && [[ $1 != *..* ]]; }   # _match VALUE ERE  (ERE kept in a variable: bash 3.2 quoting rules)
_die() { echo "REFUSE (config $MOVE_CONF): $*" >&2; exit 1; }
_DNS='^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$'; _NUM='^[0-9]+$'; _SHA='^[0-9a-f]{40}$'; _ABS='^/[A-Za-z0-9._/~+-]+$'; _UUID='^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
_NAME='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'; _PATH='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'
for _k in APP OLD NEW; do _match "${!_k:-}" "$_DNS" || _die "$_k=[${!_k:-}] is not a DNS label"; done
[ "$OLD" != "$NEW" ] || _die "OLD and NEW are the same namespace"
_match "${PV:-}" "^pvc-[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\$" || _die "PV=[${PV:-}] is not pvc-<uuid>"
for _k in PR1 PR2; do _match "${!_k:-}" "$_NUM" || _die "$_k must be a literal PR number"; done
[ "$PR1" != "$PR2" ] || _die "PR1 and PR2 must differ"
for _k in PR1_SHA PR2_SHA BASE_SHA; do _match "${!_k:-}" "$_SHA" || _die "$_k must be a full 40-hex SHA"; done
for _k in STATE_DIR WORKTREE; do _match "${!_k:-}" "$_ABS" || _die "$_k must be an absolute path (no spaces)"; done
_match "${GH_REPO:-}" '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || _die "GH_REPO must be owner/name"
_match "${CLUSTER_UID:-}" "$_UUID" || _die "CLUSTER_UID must be the kube-system namespace UID (kubectl get ns kube-system -o jsonpath='{.metadata.uid}')"
CONTROLLER=${CONTROLLER:-$APP}; _match "$CONTROLLER" "$_DNS" || _die "CONTROLLER=[$CONTROLLER]"
[ -n "${EXPECT_FILES:-}" ] && [ -n "${EXPECT_DIRS:-}" ] && [ -n "${DRIFT_PATHS:-}" ] || _die "EXPECT_FILES, EXPECT_DIRS and DRIFT_PATHS must be non-empty"
_LIST='^[A-Za-z0-9._/ -]*$'
# N6: validate the RAW list strings BEFORE they are ever word-split/glob-expanded (a `*` in a value must not depend on the caller's cwd)
for _k in EXPECT_FILES EXPECT_DIRS DRIFT_PATHS REPORT_DIRS LIVE_FILES; do [[ ${!_k:-} =~ $_LIST ]] || _die "$_k contains characters outside [A-Za-z0-9._/ -] (no globs)"; done
for _n in $EXPECT_FILES ${LIVE_FILES:-}; do _match "$_n" "$_NAME" || _die "bad file name [$_n]"; done
for _n in $EXPECT_DIRS ${REPORT_DIRS:-}; do _match "$_n" "$_NAME" || _die "bad dir name [$_n]"; done
for _n in $DRIFT_PATHS; do _match "$_n" "$_PATH" || _die "bad drift path [$_n]"; done
LIVE_FILES=${LIVE_FILES:-}; REPORT_DIRS=${REPORT_DIRS:-}
export APP OLD NEW PV PR1 PR2 PR1_SHA PR2_SHA BASE_SHA STATE_DIR WORKTREE GH_REPO CLUSTER_UID EXPECT_FILES EXPECT_DIRS DRIFT_PATHS REPORT_DIRS LIVE_FILES CONTROLLER
readonly APP OLD NEW PV PR1 PR2 PR1_SHA PR2_SHA BASE_SHA STATE_DIR WORKTREE GH_REPO CLUSTER_UID EXPECT_FILES EXPECT_DIRS DRIFT_PATHS REPORT_DIRS LIVE_FILES CONTROLLER

# N12: every kubectl call carries --request-timeout (a hung API server, e.g. an unstable Pi control plane, must not hang a tool call). Appended AFTER the
# caller's args. `gh` has no equivalent flag: gh calls are unbounded except by the tool's own limit (documented in the README).
kubectl() { command kubectl "$@" --request-timeout="${MOVE_KUBE_TIMEOUT:-20s}"; }
# --- context: refuse to run against anything but the intended cluster (exit at load; _cluster_ok re-checks before every mutating function) -----------
# Identified by the kube-system UID, not the context NAME (one cluster can be reachable under several kubeconfig names).
_cluster_ok() { [ "$(kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null)" = "$CLUSTER_UID" ] || { echo "WRONG CLUSTER (kube-system uid mismatch) — refusing" >&2; return 1; }; }
_cluster_ok || exit 1

# --- derived constants (all from the config) -----------------------------------------------------------------------------------------
export R="$WORKTREE"                        # the worktree holding the move branch (commit 1 + commit 2)
export MOVE_DIR="$STATE_DIR"                # baseline listing, T0/TAG/SINCE, silences
export MOVE_LABEL="${APP}-move"             # PV label key: ${APP}-move=1
export MOVE_SILENCES="$MOVE_DIR/silences.txt"
export AM_PORT=19093
mkdir -p "$MOVE_DIR"; touch "$MOVE_SILENCES"
# N14: derived state and the validators are frozen too (inside `hm '...'` a caller could otherwise repoint the SINCE/W12-PASS directory or weaken kn's deny-list).
readonly R MOVE_DIR MOVE_LABEL MOVE_SILENCES AM_PORT GUARDS_DIR _DNS _NUM _SHA _ABS _UUID _NAME _PATH _LIST

# --- git: the ONLY way to commit in the worktree. No push. ---------------------------------------------------------------------------
# Bot identity per the repo CLAUDE.md ("Commit authorship for agent-written changes"); -c per command, never `git config` (a worktree shares .git/config).
GIT() { git -C "$R" -c 'user.name=fizz-bot-bvn[bot]' -c 'user.email=324971095+fizz-bot-bvn[bot]@users.noreply.github.com' "$@"; }
# COMMIT "<scoped subject>" — needs MOVE_COAUTHOR (e.g. "Claude <model> <noreply@anthropic.com>": the repo's Co-Authored-By trailer names the model that
# wrote the change, so it is never defaulted); Claude-Session only if CLAUDE_SESSION_URL is set.
# NOTE: lefthook pre-commit (gitleaks + yamlfmt) runs here and may REWRITE staged YAML; re-run move_gate AFTER this.
COMMIT() {
  local trailers
  [ $# -eq 1 ] || { echo 'usage: COMMIT "<subject>"' >&2; return 1; }
  # N15: Scoped Commits (~/.claude/CLAUDE.md): "<scope>: <description>", never a Conventional Commits type prefix.
  [[ $1 =~ ^(feat|fix|docs|chore|refactor|test|tests|ci|build|perf|style|revert)(\([^\)]*\))?!?:[[:space:]] ]] && { echo "REFUSE: [$1] uses a Conventional Commits type prefix; use '<scope>: <description>' (Scoped Commits)" >&2; return 1; }
  [[ $1 =~ ^[A-Za-z0-9._/-]+(,[[:space:]][A-Za-z0-9._/-]+)*:[[:space:]]+[^[:space:]] ]] || { echo "REFUSE: subject [$1] must look like '<scope>: <description>'" >&2; return 1; }
  [ -n "${MOVE_COAUTHOR:-}" ] || { echo "REFUSE: set MOVE_COAUTHOR to the model's Co-Authored-By value (e.g. 'Claude <model> <noreply@anthropic.com>')" >&2; return 1; }
  trailers="Co-Authored-By: $MOVE_COAUTHOR"
  if [ -n "${CLAUDE_SESSION_URL:-}" ]; then trailers="$trailers"$'\n'"Claude-Session: $CLAUDE_SESSION_URL"; fi
  GIT commit -m "$1" -m "$trailers"
}

# --- namespaced kubectl: the VENDORED shared guard (kn-guard.sh, unchanged; sha256 recorded in README.md and checked by test/run.sh) --------------------
# kn is a verb + kind + FLAG allow-list (combined short flags, -A=true, --context/--server/…, secrets, cluster-scoped kinds are all refused; see its header).
# Configuration only — the vendored file is never edited. KN_KINDS/KN_CONTROLLER_KINDS are explicit lists that include the Flux Kustomization by its full name
# (the short `ks` is ambiguous). KN_VERBS is narrower than the vendored default: no scale/annotate/label through kn (raw commands, checkpointed).
# shellcheck source=kn-guard.sh
. "$GUARDS_DIR/kn-guard.sh"
KN_NAMESPACES="$OLD $NEW"
KN_VERBS="get describe logs wait apply delete patch"
# The kind lists are spelled out here (the vendored defaults are internal since the lists moved into function bodies): exactly what this guard reads or writes.
KN_KINDS="pod pods deploy deployment deployments job jobs pvc pvcs persistentvolumeclaim persistentvolumeclaims volumesnapshot volumesnapshots helmrelease helmreleases kustomization.kustomize.toolkit.fluxcd.io replicationsource.volsync.backube replicationdestination.volsync.backube"
# KN_CONTROLLER_KINDS is ADDITIVE (the built-in Flux/ESO kinds can never be removed): add the full Kustomization name so it is read/delete-only too.
KN_CONTROLLER_KINDS="kustomization.kustomize.toolkit.fluxcd.io"
readonly KN_NAMESPACES KN_VERBS KN_KINDS KN_CONTROLLER_KINDS
# _kn <ns> <args>: the same guarded kn, for this file's own FIXED writes (data_check's Job, rs_trigger's patch), plus a cluster-identity re-check first.
_kn() { _cluster_ok || return 1; kn "$@"; }
_is_move_ns() { [ "${1:-}" = "$OLD" ] || [ "${1:-}" = "$NEW" ]; }

# --- the one PV -------------------------------------------------------------------------------------------------------------------------
# pv_ok <pv> [require-label=1]: run before EVERY PV mutation. Requires: the name is exactly $PV; the PV is readable (a read error is a REFUSAL);
# it carries ${APP}-move=1 (unless require-label=0, used only by record_pv itself); claimRef is <OLD|NEW>/$APP (namespace AND name). An EMPTY claimRef is
# REFUSED: this workflow only ever re-points, and a claimRef-less PV is the R-5 "any matching claim takes it" state.
# (errexit is DISABLED inside functions called in && / || lists, so every check is explicit.)
pv_ok() {
  local pv=${1:-} need=${2:-1} j lbl cn cname
  if [ "$pv" != "$PV" ]; then echo "REFUSE: [$pv] is not the move PV ($PV)" >&2; return 1; fi
  if ! j=$(kubectl get pv "$pv" -o json); then echo "REFUSE: cannot read PV $pv (API error or absent)" >&2; return 1; fi
  if ! lbl=$(jq -r --arg k "$MOVE_LABEL" '.metadata.labels[$k] // ""' <<<"$j"); then return 1; fi
  if [ "$need" = 1 ] && [ "$lbl" != "1" ]; then echo "REFUSE: $pv lacks label $MOVE_LABEL=1 (run record_pv first)" >&2; return 1; fi
  if ! cn=$(jq -r '.spec.claimRef.namespace // ""' <<<"$j"); then return 1; fi
  if ! cname=$(jq -r '.spec.claimRef.name // ""' <<<"$j"); then return 1; fi
  if ! _is_move_ns "$cn"; then echo "REFUSE: $pv claimRef ns=[$cn] (must be $OLD or $NEW; empty is refused)" >&2; return 1; fi
  if [ "$cname" != "$APP" ]; then echo "REFUSE: $pv claimRef name=[$cname], must be $APP" >&2; return 1; fi
  echo "ok $pv (claim ns=[$cn])"
}
# record_pv: label the PV ${APP}-move=1 (the ONE PV mutation that needs no label). Only if a live $APP PVC in $OLD or $NEW names exactly $PV and that PV's
# claimRef namespace matches that claim's namespace.
record_pv() {
  local ns v cn
  _cluster_ok || return 1
  for ns in "$OLD" "$NEW"; do
    v=$(kubectl -n "$ns" get pvc "$APP" -o json 2>/dev/null | jq -r '.spec.volumeName // ""' || true)
    [ "$v" = "$PV" ] || continue
    cn=$(kubectl get pv "$PV" -o json | jq -r '.spec.claimRef.namespace // ""') || return 1
    [ "$cn" = "$ns" ] || continue
    pv_ok "$PV" 0 >/dev/null || return 1
    kubectl label pv "$PV" "$MOVE_LABEL=1" --overwrite >/dev/null || return 1
    echo "$PV"; return 0
  done
  echo "REFUSE: no $APP PVC in $OLD/$NEW names $PV with a matching claimRef namespace" >&2; return 1
}
# PV mutation: there is NO generic patcher. The only writes to the PV are record_pv (label), pv_reclaim (reclaim policy) and pv_repoint (claimRef), each
# below with its payload BUILT IN CODE from validated values — never caller-supplied (N1: a validated-but-parsed-differently payload, e.g. a UTF-8 BOM plus a
# second JSON document, reached kubectl as a Delete patch; there is no payload argument left to attack). Each re-runs pv_ok and re-verifies the cluster UID.
# pv_reclaim <pv> Retain|Delete   (Delete RE-ARMS trap 2 — only at B10, or to undo Retain while the app is untouched)
# Payloads are fixed here. Delete is accepted ONLY on a PV that is Bound AND whose claimRef PVC exists, is Bound and names this PV: a Released/Available PV flipped to Delete
# is reclaimed at once (PV + Longhorn volume gone). It ALSO needs B10_OK=yes whenever the claim is in $NEW (independent of any state file) or once
# $STATE_DIR/SINCE.txt exists (pr_merge writes it when PR 1 is merged) — the human's go-ahead, like SILENCE_OK.
pv_reclaim() {
  local pv=${1:-} pol=${2:-} j ph cn c cv cph
  case "$pol" in Retain|Delete) ;; *) echo "REFUSE: reclaim policy [$pol] must be Retain or Delete" >&2; return 1;; esac
  if [ "$pol" = Delete ]; then
    pv_ok "$pv" >/dev/null || return 1
    if ! j=$(kubectl get pv "$pv" -o json); then echo "REFUSE: cannot read PV $pv" >&2; return 1; fi
    ph=$(jq -r '.status.phase // ""' <<<"$j") || return 1
    cn=$(jq -r '.spec.claimRef.namespace // ""' <<<"$j") || return 1
    if { [ "$cn" = "$NEW" ] || [ -e "$MOVE_DIR/SINCE.txt" ]; } && [ "${B10_OK:-}" != "yes" ]; then
      echo "REFUSE: Delete is B10 (claim in $NEW, or the move started: $MOVE_DIR/SINCE.txt) and needs B10_OK=yes (the human's go-ahead)" >&2; return 1
    fi
    [ "$ph" = Bound ] || { echo "REFUSE: Delete needs the PV Bound, it is [$ph] — a $ph PV set to Delete is reclaimed at once" >&2; return 1; }
    if ! c=$(kubectl -n "$cn" get pvc "$APP" -o json); then echo "REFUSE: claim $cn/$APP does not exist — Delete would destroy the volume" >&2; return 1; fi
    cv=$(jq -r '.spec.volumeName // ""' <<<"$c") || return 1; cph=$(jq -r '.status.phase // ""' <<<"$c") || return 1
    { [ "$cv" = "$pv" ] && [ "$cph" = Bound ]; } || { echo "REFUSE: claim $cn/$APP is [$cph] on [$cv], not Bound to $pv" >&2; return 1; }
  fi
  _cluster_ok || return 1
  pv_ok "$pv" >/dev/null || return 1
  kubectl patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"'"$pol"'"}}' || return 1
  kubectl get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
}
# pv_repoint <pv> <ns>: reserve the PV for <ns>/$APP (uid/resourceVersion null) — NEVER remove claimRef (any matching claim would take it).
# Preconditions (m6): PV phase Released or Available, reclaim Retain, and the target claim <ns>/$APP absent or Pending with volumeName empty or $PV.
# (Re-pointing a Bound PV would strand a running claim; re-pointing a non-Retain PV would arm a Delete on the old claim.)
pv_repoint() {
  local pv=${1:-} ns=${2:-} j ph pol c cph cv rc
  _is_move_ns "$ns" || { echo "REFUSE: repoint target ns [$ns]" >&2; return 1; }
  _cluster_ok || return 1
  pv_ok "$pv" >/dev/null || return 1
  if ! j=$(kubectl get pv "$pv" -o json); then echo "REFUSE: cannot read PV $pv" >&2; return 1; fi
  ph=$(jq -r '.status.phase // ""' <<<"$j") || return 1; pol=$(jq -r '.spec.persistentVolumeReclaimPolicy // ""' <<<"$j") || return 1
  case "$ph" in Released|Available) ;; *) echo "REFUSE: repoint needs the PV Released or Available, it is [$ph]" >&2; return 1;; esac
  [ "$pol" = Retain ] || { echo "REFUSE: repoint needs reclaim Retain, it is [$pol]" >&2; return 1; }
  c=$(kubectl -n "$ns" get pvc "$APP" -o json 2>&1) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ] && ! grep -qi 'not found' <<<"$c"; then echo "REFUSE: cannot read claim $ns/$APP: $c" >&2; return 1; fi   # only NotFound means absent; any other error fails closed
  if [ "$rc" -eq 0 ]; then
    cph=$(jq -r '.status.phase // ""' <<<"$c") || return 1; cv=$(jq -r '.spec.volumeName // ""' <<<"$c") || return 1
    { [ "$cph" = Pending ] && { [ -z "$cv" ] || [ "$cv" = "$pv" ]; }; } || { echo "REFUSE: claim $ns/$APP exists as [$cph] on [$cv] (must be absent, or Pending on this PV)" >&2; return 1; }
  fi
  kubectl patch pv "$pv" --type merge -p '{"spec":{"claimRef":{"namespace":"'"$ns"'","name":"'"$APP"'","uid":null,"resourceVersion":null}}}'
}
# app_pv: the PV named by the app PVC's spec.volumeName, RE-READ from the live PVC on EVERY call — never from a cached file [Rh-B2].
# Refuses if the OLD and NEW claims name different PVs, or if the name is not $PV (a re-provisioned claim = STOP and ask).
app_pv() {
  local ns pv="" v=""
  for ns in "$OLD" "$NEW"; do
    v=$(kubectl -n "$ns" get pvc "$APP" -o json 2>/dev/null | jq -r '.spec.volumeName // ""' || true)
    [ -n "$v" ] || continue
    if [ -n "$pv" ] && [ "$v" != "$pv" ]; then echo "REFUSE: $APP claims in $OLD/$NEW name different PVs ($pv vs $v)" >&2; return 1; fi
    pv=$v
  done
  [ -n "$pv" ] || { echo "no PVC $APP with a volumeName in $OLD or $NEW right now (there is deliberately NO cached fallback)" >&2; return 1; }
  [ "$pv" = "$PV" ] || { echo "REFUSE: the live PVC names [$pv], not $PV — the claim was re-provisioned; STOP" >&2; return 1; }
  pv_ok "$pv" >/dev/null || return 1
  echo "$pv"
}

# --- assertions ------------------------------------------------------------------------------------------------------------------------
# inventory_ok <ns>: the app Kustomization in <ns> must have a NON-EMPTY inventory whose every entry is in <ns>. Fails closed on null.
inventory_ok() {
  local ns=${1:-}
  _is_move_ns "$ns" || { echo "REFUSE ns=[$ns]" >&2; return 1; }
  if kubectl -n "$ns" get kustomization.kustomize.toolkit.fluxcd.io "$APP" -o json | jq -e --arg p "${ns}_" '
    [ .status.inventory.entries[]?.id ] as $ids | ($ids | length) > 0 and ($ids | all(startswith($p)))' >/dev/null; then
    echo "inventory ok ($ns)"
  else
    echo "INVENTORY CHECK FAILED ($ns: empty, null, or contains an object outside $ns)" >&2; return 1
  fi
}
# others_ready: every Kustomization except the app's in $OLD/$NEW must be Ready. A reconcile starts by marking Ready=Unknown and a merge fires the
# Receiver (reconciles cluster-apps), so one "not True" is noise: fail at once on Ready=False, otherwise require not-True on 3 polls 20s apart.
others_ready() {
  local i bad falsy sel
  # shellcheck disable=SC2016  # $app/$o/$n are jq variables, bound with --arg below
  sel='select((.metadata.name==$app and (.metadata.namespace==$o or .metadata.namespace==$n))|not)'
  for i in 1 2 3; do
    falsy=$(kubectl get ks -A -o json | jq -r --arg app "$APP" --arg o "$OLD" --arg n "$NEW" ".items[]|$sel|select(((.status.conditions // [])|map(select(.type==\"Ready\"))|.[0].status // \"Unknown\")==\"False\")|\"\(.metadata.namespace)/\(.metadata.name)\"") || return 1
    [ -z "$falsy" ] || { echo "READY=False: $falsy" >&2; return 1; }
    bad=$(kubectl get ks -A -o json | jq -r --arg app "$APP" --arg o "$OLD" --arg n "$NEW" ".items[]|$sel|select(((.status.conditions // [])|map(select(.type==\"Ready\"))|.[0].status // \"Unknown\")!=\"True\")|\"\(.metadata.namespace)/\(.metadata.name)\"") || return 1
    [ -z "$bad" ] && { echo "all other ks Ready"; return 0; }
    echo "poll $i/3: not yet Ready: $bad" >&2; [ "$i" -lt 3 ] && sleep 20
  done
  echo "NOT READY after 3 polls: $bad" >&2; return 1
}
# no_sync_in_flight <ns>: BOTH RS ($APP-local, $APP-r2) must have an EMPTY status.lastSyncStartTime (trap 8, [Rh-12]). Fails closed on a read error.
no_sync_in_flight() {
  local ns=${1:-} rs st rc=0
  _is_move_ns "$ns" || { echo "REFUSE ns=[$ns]" >&2; return 1; }
  for rs in "$APP-local" "$APP-r2"; do
    if ! st=$(kn "$ns" get replicationsource.volsync.backube "$rs" -o json | jq -r '.status.lastSyncStartTime // ""'); then echo "cannot read $ns/$rs" >&2; return 1; fi
    if [ -n "$st" ]; then echo "$ns/$rs SYNC IN FLIGHT (lastSyncStartTime=$st)" >&2; rc=1; else echo "$ns/$rs idle"; fi
  done
  return $rc
}
# rs_trigger <ns> <rs> <tag>: the ONLY way this workflow sets a manual trigger (W-5). <rs> is $APP-local or $APP-r2, <tag> is pre-move-<digits>, and THAT
# source must be idle (trap 8; run no_sync_in_flight first for both — triggering the first starts its sync, so the second cannot be re-checked as a pair). Fixed merge-patch payload; kubectl goes through _kn so the namespace is pinned.
rs_trigger() {
  local ns=${1:-} rs=${2:-} tag=${3:-} st
  _is_move_ns "$ns" || { echo "REFUSE ns=[$ns]" >&2; return 1; }
  case "$rs" in "$APP-local"|"$APP-r2") ;; *) echo "REFUSE: rs [$rs] must be $APP-local or $APP-r2" >&2; return 1;; esac
  _match "$tag" '^pre-move-[0-9]+$' || { echo "REFUSE: tag [$tag] must be pre-move-<digits>" >&2; return 1; }
  st=$(kn "$ns" get replicationsource.volsync.backube "$rs" -o json | jq -r '.status.lastSyncStartTime // ""') || { echo "REFUSE: cannot read $ns/$rs" >&2; return 1; }
  [ -z "$st" ] || { echo "REFUSE: $ns/$rs has a sync in flight (lastSyncStartTime=$st, trap 8) — wait for it to finish" >&2; return 1; }
  _kn "$ns" patch replicationsource.volsync.backube "$rs" --type merge -p '{"spec":{"trigger":{"manual":"'"$tag"'"}}}'
}
# pending_claims: every Pending PVC cluster-wide (the --field-selector form is rejected by the API server [Rh-F]). Expect only the moving claim.
pending_claims() {
  kubectl get pvc -A -o json | jq -r '.items[]|select(.status.phase=="Pending")|"\(.metadata.namespace)/\(.metadata.name) sc=\(.spec.storageClassName)"'
}
# one_route <ns>: exactly ONE HTTPRoute named $APP cluster-wide, in <ns> (trap 13, oldest route wins).
one_route() {
  local want=${1:-} out n
  _is_move_ns "$want" || { echo "REFUSE ns=[$want]" >&2; return 1; }
  out=$(kubectl get httproute -A --no-headers | awk -v a="$APP" '$2==a{print $1}') || return 1
  n=$(printf '%s\n' "$out" | grep -c . || true)
  echo "$APP routes: $n in [$(echo "$out" | tr '\n' ' ')]"
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
# _count_dirs: the directories the baseline counts = EXPECT_DIRS (must be non-empty) + REPORT_DIRS (reported only).
_count_dirs() { echo "$EXPECT_DIRS ${REPORT_DIRS:-}"; }
# data_baseline_ok <file>: the baseline must reflect the app's REAL layout (read it live at P1; never assume): every EXPECT_FILES entry must exist and be
# NON-EMPTY, every EXPECT_DIRS dir must hold files. All counts are reported. Dirs that are legitimately empty go in REPORT_DIRS (or nowhere).
data_baseline_ok() {
  local f=${1:-} n esc line ok=1 d c empty=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  [ -s "$f" ] || { echo "REFUSE: baseline [$f] missing or empty" >&2; return 1; }
  for n in $EXPECT_FILES; do
    esc=$(printf '%s' "$n" | sed 's/[.[\*^$]/\\&/g')
    line=$(grep -E "^[0-9a-f]{64}  \./${esc}\$" "$f" | head -1 || true)
    if [ -z "$line" ]; then echo "baseline LACKS $n"; ok=0
    elif [ "${line%% *}" = "$empty" ]; then echo "baseline has $n but it is EMPTY"; ok=0
    else echo "baseline has $n"; fi
  done
  for d in $(_count_dirs); do
    c=$(awk -v d="$d" 'f && $1==d{print $2} /^---COUNTS/{f=1}' "$f")
    echo "count $d=[${c:-?}]"
    case " $EXPECT_DIRS " in *" $d "*) [ "${c:-0}" -gt 0 ] || { echo "baseline $d/ has no files"; ok=0; } ;; esac
  done
  [ "$ok" -eq 1 ]
}
# data_check <ns> <outfile> [pvc] [tries=80]: read-only content listing of a PVC in <ns> (default: the app PVC; pass volsync-$APP-dst-local-dest for the
# drill) as UID 0. DAC_OVERRIDE is added because drop:[ALL] would otherwise strip root's read override on mode-600 files. It is a MUTATING helper (creates a Job):
#   * it requires HM_WINDOW=yes in the environment (set only inline on the window steps that need it);
#   * it REFUSES unless the target PVC exists and is Bound (a Pending consumer would become a second consumer of the claim when it binds; nothing is applied);
#   * the Job itself carries activeDeadlineSeconds 420 + ttlSecondsAfterFinished 60 (so even a SIGKILLed client, which runs no trap, cannot leave it running or
#     lingering); the wait is deadline-bound to <=60 x 5 s (< the 600 s tool limit) and a trap installed right after the apply deletes the Job (--cascade=foreground --wait=false)
#     on EXIT INT TERM, so a killed or timed-out call cannot orphan it (an orphaned Completed/Pending pod holds pvc-protection = trap 3);
#   * after the normal delete it REQUIRES the pod (label job-name=<job>) to be gone.
# If ANY pod in <ns> mounts the PVC the Job is pinned to ITS node (RWO Multi-Attach otherwise).
# Output = names + hashes + counts only. First line of the saved file is a header:  # <job> <ns> <pvc> <utc>  (data_compare uses it). Saved only on success.
data_check() {
  local ns=${1:-} out=${2:-} pvc=${3:-$APP} tries=${4:-60} j node st="" i tmp left="" phase dirs end
  [ "${HM_WINDOW:-}" = "yes" ] || { echo "REFUSE: data_check creates a Job and only runs inside the window (HM_WINDOW=yes)" >&2; return 1; }
  [ -n "$out" ] || { echo 'usage: data_check <ns> <outfile> [pvc] [tries]' >&2; return 1; }
  _is_move_ns "$ns" || { echo "REFUSE ns=[$ns]" >&2; return 1; }
  case "$pvc" in "$APP"|"volsync-$APP-dst-local-dest") ;; *) echo "REFUSE: pvc [$pvc] is not a $APP claim" >&2; return 1;; esac
  case "$tries" in ''|*[!0-9]*) echo "REFUSE: tries [$tries]" >&2; return 1;; esac
  [ "$tries" -ge 1 ] && [ "$tries" -le 60 ] || { echo "REFUSE: tries must be 1..60 (a SECONDS deadline of tries x 5 s + 60 s delete + 60 s pod check stays under the 600 s tool limit)" >&2; return 1; }
  if ! phase=$(kn "$ns" get pvc "$pvc" -o json 2>/dev/null | jq -r '.status.phase // ""'); then phase=""; fi
  [ "$phase" = "Bound" ] || { echo "REFUSE: PVC $ns/$pvc is [${phase:-absent}], not Bound — no Job created" >&2; return 1; }
  j="hchk-$(date +%s)"; tmp="$MOVE_DIR/$j.out"; dirs=$(_count_dirs)   # dir names were validated at load: [A-Za-z0-9._/-] only, safe inside the sh -c string
  node=$(kn "$ns" get pod -o json | jq -r --arg c "$pvc" '[.items[]|select(.spec.volumes[]?.persistentVolumeClaim.claimName==$c)|.spec.nodeName][0] // ""') || return 1
  # kn-guard's `apply -f -` accepts JSON only (apiVersion/kind must be batch/v1/Job, no key named namespace/items anywhere), so the manifest is built with jq.
  # shellcheck disable=SC2016  # $d and $(find …) are meant for the helper pod's shell, not this one
  cmd='cd /data && find . -type f -print0 | sort -z | xargs -0 sha256sum && echo ---COUNTS && for d in '"$dirs"'; do echo $d $(find $d -type f 2>/dev/null | wc -l); done'
  jq -nc --arg j "$j" --arg label "$MOVE_LABEL" --arg node "$node" --arg pvc "$pvc" --arg cmd "$cmd" '
    {apiVersion:"batch/v1",kind:"Job",metadata:{name:$j,labels:{($label):"helper"}},
     spec:{backoffLimit:0,activeDeadlineSeconds:420,ttlSecondsAfterFinished:60,
       template:{spec:({restartPolicy:"Never",
         containers:[{name:"r",image:"busybox:1.37",securityContext:{runAsUser:0,allowPrivilegeEscalation:false,capabilities:{drop:["ALL"],add:["DAC_OVERRIDE"]}},
                      command:["sh","-c",$cmd],volumeMounts:[{name:"d",mountPath:"/data",readOnly:true}]}],
         volumes:[{name:"d",persistentVolumeClaim:{claimName:$pvc,readOnly:true}}]} + (if $node=="" then {} else {nodeName:$node} end))}}}' \
    | _kn "$ns" apply -f - >/dev/null || { echo "REFUSE: could not create the helper Job (kn-guard/kubectl refused or failed)" >&2; return 1; }
  # from here the Job exists: whatever ends this call (timeout, INT, TERM, error), it is deleted
  # shellcheck disable=SC2064
  # N9: EXIT deletes the Job; TERM/INT EXIT the function's shell so the poll stops (a trap that only deleted the Job left the call running).
  trap "kubectl -n '$ns' delete job '$j' --cascade=foreground --wait=false >/dev/null 2>&1 || true" EXIT
  trap 'exit 143' TERM; trap 'exit 130' INT
  end=$((SECONDS + tries * 5))
  while :; do   # deadline-bound (SECONDS), not iteration-bound: kubectl latency cannot stretch it past the tool limit
    st=$(kn "$ns" get job "$j" -o json | jq -r 'if (.status.succeeded // 0) > 0 then "ok" elif (.status.failed // 0) > 0 then "failed" else "" end') || break
    [ -n "$st" ] && break; [ "$SECONDS" -ge "$end" ] && break; sleep 5 & wait $!   # interruptible: a TERM/INT trap fires at once, not after the sleep
  done
  echo "--- data_check $ns/$pvc: job=$j pin=[$node] result=[${st:-TIMEOUT}] ---"
  kn "$ns" logs "job/$j" > "$tmp" 2>&1 || true
  wc -l < "$tmp" | sed 's/^ */lines: /'; grep -A8 -- '---COUNTS' "$tmp" || tail -5 "$tmp"
  kn "$ns" describe pod -l job-name="$j" 2>&1 | grep -E "Warning" -A3 | head -12 || true
  _kn "$ns" delete job "$j" --cascade=foreground --wait=true --timeout=60s >/dev/null 2>&1 || true
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    left=$(kn "$ns" get pods -l job-name="$j" -o name 2>/dev/null || true); [ -z "$left" ] && break; sleep 5
  done
  trap - EXIT INT TERM
  [ -z "$left" ] || { echo "HELPER POD STILL PRESENT ($left) — delete it before any PVC delete (trap 3)" >&2; return 1; }
  if [ "$st" = "ok" ]; then { echo "# $j $ns $pvc $(date -u +%FT%TZ)"; cat "$tmp"; } > "$out"; rm -f "$tmp"; echo "saved $out"; return 0; fi
  return 1
}
# data_compare [--ignore-live] <baseline> <after> [baseline-ns=$OLD]: EVERYTHING must match, LIVE_FILES* included. Between B2 (W-4) and B7 (W-12) nothing
# runs against the volume (pod at 0, movers read a snapshot clone), so even a live database file is static and is the file most likely to hold the state.
# --ignore-live (drops lines for LIVE_FILES and their -wal/-shm siblings) exists only for a comparison ACROSS A POD START; the plan never uses it, and it is
# refused when LIVE_FILES is empty. The baseline must carry a header from <baseline-ns>, the app PVC, and be NOT older than $MOVE_DIR/T-quiesced.txt
# (a leftover file from an aborted window is refused); <after> must be no older than the baseline.
_sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }
data_compare() {
  local ign=0 a b ens h ns pvc ut q ah aut d n pat="" bj aj ans apvc w12=0 alt=""
  if [ "${1:-}" = "--ignore-live" ]; then ign=1; shift; fi
  a=${1:-}; b=${2:-}; ens=${3:-$OLD}
  _is_move_ns "$ens" || { echo "REFUSE: baseline namespace [$ens] must be $OLD or $NEW" >&2; return 1; }
  if [ "$ign" -eq 1 ]; then
    [ -n "$LIVE_FILES" ] || { echo "REFUSE: --ignore-live but LIVE_FILES is empty in the config" >&2; return 1; }
    for n in $LIVE_FILES; do alt="$alt|$(printf '%s' "$n" | sed 's/[.[\*^$]/\\&/g')"; done
    pat="^[0-9a-f]{64}  \\./(${alt#|})(-wal|-shm)?\$"   # anchored: the live file and its -wal/-shm siblings only, never ./app.db.important-backup
  fi
  { [ -s "$a" ] && [ -s "$b" ]; } || { echo "REFUSE: baseline/after missing or empty" >&2; return 1; }
  h=$(head -1 "$a"); case "$h" in "# "*) ;; *) echo "REFUSE: baseline has no header line" >&2; return 1;; esac
  bj=$(awk '{print $2}' <<<"$h"); ns=$(awk '{print $3}' <<<"$h"); pvc=$(awk '{print $4}' <<<"$h"); ut=$(awk '{print $5}' <<<"$h")
  [ "$ns" = "$ens" ] || { echo "REFUSE: baseline is from ns [$ns], expected [$ens]" >&2; return 1; }
  [ "$pvc" = "$APP" ] || { echo "REFUSE: baseline is from pvc [$pvc], expected [$APP]" >&2; return 1; }
  [ -s "$MOVE_DIR/T-quiesced.txt" ] || { echo "REFUSE: $MOVE_DIR/T-quiesced.txt missing (written at W-3)" >&2; return 1; }
  q=$(head -1 "$MOVE_DIR/T-quiesced.txt")
  { [[ "$ut" > "$q" ]] || [[ "$ut" == "$q" ]]; } || { echo "REFUSE: baseline ($ut) is OLDER than the quiesce ($q) — stale file from another window" >&2; return 1; }
  ah=$(head -1 "$b"); case "$ah" in "# "*) ;; *) echo "REFUSE: after has no header line" >&2; return 1;; esac
  aj=$(awk '{print $2}' <<<"$ah"); ans=$(awk '{print $3}' <<<"$ah"); apvc=$(awk '{print $4}' <<<"$ah"); aut=$(awk '{print $5}' <<<"$ah")
  _is_move_ns "$ans" || { echo "REFUSE: after is from ns [$ans], not $OLD/$NEW" >&2; return 1; }
  case "$apvc" in "$APP"|"volsync-$APP-dst-local-dest") ;; *) echo "REFUSE: after is from pvc [$apvc], not a $APP claim" >&2; return 1;; esac
  [ "$aj" != "$bj" ] || { echo "REFUSE: after and baseline are the same listing (job $aj)" >&2; return 1; }
  [[ "$aut" > "$ut" ]] || { echo "REFUSE: after ($aut) is not strictly newer than the baseline ($ut)" >&2; return 1; }
  # N3: the W-12 marker is for exactly ONE comparison: the baseline taken in $OLD against the app claim in $NEW. Anything else (NEW vs NEW, OLD vs OLD, the RD dest) never writes it.
  if [ "$ign" -eq 0 ] && [ "$ns" = "$OLD" ] && [ "$ans" = "$NEW" ] && [ "$apvc" = "$APP" ]; then w12=1; fi
  data_baseline_ok "$a" >/dev/null || { echo "baseline not acceptable" >&2; return 1; }
  if [ "$ign" -eq 1 ]; then
    d=$(diff <(grep -v '^#' "$a" | grep -v -E "$pat") <(grep -v '^#' "$b" | grep -v -E "$pat") || true)
  else
    d=$(diff <(grep -v '^#' "$a") <(grep -v '^#' "$b") || true)
  fi
  if [ -z "$d" ]; then
    if [ "$ign" -eq 1 ]; then echo "content identical (LIVE_FILES IGNORED)"; else echo "content identical (LIVE_FILES included)"; fi
    # M6/N3: the W-12 pass marker pr_merge <PR2> requires — only a full (not --ignore-live) match of the $OLD baseline against the app claim in $NEW.
    if [ "$w12" -eq 1 ]; then { echo "baseline $a $(_sha256 "$a")"; echo "after $b $(_sha256 "$b")"; echo "at $(date -u +%FT%TZ)"; } > "$MOVE_DIR/W12-PASS"; echo "W12-PASS recorded"; fi
    return 0
  fi
  if [ "$w12" -eq 1 ]; then rm -f "$MOVE_DIR/W12-PASS"; fi
  echo "$d" | head -20; echo "CONTENT DIFFERS" >&2; return 1
}
# drill_snapshot_ok: trap 14a. The Longhorn snapshot BEHIND the NEW RD's latestImage must EXIST and be readyToUse (VolumeSnapshot.readyToUse is not proof).
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

# --- pull requests: literal numbers only, head pinned ----------------------------------------------------------------------------------
# Never run a bare `gh pr merge`: with no number it merges the PR of the current branch. Use pr_merge. Numbers/SHAs are the ones pinned in the config.
_pr_pin() { # _pr_pin <n> -> echoes "<branch> <pinned-sha>" for the configured PR number, else returns 1
  case "$1" in "$PR1") echo "${APP}-move-pr1 $PR1_SHA";; "$PR2") echo "${APP}-move-pr2 $PR2_SHA";; *) return 1;; esac
}
# pr_mergeable <n> <sha> [tries=12]: OPEN, MERGEABLE, head == <sha> == the pinned SHA; retries UNKNOWN (GitHub recomputes asynchronously, e.g. PR 2 right
# after PR 1 merged). tries must be 1..12 (5 s each).
pr_mergeable() {
  local n=${1:-} sha=${2:-} tries=${3:-12} i j m o st pin
  _match "$n" "$_NUM" || { echo "REFUSE: PR number [$n] must be a literal number" >&2; return 1; }
  _match "$sha" "$_SHA" || { echo "REFUSE: [$sha] is not a full 40-hex SHA" >&2; return 1; }
  pin=$(_pr_pin "$n") || { echo "REFUSE: PR #$n is not one of this move's PRs ($PR1, $PR2)" >&2; return 1; }
  [ "$sha" = "${pin#* }" ] || { echo "REFUSE: [$sha] is not the pinned head (${pin#* }) of PR #$n" >&2; return 1; }
  _match "$tries" "$_NUM" && [ "$tries" -ge 1 ] && [ "$tries" -le 12 ] || { echo "REFUSE: tries [$tries] must be 1..12" >&2; return 1; }
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
# DRIFT_PATHS = everything that changes how the (minimal) move renders or textually collides with it. Comment-only follow-ups belong in the cleanup PR and are NOT watched.
# base_check (m7): BASE_SHA must actually be the parent of the move commit — a wrong BASE_SHA (e.g. today's origin/main) would silently hide real drift.
base_check() {
  local par
  git -C "$R" cat-file -e "${PR1_SHA}^{commit}" 2>/dev/null || { echo "REFUSE: PR1_SHA $PR1_SHA is not in $R (fetch/checkout the move branch first)" >&2; return 1; }
  par=$(git -C "$R" rev-parse "${PR1_SHA}^") || return 1
  [ "$par" = "$BASE_SHA" ] || { echo "REFUSE: BASE_SHA $BASE_SHA is not the parent of PR1_SHA (that is $par) — drift_check would compare against the wrong base" >&2; return 1; }
  git -C "$R" rev-parse --verify -q origin/main >/dev/null || { echo "REFUSE: no origin/main in $R (fetch first)" >&2; return 1; }
  git -C "$R" merge-base --is-ancestor "$BASE_SHA" origin/main || { echo "REFUSE: BASE_SHA $BASE_SHA is not an ancestor of origin/main" >&2; return 1; }
  echo "base ok: PR1_SHA^ == BASE_SHA, BASE_SHA on origin/main"
}
drift_check() {
  local out p paths=""
  git -C "$R" fetch -q origin main || { echo "REFUSE: git fetch failed" >&2; return 1; }
  base_check || return 1
  for p in $DRIFT_PATHS; do paths="$paths $p"; done
  # shellcheck disable=SC2086
  out=$(git -C "$R" diff --stat "$BASE_SHA" origin/main -- $paths) || return 1
  if [ -n "$out" ]; then echo "DRIFT since $BASE_SHA:" >&2; echo "$out" >&2; return 1; fi
  echo "no drift on origin/main in the paths the move touches"
}
# w0b: the pre-quiesce check (BEFORE the app goes down): base ok, no drift, both PRs OPEN + MERGEABLE with the pinned heads.
w0b() { drift_check && pr_mergeable "$PR1" "$PR1_SHA" 12 && pr_mergeable "$PR2" "$PR2_SHA" 12; }
# _pv_state <phase> <policy> <claim-ns>: the PV must be exactly this (pv_ok first). Used by the two merge preconditions.
_pv_state() {
  local j
  pv_ok "$PV" >/dev/null || return 1
  j=$(kubectl get pv "$PV" -o json) || return 1
  [ "$(jq -r '.status.phase // ""' <<<"$j")" = "$1" ] && [ "$(jq -r '.spec.persistentVolumeReclaimPolicy // ""' <<<"$j")" = "$2" ] && [ "$(jq -r '.spec.claimRef.namespace // ""' <<<"$j")" = "$3" ] \
    || { echo "REFUSE: PV $PV must be phase=$1 reclaim=$2 claim=$3/$APP; got phase=$(jq -r '.status.phase // ""' <<<"$j") reclaim=$(jq -r '.spec.persistentVolumeReclaimPolicy // ""' <<<"$j") claim=$(jq -r '.spec.claimRef.namespace // ""' <<<"$j")" >&2; return 1; }
}
# _pr1_preconditions (M1): the state W-7/W-8 establish, re-checked by the guard itself immediately before PR 1 merges — this is the only step that can
# destroy the volume (trap 2: PVC pruned with a Delete PV). PV Retain + Bound to OLD/APP; OLD HelmRelease suspended, OLD Kustomization NOT suspended
# (else the merge prunes nothing, trap 6), Deployment at 0, no pod mounting the claim; quiesce recorded; the forced backups accepted for BOTH sources.
_pr1_preconditions() {
  local v t0 pods
  _pv_state Bound Retain "$OLD" || return 1
  v=$(kn "$OLD" get helmrelease "$APP" -o json | jq -r '.spec.suspend // false') || return 1
  [ "$v" = true ] || { echo "REFUSE: $OLD/helmrelease/$APP is not suspended (W-3/W-7)" >&2; return 1; }
  v=$(kn "$OLD" get kustomization.kustomize.toolkit.fluxcd.io "$APP" -o json | jq -r '.spec.suspend // false') || return 1
  [ "$v" != true ] || { echo "REFUSE: $OLD Kustomization $APP is still suspended — the merge would orphan its inventory (trap 6, W-7)" >&2; return 1; }
  # by label, not name: with CONTROLLER != APP app-template may name the Deployment <release>-<controller> (inferred). At least one must exist and ALL must be at 0.
  v=$(kn "$OLD" get deploy -l app.kubernetes.io/name="$APP" -o json | jq -r '[.items[]|(.spec.replicas // "unset")]|if length==0 then "none" else (map(tostring)|unique|join(",")) end') || return 1
  [ "$v" = 0 ] || { echo "REFUSE: $OLD deployments of $APP have replicas=[$v], want all 0" >&2; return 1; }
  no_sync_in_flight "$OLD" >/dev/null || { echo "REFUSE: a ReplicationSource sync is in flight in $OLD (trap 8)" >&2; return 1; }
  pods=$(kn "$OLD" get pod -o json | jq -r --arg c "$APP" '.items[]|select(.spec.volumes[]?.persistentVolumeClaim.claimName==$c)|.metadata.name') || return 1
  [ -z "$pods" ] || { echo "REFUSE: pods still mount $OLD/$APP: $pods (trap 3)" >&2; return 1; }
  [ -s "$MOVE_DIR/T-quiesced.txt" ] || { echo "REFUSE: $MOVE_DIR/T-quiesced.txt missing (W-3 not done)" >&2; return 1; }
  [ -s "$MOVE_DIR/T0.txt" ] || { echo "REFUSE: $MOVE_DIR/T0.txt missing (W-5 not done)" >&2; return 1; }
  t0=$(head -1 "$MOVE_DIR/T0.txt")
  check_backup "$OLD" "$APP-local" "$APP@$OLD" "$t0" >/dev/null || { echo "REFUSE: $APP-local has no accepted forced backup after T0 (W-5)" >&2; return 1; }
  check_backup "$OLD" "$APP-r2" "$APP@$OLD" "$t0" >/dev/null || { echo "REFUSE: $APP-r2 has no accepted forced backup after T0 (W-5)" >&2; return 1; }
}
# _pr2_preconditions (M4, M6): PR 1 really merged (state MERGED at ITS pinned head — not a historic same-named branch), the W-12 content match is on record
# (W12-PASS, newer than SINCE, both listings unchanged since), and the PV is Retain + Bound to NEW/APP.
_pr2_preconditions() {
  local j nb na bf bh af ah ats since
  j=$(gh pr view "$PR1" -R "$GH_REPO" --json state,headRefOid) || return 1
  [ "$(jq -r '.state' <<<"$j")" = MERGED ] && [ "$(jq -r '.headRefOid' <<<"$j")" = "$PR1_SHA" ] || { echo "REFUSE: PR 1 (#$PR1) is not MERGED at $PR1_SHA — PR 2 must never go first" >&2; return 1; }
  _pv_state Bound Retain "$NEW" || return 1
  [ -s "$MOVE_DIR/W12-PASS" ] || { echo "REFUSE: no $MOVE_DIR/W12-PASS — run data_compare (baseline vs $NEW/$APP) and get 'content identical' first (W-12)" >&2; return 1; }
  [ -e "$MOVE_DIR/SINCE.txt" ] && [ "$MOVE_DIR/W12-PASS" -nt "$MOVE_DIR/SINCE.txt" ] || { echo "REFUSE: W12-PASS is not newer than SINCE.txt (stale from another window?)" >&2; return 1; }
  # N3: the marker is only a pointer. Require EXACTLY one baseline and one after line, and RE-RUN the comparison now (default baseline ns = $OLD) instead of trusting the file.
  nb=$(grep -c '^baseline ' "$MOVE_DIR/W12-PASS" || true); na=$(grep -c '^after ' "$MOVE_DIR/W12-PASS" || true)
  { [ "$nb" = 1 ] && [ "$na" = 1 ]; } || { echo "REFUSE: W12-PASS must hold exactly one baseline and one after line (has $nb/$na) — forged or damaged" >&2; return 1; }
  read -r _ bf bh < <(grep '^baseline ' "$MOVE_DIR/W12-PASS"); read -r _ af ah < <(grep '^after ' "$MOVE_DIR/W12-PASS")
  [ "$(_sha256 "$bf" 2>/dev/null)" = "$bh" ] && [ "$(_sha256 "$af" 2>/dev/null)" = "$ah" ] || { echo "REFUSE: a W-12 listing changed or vanished since W12-PASS" >&2; return 1; }
  ats=$(head -1 "$af" | awk '{print $5}'); since=$(head -1 "$MOVE_DIR/SINCE.txt")
  [[ "$ats" > "$since" ]] || { echo "REFUSE: the W-12 after-listing ($ats) is not newer than SINCE ($since) — it was not taken after PR 1 merged" >&2; return 1; }
  data_compare "$bf" "$af" >/dev/null || { echo "REFUSE: re-running the W-12 comparison failed" >&2; return 1; }
  [ -s "$MOVE_DIR/W12-PASS" ] || { echo "REFUSE: the re-run comparison did not qualify as W-12 (baseline must be from $OLD, after from $NEW/$APP)" >&2; return 1; }
}
# pr_merge <n> <sha>: the ONLY merge path. <n> must be the configured PR1/PR2 number; <sha> the full pinned head; the PR must be base main with head branch
# ${APP}-move-pr1/pr2. PR 1 additionally needs _pr1_preconditions and WRITES SINCE.txt itself before merging (so pv_reclaim's B10_OK gate never depends on a
# manual step; SINCE stays even if the merge call fails — the stricter side); PR 2 needs _pr2_preconditions. Marks a draft ready, merges with a merge commit, head pinned.
pr_merge() {
  local n=${1:-} sha=${2:-} j ref base st draft oid want pin
  _match "$n" "$_NUM" || { echo "REFUSE: PR number [$n] must be a literal number" >&2; return 1; }
  _match "$sha" "$_SHA" || { echo "REFUSE: [$sha] is not a full 40-hex SHA" >&2; return 1; }
  pin=$(_pr_pin "$n") || { echo "REFUSE: PR #$n is not one of this move's PRs ($PR1, $PR2)" >&2; return 1; }
  want=${pin#* }
  j=$(gh pr view "$n" -R "$GH_REPO" --json state,isDraft,headRefName,headRefOid,baseRefName) || return 1
  ref=$(jq -r '.headRefName' <<<"$j"); base=$(jq -r '.baseRefName' <<<"$j"); st=$(jq -r '.state' <<<"$j"); draft=$(jq -r '.isDraft' <<<"$j"); oid=$(jq -r '.headRefOid' <<<"$j")
  [ "$base" = main ] || { echo "REFUSE: PR #$n base is [$base]" >&2; return 1; }
  [ "$st" = OPEN ] || { echo "REFUSE: PR #$n is $st" >&2; return 1; }
  [ "$ref" = "${pin%% *}" ] || { echo "REFUSE: PR #$n head branch [$ref] is not ${pin%% *}" >&2; return 1; }
  { [ "$oid" = "$sha" ] && [ "$sha" = "$want" ]; } || { echo "REFUSE: head [$oid] / given [$sha] / pinned [$want] disagree" >&2; return 1; }
  _cluster_ok || return 1
  if [ "$n" = "$PR1" ]; then _pr1_preconditions || return 1; else _pr2_preconditions || return 1; fi
  # N8: SINCE.txt is written (and verified) BEFORE anything is changed on GitHub; a failed write refuses even inside an && / || list where errexit is off.
  if [ "$n" = "$PR1" ]; then
    date -u +%FT%TZ > "$MOVE_DIR/SINCE.txt" 2>/dev/null && [ -s "$MOVE_DIR/SINCE.txt" ] || { echo "REFUSE: cannot write $MOVE_DIR/SINCE.txt — not merging" >&2; return 1; }
  fi
  if [ "$draft" = true ]; then gh pr ready "$n" -R "$GH_REPO" || return 1; fi
  gh pr merge "$n" -R "$GH_REPO" --merge --match-head-commit "$sha"
}

# --- pre-merge gate --------------------------------------------------------------------------------------------------------------------
# move_gate <ns> <want> [replicas]: run AFTER COMMIT (lefthook/yamlfmt may have rewritten files) and BEFORE opening/merging a PR. Requires ALL of:
#   1. the kubernetes tree in $R is committed (covers both namespace kustomization.yaml files);
#   2. the app build has exactly <want> lines matching volumeName|sourceNamespace (2 = commit 1 / commit 2 into NEW; 1 = rollback into OLD) AND the values:
#      exactly one PVC with volumeName == $PV and exactly one RD whose sourceNamespace == $OLD (want 2) / unset (want 1);
#   3. EVERY metadata.namespace in the app build equals <ns>;
#   4. the PARENT build (cluster-apps, literally the runbook command) has exactly ONE child Kustomization named $APP, equal to
#      "<ns> $APP ./kubernetes/apps/<ns>/$APP/app <ns>";
#   5. optional [replicas] = zero | absent : the HelmRelease's controllers.$CONTROLLER.replicas is 0 (commit 1) / not set (commit 2).
# More than one PVC or RD in the app (kind-targeted patches hit them all) fails the exactly-one checks: see classify.md class G.
move_gate() {
  local ns=${1:-} want=${2:-} rep=${3:-} built out n nss parent expect r ok=0 pvcs rds wantrd
  _is_move_ns "$ns" || { echo "GATE: bad namespace [$ns]" >&2; return 1; }
  case "$want" in 0|1|2) ;; *) echo "GATE: want must be 0, 1 or 2" >&2; return 1;; esac
  case "$rep" in ""|zero|absent) ;; *) echo "GATE: replicas must be zero|absent" >&2; return 1;; esac
  if [ -n "$(GIT status --porcelain -- kubernetes)" ]; then echo "GATE FAIL: uncommitted changes under kubernetes — COMMIT first (the gate checks COMMITTED files)" >&2; return 1; fi
  if ! built=$(cd "$R" && flux build ks "$APP" -n "$ns" --path "./kubernetes/apps/$ns/$APP/app" \
        --kustomization-file "./kubernetes/apps/$ns/$APP/ks.yaml" --dry-run); then echo "GATE FAIL: app build failed" >&2; return 1; fi
  out=$(grep -n -E "volumeName|sourceNamespace" <<<"$built" || true); echo "$out"
  n=$(printf '%s\n' "$out" | grep -c . || true)
  [ "$n" -eq "$want" ] || { echo "GATE FAIL: $n volumeName/sourceNamespace lines, want $want" >&2; ok=1; }
  if [ "$want" -ge 1 ]; then   # M5: not just HOW MANY lines — the VALUES. Exactly one PVC pinned to $PV; (want 2) exactly one RD reading the series of $OLD.
    pvcs=$(yq -N 'select(.kind=="PersistentVolumeClaim")|.spec.volumeName // "NONE"' <<<"$built")
    [ "$(grep -c . <<<"$pvcs" || true)" -eq 1 ] && [ "$pvcs" = "$PV" ] || { echo "GATE FAIL: PersistentVolumeClaim volumeName(s) = [$(echo "$pvcs" | tr '\n' ' ')], want exactly one = $PV" >&2; ok=1; }
    rds=$(yq -N 'select(.kind=="ReplicationDestination")|.spec.kopia.sourceIdentity.sourceNamespace // "NONE"' <<<"$built")
    if [ "$want" -eq 2 ]; then wantrd=$OLD; else wantrd=NONE; fi
    [ "$(grep -c . <<<"$rds" || true)" -eq 1 ] && [ "$rds" = "$wantrd" ] || { echo "GATE FAIL: ReplicationDestination sourceNamespace(s) = [$(echo "$rds" | tr '\n' ' ')], want exactly one = $wantrd" >&2; ok=1; }
  fi
  nss=$(yq -N 'select(.kind)|.metadata.namespace // "NONE"' <<<"$built" | sort -u)
  [ "$nss" = "$ns" ] || { echo "GATE FAIL: namespaces in the app build = [$(echo "$nss" | tr '\n' ' ')], want only [$ns]" >&2; ok=1; }
  if [ -n "$rep" ]; then
    r=$(C="$CONTROLLER" yq -N 'select(.kind=="HelmRelease")|.spec.values.controllers[strenv(C)].replicas // "absent"' <<<"$built")
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

# --- bounded waits (every loop is bounded; a tool call dies at 600s) -----------------------------------------------------------------
# Loop audit: every wait is bounded by a SECONDS deadline (kubectl latency cannot stretch it): wait_manual <=50 x 10 s; wait_pv_phase <=150 x 3 s;
# wait_running <=100 x 5 s; data_check <=60 x 5 s + 60 s delete + 60 s pod check; pr_mergeable 1..12 x 5 s (w0b: two = 120 s); others_ready 3 x 20 s.
# wait_manual <ns> <rs> <tag> [tries=40]: wait (10s steps) until status.lastManualSync == <tag>. Returns 1 on timeout. (Necessary, NOT sufficient: trap 8.)
wait_manual() {
  local ns=${1:-} rs=${2:-} tag=${3:-} tries=${4:-40} end cur=""
  case "$tries" in ''|*[!0-9]*) echo "REFUSE: tries [$tries]" >&2; return 1;; esac
  [ "$tries" -ge 1 ] && [ "$tries" -le 50 ] || { echo "REFUSE: wait_manual tries $tries must be 1..50 (x 10 s, deadline-bound, under the 600 s tool limit)" >&2; return 1; }
  end=$((SECONDS + tries * 10))
  while :; do
    cur=$(kn "$ns" get replicationsource.volsync.backube "$rs" -o json | jq -r '.status.lastManualSync // ""') || return 1
    [ "$cur" = "$tag" ] && { echo "$rs lastManualSync=$tag"; return 0; }
    [ "$SECONDS" -ge "$end" ] && break; sleep 10
  done
  echo "TIMEOUT: $ns/$rs lastManualSync=[$cur] != $tag" >&2; return 1
}
# wait_pv_phase <pv> <phase> [tries=100]: wait (3s steps) for the move PV's phase; bounded.
wait_pv_phase() {
  local pv=${1:-} want=${2:-} tries=${3:-100} end cur=""
  case "$tries" in ''|*[!0-9]*) echo "REFUSE: tries [$tries]" >&2; return 1;; esac
  [ "$tries" -ge 1 ] && [ "$tries" -le 150 ] || { echo "REFUSE: wait_pv_phase tries $tries must be 1..150 (x 3 s, deadline-bound)" >&2; return 1; }
  pv_ok "$pv" >/dev/null || return 1
  end=$((SECONDS + tries * 3))
  while :; do
    cur=$(kubectl get pv "$pv" -o json | jq -r '.status.phase // ""') || return 1
    [ "$cur" = "$want" ] && { echo "$pv $want"; return 0; }
    [ "$SECONDS" -ge "$end" ] && break; sleep 3
  done
  echo "TIMEOUT: $pv phase=[$cur] != $want" >&2; return 1
}
# wait_running <ns> [tries=100]: wait (5s steps) for the app pod (label app.kubernetes.io/name=$APP) to be Running+Ready. <=110 iterations.
wait_running() {
  local ns=${1:-} tries=${2:-100} end r
  case "$tries" in ''|*[!0-9]*) echo "REFUSE: tries [$tries]" >&2; return 1;; esac
  [ "$tries" -ge 1 ] && [ "$tries" -le 100 ] || { echo "REFUSE: wait_running tries $tries must be 1..100 (x 5 s, deadline-bound, under the 600 s tool limit)" >&2; return 1; }
  end=$((SECONDS + tries * 5))
  while :; do
    r=$(kn "$ns" get pod -l app.kubernetes.io/name="$APP" -o json | jq -r '[.items[]|select(.status.phase=="Running" and ((.status.containerStatuses // [])|all(.ready)))]|length') || return 1
    [ "$r" -ge 1 ] && { echo "$APP Running in $ns"; return 0; }
    [ "$SECONDS" -ge "$end" ] && break; sleep 5
  done
  echo "TIMEOUT: no Running $APP pod in $ns" >&2; return 1
}
# background watchers: PIDs recorded so they can be killed
watch_start() { local name=$1; shift; "$@" > "$MOVE_DIR/$name.log" 2>&1 & echo $! > "$MOVE_DIR/watch-$name.pid"; echo "watching $name (pid $(cat "$MOVE_DIR/watch-$name.pid")) -> $MOVE_DIR/$name.log"; }
watch_stop_all() { local f; for f in "$MOVE_DIR"/watch-*.pid; do [ -f "$f" ] || continue; kill "$(cat "$f")" 2>/dev/null || true; rm -f "$f"; done; echo "watchers stopped"; }

# --- Alertmanager silences (CREATE ONLY WITH THE HUMAN'S GO-AHEAD; scoped to the app; auto-expire) ------------------------------------
# Refuses to run unless SILENCE_OK=yes is in the environment — the human's go-ahead, given per window.
# Matchers (Alertmanager fully anchors regexes; label names: VolSync series carry obj_namespace/obj_name, pods carry namespace/pod, Flux's provider
# labels carry namespace/name/kind/reason — verified on the rehearsal). Namespace is always $OLD|$NEW, so nothing outside the move can be muted:
#   1. obj_namespace=~OLD|NEW  AND obj_name=~APP-(local|r2|dst-local)   (VolSyncVolumeOutOfSync)
#   2. namespace=~OLD|NEW      AND name=~APP                                    (Flux error events for the app's Kustomization/HelmRelease/OCIRepository)
#   3. namespace=~OLD|NEW      AND pod=~_SIL_POD (see below)             (VolSyncMoverStuck, pod-level kube-prometheus alerts)
# am_open: refuses if something already listens on $AM_PORT (a STALE port-forward — possibly to another cluster — would receive the silences), logs the
# forward's stderr to $MOVE_DIR/am-pf.log instead of /dev/null, and refuses if the forward died. UNTESTED against a real Alertmanager.
am_open()  {
  if (exec 3<>"/dev/tcp/127.0.0.1/$AM_PORT") 2>/dev/null; then echo "REFUSE: 127.0.0.1:$AM_PORT is already in use (stale port-forward?) — not sending silences to an unknown listener" >&2; return 1; fi
  kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager "$AM_PORT":9093 >"$MOVE_DIR/am-pf.log" 2>&1 &
  echo $! > "$MOVE_DIR/am-pf.pid"; trap am_close EXIT; sleep 3
  kill -0 "$(cat "$MOVE_DIR/am-pf.pid")" 2>/dev/null || { echo "REFUSE: port-forward to alertmanager died: $(tail -3 "$MOVE_DIR/am-pf.log")" >&2; return 1; }
}
am_close() { if [ -f "$MOVE_DIR/am-pf.pid" ]; then kill "$(cat "$MOVE_DIR/am-pf.pid")" 2>/dev/null || true; rm -f "$MOVE_DIR/am-pf.pid"; fi; }
# am_post <start> <end> <label1> <regex1> <label2> <regex2>: one silence with two anchored regex matchers; the id is recorded for am_unsilence.
am_post() {
  local body id start=$1 end=$2
  body=$(jq -n --arg n1 "$3" --arg v1 "$4" --arg n2 "$5" --arg v2 "$6" --arg s "$start" --arg e "$end" --arg by "$APP-move" --arg c "$APP $OLD->$NEW move (auto-expires; removed by am_unsilence)" \
    '{matchers:[{name:$n1,value:$v1,isRegex:true,isEqual:true},{name:$n2,value:$v2,isRegex:true,isEqual:true}],startsAt:$s,endsAt:$e,createdBy:$by,comment:$c}')
  id=$(curl -fsS --retry 5 --retry-delay 1 --retry-connrefused -X POST -H 'Content-Type: application/json' -d "$body" "http://127.0.0.1:$AM_PORT/api/v2/silences" | jq -r '.silenceID')
  echo "$id" >> "$MOVE_SILENCES"; echo "silence $id  $3=~$4 & $5=~$6"
}
# Silence matchers are EXACT to this app's objects (m3): a sibling app called ${APP}-foo in OLD/NEW must not be muted. Alertmanager anchors regexes fully.
#   obj_name: the VolSync objects ${APP}-local / ${APP}-r2 / ${APP}-dst-local     name: the Flux objects named ${APP}
#   pod: the app's pods (${APP}-<rs-hash>-<pod> Deployment, ${APP}-<n> StatefulSet) and its VolSync mover pods (volsync-src|dst-${APP}-{local,r2,dst-local}[-<hash>]).
#   Residual: a sibling whose own name has exactly the shape ${APP}-<5-10 chars>-<5 chars> would still match the pod matcher.
_SIL_OBJ="$APP-(local|r2|dst-local)"; _SIL_NAME="$APP"
_SIL_POD="$APP-[a-z0-9]{5,10}-[a-z0-9]{5}|$APP-[0-9]+|volsync-(src|dst)-$APP-(local|r2|dst-local)(-[a-z0-9]+)?"
readonly _SIL_OBJ _SIL_NAME _SIL_POD
am_silence() {
  local start end hrs=${AM_HOURS:-3}
  [ "${SILENCE_OK:-}" = "yes" ] || { echo "REFUSE: silences need the human's go-ahead (SILENCE_OK=yes)" >&2; return 1; }
  _match "$hrs" "$_NUM" && [ "$hrs" -ge 1 ] && [ "$hrs" -le 6 ] || { echo "REFUSE: AM_HOURS [$hrs] must be 1..6" >&2; return 1; }
  start=$(date -u +%FT%TZ); end=$(date -u -v+"$hrs"H +%FT%TZ 2>/dev/null || date -u -d "+$hrs hours" +%FT%TZ)
  am_open || return 1
  am_post "$start" "$end" obj_namespace "$OLD|$NEW" obj_name "$_SIL_OBJ"
  am_post "$start" "$end" namespace "$OLD|$NEW" name "$_SIL_NAME"
  am_post "$start" "$end" namespace "$OLD|$NEW" pod "$_SIL_POD"
  am_close
}
am_unsilence() {
  local id; am_open || return 1
  while read -r id; do
    [ -n "$id" ] || continue
    curl -fsS --retry 5 --retry-delay 1 --retry-connrefused -X DELETE "http://127.0.0.1:$AM_PORT/api/v2/silence/$id" && echo "expired $id"
  done < "$MOVE_SILENCES"
  : > "$MOVE_SILENCES"; am_close
}
