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

## Root cause: tns-csi `CreateVolume` is not idempotent (deletes live data)

A second, distinct wedge — and the most common one. **This is the real cause of
the failures previously filed here as "dead NFS export"** (e.g. `media/tdarr-r2`,
2026-07-28). It is a `tns-csi` driver bug, not a server-side NFS problem, and it
affects **both NFS and NVMe-oF**.

The CSI spec requires `CreateVolume` to be idempotent. The external-provisioner
sometimes issues a duplicate `CreateVolume` for a volume it has already created.
tns-csi **v0.17.6**'s already-exists path returns a `CreateVolumeResponse`
**without `volume.content_source`**. For a snapshot-sourced PVC the provisioner
validates that field, rejects the reply with `volume content source missing`, and
"rolls back" by calling `DeleteVolume` — **destroying the ZFS dataset behind a PV
that was already created and Bound**. The PVC stays `Bound`, the PV still exists,
but its backing dataset is gone.

Log fingerprint in `tns-csi-controller`, all inside one ~90s window:

```
00:01:09  === CreateVolume CALLED === Name: pvc-XXX     # clone work logged
00:01:49  successfully created PV pvc-XXX / ProvisioningSucceeded
00:01:52  === CreateVolume CALLED === Name: pvc-XXX     # NO clone work = already-exists path
00:02:03  DeleteDataset: Starting deletion of ... pvc-XXX
00:02:46  ProvisioningFailed "volume content source missing"
```

**Three symptoms, one cause.** Which one you see depends on the protocol and on
whether a node had mounted the volume before the erroneous delete landed. Do not
chase these as three separate storage problems:

```
# NFS, never mounted:
MountVolume.MountDevice failed ... mount.nfs: mounting vault.funb.us:/mnt/... failed,
reason given by server: No such file or directory

# NFS, already mounted:
MountVolume.SetUp failed for volume "pvc-..." : applyFSGroup failed for vol
apps/tns-csi/nfs/pvc-...: lstat .../mount: stale file handle

# NVMe-oF (the subsystem for the deleted ZVOL never attaches):
MountVolume.MountDevice failed for volume "pvc-..." : rpc error:
code = DeadlineExceeded desc = context deadline exceeded
code = DeadlineExceeded desc = stream terminated by RST_STREAM with error code: CANCEL
```

Confirmation is identical in every case: the PVC is `Bound` but the backing
dataset/ZVOL is gone. Check the matching tree — `apps/tns-csi/nfs` or
`apps/tns-csi/nvmeof`.

kubelet retries the identical doomed mount forever (e.g. `x849 over 28h`). The
dead volume must be discarded and reprovisioned — re-snapshotting the same PVC
name does not help.

Confirm the dataset really is gone (PVC `Bound`, dataset absent):

```bash
ssh bluevulpine@10.0.10.10 'zfs list -r apps/tns-csi/nfs' | grep <pvc-uid>   # no output
```

List every occurrence (slow, >2min — run it backgrounded):

```bash
kubectl logs -n kube-system deploy/tns-csi-controller -c csi-provisioner --since=380h \
  | grep 'volume content source missing'
```

## Fourth fingerprint: a *stale* dataset blocks the clone (2026-08-29)

The three symptoms above all follow from the dataset being **deleted**. This one is the
inverse — the dataset **already existed** and refused the clone:

```
controller_snapshot_clone.go:359 Failed to clone snapshot: ... [EFAULT] Failed to clone
  snapshot: cannot create 'apps/tns-csi/nvmeof/pvc-<uid>': dataset already exists
```

Node side, the NVMe-oF controller attaches with the correct NQN but the namespace never
appears, so kubelet retries forever:

```
node_nvmeof_discovery.go:312 Device path /dev/nvme2n1 still not ready after ns-rescan
  (controller: nvme2) - returning unhealthy status
MountVolume.MountDevice failed ... code = DeadlineExceeded desc = context deadline exceeded
```

