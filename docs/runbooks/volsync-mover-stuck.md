# Runbook: `VolSyncMoverStuck` — VolSync mover stuck in ContainerCreating

**Alert:** `VolSyncMoverStuck` (severity: warning)
**Fires when:** a `volsync-src-*` / `volsync-dst-*` mover pod has a container stuck
in `ContainerCreating` for >20m. Normal movers complete in minutes, so this
indicates the sync is wedged. Usually precedes the critical `VolSyncVolumeOutOfSync`.

## Root cause (historical — now prevented, see below)

The `tns.csi.io` (NVMe-oF / iSCSI, XFS) driver failed `NodeStageVolume` when
mounting a restored VolumeSnapshot, retrying the identical doomed mount forever:

```
MountVolume.MountDevice failed ... tns.csi.io ...
wrong fs type, bad option, bad superblock on /dev/nvmeXn1
```

The actual cause is an **XFS duplicate UUID**, not a corrupt/crash-inconsistent
snapshot. VolSync snapshots the source PVC while it is still mounted and live,
so the restored snapshot/clone carries the *same* XFS filesystem UUID as the
still-mounted source. XFS refuses to mount a filesystem whose UUID duplicates an
already-mounted one, which surfaces as "bad superblock". Because the UUID
collision is inherent to snapshotting a live filesystem, **a fresh snapshot has
the same duplicate UUID — re-snapshotting does not help** (confirmed
2026-07-05: a brand-new clone failed identically).

## Fix — already applied, StorageClass-level (PR #1442)

The permanent fix is `mountOptions: [nouuid]` on the tns-csi StorageClasses
(`tns-csi-nvmeof`, `tns-csi-iscsi`). `nouuid` tells XFS to skip the
UUID-uniqueness check at mount time, so a restored snapshot mounts cleanly
alongside its still-mounted source. Both StorageClasses currently carry
`mountOptions: ["nouuid"]`, so this failure mode is prevented at the
StorageClass level. See
[PR #1442](https://github.com/bluevulpine/flux-talos/pull/1442) for the change.

## If this alert fires now

1. **Regression check** — confirm the StorageClasses still have `nouuid`:

   ```bash
   kubectl get sc tns-csi-nvmeof tns-csi-iscsi -o \
     jsonpath='{range .items[*]}{.metadata.name}{": "}{.mountOptions}{"\n"}{end}'
   ```

2. If `nouuid` is present and the mover is still stuck, this is a **different**
   cause than the historical UUID collision — do not try re-snapshotting.
   Investigate generically:

   ```bash
   # Which mover is stuck, and why (look at Events):
   kubectl -n <ns> describe pod <volsync-...-pod>

   # Confirm the ReplicationSource is wedged (SyncInProgress, stale lastSyncTime):
   kubectl -n <ns> get replicationsource <app>-local \
     -o jsonpath='{.status.conditions[0].reason}{"  last="}{.status.lastSyncTime}{"\n"}'
   ```

   Also check node NVMe-oF/iSCSI connectivity (session state, target
   reachability) — a stuck mover can also indicate a transport-layer issue
   unrelated to the filesystem.

## Root cause: `tns-csi-nfs` stale file handle (needs PAUSE, not just delete)

A second, distinct wedge (seen `media/tdarr-r2`, 2026-07-28) affects the
`tns-csi-nfs` (NFS) driver rather than NVMe-oF/iSCSI. The mover's snapshot-clone
src PVC mounts with a **stale NFS file handle** — the underlying PV's NFS export
is dead (server-side path gone or recreated), so the mount can never succeed:

```
MountVolume.SetUp failed for volume "pvc-..." : applyFSGroup failed for vol
apps/tns-csi/nfs/pvc-...: lstat .../mount: stale file handle
```

kubelet retries the identical doomed mount forever (e.g. `x577 over 19h`). The
dead volume must be discarded and reprovisioned — re-snapshotting the same PVC
name does not help.

**Why the obvious fix deadlocks:** deleting the stuck mover Job + src PVC +
snapshot is *not* enough. VolSync's controller immediately recreates the mover
Job pointing at the same deterministic PVC name, which re-grabs the
`kubernetes.io/pvc-protection` finalizer on the still-`Terminating` PVC and
re-hits the same dead PV. Result: PVC stuck `Terminating`, new mover stuck
`ContainerCreating` — a loop that never converges.

**Recovery — pause first so the mover stops respawning:**

```bash
NS=media; SRC=tdarr-r2   # adjust

# 1. Pause the ReplicationSource — tears down the in-flight Job/pod, releasing
#    pvc-protection so the old PVC + PV + VolumeSnapshot delete cleanly.
kubectl -n "$NS" patch replicationsource "$SRC" --type=merge -p '{"spec":{"paused":true}}'

# 2. Confirm the src pod / PVC / VolumeSnapshot are all gone.
kubectl -n "$NS" get pod,pvc,volumesnapshot | grep "$SRC" || echo "clear"

# 3. Resume — VolSync provisions a fresh snapshot -> PVC (new NFS export) -> mover.
kubectl -n "$NS" patch replicationsource "$SRC" --type=merge -p '{"spec":{"paused":false}}'

# 4. (Optional) validate now instead of waiting for the schedule. Capture the
#    current trigger FIRST, force one manual sync, watch it complete, then restore.
kubectl -n "$NS" get replicationsource "$SRC" -o jsonpath='{.spec.trigger}{"\n"}'   # note the schedule
kubectl -n "$NS" patch replicationsource "$SRC" --type=merge \
  -p '{"spec":{"trigger":{"manual":"recovery-verify","schedule":null}}}'
# ...wait for the fresh mover to reach Running/Completed and lastSyncTime to advance...
kubectl -n "$NS" patch replicationsource "$SRC" --type=merge \
  -p '{"spec":{"trigger":{"schedule":"<ORIGINAL>","manual":null}}}'
```

Restoring the exact original schedule means no Flux drift — the runtime spec
matches the Git manifest again.

**Sibling failure mode (Longhorn, not NFS):** a `*-local-src` VolumeSnapshot stuck
`readyToUse=false` (`waitForSnapshotToBeReady: timeout`) while the source volume is
healthy. No respawn-deadlock here — just
`kubectl -n <ns> delete volumesnapshot volsync-<app>-local-src` and VolSync
recreates a working one on the next reconcile.

## Diagnose

```bash
# Which mover is stuck, and why (look for FailedMount / bad superblock):
kubectl -n <ns> describe pod <volsync-src-...-pod> | sed -n '/Events:/,$p'

# Confirm the ReplicationSource is wedged (SyncInProgress, stale lastSyncTime):
kubectl -n <ns> get replicationsource <app>-local \
  -o jsonpath='{.status.conditions[0].reason}{"  last="}{.status.lastSyncTime}{"\n"}'

# Confirm which snapshot/clone it is mounting:
kubectl -n <ns> get pvc,volumesnapshot | grep 'volsync-<app>-local-src'
```

## Note: `valheim-syncthing` is NOT this

`valheim-syncthing` is a VolSync **Syncthing** continuous mover; it never reports
`lastSyncTime`, so `VolSyncVolumeOutOfSync` false-fires for it perpetually. That
is a separate monitoring gap, not a stuck mount — do not treat it as this issue.
