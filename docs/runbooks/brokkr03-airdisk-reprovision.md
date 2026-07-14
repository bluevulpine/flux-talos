# Runbook: brokkr03 AirDisk EPHEMERAL reprovision

Fixes a first-boot partitioning artifact on brokkr03: its AirDisk 1TB SSD split
`EPHEMERAL` and `u-data-1` unevenly compared to its siblings, leaving
`EPHEMERAL` half the size it should be and chronically short on headroom for
container images. `talos/talconfig.yaml` is not wrong — all three brokkr nodes
declare identical `maxSize: 100GiB` / `grow: false` for `EPHEMERAL`. This is
partition-table drift from the node's original provisioning, not a config bug.

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

2. **postgres18 check:** the CNPG primary (`postgres18-1`) runs on brokkr03,
   but its PVC's only Longhorn replica lives on `data-2` (Samsung, untouched
   by this runbook) — confirmed via `replicas.longhorn.io`. **No switchover
   needed for this operation.** (If a future runbook ever touches `data-2` or
   does a full node wipe, switch the primary to `postgres18-2`/`-3` first via
   `kubectl cnpg promote postgres18 <instance>` or a CNPG `Cluster` primary
   update — not needed here.)

3. **openbao / immich / nexus:** already verified safe by design — openbao's
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
Scope to just the AirDisk's `EPHEMERAL` label and the `u-data-1` partition;
leave `META`/`STATE`/boot alone (they hold this node's cluster identity and
certs — wiping them would force a full re-join, which is unnecessary here).

```bash
export TALOSCONFIG=./talos/clusterconfig/talosconfig

talosctl reset -n 10.0.10.40 \
  --system-labels-to-wipe=EPHEMERAL \
  --user-disks-to-wipe=/dev/nvme1n1p5 \
  --wipe-mode=user-disks \
  --graceful=true \
  --reboot=true
```

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
`/dev/nvme1n1p5` before wiping.

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
against it.

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
