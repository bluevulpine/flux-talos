#!/bin/bash
# Manual Talos node upgrade. tuppr's TalosUpgrade is suspended because talosctl's
# built-in drain hangs on Longhorn's instance-manager PDB, so the drain is done here
# instead. Used for the v1.13.11 roll of every worker (2026-10-03).
#   plan    <node>                      read-only: what would be scaled, CNPG primary, movers, gate
#   prep    <node>                      gate, scale down workloads whose volume has no healthy replica elsewhere, drain
#   upgrade <node> <version>            talosctl upgrade --drain=false (+ powercycle on brokkr)
#   restore <node>                      uncordon, scale back to recorded replicas, wait for volumes healthy
#   roll    <node> <version>            prep, upgrade, restore -- stops at the first phase that fails
# Order: Pi workers, then brokkr (CNPG primary last), then the control plane.
#
# Env:
#   TALOSCTL        talosctl on the NODES' minor version (Homebrew can be a minor ahead); default: talosctl
#   TALOS_ENDPOINT  talosctl endpoint; default 10.0.10.30 (VIP). For the control plane use its own IP:
#                   the VIP disappears while it reboots.
#   ROLL_STATE_DIR  where the scale-down record and API snapshots live; default ~/.local/state/talos-node-roll.
#                   Keep roll-<node>.scaled until restore has run: re-running prep truncates it.
# bash 3.2 safe (macOS /bin/bash).
set -euo pipefail

readonly C=admin@home-kubernetes
readonly EP=${TALOS_ENDPOINT:-10.0.10.30}
readonly TALOSCTL=${TALOSCTL:-talosctl}
readonly S=${ROLL_STATE_DIR:-$HOME/.local/state/talos-node-roll}
export TALOSCONFIG=${TALOSCONFIG:-$(cd "$(dirname "$0")/.." && pwd)/talos/talosconfig}
mkdir -p "$S"
k() { kubectl --context "$C" "$@"; }

