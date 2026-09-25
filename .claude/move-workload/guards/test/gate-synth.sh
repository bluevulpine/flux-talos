#!/bin/bash
# move_gate against a SYNTHETIC minimal tree built from the conf's values (no real commits needed): proves the gate for ANY conf — including a CONTROLLER
# different from APP (the yq strenv path), the exactly-one-PVC/RD checks (classify class G), and the value checks. Local render only (flux build --dry-run).
#   /bin/bash test/gate-synth.sh [conf]          (default examples/probe.conf)
# shellcheck disable=SC1090,SC1091,SC2086,SC2016
[ -n "${BASH_VERSION:-}" ] || { echo "run under /bin/bash (never zsh)" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; GS="$(cd "$HERE/.." && pwd)"
CONF=${1:-$GS/examples/probe.conf}; CONF=$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF"); . "$GS/confparse.sh"; parse_conf "$CONF" "APP OLD NEW PV PR1 PR2 PR1_SHA PR2_SHA BASE_SHA STATE_DIR WORKTREE GH_REPO CLUSTER_UID EXPECT_FILES EXPECT_DIRS DRIFT_PATHS REPORT_DIRS LIVE_FILES CONTROLLER" || exit 1   # conf parsed as DATA (N5)
CTRL=${CONTROLLER:-$APP}
unset T; T=$(mktemp -d "${TMPDIR:-/tmp}/move-gate-synth.XXXXXX") && T=$(cd "$T" && pwd -P) || exit 1
trap 'rm -rf "$T"' EXIT
GD=$T/gd; FX=$T/fx; WT=$GD/wt; mkdir -p "$GD/test" "$FX" "$GD/state" "$WT"; cp "$GS/move-guards.sh" "$GS/confparse.sh" "$GS/kn-guard.sh" "$GD/"; cp -R "$GS/test/bin" "$GD/test/bin"
export FX PATH="$GD/test/bin:$PATH" HM_FAKE=1 FAKE_CLUSTER_UID=$CLUSTER_UID
{ for k in APP OLD NEW PV PR1 PR2 PR1_SHA PR2_SHA BASE_SHA GH_REPO CLUSTER_UID EXPECT_FILES EXPECT_DIRS REPORT_DIRS LIVE_FILES DRIFT_PATHS CONTROLLER; do [ -n "${!k:-}" ] && printf '%s="%s"\n' "$k" "${!k}"; done
  printf 'STATE_DIR="%s"\nWORKTREE="%s"\n' "$GD/state" "$WT"; } > "$GD/move.conf"; export MOVE_CONF=$GD/move.conf
C="git -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null"
K=$WT/kubernetes/apps/$NEW/$APP; mkdir -p "$K/app" "$WT/kubernetes/flux/cluster"
cat > "$WT/kubernetes/flux/cluster/ks.yaml" <<Y
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: {name: cluster-apps, namespace: flux-system}
spec: {interval: 1h, path: ./kubernetes/apps, prune: true, sourceRef: {kind: GitRepository, name: home-kubernetes}}
Y
printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: [./%s]\n' "$NEW" > "$WT/kubernetes/apps/kustomization.yaml"
printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamespace: %s\nresources: [./%s/ks.yaml]\n' "$NEW" "$APP" > "$WT/kubernetes/apps/$NEW/kustomization.yaml"
cat > "$K/ks.yaml" <<Y
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: {name: $APP}
spec: {interval: 1h, path: ./kubernetes/apps/$NEW/$APP/app, prune: true, targetNamespace: $NEW, sourceRef: {kind: GitRepository, name: home-kubernetes}}
Y
cat > "$K/app/pvc.yaml" <<Y
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: \${APP}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
Y
cat > "$K/app/rd.yaml" <<Y
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: \${APP}-dst-local
spec:
  trigger: {manual: restore-once}
  kopia:
    sourceIdentity:
      sourceName: \${APP}
Y
cat > "$K/app/hr.yaml" <<Y
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: {name: $APP}
spec: {values: {controllers: {$CTRL: {replicas: 0}}}}
Y
cat > "$K/app/kustomization.yaml" <<Y
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [./pvc.yaml, ./rd.yaml, ./hr.yaml]
patches:
  - target: {kind: PersistentVolumeClaim}
    patch: |-
      - op: add
        path: /spec/volumeName
        value: $PV
  - target: {kind: ReplicationDestination}
    patch: |-
      - op: add
        path: /spec/kopia/sourceIdentity/sourceNamespace
        value: $OLD
Y
( cd "$WT" && git init -q && git checkout -q -b main && git add -A && $C commit -q -m synth ) || exit 1
pass=0; fail=0
G() { local out rc; out=$(/bin/bash -c "source $GD/move-guards.sh; $3" 2>&1); rc=$?
  echo "### $1"; echo "$out" | grep -E "GATE|replicas|children" | tail -5
  if { [ "$2" = PASS ] && [ $rc -eq 0 ]; } || { [ "$2" = FAIL ] && [ $rc -ne 0 ]; }; then pass=$((pass+1)); echo "ok (expected $2)"; else fail=$((fail+1)); echo "UNEXPECTED rc=$rc (expected $2)"; echo "$out" | tail -8; fi; }
reset() { ( cd "$WT" && git reset -q --hard HEAD ); }
G "synthetic tree: $NEW 2 zero"                                   PASS "move_gate $NEW 2 zero"
G "synthetic tree: $NEW 2 absent (replicas are 0)"                FAIL "move_gate $NEW 2 absent"
sed -i '' "s/controllers: {$CTRL:/controllers: {other-ctrl:/" "$K/app/hr.yaml"; ( cd "$WT" && $C commit -qam x )
G "controller key != CONTROLLER (replicas absent for it)"         FAIL "move_gate $NEW 2 zero"; reset; ( cd "$WT" && git reset -q --hard HEAD~1 )
sed -i '' "s/value: $PV/value: pvc-00000000-dead-beef-0000-000000000000/" "$K/app/kustomization.yaml"; ( cd "$WT" && $C commit -qam x )
G "wrong volumeName value"                                        FAIL "move_gate $NEW 2 zero"; ( cd "$WT" && git reset -q --hard HEAD~1 )
sed -i '' -E "s/value: $OLD\$/value: media/" "$K/app/kustomization.yaml"; ( cd "$WT" && $C commit -qam x )
G "wrong sourceNamespace value"                                   FAIL "move_gate $NEW 2 zero"; ( cd "$WT" && git reset -q --hard HEAD~1 )
sed 's/\${APP}/${APP}-2/' "$K/app/pvc.yaml" > "$K/app/pvc2.yaml"; sed -i '' 's|resources: \[./pvc.yaml|resources: [./pvc2.yaml, ./pvc.yaml|' "$K/app/kustomization.yaml"; ( cd "$WT" && git add -A && $C commit -qm x )
G "TWO PVCs (class G): kind-targeted patch pins both -> gate fails" FAIL "move_gate $NEW 2 zero"; ( cd "$WT" && git reset -q --hard HEAD~1 )
echo; echo "synthetic gate scenarios: passed=$pass failed=$fail (app=$APP controller=$CTRL)"; [ "$fail" -eq 0 ]
