# tns-csi: snapshot-restored XFS volume wedges with "bad superblock" — driver never runs fsck/xfs_repair

**Driver:** `bfenski/tns-csi:v0.17.6` (chart `bfenski/tns-csi-driver:0.17.6`)
**Protocol:** NVMe-oF (TCP) — also applies to iSCSI (any block volume with a filesystem)
**fsType:** `xfs`
**Reporter environment:** Talos v1.12.6, k8s v1.35.3, VolSync (`copyMethod: Snapshot`), TrueNAS SCALE backend.

## Summary

When a VolumeSnapshot is restored to a new block volume and that restored
filesystem is even slightly crash-inconsistent (as any snapshot of a *live,
mounted* XFS filesystem can be), `NodeStageVolume` fails the `mount` with the
generic error below and then **retries the identical failing mount forever**.
The mover pod is stuck in `ContainerCreating` indefinitely (observed 33h,
866 mount attempts) until an operator manually deletes the snapshot + clone +
consumer so a *fresh* snapshot is taken.

```
mount: .../globalmount: wrong fs type, bad option, bad superblock on /dev/nvme2n1,
       missing codepage or helper program, or other error.
```

## Root cause

`node_device.go` formatting logic (line numbers from v0.17.6 klog output):

```
node_device.go:266  Checking if device /dev/nvme2n1 needs formatting (max 25 retries ...)
node_device.go:342  needsFormat attempt 1/25 for /dev/nvme2n1: filesystem detected, needsFormat=false
node_device.go:370  Device /dev/nvme2n1 has existing filesystem, skipping format
driver.go:206       GRPC error: NodeStageVolume returned error: ... bad superblock ...
```

The `needsFormat` heuristic detects an existing filesystem **signature** (via
blkid) and correctly declines to reformat (reformatting would destroy the
restored data). But it then attempts a plain `mount` with **no recovery path**:

1. XFS refuses to mount a filesystem whose log/superblock is inconsistent from a
   crash-consistent snapshot; the driver never runs `xfs_repair` (or `fsck` for
   ext-family) to recover it.
2. On failure the driver loops on the same device state, so the condition is
   **permanent**, not transient — it cannot self-heal.

This makes `copyMethod: Snapshot` backups (VolSync, or any snapshot-restore
workflow) fragile: a single inconsistent snapshot wedges the volume forever.

## Reproduction

1. Provision an XFS NVMe-oF (or iSCSI) PVC and keep it mounted + actively written.
2. Take a VolumeSnapshot of it while writes are in flight (no fs-freeze).
3. Restore the snapshot to a new PVC and mount it (e.g., via a VolSync mover).
4. Intermittently the restore fails to mount with "bad superblock" and retries
   forever. A subsequently retaken snapshot (captured at a consistent moment)
   mounts fine — confirming the data path is sound and the gap is the missing
   recovery/repair step.

## Suggested fixes (any one helps; combined is best)

1. **Run a filesystem check/repair before mount when `needsFormat=false`:**
   - XFS: `xfs_repair -L` is destructive to the log; safer is to attempt
     `mount` and, on failure, run `xfs_repair` then retry once. (Mounting XFS
     normally replays a *clean-but-dirty* log automatically; genuine superblock
     inconsistency needs `xfs_repair`.)
   - ext4/xfs generic: run `fsck -a` / `xfs_repair` on the staged device before
     the first mount attempt.
2. **Surface the failure instead of looping silently** — after N failed mounts,
   fail `NodeStageVolume` with a clear "filesystem requires repair" message and
   an event, so operators/automation can react rather than discovering a 33h
   `ContainerCreating`.
3. **Optionally honor a StorageClass parameter** (e.g.
   `fsRepairOnStage: "true"`) so operators can opt into automatic repair.

## Impact

Silent, permanent backup failure. In our case a critical `VolSyncVolumeOutOfSync`
alert fired for ~33h while the mover retried a doomed mount 866 times; the volume
was only unblocked by manually deleting the snapshot/clone/Job to force a fresh
snapshot.
