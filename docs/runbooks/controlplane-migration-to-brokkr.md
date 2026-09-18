# Plan: move control-plane duty from the jormungandr Pis to the brokkr nodes

**Status: PROPOSED — not executed.** Written 2026-09-18.

## Why

The Pi control planes (4 cores / 7.8 GB) sit at 75-87% memory and fall into a
Talos `OOMController` runaway that SIGKILLs pods across the node. Measured:

- `kube-apiserver` alone is **~3.3 GB steady state** — 42% of a 7.8 GB node.
  It is **not leaking** (7d avg 3708 MB → 3246 → 3351; it oscillates), so a
  restart cadence does not fix it.
- etcd data grew **+18% in four weeks** (147 → 174 MB in use), and apiserver
  working set tracks object count, so this gets worse.
- The Pis are correctly tainted and genuinely CP-only. Nothing to reclaim by
  rescheduling.

This is a sizing mismatch, not a Pi defect — any 8 GB node would do this.
brokkr nodes are 16 cores / 62.6 GB at 25-36% memory and 9-23% CPU. CP duty
costs ~5 GB and ~2 cores, landing the busiest node at ~42% memory / 36% CPU.
etcd also moves from 2.66-2.90 ms mean fsync onto NVMe.

## The constraint that shapes everything

**Talos cannot convert a worker to a control plane in place.** Machine type
changes require a full `talosctl reset` and reinstall — this is by design
(PKI, etcd membership, service topology). There is no promote command.

So each brokkr node must be **wiped and rebuilt**. That is the entire cost of
this plan.

## What a brokkr wipe destroys

| Data | Count | Recovery |
| --- | --- | --- |
| Longhorn replicas on that node | ~100 (97/99/107 across the three) | Must be **evicted first** — Longhorn migrates them to the other two nodes |
| …of which hold live app data | ~22 per node (65 attached, 1 replica) | Eviction, or VolSync restore |
| …of which are disposable | ~60 per node (180 detached, mostly the 138 VolSync caches) | Recreated on demand |
| `openebs-hostpath` PVCs | brokkr01: `dev-shell`, `dev-ubuntu` ×2; brokkr03: arc-runner work | **Node-bound, no replication.** Back up or accept loss |

**243 of 263 Longhorn volumes are `numberOfReplicas: 1`, and every replica
lives on brokkr01/02/03.** That is a standing single-node-failure exposure
independent of this migration, and it is what makes the migration slow: every
node wipe means evicting ~100 replicas off and rebalancing them back.

## Phase 0 — pre-flight (do all of it)

```bash
# 1. etcd healthy, alarms clear, one leader, indices in sync
talosctl -n 10.0.10.31,10.0.10.32,10.0.10.33 etcd status
talosctl -n 10.0.10.31,10.0.10.32,10.0.10.33 etcd alarm list   # must be empty

# 2. Take an etcd snapshot — the rollback of last resort
talosctl -n 10.0.10.31 etcd snapshot /tmp/etcd-pre-migration.snap

# 3. Confirm VolSync backups are current for every app with Longhorn data.
#    This is the real safety net. Do not start until it is green.
flux get kustomizations -A | grep -i volsync
kubectl get replicationsources -A

# 4. Longhorn capacity check — can two nodes hold three nodes' replicas?
kubectl -n longhorn-system get nodes.longhorn.io -o custom-columns=\
'NODE:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'
# Inspect available vs used per disk in the Longhorn UI before proceeding.

# 5. Back up openebs-hostpath data (dev-shell, dev-ubuntu, arc-runner) or
#    explicitly decide it is disposable. It will NOT survive.
```

Also decide up front: **the brokkr CP nodes must still run workloads.**
`talos/talconfig.yaml` line 587 currently has `allowSchedulingOnMasters: false`,
which is what puts the `node-role.kubernetes.io/control-plane:NoSchedule` taint
on the Pis today. Flip it to `true` **before** the first node is rebuilt, or
brokkr01 comes back as a control plane that schedules nothing — and you will
have wiped a third of your worker capacity to gain an idle node.

## Phase 1 — per-node loop

Run this **once per brokkr node, fully, before starting the next.** Never have
two brokkr nodes out at the same time: with single-replica volumes on three
nodes, two out means data loss.

Sequence the etcd membership as **add one, then remove one**, so the cluster
goes 3 → 4 → 3 rather than ever dropping to 2:

```
add brokkr01 → 4 members → remove jormungandr1 → 3
add brokkr02 → 4 members → remove jormungandr2 → 3
add brokkr03 → 4 members → remove jormungandr3 → 3
```

At 4 members quorum is 3, so you can lose exactly one. Do not linger there.

### 1a. Drain Longhorn off the node

