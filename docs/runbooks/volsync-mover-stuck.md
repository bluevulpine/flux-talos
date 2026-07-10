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