phase=${1:?usage: $0 plan|prep|upgrade|restore|roll <node> [version]}; node=${2:?node}
ip=$(k get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
[[ -n "$ip" ]] || { echo "no InternalIP for $node" >&2; exit 1; }

gate() { # attached Longhorn volumes that are not healthy
  k -n longhorn-system get volumes.longhorn.io -o json | python3 -c '
import sys, json
v = json.load(sys.stdin)["items"]
import re
# Skip backup-mover volumes (VolSync/kopiur *-src clones, caches, RD dest): they are
# created and attached minutes before each backup and are briefly unknown/degraded
# by design, which kept this gate permanently tripped on 2026-10-03. App volumes
# must still all be healthy.
MOVER = re.compile(r"^(volsync-|kopiur-)|-src$|-cache$|-dst-")
def mover(x): return bool(MOVER.search(x["status"].get("kubernetesStatus", {}).get("pvcName") or ""))
bad = [x["metadata"]["name"] for x in v if x["status"].get("state") == "attached" and x["status"].get("robustness") != "healthy" and not mover(x)]
print(len(bad), " ".join(bad))'
}

# Workloads (ns kind name) owning pods on $node that mount a Longhorn volume attached on $node.
# Skips operator/HA-managed workloads that the drain evicts under their own PDBs.
workloads_on_node() {
  k -n longhorn-system get volumes.longhorn.io -o json > "$S/roll-vols.json"
  k get pods -A -o json --field-selector "spec.nodeName=$node" > "$S/roll-pods.json"
  k get rs -A -o json > "$S/roll-rs.json"
  k -n longhorn-system get replicas.longhorn.io -o json > "$S/roll-reps.json"
  python3 - "$node" "$S" <<'PY'
import json, sys
node, S = sys.argv[1], sys.argv[2]
vols = json.load(open(S + "/roll-vols.json"))["items"]
# A volume is MOVABLE if it has a healthy, running replica on another node: the drain
# can then evict its pod gracefully and it reattaches next to that replica in ~a
# minute. Only workloads with at least one volume whose sole healthy replica is on
# this node get scaled down (2026-10-03: after the 2-replica rollout most app
# volumes are movable; scaling them all kept 29 apps down for the whole reboot).
elsewhere = set()
for r in json.load(open(S + "/roll-reps.json"))["items"]:
    sp, st = r["spec"], r.get("status", {})
    if sp.get("nodeID") and sp["nodeID"] != node and st.get("currentState") == "running" and sp.get("healthyAt") and not sp.get("failedAt"):
        elsewhere.add(sp["volumeName"])
att, stuck = set(), set()
for v in vols:
    k = v["status"].get("kubernetesStatus", {})
    if v["status"].get("state") == "attached" and v["status"].get("currentNodeID") == node and k.get("pvcName"):
        att.add((k["namespace"], k["pvcName"]))
        if v["metadata"]["name"] not in elsewhere:
            stuck.add((k["namespace"], k["pvcName"]))
rs = {(r["metadata"]["namespace"], r["metadata"]["name"]): (r["metadata"].get("ownerReferences") or [{}])[0] for r in json.load(open(S + "/roll-rs.json"))["items"]}
SKIP_NS = {"longhorn-system", "openbao", "kube-system"}
out = set()
for p in json.load(open(S + "/roll-pods.json"))["items"]:
    ns = p["metadata"]["namespace"]
    if ns in SKIP_NS or p["status"].get("phase") in ("Succeeded", "Failed"):
        continue
    claims = {v["persistentVolumeClaim"]["claimName"] for v in p["spec"].get("volumes", []) if v.get("persistentVolumeClaim")}
    if not any((ns, c) in att for c in claims):
        continue
    movable = not any((ns, c) in stuck for c in claims)
    o = (p["metadata"].get("ownerReferences") or [{}])[0]
    kind, name = o.get("kind"), o.get("name")
    if kind == "ReplicaSet":
        o2 = rs.get((ns, name), {})
        kind, name = o2.get("kind"), o2.get("name")
    if kind in ("Cluster",):                       # CNPG instance: switch over, drain evicts it
        print("SKIP-CNPG", ns, name); continue
    if kind == "StatefulSet" and (name.startswith("prometheus-") or name.startswith("alertmanager-")):
        print("SKIP-OPERATOR", ns, name); continue
    if kind == "Job" or kind is None:
        print("SKIP-JOB", ns, p["metadata"]["name"]); continue
    kd = {"Deployment": "deploy", "StatefulSet": "sts"}.get(kind, kind)
    if movable:
        print("MOVE", ns, kd, name); continue      # drain evicts it; it reschedules elsewhere
    out.add((ns, kd, name))
for ns, kind, name in sorted(out):
    print("SCALE", ns, kind, name)
PY
}

case "$phase" in
plan)
  echo "== $node ($ip) talos=$(k get node "$node" -o jsonpath='{.status.nodeInfo.osImage}')"
  echo "-- gate (attached-unhealthy): $(gate)"
  echo "-- CNPG primary: $(k -n database get cluster postgres18 -o jsonpath='{.status.currentPrimary}') on $(k -n database get pod "$(k -n database get cluster postgres18 -o jsonpath='{.status.currentPrimary}')" -o jsonpath='{.spec.nodeName}')"
  echo "-- running backup movers: $(k get pods -A --no-headers | grep -E 'volsync-(src|dst)|-(local|r2)-[0-9]{14}' | grep -cv -E 'Completed|Error' || true)"
  workloads_on_node
  ;;
