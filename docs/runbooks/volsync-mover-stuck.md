# Runbook: `VolSyncMoverStuck` — VolSync mover stuck in ContainerCreating

**Alert:** `VolSyncMoverStuck` (severity: warning)
**Fires when:** a `volsync-src-*` / `volsync-dst-*` mover pod has a container stuck
in `ContainerCreating` for >20m. Normal movers complete in minutes, so this
indicates the sync is wedged. Usually precedes the critical `VolSyncVolumeOutOfSync`.

## Most common cause

The `tns.csi.io` (NVMe-oF / iSCSI, XFS) driver restored a VolumeSnapshot whose
filesystem is crash-inconsistent, so `NodeStageVolume` fails to mount it and
**retries the same doomed mount forever**:

```
MountVolume.MountDevice failed ... tns.csi.io ...
wrong fs type, bad option, bad superblock on /dev/nvmeXn1
```

Root cause + upstream write-up: [`docs/tns-csi-snapshot-mount-issue.md`](../tns-csi-snapshot-mount-issue.md).
The driver never runs `xfs_repair`/`fsck`; a *fresh* snapshot (captured at a
consistent moment) mounts fine, so the fix is to force VolSync to retake one.

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

## Fix — force a fresh snapshot (safe)

Deleting *only* the Job just recreates it against the same bad clone. Delete the
**Job + clone PVC + snapshot** so VolSync regenerates all three. The Kopia
repository and offsite (r2) backups are untouched — this only discards a
transient, point-in-time snapshot.

```bash
kubectl -n <ns> delete job         volsync-src-<app>-local --cascade=foreground
kubectl -n <ns> delete pvc         volsync-<app>-local-src
kubectl -n <ns> delete volumesnapshot volsync-<app>-local-src
```

VolSync restarts the sync within ~1 min. Verify recovery:

```bash
kubectl -n <ns> get replicationsource <app>-local \
  -o jsonpath='{.status.latestMoverStatus.result}{"  last="}{.status.lastSyncTime}{"\n"}'
# expect: Successful  last=<recent timestamp>
```

The transient snapshot/PVC are torn down automatically on a successful sync.

## If it recurs immediately

The retaken snapshot may also be inconsistent. Retry the delete-trio once or
twice (each retake is an independent point-in-time). If it never succeeds, the
source filesystem itself may need attention, or move that workload's backup path
to ext4 (more tolerant of crash-consistent snapshots than XFS). Escalate via the
upstream issue in `docs/tns-csi-snapshot-mount-issue.md`.

## Note: `valheim-syncthing` is NOT this

`valheim-syncthing` is a VolSync **Syncthing** continuous mover; it never reports
`lastSyncTime`, so `VolSyncVolumeOutOfSync` false-fires for it perpetually. That
is a separate monitoring gap, not a stuck mount — do not run the delete-trio for it.