**Distinguish it from the deletion cases before acting:** here `nouuid` is present on the
StorageClasses, and the rollback fingerprint (`volume content source missing` plus a
`DeleteDataset` for the same uid) is **absent**. `zfs list` will *find* the dataset rather
than miss it.

## Fifth fingerprint: the Longhorn clone fails (2026-09-05)

**Not tns-csi at all.** Every fingerprint above is `tns.csi.io`; this one is
`driver.longhorn.io`, and the four checks above will all come back clean and send you
looking in the wrong place. Seen twice in one day: `media/jellyfin-local` wedged
**23h50m** and `develop/hermes-local` **13h07m**.

The attach error is Longhorn's wording, not a mount failure:

```
AttachVolume.Attach failed for volume "pvc-<uid>" : rpc error: code = Aborted
  desc = volume pvc-<uid> is not ready for workloads
```

Confirm it on the Longhorn volume behind the transient clone PVC — `cloneStatus.state`
is the tell:

```bash
PV=$(kubectl -n <ns> get pvc volsync-<app>-local-src -o jsonpath='{.spec.volumeName}')
kubectl -n longhorn-system get volumes.longhorn.io "$PV" \
  -o jsonpath='{.status.state}{"  "}{.status.cloneStatus}{"\n"}'
# detached  {"attemptCount":10,"snapshot":"...","sourceVolume":"...","state":"failed"}
```

`state: failed` with a climbing `attemptCount` means the clone will never complete, so the
staged volume never becomes attachable and the mover waits on it forever. **Check the
source volume too — it is a red herring in this case:** both sources were `attached` /
`healthy` throughout, so a healthy source does not rule this out.

Distinguishing it in one line: the PVC's StorageClass. `longhorn-1-replica*` is this
fingerprint; `tns-csi-*` is one of the four above.

Root cause of the clone failure itself is **not established** — the engine warnings in
`longhorn-manager` (`Failed to get purge status`, `cannot check the CLI API version`) are
downstream of the volume being detached, not the cause. What is established is the
remediation below clears it and the next sync succeeds in about a minute.

## Recovery — pause the source FIRST

**Driver-agnostic:** this procedure clears every fingerprint above, tns-csi or Longhorn.

The wedged object is the transient clone PVC (`volsync-<app>-<dest>-src`), never the app's
live PVC. Deleting it directly will stall in `Terminating`: VolSync immediately respawns a
mover that re-grabs the PVC and holds the `pvc-protection` finalizer.

```bash
# 1. stop the actor, or the next two steps fight it
kubectl -n <ns> patch replicationsource <app>-local --type=merge -p '{"spec":{"paused":true}}'

# 2. clear the mover and the wedged clone PVC (reclaimPolicy=Delete removes the dataset)
#
# NOTE the selector. This step used to read `-l volsync.backube/mover`, which matches
# NOTHING -- it prints "No resources found" and exits 0, so the step looks like it worked
# while leaving the mover in place. A mover pod's actual labels are:
#   app.kubernetes.io/created-by=volsync
#   job-name=volsync-src-<app>-<dest>        (plus the batch.kubernetes.io/ equivalents)
# Scope by job-name, not by created-by alone -- the latter also matches the long-lived
# Syncthing mover Deployment in `games`.
kubectl -n <ns> delete pod -l job-name=volsync-src-<app>-local --force --grace-period=0
kubectl -n <ns> delete pvc volsync-<app>-local-src

# 3. resume
kubectl -n <ns> patch replicationsource <app>-local --type=merge -p '{"spec":{"paused":false}}'
```

**Then restore the trigger.** If you used a manual trigger to test recovery, remove it — a
lingering `spec.trigger.manual` parks the source on `WaitingForManual` and it silently stops
running on schedule:

```bash
kubectl -n <ns> patch replicationsource <app>-local --type=merge \
  -p '{"spec":{"trigger":{"schedule":"<original>","manual":null}}}'
# verify: reason should read WaitingForSchedule, not WaitingForManual
```

