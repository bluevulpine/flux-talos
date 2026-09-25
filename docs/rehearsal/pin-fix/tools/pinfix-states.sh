#!/bin/bash
# pinfix-states.sh — the ONLY writer of the two files the pin-fix rehearsal edits. Pure: no kubectl, no cluster, no git. Sourced by pinfix-guards.sh
# (which adds the guards) and by the test suite / build proofs directly.
# Plan: hermes-to-ai:docs/rehearsal/pin-fix/plan.md
#
# The rehearsal walks ONE branch through these states of moveprobe2/app/kustomization.yaml (+ the VOLSYNC_CAPACITY line of ks.yaml):
#
#   state      volumeName+RD sourceNamespace   ssa: IfNotPresent   prune: disabled   capacity   probe on the PVC
#   base       -                                -                   -                 1Gi        -
#   control    -                                -                   -                 1Gi        -      (== base; "the fix commit WITHOUT the annotation")
#   s1         pv (needs <pv>)                  -                   -                 1Gi        -      (== the real post-move hermes shape)
#   fix        -                                yes                 -                 1Gi        -      (the proposed fix: annotation, no pin)
#   fix-cap2   -                                yes                 -                 2Gi        -      (S3a)
#   fix-meta   -                                yes                 -                 2Gi        label + annotation + storageClassName (S3b)
#   fix-vn     -                                yes                 -                 2Gi        volumeName = a different PV name (S6)
#   fixprune   -                                yes                 yes               2Gi        -      (S5a; also the S4 rebuild state)
#
# Written for bash 3.2 (/bin/bash on macOS).
set -euo pipefail

# Never a valid pin, in any state (hermes now lives in `ai`; this rehearsal must not be able to name its PV).
export PIN_HERMES_PV=pvc-12f54114-9e99-442b-bae4-53a9cb239d69
# The RD sourceNamespace value of the hermes-shaped pin. `rehearsal-old` is an empty scratch namespace: no moveprobe2 series exists there.
export PIN_OLD_NS=rehearsal-old
# A well-formed name that no PV has (S6 mismatch probe).
export PIN_FAKE_PV=pvc-00000000-0000-4000-8000-000000000000

# pin_state_ok <state>: 0 if the state name is known.
pin_state_ok() { case "${1:-}" in base|control|s1|fix|fix-cap2|fix-meta|fix-vn|fixprune) return 0;; *) return 1;; esac; }
# pin_cap <state>: the VOLSYNC_CAPACITY of a state.
pin_cap() { case "${1:-}" in fix-cap2|fix-meta|fix-vn|fixprune) echo 2Gi;; base|control|s1|fix) echo 1Gi;; *) return 1;; esac; }

# pin_render <state> [pv]: the whole moveprobe2/app/kustomization.yaml for a state, on stdout.
pin_render() {
  local st=${1:-} pv=${2:-} ssa=0 prune=0 probe=none pin=0
  pin_state_ok "$st" || { echo "pin_render: unknown state [$st]" >&2; return 1; }
  case "$st" in
    s1) pin=1
        [[ "$pv" =~ ^pvc-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "pin_render: s1 needs a PV name pvc-<uuid>, got [$pv]" >&2; return 1; }
        [ "$pv" != "$PIN_HERMES_PV" ] || { echo "pin_render: refusing the hermes PV" >&2; return 1; } ;;
    fix|fix-cap2) ssa=1 ;;
    fix-meta) ssa=1; probe=meta ;;
    fix-vn) ssa=1; probe=vn ;;
    fixprune) ssa=1; prune=1 ;;
  esac
  if [ "$st" != s1 ] && [ -n "$pv" ]; then echo "pin_render: state [$st] takes no PV" >&2; return 1; fi
  cat <<EOF
---
# yaml-language-server: \$schema=https://json.schemastore.org/kustomization
# STATE: $st  (written by pinfix-states.sh — do not hand-edit; the scenarios move between states with pin_state)
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./ocirepository.yaml
  - ./helmrelease.yaml
components:
  - ../../../../components/volsync-claim
  - ../../../../components/volsync-backup
EOF
  if [ "$pin" = 0 ] && [ "$ssa" = 0 ] && [ "$probe" = none ]; then return 0; fi
  echo "patches:"
  if [ "$pin" = 1 ]; then
    cat <<EOF
  # Target by KIND, never by name (the names are \${APP}/\${APP}-dst-local until postBuild substitution; a name target is silently dropped).
  - target: {kind: PersistentVolumeClaim}
    patch: |-
      - op: add
        path: /spec/volumeName
        value: $pv
  - target: {kind: ReplicationDestination}
    patch: |-
      - op: add
        path: /spec/kopia/sourceIdentity/sourceNamespace
        value: $PIN_OLD_NS
EOF
  fi
  if [ "$ssa" = 1 ]; then
    # A strategic-merge patch (NOT a JSON add): it works whether or not metadata.annotations exists on the claim.
    cat <<EOF
  - target: {kind: PersistentVolumeClaim}
    patch: |-
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: not-used
        annotations:
          kustomize.toolkit.fluxcd.io/ssa: IfNotPresent
EOF
    if [ "$prune" = 1 ]; then echo "          kustomize.toolkit.fluxcd.io/prune: disabled"; fi
  fi
  case "$probe" in
    meta) cat <<EOF
  # S3b probe: a label, an annotation and an (immutable) storageClassName that the live claim does NOT have.
  - target: {kind: PersistentVolumeClaim}
    patch: |-
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: not-used
        labels:
          pin-probe: s3b
        annotations:
          pin-probe: s3b
      spec:
        storageClassName: longhorn
EOF
    ;;
    vn) cat <<EOF
  # S6 probe: a desired volumeName that differs from the bound one (immutable on a bound claim).
  - target: {kind: PersistentVolumeClaim}
    patch: |-
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: not-used
      spec:
        volumeName: $PIN_FAKE_PV
EOF
    ;;
  esac
}

# pin_write <state> [pv]: write kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/{app/kustomization.yaml, ks.yaml (VOLSYNC_CAPACITY only)} under $1's repo.
# Usage: PIN_REPO=<worktree> pin_write <state> [pv]. Renders to a temp file first, so a failed render leaves the files untouched.
pin_write() {
  local st=${1:-} pv=${2:-} d cap tmp
  [ -n "${PIN_REPO:-}" ] && [ -d "$PIN_REPO/kubernetes/rehearsal-pin" ] || { echo "pin_write: PIN_REPO must be the rehearsal-pin worktree" >&2; return 1; }
  d="$PIN_REPO/kubernetes/rehearsal-pin/rehearsal-new/moveprobe2"
  cap=$(pin_cap "$st") || { echo "pin_write: unknown state [$st]" >&2; return 1; }
  tmp=$(mktemp)
  if ! pin_render "$st" "$pv" > "$tmp"; then rm -f "$tmp"; return 1; fi
  mv "$tmp" "$d/app/kustomization.yaml"
  sed -i.bak -E "s/^( +VOLSYNC_CAPACITY: ).*$/\\1$cap/" "$d/ks.yaml" && rm -f "$d/ks.yaml.bak"
  grep -q "VOLSYNC_CAPACITY: $cap\$" "$d/ks.yaml" || { echo "pin_write: VOLSYNC_CAPACITY line not updated" >&2; return 1; }
  echo "state=$st cap=$cap${pv:+ pv=$pv}"
}
