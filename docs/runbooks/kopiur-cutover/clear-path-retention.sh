#!/bin/bash
# ============================================================================
# Per-app cutover, step 2 (runbook "Per-app cutover"): clear the VolSync fork's
# path-scope retention on <app>@<ns>:/data, in BOTH repositories, so kopiur's
# identity-scope pin (keep-* = i32::MAX) wins and kopiur's CR-driven GFS is the only
# deleter. Live kopia write: Derek runs it.
#
# Run AFTER the cutover merge has applied: the fork re-sets these rules on every
# VolSync run, so clearing earlier is undone. The script refuses while any VolSync
# ReplicationSource or mover for the app still exists.
#
# Credentials: kopiur's per-namespace kopiur-{local,r2}-secret (same keys as VolSync's,
# which the cutover deletes). Bucket/endpoint come from the live ClusterRepository.
#
#   ./clear-path-retention.sh <app> [ns]      e.g. ./clear-path-retention.sh jellyseerr
#   DRY=1 ./clear-path-retention.sh <app>     server dry-run of both pods, skips the VolSync check
# ============================================================================
set -euo pipefail
readonly APP="${1:?usage: $0 <app> [ns]}"
readonly NS="${2:-media}"
# The VolSync fork's own image (kopia 0.22.3), kept in step with its HelmRelease.
# renovate: datasource=docker depName=ghcr.io/perfectra1n/volsync
readonly IMAGE_TAG=v0.17.11
readonly IMAGE="ghcr.io/perfectra1n/volsync:${IMAGE_TAG}"
readonly KA=(--request-timeout=30s)
# kopia connect loads the repository index into memory. 1Gi was enough for W0
# (2026-09-24) but OOMKilled 2 s into connect on kopia-local at indexBlobCount 652
# (2026-09-25); kopia-maintenance-local needs 4Gi for the same reason. Override with MEM=.
readonly MEM="${MEM:-4Gi}"

# Fail closed: capture kubectl's output first, so a failed call aborts (set -e) instead
# of counting as "0 found". Only grep's no-match exit is tolerated.
vs_objs=$(kubectl "${KA[@]}" -n "$NS" get replicationsource,replicationdestination -o name)
pods=$(kubectl "${KA[@]}" -n "$NS" get pods -o name)
left=$(grep -cE "/${APP}-(local|r2|dst-local)$" <<<"$vs_objs" || true)
movers=$(grep -c "volsync-src-${APP}-" <<<"$pods" || true)
if [[ -z "${DRY:-}" && ( "$left" != 0 || "$movers" != 0 ) ]]; then
    echo "VolSync still present for ${APP} (${left} objects, ${movers} mover pods); wait for the prune" >&2
    exit 1
fi

run_leg() {
    local leg="$1" pod="kopia-clear-${APP}-$1" endpoint bucket tls
    endpoint=$(kubectl "${KA[@]}" get clusterrepository "kopia-${leg}" -o jsonpath='{.spec.backend.s3.endpoint}')
    bucket=$(kubectl "${KA[@]}" get clusterrepository "kopia-${leg}" -o jsonpath='{.spec.backend.s3.bucket}')
    tls=$(kubectl "${KA[@]}" get clusterrepository "kopia-${leg}" -o jsonpath='{.spec.backend.s3.tls.disableTls}')
    local dry=()
    [[ -n "${DRY:-}" ]] && dry=(--dry-run=server)
    [[ -z "${DRY:-}" ]] && kubectl "${KA[@]}" -n "$NS" delete pod "$pod" --ignore-not-found --wait >/dev/null
    kubectl "${KA[@]}" apply --validate=false "${dry[@]+"${dry[@]}"}" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${NS}
spec:
  restartPolicy: Never
  containers:
    - name: kopia
      image: ${IMAGE}
      command: [/bin/bash, -c]
      args:
        - |
          set -euo pipefail
          target='${APP}@${NS}:/data'
          args=(--bucket='${bucket}' --endpoint='${endpoint}'
                --access-key="\$AWS_ACCESS_KEY_ID" --secret-access-key="\$AWS_SECRET_ACCESS_KEY")
          [[ '${tls}' == true ]] && args+=(--disable-tls)
          kopia repository connect s3 "\${args[@]}" >/dev/null
          keep='^ *(Annual|Monthly|Weekly|Daily|Hourly|Latest) snapshots:'
          echo "### before"; kopia policy show "\$target" | grep -E "\$keep"
          kopia policy set "\$target" \
            --keep-latest=inherit --keep-hourly=inherit --keep-daily=inherit \
            --keep-weekly=inherit --keep-monthly=inherit --keep-annual=inherit
          echo "### after"; kopia policy show "\$target" | grep -E "\$keep" | tee /tmp/after
          n=\$(grep -c 'inherited from ${APP}@${NS}' /tmp/after || true)
          echo "RESULT ${leg}: \$([ "\$n" = 6 ] && echo PASS || echo FAIL) (\$n/6 keep-* inherited from ${APP}@${NS})"
      env:
        - {name: KOPIA_PASSWORD, valueFrom: {secretKeyRef: {name: kopiur-${leg}-secret, key: KOPIA_PASSWORD}}}
        - {name: AWS_ACCESS_KEY_ID, valueFrom: {secretKeyRef: {name: kopiur-${leg}-secret, key: AWS_ACCESS_KEY_ID}}}
        - {name: AWS_SECRET_ACCESS_KEY, valueFrom: {secretKeyRef: {name: kopiur-${leg}-secret, key: AWS_SECRET_ACCESS_KEY}}}
        - {name: KOPIA_CONFIG_PATH, value: /tmp/kopia/repository.config}
        - {name: KOPIA_CACHE_DIRECTORY, value: /tmp/kopia/cache}
        - {name: KOPIA_LOG_DIR, value: /tmp/kopia/logs}
        - {name: KOPIA_CHECK_FOR_UPDATES, value: "false"}
      resources:
        requests: {cpu: 50m, memory: 128Mi}
        limits: {memory: ${MEM}}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
      volumeMounts:
        - {name: tmp, mountPath: /tmp}
  volumes:
    - name: tmp
      emptyDir: {}
EOF
    [[ -n "${DRY:-}" ]] && return 0
    echo "=== ${leg}: ${NS}/${pod}"
    kubectl "${KA[@]}" -n "$NS" wait pod "$pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m ||
        kubectl -n "$NS" get pod "$pod"
    local log
    log=$(kubectl -n "$NS" logs "$pod" 2>&1 || true)
    printf '%s\n' "$log"
    kubectl "${KA[@]}" -n "$NS" delete pod "$pod" --wait=false >/dev/null
    # A pod killed before it prints (OOMKilled on connect, 2026-09-25) leaves no RESULT
    # line at all; count that as a failure rather than something to spot by eye.
    if ! grep -q "^RESULT ${leg}: PASS" <<<"$log"; then
        echo "LEG FAILED: ${leg} (no PASS line)" >&2
        failed+=("$leg")
    fi
}

failed=()
run_leg local
run_leg r2
[[ -n "${DRY:-}" || ${#failed[@]} -eq 0 ]] || { echo "FAILED legs: ${failed[*]}" >&2; exit 1; }