```bash
# Disable scheduling, then request eviction; watch replicas migrate away
kubectl -n longhorn-system patch nodes.longhorn.io brokkr0N --type=merge \
  -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'

# WAIT until zero replicas remain on the node. This is the slow step.
kubectl -n longhorn-system get replicas.longhorn.io \
  -o jsonpath='{range .items[*]}{.spec.nodeID}{"\n"}{end}' | grep -c brokkr0N
# must reach 0
```

**Do not proceed while that count is non-zero.** This is the step that
protects the ~22 live single-replica volumes on the node.

### 1b. Drain Kubernetes workloads

```bash
kubectl cordon brokkr0N
kubectl drain brokkr0N --ignore-daemonsets --delete-emptydir-data --timeout=15m
```

### 1c. Flip the node to control plane and regenerate config

In `talos/talconfig.yaml`, for that node: `controlPlane: false` → `true`.
Then regenerate (per CLAUDE.md, `talos/clusterconfig/` is gitignored and
generated — never hand-edit it):

```bash
just talos gen-config
```

### 1d. Wipe and reinstall

```bash
talosctl -n <brokkr0N-ip> reset --graceful=false --reboot --wipe-mode all
# node reboots into maintenance mode, then:
talosctl apply-config --insecure --nodes <brokkr0N-ip> \
  --file talos/clusterconfig/<cluster>-brokkr0N.yaml
```

### 1e. Verify it joined as a control plane

```bash
talosctl -n <brokkr0N-ip> etcd status          # new member, raft index catching up
talosctl -n <all-cp-ips> etcd status           # 4 members, indices converging
kubectl get nodes                              # brokkr0N Ready, control-plane role
```

**Gate: do not continue until raft indices are in sync and alarms are clear.**

### 1f. Remove the paired Pi from etcd

```bash
# If it is the leader, move leadership first
talosctl -n <pi-ip> etcd forfeit-leadership
talosctl -n <pi-ip> etcd remove-member <member-id>
```

Then set that Pi to `controlPlane: false` in `talconfig.yaml`, regenerate,
reset and reinstall it as a **worker** — it keeps driving the rack LCD via
`rackpanel-agent`, alongside j4.

### 1g. Return the node to service

```bash
kubectl uncordon brokkr0N
kubectl -n longhorn-system patch nodes.longhorn.io brokkr0N --type=merge \
  -p '{"spec":{"allowScheduling":true,"evictionRequested":false}}'
```

Let Longhorn rebalance and reach `healthy` on all volumes **before** starting
the next node.

## Rollback points

| Stage | If it fails | Recovery |
| --- | --- | --- |
| Before 1d (wipe) | Anything | Re-enable Longhorn scheduling, uncordon. Zero damage — nothing destructive has happened yet |
| After wipe, node won't join as CP | Config or hardware | Flip `controlPlane` back to `false`, regenerate, reinstall as a worker. Cluster is unchanged; you have lost only that node's local data |
| etcd member won't sync | etcd corruption | `etcd remove-member` the new node, rebuild it as a worker, restore from the Phase 0 snapshot if the cluster is damaged |
| Longhorn volume lost | Eviction missed a replica | VolSync restore from `*-local` (NAS) or `*-r2` |

The irreversible moment is **1d**. Everything before it is free to abandon.

## Honest cost

Three node wipes, roughly 300 replica migrations (~100 off and back per node),
and three etcd membership changes. Each node is hours, not minutes, dominated
by Longhorn rebuild time. The cluster stays up throughout, but capacity is
reduced by one third for the duration of each node.

## The alternative worth pricing first

**Three used x86 mini-PCs as dedicated control planes** — ThinkCentre M720q /
M920q Tiny, Dell OptiPlex Micro, or similar, 16 GB, roughly $100-150 each.

Against this plan that is:

- **No brokkr wipes.** No Longhorn eviction, no rebuild, no `openebs-hostpath`
  loss, no reduced capacity window. The brokkr nodes are never touched.
- **CP isolation preserved** — the property the current design was built for.
  A runaway workload cannot OOM the apiserver.
- **Better CP hardware than either option**: NVMe (sub-millisecond etcd fsync
  versus 2.66-2.90 ms on the Pis), real gigabit NIC, more cores, x86 matching
  the rest of the fleet.
- **Sidesteps the RAM market** — used machines come with their RAM.
- Cheaper than Pi 5 at $305/node ($915 for three).

The migration in this document costs no hardware but spends its budget in risk
and hours instead. If ~$350 for three used SFF machines is acceptable, that is
the lower-risk path and it leaves the brokkr nodes doing what they are good at.

## Regardless of which path: fix the replica exposure

243 of 263 Longhorn volumes run a single replica, all on three nodes. Today,
losing one brokkr node loses ~22 live volumes and forces a VolSync restore.
That is worth addressing on its own merits, and doing it **first** would also
make this migration far safer — evicting replicas is trivial when a second
copy already exists elsewhere.