### Verify a *backup*, not a cleared alert

`lastSyncTime` advances when the wedged sync is torn down, **with no backup behind it**.
On 2026-09-05 `develop/hermes-local` showed a fresh `lastSyncTime` and
`latestMoverStatus.result: None` — and that source had never once synced since deploy.
Read the mover result, not the timestamp:

```bash
kubectl -n <ns> get replicationsource <app>-local \
  -o jsonpath='{.status.lastSyncTime}{"  result="}{.status.latestMoverStatus.result}{"\n"}'
# want: result=Successful   (not None, not Failed)
```

`lastSyncDuration` is also misleading straight after a wedge — it spans the wedge, so it
reads in hours. A healthy `-local` mover on a small volume finishes in about a minute.

## ⚠️ The stagger mitigation is known-insufficient (2026-08-29)

The model below — that all 9 recorded incidents fell in `00:02:10`–`00:03:06` when the R2
component fired ~39 sources at once, and that *"the staggered `-local` sources ... have never
hit it"* — **no longer holds.**

`games/valheim-local` wedged at **~23:00 on 2026-08-29**: a staggered `-local` source, nowhere
near the R2 burst, with no concurrent fan-out to explain it. Concurrency is therefore not a
sufficient explanation, and staggering is not a sufficient mitigation.

Also, the escape hatch below is closed: `bfenski/tns-csi` newest published tag is **still
v0.17.6** (checked 2026-08-30). There is nothing to upgrade to.

**Durable mitigation instead:** move affected sources off CSI staging entirely with
`VOLSYNC_COPYMETHOD: Direct`, which reads the live PVC and never calls `CreateVolume`.
Caveats: Direct is a crash-consistent live read (do **not** use it for apps holding live
SQLite, e.g. frigate/jellyfin), and on a **ReadWriteOnce** source the mover must land on the
app's node — see `spec.kopia.moverAffinity`. As of 2026-08-30 all 14 existing Direct sources
in this cluster are RWX; RWO Direct is being canaried on `games/valheim`.

**Mitigation applied (not a fix).** 18 days of logs showed 9 incidents across 6
apps and both protocols — **every one between 00:02:10 and 00:03:06** (one burst
destroyed two volumes in the same second), when
`components/volsync/r2.yaml` fired all ~39 R2 sources at once. The staggered
`-local` sources, which run ~24x more often, have never hit it. R2 schedules are
now staggered per-app via `VOLSYNC_R2_SCHEDULE` (00:03–05:49, ~8min apart), which
removes the concurrency that triggers the race. **The driver bug is still
present** — v0.17.6 was the newest release as of 2026-08-07, so there is nothing
to upgrade to. If this recurs, check for a newer `bfenski/tns-csi-driver` tag.

**Hour 03 is intentionally left empty** in that stagger: `kopia-maint-r2` runs at
`0 3 * * *` against the same Kopia R2 repository the backups write to (and
`unifi-phantom-clients-cleanup` runs then too). When adding a new app, pick a free
slot outside hour 03 and confirm it does not collide with that app's own
`VOLSYNC_LOCAL_SCHEDULE`:

```bash
# free slots — minutes are 3,11,19,27,33,41,49,57 in hours 0,1,2,4,5
grep -rh 'VOLSYNC_R2_SCHEDULE' kubernetes/apps/ | sort -u
```

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
# ...wait for the fresh mover to reach Running/Completed, then check the MOVER RESULT --
#    lastSyncTime advances on teardown even when nothing was backed up. See
#    "Verify a *backup*, not a cleared alert" above.
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

**Do not confuse that with the fifth fingerprint above.** Both are Longhorn and both
leave a healthy source, but they fail at different stages: there the *VolumeSnapshot*
never becomes `readyToUse`; in the fifth fingerprint the snapshot is fine and the
*clone from it* fails (`cloneStatus.state: failed` on the Longhorn volume). Deleting the
VolumeSnapshot does not fix a failed clone — check `cloneStatus` before choosing.

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