prep)
  read -r bad names < <(gate); [[ "$bad" == 0 ]] || { echo "GATE: $bad attached volumes not healthy: $names" >&2; exit 2; }
  primary=$(k -n database get cluster postgres18 -o jsonpath='{.status.currentPrimary}')
  [[ "$(k -n database get pod "$primary" -o jsonpath='{.spec.nodeName}')" != "$node" ]] || { echo "CNPG primary $primary is on $node: switch over first" >&2; exit 3; }
  : > "$S/roll-$node.scaled"
  workloads_on_node | while read -r tag ns kind name; do
    [[ "$tag" == SCALE ]] || { echo "  $tag $ns $kind $name"; continue; }
    r=$(k -n "$ns" get "$kind" "$name" -o jsonpath='{.spec.replicas}')
    echo "$ns $kind $name $r" >> "$S/roll-$node.scaled"
    k -n "$ns" scale "$kind" "$name" --replicas=0 >/dev/null && echo "  scaled $ns/$kind/$name $r -> 0"
  done
  # wait for those pods to be gone (graceful shutdown before the drain)
  for _ in $(seq 1 60); do
    left=$(workloads_on_node | grep -c '^SCALE' || true); echo "$(date +%T) workloads still holding volumes on $node: $left"
    [[ "$left" == 0 ]] && break; sleep 5
  done
  k drain "$node" --ignore-daemonsets --delete-emptydir-data --force \
    --pod-selector='longhorn.io/component!=instance-manager' --timeout=600s || { echo "drain of $node failed" >&2; exit 6; }
  [[ "$(k get node "$node" -o jsonpath='{.spec.unschedulable}')" == true ]] || { echo "node $node is not cordoned after drain" >&2; exit 5; }
  echo "$(date +%T) PREP DONE for $node"
  ;;
upgrade)
  ver=${3:?version}
  # A client a minor ahead of the nodes is what Homebrew silently installs; refuse it.
  cv=$("$TALOSCTL" version --client --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+' | head -1)
  [[ "$cv" == "$(echo "$ver" | grep -oE '^v[0-9]+\.[0-9]+')" ]] || { echo "talosctl is $cv, target is $ver: set TALOSCTL to a matching client" >&2; exit 7; }
  img=$("$TALOSCTL" -n "$ip" -e "$EP" get machineconfig -o yaml 2>/dev/null | awk '/^ +image: factory\.talos\.dev/ {print $2; exit}')
  [[ -n "$img" ]] || { echo "could not read installer image from $node machineconfig" >&2; exit 4; }
  img="${img%:*}:$ver"
  extra=(); [[ "$node" == brokkr* ]] && extra=(--reboot-mode=powercycle)
  echo "$(date +%T) upgrading $node ($ip) to $img ${extra[*]+"${extra[*]}"}"
  "$TALOSCTL" -n "$ip" -e "$EP" upgrade --image "$img" --drain=false ${extra[@]+"${extra[@]}"} --wait --timeout 25m0s 2>&1 | grep -v -E "WARNING|^\s*$" | tail -8
  for _ in $(seq 1 60); do
    v=$(k get node "$node" -o jsonpath='{.status.nodeInfo.osImage}{" "}{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    echo "$(date +%T) $node: $v"; [[ "$v" == *"$ver"*True ]] && break; sleep 10
  done
  ;;
restore)
  k uncordon "$node" >/dev/null && echo "uncordoned $node"
  if [[ -s "$S/roll-$node.scaled" ]]; then
    while read -r ns kind name r; do k -n "$ns" scale "$kind" "$name" --replicas="$r" >/dev/null && echo "  scaled $ns/$kind/$name -> $r"; done < "$S/roll-$node.scaled"
  fi
  for _ in $(seq 1 90); do
    read -r bad names < <(gate); echo "$(date +%T) attached-unhealthy volumes: $bad $names"
    [[ "$bad" == 0 ]] && break; sleep 20
  done
  echo "-- not-ready pods cluster-wide:"; k get pods -A --no-headers | grep -v -E "Running|Completed" | awk '{print "   "$1"/"$2,$4}' | head -12
  echo "$(date +%T) RESTORE DONE for $node"
  ;;
roll)
  # The ONLY supported way to run the three phases together. Each phase is a
  # separate process and its exit status is checked directly -- never pipe a
  # phase into grep/tail: the pipeline returns the filter's status, which once
  # let a failed prep (gate tripped, nothing drained) fall through to an
  # undrained power-cycle of brokkr01 (2026-10-03).
  ver=${3:?version}
  "$0" prep "$node" || { echo "ROLL ABORTED: prep failed for $node; node NOT upgraded" >&2; exit 10; }
  "$0" upgrade "$node" "$ver" || { echo "ROLL ABORTED: upgrade failed for $node; restore by hand" >&2; exit 11; }
  "$0" restore "$node"
  ;;
*) echo "unknown phase" >&2; exit 1 ;;
esac
