#!/bin/bash
# pinfix-guards.sh — guards + helpers for the `ssa: IfNotPresent` volume-pin rehearsal on the throwaway app moveprobe2.
# Lives OUTSIDE every repo. Plan: hermes-to-ai:docs/rehearsal/pin-fix/plan.md
# Adapted from rehearsal-guards.sh (the first Flux-level rehearsal) and hermes-move-guards.sh (interlocks).
#
# USE: start EVERY command block with   source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
# and run it under /bin/bash directly:  /bin/bash <<'EOF' ... EOF
# NEVER `zsh -c`: a nested zsh re-reads ~/.zshenv, puts the real kubectl ahead of a fake, and once hit the live cluster.
# Written for bash 3.2 (/bin/bash on macOS): no mapfile, no associative arrays, no ${x,,}.
#
# DIFFERENCES FROM rehearsal-guards.sh (deliberate):
#   * APP is pinned to moveprobe2 and NOT read from the environment (kopia residue exists for moveprobe; moveprobe2 is fresh).
#   * State/paths are derived from THIS FILE's directory, never from the caller's environment.
#   * PVs are labelled rehearsal=pin and tracked in pinfix-state/, so a leftover rehearsal-state/ from the first rehearsal cannot collide.
#   * PUSH is pinned to rehearsal-pin:refs/heads/rehearsal-pin, and refuses a HEAD that pin_gate has not passed.
#   * The only PV mutators are pv_reclaim (Retain|Delete), pv_repoint (Released/Available -> rehearsal-new/moveprobe2, never a removal) and pv_delete.
#   * Mutating helpers need PIN_WINDOW=yes (set only inside a scenario block); pushing and Job/CR creation also need a recorded, unexpired silence.
#   * PIN_FAKE=1 (the test harness) refuses to run unless kubectl, flux AND curl are the harness fakes and KUBECONFIG is the harness's dead one.
# shellcheck disable=SC2119,SC2120,SC2016
# ^ SC2119/2120: PUSH and push_delete_branch deliberately take NO arguments and check $# to refuse any. SC2016: the single-quoted `${` and $(…) are LITERAL on purpose.
# PIN_POLL_* / PIN_AM_WAIT / PIN_POLL / FAKE_* below are TEST HOOKS (m9): they only shorten sleeps, every wait stays bounded and fails closed (a 0 s poll times out and
# the helper Job is deleted). They are documented, not removed; the plan never sets them.
set -euo pipefail

