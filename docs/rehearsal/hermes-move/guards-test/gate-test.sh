#!/bin/bash
# move_gate scenarios against real commits in a scratch git worktree (removed afterwards). Fake kubectl only supplies the kube-system UID. Run: bash gate-test.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; T=${T:-/private/tmp/claude-501/gt2}; export FX=$T/fx PATH=$HERE/bin:$PATH
SHA1=b7667471e658da525f1dd3aaa0ca1524a96d1717; SHA2=b91dd0c9b94b959432ce4b0d2ec1b788d02a5dbf
REPO=$HERE/../hermes-move
rm -rf "$T"; mkdir -p "$T/gd" "$FX"; cp "$HERE/../hermes-move-guards.sh" "$T/gd/"
git -C "$REPO" worktree add -q --detach "$T/gd/hermes-move" $SHA1
G() { echo "### $1"; /bin/bash -c "source $T/gd/hermes-move-guards.sh; $2" 2>&1 | tail -"${3:-12}"; echo "rc=${PIPESTATUS[0]}"; }
G "commit 1: ai 2 zero (expect PASS)" 'move_gate ai 2 zero'
G "commit 1: ai 2 absent (expect FAIL replicas)" 'move_gate ai 2 absent' 6
G "commit 1: develop 2 (expect FAIL)" 'move_gate develop 2' 3
cd "$T/gd/hermes-move" || exit 1
C="git -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null"
sed -i '' 's/{kind: PersistentVolumeClaim}/{name: hermes, kind: PersistentVolumeClaim}/;s/{kind: ReplicationDestination}/{name: hermes-dst-local, kind: ReplicationDestination}/' kubernetes/apps/ai/hermes/app/kustomization.yaml
$C commit -qam scratch; G "name-targeted patches (expect FAIL, 0 lines)" 'move_gate ai 2 zero' 7; $C reset -q --hard $SHA1
sed -i '' 's/targetNamespace: ai/targetNamespace: develop/' kubernetes/apps/ai/hermes/ks.yaml
$C commit -qam scratch; G "stale targetNamespace (expect FAIL)" 'move_gate ai 2 zero' 8; $C reset -q --hard $SHA1
sed -i '' '/\.\/hermes\/ks.yaml/d' kubernetes/apps/ai/kustomization.yaml
$C commit -qam scratch; G "ks.yaml unlisted in ai (expect FAIL, 158 children)" 'move_gate ai 2 zero' 8; $C reset -q --hard $SHA1
echo x >> kubernetes/apps/ai/hermes/README.md; G "uncommitted change (expect FAIL)" 'move_gate ai 2 zero' 3; git checkout -q -- .
$C checkout -q --detach $SHA2; G "commit 2: ai 2 absent (expect PASS)" 'move_gate ai 2 absent'
G "commit 2: ai 2 zero (expect FAIL replicas)" 'move_gate ai 2 zero' 5
git -C "$REPO" worktree remove --force "$T/gd/hermes-move"; git -C "$REPO" worktree prune
