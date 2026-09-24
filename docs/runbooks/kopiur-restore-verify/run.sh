#!/bin/bash
# ============================================================================
# W0 per-wave restore gate (runbook "Gates → Per wave"): restore recyclarr's W0
# snapshots from kopia-local AND kopia-r2 into scratch PVCs, then compare both
# against the live volume, read-only, in one pod. Live experiment in `media`:
# Derek runs it. Nothing here writes to the live `recyclarr` PVC.
#
# Window: recyclarr's CronJob runs @daily 00:00Z and mounts the PVC; kopiur's
# recyclarr-local fires H 6 and VolSync recyclarr-local 06:00Z. Run between ~01:00Z
# and ~05:30Z or after ~07:30Z so nothing competes for the RWO volume.
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
    kubectl "${KA[@]}" -n "$NS" delete pod w0-verify-recyclarr-compare --ignore-not-found
    kubectl "${KA[@]}" -n "$NS" delete restores.kopiur.home-operations.com \
        w0-verify-recyclarr-local w0-verify-recyclarr-r2 --ignore-not-found
    # The Restore does not own its target PVC (kopiur docs/restores.md), so delete it explicitly.
    kubectl "${KA[@]}" -n "$NS" delete pvc w0-verify-recyclarr-local w0-verify-recyclarr-r2 --ignore-not-found
    exit 0
fi

if [[ "${1:-}" == compare ]]; then
    # Re-run only the comparison against the already-restored PVCs.
    kubectl "${KA[@]}" -n "$NS" delete pod w0-verify-recyclarr-compare --ignore-not-found --wait
    kubectl "${KA[@]}" apply --validate=false -f compare-pod.yaml
    kubectl "${KA[@]}" -n "$NS" wait pod/w0-verify-recyclarr-compare \
        --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m
    kubectl -n "$NS" logs w0-verify-recyclarr-compare
    exit 0
fi

# Refuse to run while recyclarr's own job is active: it holds the RWO volume.
if [[ -n "$(kubectl "${KA[@]}" -n "$NS" get cronjob recyclarr -o jsonpath='{.status.active}')" ]]; then
    echo "recyclarr job is running; retry after it finishes" >&2
    exit 1
fi

kubectl "${KA[@]}" apply --validate=false -f restores.yaml
echo "waiting for both Restores to reach Completed (or Failed)..."
for r in w0-verify-recyclarr-local w0-verify-recyclarr-r2; do
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
kubectl "${KA[@]}" -n "$NS" wait pod/w0-verify-recyclarr-compare \
    --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m
kubectl -n "$NS" logs w0-verify-recyclarr-compare
echo "done. Paste the output back, then: ./run.sh cleanup"