# --- interlocks, BEFORE anything talks to a cluster -----------------------------------------------------------------
if [ "${PIN_FAKE:-}" = 1 ]; then
  for _t in kubectl flux curl; do
    case "$(command -v "$_t" 2>/dev/null)" in */pinfix-guards-test/bin/"$_t") ;; *) echo "PIN_FAKE=1 but $_t is [$(command -v "$_t" 2>/dev/null)], not the harness fake — refusing" >&2; exit 1;; esac
  done
  case "${KUBECONFIG:-}" in */pinfix-guards-test/*|/private/tmp/*/gt-pin/*) ;; *) echo "PIN_FAKE=1 but KUBECONFIG=[${KUBECONFIG:-}] is not the harness's dead kubeconfig — refusing" >&2; exit 1;; esac
fi

# --- context: refuse to run against anything but the home cluster (exit, not return) --------------------------------
# Identify the cluster by its kube-system UID, not by context NAME (the same cluster is reachable as admin@home-kubernetes and over the tailnet).
[ "$(kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null)" = "793124f9-2b2e-4c9e-9fd0-41d27bd2d5a0" ] || { echo "WRONG CLUSTER (kube-system uid mismatch) — refusing" >&2; exit 1; }

# --- constants (derived from this file's location; NOT overridable from the environment) ------------------------------
GUARDS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pinfix-states.sh
source "$GUARDS_DIR/pinfix-states.sh"
export R="$GUARDS_DIR/rehearsal-pin"                                # the worktree holding branch rehearsal-pin
export BRANCH=rehearsal-pin
export APP=moveprobe2 OLD=rehearsal-old NEW=rehearsal-new           # pinned
export HERMES_PV=$PIN_HERMES_PV                                     # hermes' PV (now bound to ai/hermes): never touched
export PIN_DIR="$GUARDS_DIR/pinfix-state"
export PIN_PVS="$PIN_DIR/pins.txt"                                  # every rehearsal PV name, recorded when first seen
export PIN_SILENCES="$PIN_DIR/silences.txt"
export PIN_UNTIL="$PIN_DIR/silence-until.epoch"
export PIN_GATED="$PIN_DIR/gated-head.txt"                          # the HEAD sha pin_gate last PASSED; PUSH refuses anything else
export PIN_SESSION_URL="https://claude.ai/code/session_01AA9xxfsX3xSg8xher3SAKa"
mkdir -p "$PIN_DIR"; touch "$PIN_PVS" "$PIN_SILENCES"
export AM_PORT=19093
CHILD_PATH="./kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/app"

need_window() { [ "${PIN_WINDOW:-}" = yes ] || { echo "REFUSE: $1 needs PIN_WINDOW=yes (set only inside a scenario block)" >&2; return 1; }; }
# need_silence: an Alertmanager silence must be recorded AND not expired (am_silence writes both).
need_silence() {
  local u
  [ -s "$PIN_SILENCES" ] || { echo "REFUSE: $1 needs a recorded silence (am_silence first)" >&2; return 1; }
  u=$(cat "$PIN_UNTIL" 2>/dev/null || echo 0)
  [ "$(date +%s)" -lt "${u:-0}" ] || { echo "REFUSE: $1 — the recorded silence has expired (re-run am_silence)" >&2; return 1; }
}
on_branch() { [ "$(git -C "$R" branch --show-current 2>/dev/null)" = "$BRANCH" ] || { echo "REFUSE: $R is not on $BRANCH" >&2; return 1; }; }

# --- git: the ONLY way to commit/push in the rehearsal worktree ----------------------------------------------------
GIT() { git -C "$R" -c 'user.name=fizz-bot-bvn[bot]' -c 'user.email=324971095+fizz-bot-bvn[bot]@users.noreply.github.com' "$@"; }
# COMMIT "rehearsal-pin: <subject>" — scoped subject required; trailers Co-Authored-By + Claude-Session (the session that authored this rehearsal).
# NOTE: lefthook pre-commit (gitleaks + yamlfmt) may REWRITE staged YAML; pin_gate runs on the COMMITTED files afterwards.
COMMIT() {
  [ $# -eq 1 ] || { echo 'usage: COMMIT "rehearsal-pin: <subject>"' >&2; return 1; }
  on_branch || return 1
  case "$1" in rehearsal-pin:\ *) ;; *) echo "REFUSE: subject must start with 'rehearsal-pin: ' (scoped commit)" >&2; return 1;; esac
  GIT commit -m "$1" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"$'\n'"Claude-Session: $PIN_SESSION_URL"
}
# PUSH takes NO arguments; one hard-coded refspec; only a HEAD that pin_gate passed; window + silence required.
PUSH() {
  local head gated
  [ $# -eq 0 ] || { echo "PUSH takes no arguments — refusing" >&2; return 1; }
  need_window PUSH || return 1; need_silence PUSH || return 1; on_branch || return 1
  head=$(git -C "$R" rev-parse HEAD) || return 1
  gated=$(cat "$PIN_GATED" 2>/dev/null || true)
  [ "$head" = "$gated" ] || { echo "REFUSE: HEAD $head was not passed by pin_gate (last gated: [${gated:-none}])" >&2; return 1; }
  git -C "$R" push origin "$BRANCH:refs/heads/$BRANCH"
}
# push_delete_branch: teardown only. Deletes exactly origin/rehearsal-pin.
push_delete_branch() {
  [ $# -eq 0 ] || { echo "takes no arguments — refusing" >&2; return 1; }
  need_window push_delete_branch || return 1
  git -C "$R" push origin --delete "$BRANCH"
}

# --- namespaced kubectl: a verb + kind allow-list pinned to the two scratch namespaces (reusable: kn-guard.sh) ------------------
# NOT a plain `kubectl -n`: kubectl takes the LAST -n and cluster-scoped kinds ignore -n, so kn also refuses -n/--namespace/-A/--all-namespaces anywhere, every
# cluster-scoped or foreign kind (pv, ns, node, crd, *.longhorn.io, storageclass, volumesnapshotcontent, …) and any verb outside its list. See kn-guard.sh.
KN_NAMESPACES="rehearsal-old rehearsal-new"; KN_APPLY_KINDS="batch/v1/Job"
# shellcheck source=kn-guard.sh
source "$GUARDS_DIR/kn-guard.sh"
# fx: the ONLY flux CLI entry for cluster-facing verbs. Whitelist: reconcile source git rehearsal; reconcile/suspend/resume ks rehearsal-apps (flux-system);
# reconcile/suspend/resume ks|hr moveprobe2 (rehearsal-new). Read-only `get`/`build` pass through.
fx() {
  local verb=${1:-} a
  case "$verb" in
    get|build) flux "$@"; return ;;
    diff) # read-only server-side dry-run, moveprobe2 only (S6 probe)
      case "$*" in "diff ks moveprobe2 -n rehearsal-new "*|"diff kustomization moveprobe2 -n rehearsal-new "*) flux "$@"; return ;; esac
      echo "REFUSE: fx diff is only for ks moveprobe2 -n rehearsal-new" >&2; return 1 ;;
    reconcile|suspend|resume) need_window "fx $verb" || return 1; need_silence "fx $verb" || return 1 ;;
    *) echo "REFUSE: fx $verb" >&2; return 1 ;;
  esac
  a="$*"
  case "$a" in
    "reconcile source git rehearsal -n flux-system") ;;
    "$verb ks rehearsal-apps -n flux-system"|"reconcile ks rehearsal-apps -n flux-system --with-source") ;;
    "$verb ks moveprobe2 -n rehearsal-new"|"$verb hr moveprobe2 -n rehearsal-new"|"reconcile ks moveprobe2 -n rehearsal-new --with-source") ;;
    *) echo "REFUSE: fx $a is not on the whitelist" >&2; return 1 ;;
  esac
  flux "$@"
}

# --- PV bookkeeping and guards ---------------------------------------------------------------------------------------
# record_pv <ns> <pvc>: the PV bound to a PVC in a scratch namespace -> recorded in $PIN_PVS, labelled rehearsal=pin, name printed.
record_pv() {
  local ns=${1:-} pvc=${2:-} pv cn j
  case "$ns" in rehearsal-old|rehearsal-new) ;; *) echo "REFUSE ns=[$ns]" >&2; return 1;; esac
  if ! j=$(kn "$ns" get pvc "$pvc" -o json); then echo "cannot read PVC $ns/$pvc" >&2; return 1; fi
  pv=$(jq -r '.spec.volumeName // ""' <<<"$j") || return 1
  [ -n "$pv" ] || { echo "PVC $ns/$pvc has no volume yet" >&2; return 1; }
  [ "$pv" != "$HERMES_PV" ] || { echo "REFUSE: hermes PV" >&2; return 1; }
  cn=$(kubectl get pv "$pv" -o json | jq -r '.spec.claimRef.namespace // ""') || return 1
  [ "$cn" = "$ns" ] || { echo "REFUSE: $pv claimRef ns=[$cn] != $ns" >&2; return 1; }
  grep -qx "$pv" "$PIN_PVS" || echo "$pv" >> "$PIN_PVS"
  kubectl label pv "$pv" rehearsal=pin --overwrite >/dev/null
  echo "$pv"
}
# adopt_pv <pv>: teardown enumeration ONLY — records a PV whose claimRef namespace is rehearsal-*.
adopt_pv() {
  local pv=${1:-} cn
  [ -n "$pv" ] && [ "$pv" != "$HERMES_PV" ] || { echo "REFUSE: empty or hermes PV" >&2; return 1; }
  cn=$(kubectl get pv "$pv" -o json | jq -r '.spec.claimRef.namespace // ""') || return 1
  case "$cn" in rehearsal-old|rehearsal-new) ;; *) echo "REFUSE adopt: $pv claimRef ns=[$cn]" >&2; return 1;; esac
  grep -qx "$pv" "$PIN_PVS" || echo "$pv" >> "$PIN_PVS"
  kubectl label pv "$pv" rehearsal=pin --overwrite >/dev/null
}
# rehearsal_pv_ok <pv>: run before EVERY PV mutation. Requires: not hermes, in $PIN_PVS, labelled rehearsal=pin, claimRef namespace rehearsal-* (an empty claimRef is refused). A READ ERROR is a REFUSAL; "gone:" is printed ONLY on a confirmed empty --ignore-not-found read.
# (errexit is DISABLED inside functions called in && / || lists, so every check is explicit.)
rehearsal_pv_ok() {
  local pv=${1:-} out j cn lbl
  if [ -z "$pv" ] || [ "$pv" = "$HERMES_PV" ]; then echo "REFUSE: empty or hermes PV" >&2; return 1; fi
  if ! grep -qx "$pv" "$PIN_PVS"; then echo "REFUSE: $pv not in $PIN_PVS" >&2; return 1; fi
  if ! out=$(kubectl get pv "$pv" --ignore-not-found -o name); then echo "REFUSE: cannot read PV $pv (API error)" >&2; return 1; fi
  if [ -z "$out" ]; then echo "gone: $pv"; return 0; fi
  if ! j=$(kubectl get pv "$pv" -o json); then echo "REFUSE: cannot read PV $pv (API error)" >&2; return 1; fi
  if ! lbl=$(jq -r '.metadata.labels.rehearsal // ""' <<<"$j"); then return 1; fi
  if [ "$lbl" != "pin" ]; then echo "REFUSE: $pv lacks label rehearsal=pin" >&2; return 1; fi
  if ! cn=$(jq -r '.spec.claimRef.namespace // ""' <<<"$j"); then return 1; fi
  # An EMPTY claimRef is REFUSED (m8): that is the R-5 "any matching claim takes it" state, and no step of this plan needs it (re-point only).
  case "$cn" in rehearsal-old|rehearsal-new) ;; *) echo "REFUSE: $pv claimRef ns=[$cn] (must be rehearsal-*; empty is refused)" >&2; return 1;; esac
  echo "ok $pv (claim ns=[$cn])"
}
# pv_reclaim <pv> Retain|Delete: the ONLY patch this rehearsal ever makes to a PV. Delete RE-ARMS the loss of PV + Longhorn volume (~19 s).
pv_reclaim() {
  local pv=${1:-} pol=${2:-} ph
  need_window pv_reclaim || return 1
  case "$pol" in Retain|Delete) ;; *) echo "REFUSE: reclaim policy [$pol] must be Retain or Delete" >&2; return 1;; esac
  rehearsal_pv_ok "$pv" >/dev/null || return 1
  if [ "$pol" = Delete ]; then
    # m1: a Released/Available PV flipped to Delete is reclaimed AT ONCE (PV + Longhorn volume). Only a Bound PV may be flipped. Teardown uses pv_delete for the rest.
    if ! ph=$(kubectl get pv "$pv" -o json | jq -r '.status.phase // ""'); then echo "REFUSE: cannot read PV $pv" >&2; return 1; fi
    [ "$ph" = Bound ] || { echo "REFUSE: Delete needs the PV Bound, $pv is [$ph] — a $ph PV set to Delete is reclaimed at once (use pv_delete at teardown)" >&2; return 1; }
  fi
  kubectl patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"'"$pol"'"}}' || return 1
  kubectl get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
}
# pv_repoint <pv>: reserve a Released/Available PV for rehearsal-new/moveprobe2 (uid/resourceVersion null) — NEVER remove claimRef (any matching claim would take it [R-5]).
# The claim is fixed (this rehearsal has exactly one app), and a Bound PV is refused: re-pointing a bound PV is never wanted.
pv_repoint() {
  local pv=${1:-} ph
  need_window pv_repoint || return 1
  rehearsal_pv_ok "$pv" >/dev/null || return 1
  if ! ph=$(kubectl get pv "$pv" -o json | jq -r '.status.phase // ""'); then echo "REFUSE: cannot read PV $pv" >&2; return 1; fi
  case "$ph" in Released|Available) ;; *) echo "REFUSE: PV $pv is [$ph]; only Released/Available may be re-pointed" >&2; return 1;; esac
  kubectl patch pv "$pv" --type merge -p '{"spec":{"claimRef":{"namespace":"'"$NEW"'","name":"'"$APP"'","uid":null,"resourceVersion":null}}}'
}
# pv_delete <pv>: teardown. The Longhorn volume is deleted ONLY after the PV is confirmed gone (delete succeeded and a --ignore-not-found read is empty).
pv_delete() {
  local pv=${1:-} st out
  need_window pv_delete || return 1
  if ! st=$(rehearsal_pv_ok "$pv"); then return 1; fi
  case "$st" in
    gone:*) : ;;
    *)
      if ! kubectl delete pv "$pv" --ignore-not-found --timeout=240s; then echo "pv delete failed — NOT deleting the Longhorn volume" >&2; return 1; fi
      if ! out=$(kubectl get pv "$pv" --ignore-not-found -o name); then echo "cannot confirm PV gone — NOT deleting the Longhorn volume" >&2; return 1; fi
      if [ -n "$out" ]; then echo "PV $pv still present — NOT deleting the Longhorn volume" >&2; return 1; fi ;;
  esac
  kubectl -n longhorn-system delete volumes.longhorn.io "$pv" --ignore-not-found
}
# app_pv: the PV of $APP's PVC, RE-READ from spec.volumeName on EVERY call — never cached [Rh-B2]. Records + labels it on first sight.
app_pv() {
  local pv v
  v=$(kubectl -n "$NEW" get pvc "$APP" -o json 2>/dev/null | jq -r '.spec.volumeName // ""' || true)
  pv=$v
  [ -n "$pv" ] || { echo "no PVC $APP with a volumeName in $NEW right now (deliberately NO cached fallback)" >&2; return 1; }
  if ! grep -qx "$pv" "$PIN_PVS"; then record_pv "$NEW" "$APP" >/dev/null || { echo "cannot record $pv" >&2; return 1; }; fi
  rehearsal_pv_ok "$pv" >/dev/null || return 1
  echo "$pv"
}

# --- the two states the scenarios edit ---------------------------------------------------------------------------------
# live_pv: the volumeName of the app's live claim, or empty when there is none (never an error).
live_pv() { kubectl -n "$NEW" get pvc "$APP" -o json 2>/dev/null | jq -r '.spec.volumeName // ""' || true; }
# s1_pv <pv-or-empty>: the PV an s1 (pinned) state may name. With a live claim: exactly that claim's PV. With NO live claim (the real-shape S1 deletes it first):
# the caller must pass a PV that is recorded, labelled, and waiting for its claim (Released/Available). Prints the PV.
s1_pv() {
  local pv=${1:-} live ph
  live=$(live_pv)
  if [ -n "$live" ]; then
    [ -n "$pv" ] || pv=$live
    [ "$pv" = "$live" ] || { echo "REFUSE: s1 must pin the LIVE bound PV [$live], not [$pv]" >&2; return 1; }
  else
    [ -n "$pv" ] || { echo "REFUSE: no live claim — pass the retained PV explicitly" >&2; return 1; }
    rehearsal_pv_ok "$pv" >/dev/null || return 1
    if ! ph=$(kubectl get pv "$pv" -o json | jq -r '.status.phase // ""'); then echo "REFUSE: cannot read PV $pv" >&2; return 1; fi
    case "$ph" in Released|Available) ;; *) echo "REFUSE: with no live claim the PV must be Released/Available, [$pv] is [$ph]" >&2; return 1;; esac
  fi
  echo "$pv"
}
# pin_state <state> [pv]: write moveprobe2's app/kustomization.yaml (+ VOLSYNC_CAPACITY) for a state. s1 pins the LIVE bound PV (re-read; a different one is refused),
# or — when the claim has been deleted on purpose (S1) — the recorded, Retained, Released PV you pass.
pin_state() {
  local st=${1:-} pv=${2:-}
  on_branch || return 1
  pin_state_ok "$st" || { echo "REFUSE: unknown state [$st]" >&2; return 1; }
  if [ "$st" = s1 ]; then pv=$(s1_pv "$pv") || return 1; fi
  PIN_REPO=$R pin_write "$st" "$pv"
}
# pin_gate <state> [pv]: run AFTER COMMIT (lefthook/yamlfmt may have rewritten files), BEFORE PUSH. ALL of:
#   1. on rehearsal-pin; the WHOLE kubernetes/rehearsal-pin{,-bootstrap} trees committed;
#   2. the COMMITTED app kustomization carries `# STATE: <state> ` and the committed ks.yaml carries that state's VOLSYNC_CAPACITY;
#   3. the app build has: volumeName lines (s1:1, fix-vn:1, else 0), sourceNamespace (s1:1 else 0), `ssa: IfNotPresent` (fix*:1 else 0),
#      `prune: disabled` (fixprune:1 else 0); the PVC storage == the state's capacity; for s1 the built volumeName == the live PV (or the retained, Released PV passed in);
#   4. EVERY metadata.namespace in the app build is rehearsal-new;
#   5. the PARENT build has exactly ONE child Kustomization named moveprobe2 == "rehearsal-new moveprobe2 <CHILD_PATH> rehearsal-new", and no child in rehearsal-old.
# On PASS writes HEAD's sha to $PIN_GATED (PUSH refuses any other HEAD).
pin_gate() {
  local st=${1:-} pv=${2:-} built out nv ns_s parent expect ok=0 wv=0 ws=0 wa=0 wp=0 head cap got
  on_branch || return 1
  pin_state_ok "$st" || { echo "GATE: unknown state [$st]" >&2; return 1; }
  cap=$(pin_cap "$st") || return 1
  case "$st" in s1) wv=1; ws=1;; fix-vn) wv=1;; esac
  case "$st" in fix|fix-cap2|fix-meta|fix-vn|fixprune) wa=1;; esac
  [ "$st" = fixprune ] && wp=1
  if [ -n "$(GIT status --porcelain -- kubernetes/rehearsal-pin kubernetes/rehearsal-pin-bootstrap)" ]; then echo "GATE FAIL: uncommitted changes under kubernetes/rehearsal-pin* — COMMIT first (the gate checks COMMITTED files)" >&2; return 1; fi
  git -C "$R" show "HEAD:kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/app/kustomization.yaml" | grep -q "^# STATE: $st " || { echo "GATE FAIL: committed app kustomization is not state [$st]" >&2; ok=1; }
  git -C "$R" show "HEAD:kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/ks.yaml" | grep -q "VOLSYNC_CAPACITY: $cap\$" || { echo "GATE FAIL: committed ks.yaml VOLSYNC_CAPACITY != $cap" >&2; ok=1; }
  if ! built=$(cd "$R" && flux build ks "$APP" -n "$NEW" --path "$CHILD_PATH" --kustomization-file ./kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/ks.yaml --dry-run); then echo "GATE FAIL: app build failed" >&2; return 1; fi
  out=$(grep -n -E "volumeName|sourceNamespace" <<<"$built" || true); echo "$out"
  nv=$(grep -c volumeName <<<"$built" || true); [ "$nv" -eq "$wv" ] || { echo "GATE FAIL: $nv volumeName lines, want $wv" >&2; ok=1; }
  nv=$(grep -c sourceNamespace <<<"$built" || true); [ "$nv" -eq "$ws" ] || { echo "GATE FAIL: $nv sourceNamespace lines, want $ws" >&2; ok=1; }
  nv=$(grep -c 'kustomize.toolkit.fluxcd.io/ssa: IfNotPresent' <<<"$built" || true); [ "$nv" -eq "$wa" ] || { echo "GATE FAIL: $nv ssa IfNotPresent annotations, want $wa" >&2; ok=1; }
  nv=$(grep -c 'kustomize.toolkit.fluxcd.io/prune: disabled' <<<"$built" || true); [ "$nv" -eq "$wp" ] || { echo "GATE FAIL: $nv prune:disabled annotations, want $wp" >&2; ok=1; }
  got=$(yq -N 'select(.kind=="PersistentVolumeClaim")|.spec.resources.requests.storage' <<<"$built")
  [ "$got" = "$cap" ] || { echo "GATE FAIL: built PVC storage [$got] != $cap" >&2; ok=1; }
  if [ "$st" = s1 ]; then
    pv=$(s1_pv "$pv") || return 1
    got=$(yq -N 'select(.kind=="PersistentVolumeClaim")|.spec.volumeName' <<<"$built")
    [ "$got" = "$pv" ] || { echo "GATE FAIL: built volumeName [$got] != live PV [$pv]" >&2; ok=1; }
  fi
  ns_s=$(yq -N 'select(.kind)|.metadata.namespace // "NONE"' <<<"$built" | sort -u)
  [ "$ns_s" = "$NEW" ] || { echo "GATE FAIL: namespaces in the app build = [$(echo "$ns_s" | tr '\n' ' ')], want only [$NEW]" >&2; ok=1; }
  if ! parent=$(cd "$R" && flux build ks rehearsal-apps -n flux-system --path ./kubernetes/rehearsal-pin \
        --kustomization-file ./kubernetes/rehearsal-pin-bootstrap/rehearsal-apps.yaml --dry-run \
        | yq -N 'select(.kind=="Kustomization")|[.metadata.namespace,.metadata.name,.spec.path,.spec.targetNamespace]|join(" ")'); then
    echo "GATE FAIL: parent build failed" >&2; return 1; fi
  echo "parent children: $(grep -c . <<<"$parent" || true)"; grep -F " $APP " <<<"$parent" || true
  expect="$NEW $APP $CHILD_PATH $NEW"
  [ "$(grep -c -F " $APP " <<<"$parent" || true)" -eq 1 ] || { echo "GATE FAIL: need exactly ONE child Kustomization named $APP" >&2; ok=1; }
  grep -qxF "$expect" <<<"$parent" || { echo "GATE FAIL: parent child != [$expect]" >&2; ok=1; }
  if [ "$ok" -eq 0 ]; then head=$(git -C "$R" rev-parse HEAD) && echo "$head" > "$PIN_GATED" && echo "GATE PASS ($st) $head"; return 0; fi
  rm -f "$PIN_GATED"; echo "GATE FAIL — DO NOT PUSH" >&2; return 1
}

# no_consumers: FAIL if ANY pod in rehearsal-new (Completed and Job pods included) references the app claim — it would hold pvc-protection (trap 3) and block the
# claim's deletion. Run it before deleting the claim (S1-B, S4-B); a printed list is not a check.
no_consumers() {
  local j left
  if ! j=$(kn "$NEW" get pod -o json); then echo "REFUSE: cannot list pods" >&2; return 1; fi
  left=$(jq -r --arg c "$APP" '.items[]|select(.spec.volumes[]?.persistentVolumeClaim.claimName==$c)|.metadata.name' <<<"$j") || return 1
  [ -z "$left" ] || { echo "REFUSE: pod(s) still reference claim $APP: $(echo "$left" | tr '\n' ' ')" >&2; return 1; }
  echo "no pod references $APP"
}

# --- assertions --------------------------------------------------------------------------------------------------------
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
# others_ready: every Kustomization outside rehearsal-* (and rehearsal-apps) must be Ready. Ready=False fails at once; otherwise not-True must persist 3 polls,
# 20 s apart (a push fires the Receiver, which reconciles cluster-apps: a transient Ready=Unknown is noise).
others_ready() {
  local i bad falsy
  for i in 1 2 3; do
    falsy=$(kubectl get ks -A -o json | jq -r '.items[]|select((.metadata.namespace|test("^rehearsal-"))|not)|select(.metadata.name!="rehearsal-apps")
            |select(((.status.conditions // [])|map(select(.type=="Ready"))|.[0].status // "Unknown")=="False")|"\(.metadata.namespace)/\(.metadata.name)"') || return 1
    [ -z "$falsy" ] || { echo "READY=False: $falsy" >&2; return 1; }
    bad=$(kubectl get ks -A -o json | jq -r '.items[]|select((.metadata.namespace|test("^rehearsal-"))|not)|select(.metadata.name!="rehearsal-apps")
            |select(((.status.conditions // [])|map(select(.type=="Ready"))|.[0].status // "Unknown")!="True")|"\(.metadata.namespace)/\(.metadata.name)"') || return 1
    [ -z "$bad" ] && { echo "all other ks Ready"; return 0; }
    echo "poll $i/3: not yet Ready: $bad" >&2; [ "$i" -lt 3 ] && sleep "${PIN_POLL:-20}"
  done
  echo "NOT READY after 3 polls: $bad" >&2; return 1
}
# hermes_snapshot / hermes_same: READ-ONLY (only `get`). The real hermes now lives in `ai`; the rehearsal must never move it. Records uid|volumeName|phase of the
# ai/hermes CLAIM and compares later. The PV's phase/reclaim are deliberately NOT compared (m7): hermes' own B10 (Retain -> Delete) or B11 cleanup may land during
# the ~6 h window and must not cause a false ABORT. Not a kn call on purpose: kn refuses `ai`.
hermes_snapshot() {
  kubectl -n ai get pvc hermes -o json | jq -r '[.metadata.uid,.spec.volumeName,.status.phase]|join("|")'
}
# hermes_owners: who owns which field on the REAL ai/hermes claim, canonical form (read-only). Recorded at P0 and re-compared right before the hermes cleanup PR (m10).
hermes_owners() {
  kubectl -n ai get pvc hermes --show-managed-fields -o json | jq -c '[.metadata.managedFields[]|{m:.manager,op:.operation,sub:(.subresource // null),spec:((.fieldsV1["f:spec"] // {})|keys),meta:((.fieldsV1["f:metadata"] // {})|keys)}]|sort_by(.m,.op,(.sub // ""))'
}
hermes_same() {
  local want=${1:-} now
  [ -n "$want" ] || { echo 'usage: hermes_same "<snapshot>"' >&2; return 1; }
  now=$(hermes_snapshot) || return 1
  [ "$now" = "$want" ] && { echo "hermes untouched: $now"; return 0; }
  echo "HERMES CHANGED: was [$want] now [$now]" >&2; return 1
}
# preflight_clean: nothing from ANY earlier rehearsal may exist (namespaces, Flux CRs, labelled PVs, the remote branch).
preflight_clean() {
  local n f p b rc=0
  n=$(kubectl get ns --no-headers 2>/dev/null | grep '^rehearsal-' || true); [ -z "$n" ] || { echo "LEFTOVER namespaces: $n" >&2; rc=1; }
  f=$(kubectl -n flux-system get ks,gitrepository --no-headers 2>/dev/null | grep -E 'rehearsal' || true); [ -z "$f" ] || { echo "LEFTOVER flux objects: $f" >&2; rc=1; }
  p=$(kubectl get pv -o json | jq -r '.items[]|select(((.spec.claimRef.namespace // "")|test("^rehearsal-"))or((.metadata.labels.rehearsal // "")!=""))|.metadata.name') || return 1
  [ -z "$p" ] || { echo "LEFTOVER PVs: $p" >&2; rc=1; }
  # FAIL CLOSED: an unreadable remote (no worktree, network, auth) is NOT "no branch".
  if ! b=$(git -C "$R" ls-remote --heads origin "$BRANCH" 2>/dev/null); then echo "cannot read the remote branch state from $R — run: git ls-remote --heads origin $BRANCH" >&2; rc=1
  elif [ -n "$b" ]; then echo "LEFTOVER remote branch: $b" >&2; rc=1; fi
  [ "$rc" -eq 0 ] && echo "preflight clean"; return "$rc"
}
# pvc_state: one-line JSON of the live claim: uid, volumeName, requested/actual storage, storageClassName, the annotations/labels that matter, and WHO OWNS WHICH FIELD.
pvc_state() {
  kubectl -n "$NEW" get pvc "$APP" --show-managed-fields -o json | jq -c '{uid:.metadata.uid,phase:.status.phase,volumeName:.spec.volumeName,
    req:.spec.resources.requests.storage,cap:.status.capacity.storage,sc:.spec.storageClassName,
    ssa:(.metadata.annotations["kustomize.toolkit.fluxcd.io/ssa"] // null),prune:(.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"] // null),
    probeAnn:(.metadata.annotations["pin-probe"] // null),probeLbl:(.metadata.labels["pin-probe"] // null),
    owners:([.metadata.managedFields[]|{m:.manager,op:.operation,sub:(.subresource // null),spec:((.fieldsV1["f:spec"] // {})|keys),meta:((.fieldsV1["f:metadata"] // {})|keys)}]|sort_by(.m,.op,(.sub // "")))}'
}
# s1_equiv: the S1 EQUIVALENCE CHECK. Compares WHO OWNS WHICH FIELD on the rehearsal claim with the REAL post-move ai/hermes claim (read-only `get`; kn refuses ai on
# purpose). Equal ⇒ the rehearsal reached the same server-side-apply state as the real move (Flux Apply owns volumeName; kube-controller-manager owns only annotations).
# A claim that was dynamically provisioned and pinned afterwards differs: kube-controller-manager (Update) then ALSO owns f:volumeName.
s1_equiv() {
  local a b
  a=$(pvc_state | jq -c '.owners') || return 1
  b=$(hermes_owners) || return 1
  if [ "$a" = "$b" ]; then echo "owners EQUAL to ai/hermes: $a"; return 0; fi
  echo "owners DIFFER from ai/hermes" >&2; echo "  rehearsal: $a" >&2; echo "  hermes   : $b" >&2; return 1
}
pvc_uid() { kubectl -n "$NEW" get pvc "$APP" -o json | jq -r '.metadata.uid'; }
# ks_report: Ready condition + attempted/applied revision of the child Kustomization (one line).
ks_report() {
  kubectl -n "$NEW" get ks "$APP" -o json | jq -r '"Ready=\((.status.conditions // [])|map(select(.type=="Ready"))|.[0]|(.status // "?")+" "+(.reason // "")) attempted=\(.status.lastAttemptedRevision // "-") applied=\(.status.lastAppliedRevision // "-") msg=\((.status.conditions // [])|map(select(.type=="Ready"))|.[0].message // "" | .[0:400])"'
}
# wait_ks_outcome <sha> [tries=60]: bounded (5 s steps). Waits until the child Kustomization has ATTEMPTED revision <sha> and is settled:
#   returns 0 = Ready=True at <sha> (applied), 2 = Ready=False at <sha> (STALL — read ks_report), 1 = timeout.
wait_ks_outcome() {
  local sha=${1:-} tries=${2:-60} i r
  case "$sha" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *) echo "usage: wait_ks_outcome <sha> [tries]" >&2; return 1;; esac
  for i in $(seq 1 "$tries"); do
    r=$(kubectl -n "$NEW" get ks "$APP" -o json | jq -r --arg s "$sha" '
      (.status.lastAttemptedRevision // "") as $a | ((.status.conditions // [])|map(select(.type=="Ready"))|.[0].status // "Unknown") as $r
      | if ($a|endswith($s)) and $r=="True" then "ok" elif ($a|endswith($s)) and $r=="False" then "stall" else "wait" end') || return 1
    case "$r" in ok) echo "ks settled Ready=True at $sha"; return 0;; stall) echo "ks Ready=False at $sha"; return 2;; esac
    sleep "${PIN_POLL_S:-5}"
  done
  echo "TIMEOUT waiting for ks at $sha: $(ks_report)" >&2; return 1
}
# push_and_reconcile: after a passed gate: PUSH, then source + child reconcile (whitelisted), then wait for the outcome at the pushed sha. Returns wait_ks_outcome's code.
push_and_reconcile() {
  local sha rc=0
  sha=$(git -C "$R" rev-parse HEAD) || return 1
  PUSH || return 1
  fx reconcile source git rehearsal -n flux-system || true
  fx reconcile ks moveprobe2 -n rehearsal-new || true
  wait_ks_outcome "$sha" || rc=$?
  ks_report; return "$rc"
}

# check_backup <ns> <replicationsource> <identity>: the R-3 acceptance rule. Non-zero on any miss.
check_backup() {
  local L c s o e rc=0
  L=$(kn "$1" get replicationsource.volsync.backube "$2" -o json | jq -r '.status.latestMoverStatus.logs // ""')
  c=$(grep -c 'Created snapshot with root' <<<"$L" || true); s=$(grep -cF "Setting policy for $3:/data" <<<"$L" || true)
  o=$(grep -cF 'OPERATION_RESULT: SUCCESS' <<<"$L" || true); e=$(grep -c 'Directory is empty' <<<"$L" || true)
  echo "Created snapshot: $c (>=1)  Setting policy $3: $s (>=1)  RESULT SUCCESS: $o (>=1)  Directory is empty: $e (0)"
  { [ "$c" -ge 1 ] && [ "$s" -ge 1 ] && [ "$o" -ge 1 ] && [ "$e" -eq 0 ]; } || { echo "check_backup FAILED for $1/$2" >&2; rc=1; }
  return $rc
}
# wait_manual <ns> <rs> <tag> [tries=50]: wait (10 s steps) until status.lastManualSync == <tag>. Returns 1 on timeout.
wait_manual() {
  local ns=$1 rs=$2 tag=$3 tries=${4:-50} i cur=""
  for i in $(seq 1 "$tries"); do
    cur=$(kn "$ns" get replicationsource.volsync.backube "$rs" -o json | jq -r '.status.lastManualSync // ""') || return 1
    [ "$cur" = "$tag" ] && { echo "$rs lastManualSync=$tag"; return 0; }
    sleep "${PIN_POLL_M:-10}"
  done
  echo "TIMEOUT: $ns/$rs lastManualSync=[$cur] != $tag" >&2; return 1
}
# slot_clear [minutes-needed=0]: refuse if NOW, or the next <minutes-needed> minutes, overlap a scheduled slot — UTC :45-:49 (local RS :47) and, in hour 06, 06:43-06:47
# (r2 06:45). Run it before anything that removes or swaps the PVC; give S3a a look-ahead (it leaves the RS/RD at 2Gi over a 1Gi claim until S3d).
slot_clear() {
  local mm hh need=${1:-0}
  case "$need" in ''|*[!0-9]*) echo "REFUSE: slot_clear look-ahead [$need] must be a number of minutes" >&2; return 1;; esac
  mm=$(date -u +%M); hh=$(date -u +%H); mm=$((10#$mm)); hh=$((10#$hh))
  if [ "$mm" -le 49 ] && [ $((mm + need)) -ge 45 ]; then echo "REFUSE: :$mm (+${need} min) overlaps the local RS slot (:45-:49) — wait" >&2; return 1; fi
  if [ "$hh" -eq 6 ] && [ "$mm" -le 47 ] && [ $((mm + need)) -ge 43 ]; then echo "REFUSE: 06:$mm (+${need} min) overlaps the r2 slot (06:43-06:47)" >&2; return 1; fi
  return 0
}
# backup_now <tag>: forced backup of BOTH sources under the CURRENT series, gated against the scheduled slots and in-flight syncs (trap 8 [R-4]).
# Refuses inside the scheduled slots (slot_clear); refuses if a sync is in flight (lastSyncStartTime set); waits; then check_backup.
backup_now() {
  local tag=${1:-} rs T0 lst rc=0
  need_window backup_now || return 1; need_silence backup_now || return 1
  case "$tag" in pin-*) ;; *) echo "REFUSE: tag must start with pin-" >&2; return 1;; esac
  slot_clear || return 1
  for rs in "$APP-local" "$APP-r2"; do
    lst=$(kn "$NEW" get replicationsource.volsync.backube "$rs" -o json | jq -r '.status.lastSyncStartTime // ""') || return 1
    [ -z "$lst" ] || { echo "REFUSE: $rs has a sync in flight (lastSyncStartTime=$lst) — a scheduled sync would stamp the tag; wait" >&2; return 1; }
  done
  T0=$(date -u +%FT%TZ)
  for rs in "$APP-local" "$APP-r2"; do kn "$NEW" patch replicationsource.volsync.backube "$rs" --type merge -p '{"spec":{"trigger":{"manual":"'"$tag"'"}}}' >/dev/null || return 1; done
  # NOT wait_manual: the child Kustomization (5 min interval) strips a hand-patched trigger.manual [Rh-7] — observed again live — so lastManualSync may NEVER equal the tag
  # even though the sync ran and succeeded. The criterion is: no sync in flight AND lastSyncTime > T0 (slot_clear + the pre-flight in-flight gate make that sync ours).
  for rs in "$APP-local" "$APP-r2"; do wait_synced "$rs" "$T0" || rc=1; done
  [ "$rc" -eq 0 ] || { echo "manual backup did not complete — do NOT accept it" >&2; return 1; }
  for rs in "$APP-local" "$APP-r2"; do
    lst=$(kn "$NEW" get replicationsource.volsync.backube "$rs" -o json | jq -r '.status.lastSyncTime // ""') || return 1
    [[ "$lst" > "$T0" ]] || { echo "$rs STALE: lastSyncTime $lst <= T0 $T0" >&2; rc=1; }
    check_backup "$NEW" "$rs" "$APP@$NEW" || rc=1
  done
  return $rc
}
# wait_synced <rs> <T0> [tries=50]: wait (10 s steps) until the RS has NO sync in flight (lastSyncStartTime empty) and lastSyncTime > <T0>. Returns 1 on timeout.
wait_synced() {
  local rs=$1 t0=$2 tries=${3:-50} i j st lst=""
  for i in $(seq 1 "$tries"); do
    j=$(kn "$NEW" get replicationsource.volsync.backube "$rs" -o json) || return 1
    st=$(jq -r '.status.lastSyncStartTime // ""' <<<"$j") || return 1; lst=$(jq -r '.status.lastSyncTime // ""' <<<"$j") || return 1
    if [ -z "$st" ] && [[ "$lst" > "$t0" ]]; then echo "$rs synced at $lst (> $t0)"; return 0; fi
    sleep "${PIN_POLL_M:-10}"
  done
  echo "TIMEOUT: $NEW/$rs lastSyncTime=[$lst] not > $t0 (or a sync is still in flight)" >&2; return 1
}
# wait_pv_phase <pv> <phase> [tries=100]: wait (3 s steps) for a PV phase; bounded.
wait_pv_phase() {
  local pv=$1 want=$2 tries=${3:-100} i cur=""
  rehearsal_pv_ok "$pv" >/dev/null || return 1
  for i in $(seq 1 "$tries"); do
    cur=$(kubectl get pv "$pv" -o json | jq -r '.status.phase // ""') || return 1
    [ "$cur" = "$want" ] && { echo "$pv $want"; return 0; }
    sleep "${PIN_POLL_P:-3}"
  done
  echo "TIMEOUT: $pv phase=[$cur] != $want" >&2; return 1
}
# wait_running <ns> [tries=60]: wait (5 s steps) for the app pod to be Running+Ready.
wait_running() {
  local ns=$1 tries=${2:-60} i r
  for i in $(seq 1 "$tries"); do
    r=$(kn "$ns" get pod -l app.kubernetes.io/name="$APP" -o json | jq -r '[.items[]|select(.status.phase=="Running" and ((.status.containerStatuses // [])|all(.ready)))]|length') || return 1
    [ "$r" -ge 1 ] && { echo "$APP Running in $ns"; return 0; }
    sleep "${PIN_POLL_R:-5}"
  done
  echo "TIMEOUT: no Running $APP pod in $ns" >&2; return 1
}
# ro_run <pvc> "<shell command>": read-only uid-0 Job on a PVC in rehearsal-new (a restored tree may be root-owned). Runs the command in /data, pinned to the node
# of any pod that already mounts <pvc> (RWO), waits for succeeded OR failed, ALWAYS prints logs, always deletes the Job (a Completed pod blocks PVC deletion).
# Refuses unless the PVC exists and is Bound. Keep <shell command> free of a leading `cd` and of newlines.
ro_run() {
  local pvc=${1:-} cmd=${2:-} j node st="" i phase left
  need_window ro_run || return 1; need_silence ro_run || return 1
  case "$pvc" in "$APP"|volsync-"$APP"-dst-local-dest) ;; *) echo "REFUSE: pvc [$pvc] is not a $APP claim" >&2; return 1;; esac
  phase=$(kn "$NEW" get pvc "$pvc" -o json 2>/dev/null | jq -r '.status.phase // ""' || true)
  [ "$phase" = Bound ] || { echo "REFUSE: PVC $NEW/$pvc is [${phase:-absent}], not Bound — no Job created" >&2; return 1; }
  j="ro-$(date +%s)"
  node=$(kn "$NEW" get pod -o json | jq -r --arg c "$pvc" '[.items[]|select(.spec.volumes[]?.persistentVolumeClaim.claimName==$c)|.spec.nodeName][0] // ""') || return 1
  # The helper Job is built as JSON by jq and goes through kn's `apply -f -`, which accepts JSON only (YAML is refused: its scalar rules differ between kubectl and any parser).
  jq -n --arg j "$j" --arg node "$node" --arg cmd "cd /data && $cmd" --arg pvc "$pvc" '
    {apiVersion: "batch/v1", kind: "Job", metadata: {name: $j, labels: {rehearsal: "pin"}},
     spec: {backoffLimit: 0, template: {spec: ({restartPolicy: "Never",
       containers: [{name: "r", image: "busybox:1.37",
                     securityContext: {runAsUser: 0, allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"], add: ["DAC_OVERRIDE"]}},
                     command: ["sh", "-c", $cmd], volumeMounts: [{name: "d", mountPath: "/data", readOnly: true}]}],
       volumes: [{name: "d", persistentVolumeClaim: {claimName: $pvc, readOnly: true}}]}
       + (if $node != "" then {nodeName: $node} else {} end))}}}' | kn "$NEW" apply -f - >/dev/null || return 1
  # m2: from here on a killed/timed-out block must not orphan the Job — its pod would hold pvc-protection (trap 3) and make the next `delete pvc` time out.
  RO_JOB=$j; trap 'ro_cleanup' EXIT; trap 'ro_cleanup; exit 130' INT TERM
  for i in $(seq 1 60); do
    st=$(kn "$NEW" get job "$j" -o json | jq -r 'if (.status.succeeded // 0) > 0 then "ok" elif (.status.failed // 0) > 0 then "failed" else "" end') || break
    [ -n "$st" ] && break; sleep "${PIN_POLL_J:-5}"
  done
  echo "--- ro_run $NEW/$pvc: job=$j pin=[$node] result=[${st:-TIMEOUT}] ---"
  kn "$NEW" logs "job/$j" 2>&1 || true
  kn "$NEW" delete job "$j" --cascade=foreground --wait=true >/dev/null 2>&1 || true
  # the pod (label job-name=<job>) must really be gone before we return: a Completed pod still holds the claim
  left=1
  for i in $(seq 1 30); do
    left=$(kn "$NEW" get pod -l "job-name=$j" -o json | jq '.items|length') || left=1
    [ "$left" = 0 ] && break; sleep "${PIN_POLL_J:-5}"
  done
  RO_JOB=""; trap - EXIT INT TERM
  [ "$left" = 0 ] || { echo "REFUSE: the helper pod of $j is still present — it holds pvc-protection; delete it before touching the claim" >&2; return 1; }
  [ "$st" = ok ]
}
# ro_cleanup: trap handler for ro_run (EXIT/INT/TERM). Deletes the recorded helper Job with foreground cascade and does not wait.
ro_cleanup() {
  if [ -n "${RO_JOB:-}" ]; then kn "$NEW" delete job "$RO_JOB" --cascade=foreground --wait=false >/dev/null 2>&1 || true; RO_JOB=""; fi
}
# data_check: content + continuity of the app claim. `sha256sum -c` proves the original bytes; starts=<n> and the log lines prove CONTINUITY (every start appends
# one line: an empty or older-snapshot volume lacks the later ones). Output is names + hashes + the log only.
data_check() { ro_run "$APP" 'sha256sum -c SHA256SUMS && echo starts=$(wc -l < starts.log) && cat starts.log'; }

# --- bootstrap: the ONLY hand-applied objects --------------------------------------------------------------------------
# bootstrap_apply: `kubectl apply -f` of exactly the two Flux CRs, after checking they exist, contain no ${VAR}, and name only what this rehearsal owns.
bootstrap_apply() {
  local d="$R/kubernetes/rehearsal-pin-bootstrap" f
  need_window bootstrap_apply || return 1; need_silence bootstrap_apply || return 1; on_branch || return 1
  for f in gitrepository.yaml rehearsal-apps.yaml; do
    [ -f "$d/$f" ] || { echo "REFUSE: $d/$f missing" >&2; return 1; }
    if grep -q '\${' "$d/$f"; then echo "REFUSE: $f contains \${ (envsubst trap)" >&2; return 1; fi
  done
  [ "$(yq -N '.metadata.name' "$d/gitrepository.yaml")" = rehearsal ] || { echo "REFUSE: gitrepository name" >&2; return 1; }
  [ "$(yq -N '.spec.ref.name' "$d/gitrepository.yaml")" = "refs/heads/$BRANCH" ] || { echo "REFUSE: gitrepository ref" >&2; return 1; }
  [ "$(yq -N '.metadata.name' "$d/rehearsal-apps.yaml")" = rehearsal-apps ] || { echo "REFUSE: parent name" >&2; return 1; }
  [ "$(yq -N '.spec.path' "$d/rehearsal-apps.yaml")" = ./kubernetes/rehearsal-pin ] || { echo "REFUSE: parent path" >&2; return 1; }
  [ "$(yq -N '.spec.sourceRef.name' "$d/rehearsal-apps.yaml")" = rehearsal ] || { echo "REFUSE: parent sourceRef" >&2; return 1; }
  kubectl apply -f "$d/gitrepository.yaml" -f "$d/rehearsal-apps.yaml"
}

# --- background watchers (PIDs recorded so they can be killed) ---------------------------------------------------------
watch_start() { local name=$1; shift; "$@" > "$PIN_DIR/$name.log" 2>&1 & echo $! > "$PIN_DIR/watch-$name.pid"; echo "watching $name (pid $(cat "$PIN_DIR/watch-$name.pid")) -> $PIN_DIR/$name.log"; }
watch_stop_all() { local f; for f in "$PIN_DIR"/watch-*.pid; do [ -f "$f" ] || continue; kill "$(cat "$f")" 2>/dev/null || true; rm -f "$f"; done; echo "watchers stopped"; }

# --- Alertmanager silences (CREATE ONLY WITH THE HUMAN'S GO-AHEAD; scoped to rehearsal-*; auto-expire) --------------------------------
# Requires SILENCE_OK=yes in the environment. Flux's alertmanager provider labels (verified on the first rehearsal): alertname, severity, reason, kind, name, namespace.
# VolSync series carry obj_namespace/obj_name. Alertmanager fully anchors regexes, so `rehearsal-.*` cannot match `ai`, `develop` or hermes.
am_open()  {
  kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager "$AM_PORT":9093 >/dev/null 2>&1 &
  echo $! > "$PIN_DIR/am-pf.pid"; trap am_close EXIT; sleep "${PIN_AM_WAIT:-3}"
}
am_close() { if [ -f "$PIN_DIR/am-pf.pid" ]; then kill "$(cat "$PIN_DIR/am-pf.pid")" 2>/dev/null || true; rm -f "$PIN_DIR/am-pf.pid"; fi; }
am_silence() {
  local start end body id m hours=${AM_HOURS:-8}
  [ "${SILENCE_OK:-}" = yes ] || { echo "REFUSE: silences need the human's go-ahead (SILENCE_OK=yes)" >&2; return 1; }
  case "$hours" in [1-9]|1[0-2]) ;; *) echo "REFUSE: AM_HOURS must be 1..12" >&2; return 1;; esac
  start=$(date -u +%FT%TZ); end=$(date -u -v+"${hours}"H +%FT%TZ 2>/dev/null || date -u -d "+${hours} hours" +%FT%TZ)
  am_open
  for m in 'namespace|rehearsal-.*' 'obj_namespace|rehearsal-.*' 'name|rehearsal-apps|rehearsal'; do
    body=$(jq -n --arg n "${m%%|*}" --arg v "${m#*|}" --arg s "$start" --arg e "$end" \
      '{matchers:[{name:$n,value:$v,isRegex:true,isEqual:true}],startsAt:$s,endsAt:$e,createdBy:"rehearsal-pin",comment:"pin-fix rehearsal (auto-expires; removed in teardown)"}')
    id=$(curl -fsS --retry 5 --retry-delay 1 --retry-connrefused -X POST -H 'Content-Type: application/json' -d "$body" "http://127.0.0.1:$AM_PORT/api/v2/silences" | jq -r '.silenceID')
    echo "$id" >> "$PIN_SILENCES"; echo "silence $id  ${m%%|*}=~${m#*|}"
  done
  echo $(( $(date +%s) + hours * 3600 )) > "$PIN_UNTIL"
  am_close
}
am_unsilence() {
  local id; am_open
  while read -r id; do
    [ -n "$id" ] || continue
    curl -fsS --retry 5 --retry-delay 1 --retry-connrefused -X DELETE "http://127.0.0.1:$AM_PORT/api/v2/silence/$id" && echo "expired $id"
  done < "$PIN_SILENCES"
  : > "$PIN_SILENCES"; rm -f "$PIN_UNTIL"; am_close
}

# verify_clean: teardown verification. Returns non-zero if ANY rehearsal residue is left (namespaces, Flux CRs, PVs + Longhorn volumes, VolumeSnapshotContents,
# the remote branch, silences, watchers). Also prints hermes's state for the caller to compare.
verify_clean() {
  local rc=0 p l v
  preflight_clean || rc=1
  while read -r p; do
    [ -n "$p" ] || continue
    kubectl get pv "$p" --ignore-not-found -o name | grep -q . && { echo "PV still present: $p" >&2; rc=1; }
    kubectl -n longhorn-system get volumes.longhorn.io "$p" --ignore-not-found -o name | grep -q . && { echo "Longhorn volume still present: $p" >&2; rc=1; }
  done < "$PIN_PVS"
  l=$(kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r '.items[]|select((.status.kubernetesStatus.namespace // "")|test("^rehearsal-"))|.metadata.name') || return 1
  [ -z "$l" ] || { echo "Longhorn volumes still tied to rehearsal-*: $l" >&2; rc=1; }
  v=$(kubectl get volumesnapshotcontent -o json | jq -r '.items[]|select((.spec.volumeSnapshotRef.namespace // "")|test("^rehearsal-"))|.metadata.name') || return 1
  [ -z "$v" ] || { echo "VolumeSnapshotContents still tied to rehearsal-*: $v" >&2; rc=1; }
  [ ! -s "$PIN_SILENCES" ] || { echo "silences still recorded: $(cat "$PIN_SILENCES")" >&2; rc=1; }
  ls "$PIN_DIR"/watch-*.pid >/dev/null 2>&1 && { echo "watchers still recorded" >&2; rc=1; }
  return $rc
}
