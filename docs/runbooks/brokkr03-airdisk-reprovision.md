# Runbook: brokkr03 AirDisk EPHEMERAL reprovision

Fixes a first-boot partitioning artifact on brokkr03: its AirDisk 1TB SSD split
`EPHEMERAL` and `u-data-1` unevenly compared to its siblings, leaving
`EPHEMERAL` half the size it should be and chronically short on headroom for
container images. `talos/talconfig.yaml` is not wrong — all three brokkr nodes
declare identical `maxSize: 100GiB` / `grow: false` for `EPHEMERAL`. This is
partition-table drift from the node's original provisioning, not a config bug.

**Status: executed successfully on 2026-07-14.** `EPHEMERAL` went from 54GB →
107GB, `u-data-1` from 969GB → 916GB — now matching brokkr01 exactly. One real
casualty: `develop/dev-shell-0` (an `openebs-hostpath` PVC, not Longhorn) lost
its data because that storage class was never inventoried before wiping — see
[Lessons learned](#lessons-learned-from-the-2026-07-14-run) before running this
again on another node.

## Root cause

| Node | AirDisk device | `EPHEMERAL` | `u-data-1` |
| --- | --- | --- | --- |
| brokkr01 | nvme0n1 | 107 GB | 916 GB |
| brokkr03 | **nvme1n1** | **54 GB** | 969 GB |

Same 1023GB total, different split. `EPHEMERAL` has `grow: false`, so Talos
never resizes it upward on its own — it's stuck at whatever it got the first
time.

## Identifiers (brokkr03, `10.0.10.40`)

- **AirDisk (target of this runbook):** `nvme1n1`, serial `NHH331R001475P70GX`
  — holds boot/`META`(`p2`)/`STATE`(`p3`)/`EPHEMERAL`(`p4`)/`u-data-1`(`p5`)
- **Samsung 990 EVO 2TB (do not touch):** `nvme0n1`, serial `S7M4NL0X803527R`
  — holds `u-data-2`, backs Longhorn disk `data-2` (UUID `a0517f71-...`)
- Longhorn disk `data-1` (the one being reprovisioned) = UUID `48d0e531-...`,
  path `/var/mnt/data-1`, backed by `u-data-1` on the AirDisk

## Pre-flight (already done, re-verify if time has passed)

1. **Longhorn eviction on `data-1` was already run and completed clean** —
   all replicas migrated off to brokkr01/brokkr02 with zero faults, zero pod
   disruption. Scheduling was left disabled on that disk
   (`allowScheduling: false`) so nothing should have landed back on it since.
   Re-confirm before proceeding:

   ```bash
   kubectl get nodes.longhorn.io brokkr03 -n longhorn-system \
     -o jsonpath='{.spec.disks.data-1}'
   # expect: allowScheduling=false, evictionRequested=true

   kubectl get nodes.longhorn.io brokkr03 -n longhorn-system -o json | \
     python3 -c "import json,sys; d=json.load(sys.stdin); print(d['status']['diskStatus']['data-1']['storageScheduled'])"
   # expect: 0
   ```

   If non-zero, something landed back on the disk — re-run the eviction
   (patch `evictionRequested: true` again) and wait for it to drain before
   continuing.

2. **postgres18 check — promote the primary off the node regardless of which
   disk it's on.** The CNPG primary's PVC's only Longhorn replica lives on
   `data-2` (Samsung, untouched by this runbook), so it looks safe on paper —
   but `kubectl drain` cannot gracefully evict the `longhorn-manager`
   `instance-manager` pod (blocked by its own PodDisruptionBudget, since it's
   still serving live replica traffic). That pod dies uncontrolled the moment
   the node actually reboots, which means *any* volume whose only replica sits
   on this node — including `data-2`-backed ones — goes through a real,
   if brief, network-serving gap right at reboot. **Promote the primary to an
   instance whose replica lives on a different node *before* draining**, even
   if the disk you're wiping isn't the one backing it:

   ```bash
   kubectl cnpg promote postgres18 <instance-number>
   # confirm:
   kubectl get cluster.postgresql.cnpg.io postgres18 -n database -o wide
   ```

   Verify the new primary's pod *and* its Longhorn replica both land off the
   node being worked on before proceeding — pod placement and replica
   placement are independent and both matter.

3. **Audit *every* storage class pinned to the node, not just Longhorn.**
   This is the step that bit us on the first run: `openebs-hostpath` (used by
   dev-shell/dev-container PVCs) provisions a raw directory under
   `/var/openebs/local/<pvc>` directly on whichever node the pod lands on,
   with hard `nodeAffinity` pinning it there permanently. That path lives on
   `EPHEMERAL` — wiping it destroys that data outright, and Longhorn's
   eviction tooling has no visibility into it at all since it isn't a
   Longhorn volume. Check for this *before* draining:

   ```bash
   kubectl get pv -o json | python3 -c "
   import json,sys
   d=json.load(sys.stdin)
   for pv in d['items']:
       if pv['spec'].get('storageClassName') == 'openebs-hostpath':
           ref = pv['spec'].get('claimRef',{})
           aff = pv['spec'].get('nodeAffinity',{}).get('required',{}).get('nodeSelectorTerms',[])
           nodes = [v for t in aff for e in t.get('matchExpressions',[]) if e.get('key')=='kubernetes.io/hostname' for v in e.get('values',[])]
           print(ref.get('namespace'), ref.get('name'), '-> pinned to', nodes)
   "
   ```

   Anything pinned to the node being wiped needs an explicit decision before
   proceeding: back it up, accept the loss, or relocate the workload's data
   manually first (there's no live-migration path for hostpath volumes the
   way there is for Longhorn). Check for VolSync coverage too — the same way
   the Longhorn-backed PVCs were checked below.

4. **openbao / immich / nexus:** already verified safe by design — openbao's
   3-node Raft quorum + its own 6-hourly `snapshot-cronjob` back it
   independently of Longhorn; immich's actual photo library is NFS, the
   Longhorn PVC is just a disposable ML-model cache; nexus is an
   intentionally-unbacked pull-through cache per its own HelmRelease comments.
   Nothing further to do for any of them.

## Step 1 — cordon and drain the node

`EPHEMERAL` backs `/var/lib/containerd` and `/var/lib/kubelet` — wiping it
kills every container's state on this node regardless of what Longhorn does.
Drain first so workloads reschedule cleanly instead of just dying when the
partition disappears.

```bash
kubectl cordon brokkr03
kubectl drain brokkr03 --ignore-daemonsets --delete-emptydir-data --timeout=5m
```

Verify nothing is left except DaemonSet-managed pods:

```bash
kubectl get pods -A --field-selector spec.nodeName=brokkr03 -o wide
```

## Step 2 — wipe only the target partitions

Use `talosctl reset` with **explicit scoping** — the default `--wipe-mode all`
wipes every disk on the node, including the untouched Samsung `data-2` disk.
Scope to just the AirDisk's `EPHEMERAL` and `u-data-1` volumes; leave
`META`/`STATE`/boot alone (they hold this node's cluster identity and certs —
wiping them would force a full re-join, which is unnecessary here).

**Use `--system-labels-to-wipe` for *both* labels — not `--user-disks-to-wipe`
for the user volume.** This isn't a style preference, it's load-bearing:
traced through the actual Talos source
(`internal/app/machined/pkg/runtime/v1alpha1/v1alpha1_sequencer_tasks.go`,
confirmed against Talos v1.13.5, the version this cluster runs) and the two
flags are **not symmetric**:

- `--system-labels-to-wipe=<label>` → `ResetSystemDiskSpec` →
  `partition.VolumeWipeTarget.Wipe()`, which wipes content **and drops the
  GPT partition table entry** (`gpt.DeletePartition()` + `pt.Write()` — added
  in [siderolabs/talos#12207](https://github.com/siderolabs/talos/pull/12207),
  merged 2025-11-13, present in v1.12.0+ and thus in v1.13.x).
- `--user-disks-to-wipe=<device>` → `ResetUserDisks` → calls
  `partition.WipeWithSignatures()` **directly**, with no partition-drop step
  at all. Content-only. The GPT entry — and therefore the partition's exact
  boundaries and size — survives completely untouched.

Despite the flag's name, `--system-labels-to-wipe` isn't actually restricted
to `META`/`STATE`/`EPHEMERAL`: server-side
(`internal/app/machined/internal/server/v1alpha1/v1alpha1_server.go`, `Reset`
handler) each label is looked up as a `VolumeStatus` resource **by ID**, and
`u-data-1` is itself a valid `VolumeStatus` ID — so it can go through the same
flag and get the same partition-dropping treatment. This is *why* the fix
works: `EPHEMERAL` and `u-data-1` are adjacent on the disk, so dropping both
GPT entries leaves one contiguous free region for Talos's next-boot
provisioning pass to correctly hand `EPHEMERAL` its full `maxSize` before
`u-data-1` (`grow: true`) claims what's left — matching the pattern Talos's
own maintainers recommend for a system volume sharing a disk with a user
volume ([siderolabs/talos#12713](https://github.com/siderolabs/talos/discussions/12713)).

Passing only `--user-disks-to-wipe=/dev/nvme1n1p5` (the original, wrong draft
of this runbook) would have dropped `EPHEMERAL`'s partition fine, but
`u-data-1` would have kept its exact 969GB boundary — leaving `EPHEMERAL`
nowhere to grow into, landing right back at ~54GB after reboot. This matches
a prior real-world attempt at this exact fix that silently didn't work.

```bash
export TALOSCONFIG=./talos/clusterconfig/talosconfig

talosctl reset -n 10.0.10.40 \
  --system-labels-to-wipe=EPHEMERAL \
  --system-labels-to-wipe=u-data-1 \
  --wipe-mode=system-disk \
  --graceful=true \
  --reboot=true
```

- `--wipe-mode=system-disk`, not `all` or `user-disks` — the server explicitly
  **rejects** the request if `Mode == USER_DISKS` while
  `SystemPartitionsToWipe` is set, and passing non-empty
  `--system-labels-to-wipe` is also what keeps `systemDiskPaths` empty
  server-side, which is what prevents the dangerous whole-disk
  `ResetSystemDisk` phase (as opposed to the scoped `ResetSystemDiskSpec`)
  from ever running. Don't add `--user-disks-to-wipe` back in for this
  operation — it's unnecessary once both labels are passed via
  `--system-labels-to-wipe`, and mixing modes risks re-triggering the
  content-only path for no benefit.
- `--graceful=true` lets Talos cordon/leave cleanly on its own too (belt and
  suspenders alongside the manual drain in Step 1).
- `--reboot=true` so the node comes back up automatically once wiped.
- Double-check the device/partition names against current reality before
  running — re-run `talosctl -n 10.0.10.40 get disks` and
  `talosctl -n 10.0.10.40 get volumestatus` right before this step in case
  anything shifted since this runbook was written.

**If unsure at execution time**, do a dry check first:

```bash
talosctl -n 10.0.10.40 get volumestatus
talosctl -n 10.0.10.40 get disks
```

and confirm `EPHEMERAL` is still `/dev/nvme1n1p4` and `u-data-1` is still
`/dev/nvme1n1p5` before wiping. To double check the exact GPT partition label
Talos will match against (should be `EPHEMERAL` / `u-data-1` respectively):

```bash
talosctl -n 10.0.10.40 get discoveredvolumes -o yaml | grep -A20 "id: nvme1n1p4\|id: nvme1n1p5" | grep partition_label
```

## Step 3 — wait for the node to come back

```bash
talosctl -n 10.0.10.40 dmesg -f    # watch boot progress, Ctrl-C once it settles
kubectl get nodes brokkr03 -w      # wait for Ready
```

## Step 4 — verify the repartition actually fixed the split

```bash
talosctl -n 10.0.10.40 get volumestatus | grep -E "EPHEMERAL|u-data-1"
```

Expect `EPHEMERAL` at (or near) `100 GB` this time, `u-data-1` correspondingly
smaller (~870GB) — matching the intended `maxSize: 100GiB` from
`talos/talconfig.yaml`. No YAML changes are needed for this — the config
already declared the right sizes; the disk just needed to actually reprovision
against it. **Confirmed on the 2026-07-14 run:** `EPHEMERAL` came back at
`107 GB`, `u-data-1` at `916 GB` — an exact match for brokkr01's split.

Also confirm the disk-pressure issue is resolved as a side effect (fresh
containerd state, no accumulated orphaned overlayfs snapshots):

```bash
kubectl get --raw "/api/v1/nodes/brokkr03/proxy/stats/summary" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d['node']['fs'])"
```

## Step 5 — re-register the disk with Longhorn

The old `data-1` disk entry on `nodes.longhorn.io/brokkr03` still points at the
now-defunct UUID (`48d0e531-...`) — the wipe erased its `longhorn-disk.cfg`
marker along with everything else on that partition. Longhorn will discover
the fresh partition as an unrecognized disk at the same path. Remove the stale
entry and let it re-register, then re-enable scheduling:

```bash
# Remove the stale disk entry (references the old, now-gone UUID)
kubectl patch nodes.longhorn.io brokkr03 -n longhorn-system --type=json \
  -p='[{"op": "remove", "path": "/spec/disks/data-1"}]'

# Longhorn's node controller auto-detects the new partition at /var/mnt/data-1
# on next reconcile (usually within seconds). Confirm it shows up:
kubectl get nodes.longhorn.io brokkr03 -n longhorn-system \
  -o jsonpath='{.spec.disks}' | python3 -m json.tool

# Re-enable scheduling on the newly-registered disk
kubectl patch nodes.longhorn.io brokkr03 -n longhorn-system --type=merge \
  -p '{"spec":{"disks":{"data-1":{"allowScheduling":true}}}}'
```

If Longhorn doesn't auto-add the disk within a minute or two, check the
`longhorn-manager` pod on brokkr03 for errors, and confirm
`/var/mnt/data-1` actually exists and is writable post-reboot.

## Step 6 — uncordon

```bash
kubectl uncordon brokkr03
```

## Step 7 — final validation

```bash
# Node healthy
kubectl get node brokkr03

# No degraded/faulted volumes cluster-wide
kubectl get volumes.longhorn.io -n longhorn-system -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
bad = [v['metadata']['name'] for v in d['items'] if v.get('status',{}).get('robustness') not in ('healthy','unknown')]
print('non-healthy:', bad if bad else 'none')
"

# Original disk-pressure pods (jellyfin etc.) rescheduled and healthy
kubectl get pods -A -o wide | grep brokkr03

# Disk headroom actually improved
kubectl describe node brokkr03 | grep -A2 "^Conditions" | grep DiskPressure
```

Optional: let Longhorn rebalance replicas back onto the fresh `data-1` disk
for data locality, or leave workloads as-is on brokkr01/brokkr02 — both are
fine long-term; the other nodes have headroom to carry the load indefinitely.

## Rollback / abort notes

- Steps 1–4 are non-destructive to anything except the already-evicted
  `EPHEMERAL`/`u-data-1` partitions. If the node fails to come back healthy
  after Step 2's reboot, `META`/`STATE`/boot were never touched, so the node's
  cluster identity and certs are intact — this is recoverable via normal Talos
  troubleshooting (console/IPMI access), not a full re-provision.
- If Step 5's disk re-registration goes sideways, Longhorn simply won't
  schedule anything new to `data-1` until fixed — no data at risk, since
  nothing was ever moved back onto it yet.
- Having physical/IPMI console access to brokkr03 during Step 2–3 is worth
  arranging beforehand, as general practice for any partition-table surgery
  regardless of how well-scoped.

## Lessons learned from the 2026-07-14 run

Everything above already reflects these fixes inline, but for the record —
what actually went wrong on the first live run, in order:

1. **`--user-disks-to-wipe` doesn't drop partitions.** Original draft used it
   for `u-data-1`. Traced the actual Go source before running (see Step 2) and
   caught it pre-execution — this would have silently failed to fix anything,
   reproducing a prior real-world dead end with this exact class of fix.
   Corrected to pass both `EPHEMERAL` and `u-data-1` through
   `--system-labels-to-wipe`, which does drop partitions for either.

2. **`openebs-hostpath` was never inventoried.** The pre-flight data-safety
   pass only covered Longhorn-backed PVCs (`data-1`/`data-2`), because that
   was the storage system being evicted/tested. It didn't occur to check for
   *other* storage classes with data pinned to the node until after the wipe,
   when `develop/dev-shell-0` came up with `FailedMount` against a
   `/var/openebs/local/...` path that no longer existed. That PVC had no
   VolSync backup and the loss was accepted as minor, but the process gap is
   real: **any full-EPHEMERAL-wipe runbook needs to inventory every storage
   class with data on the target node, not just the one being actively
   tested via eviction.** Added as pre-flight step 3 above.

3. **CNPG primary promotion is about the node, not the disk.** Original plan
   only checked whether `postgres18-1`'s *disk* (`data-2`) was in scope, and
   concluded no switchover was needed. That was true for data safety but
   incomplete for availability: the `instance-manager` pod can't be
   gracefully drained (PDB-blocked) and dies uncontrolled on reboot,
   producing a brief network-serving gap for *any* single-replica volume on
   that node — including ones on the untouched disk. The primary was promoted
   to `postgres18-3` (replica on brokkr01) mid-session, on the user's own
   initiative, specifically to avoid the primary riding out that gap. Folded
   into pre-flight step 2 above as a should-always-do, not a
   disk-specific check.

4. **The Longhorn eviction test (documented separately, done before this
   runbook was written) was the right call and worked exactly as expected** —
   zero faults, zero pod disruption, full `data-1` drain in a few minutes.
   Worth repeating as a pre-flight step for any future disk-level Longhorn
   work on this cluster.
