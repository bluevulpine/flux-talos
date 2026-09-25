#!/bin/bash
# ============================================================================
# W1 per-wave restore gate (runbook "Gates → Per wave"): restore calibre-web's
# snapshots from kopia-local AND kopia-r2 into scratch PVCs, then compare both
# against the live volume and each other, read-only, in one pod. Live experiment
# in `media`: Derek runs it. Nothing here writes to the live `calibre-web` PVC.
#
# Window: calibre-web runs always (brokkr01); the compare pod is pinned there so
# it can share the RWO volume. Backup movers read staged clones, not the live
# PVC. Next slots: VolSync calibre-web-local 16:15Z, kopiur ~16:25Z.
#
#   ./run.sh           restore + compare, prints RESULT
#   ./run.sh compare   re-run only the comparison (restored PVCs must exist)
#   ./run.sh cleanup   delete the Restores, the compare pod and the scratch PVCs
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"
readonly NS=media
readonly KA=(--request-timeout=30s)

if [[ "${1:-}" == cleanup ]]; then
    kubectl "${KA[@]}" -n "$NS" delete pod w1-verify-calibre-web-compare --ignore-not-found
    kubectl "${KA[@]}" -n "$NS" delete restores.kopiur.home-operations.com \
        w1-verify-calibre-web-local w1-verify-calibre-web-r2 --ignore-not-found
    # The Restore does not own its target PVC (kopiur docs/restores.md), so delete it explicitly.
    kubectl "${KA[@]}" -n "$NS" delete pvc w1-verify-calibre-web-local w1-verify-calibre-web-r2 --ignore-not-found
    exit 0
fi

if [[ "${1:-}" == compare ]]; then
    # Re-run only the comparison against the already-restored PVCs.
    kubectl "${KA[@]}" -n "$NS" delete pod w1-verify-calibre-web-compare --ignore-not-found --wait
    kubectl "${KA[@]}" apply --validate=false -f compare-pod.yaml
    kubectl "${KA[@]}" -n "$NS" wait pod/w1-verify-calibre-web-compare \
        --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m
    kubectl -n "$NS" logs w1-verify-calibre-web-compare
    exit 0
fi

# The compare pod is pinned to brokkr01; refuse if calibre-web has moved.
node="$(kubectl "${KA[@]}" -n "$NS" get pods -l app.kubernetes.io/name=calibre-web -o jsonpath='{.items[0].spec.nodeName}')"
if [[ "$node" != brokkr01 ]]; then
    echo "calibre-web runs on '$node', not brokkr01: update nodeName in compare-pod.yaml" >&2
    exit 1
fi

kubectl "${KA[@]}" apply --validate=false -f restores.yaml
echo "waiting for both Restores to reach Completed (or Failed)..."
for r in w1-verify-calibre-web-local w1-verify-calibre-web-r2; do
    kubectl "${KA[@]}" -n "$NS" wait "restores.kopiur.home-operations.com/$r" \
        --for=jsonpath='{.status.phase}'=Completed --timeout=20m || {
        kubectl -n "$NS" get "restores.kopiur.home-operations.com/$r" -o json |
            jq '{phase: .status.phase, conditions: [.status.conditions[]? | {type, status, reason, message}]}'
        exit 1
    }
    kubectl -n "$NS" get "restores.kopiur.home-operations.com/$r" -o json |
        jq -c '{restore: .metadata.name, resolved: .status.resolved, progress: .status.progress}'
done

kubectl "${KA[@]}" apply --validate=false -f compare-pod.yaml
kubectl "${KA[@]}" -n "$NS" wait pod/w1-verify-calibre-web-compare \
    --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m
kubectl -n "$NS" logs w1-verify-calibre-web-compare
echo "done. Paste the output back, then: ./run.sh cleanup"
