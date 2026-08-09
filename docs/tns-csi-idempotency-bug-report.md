# Upstream bug report — draft for filing at `fenio/tns-csi`

> Working draft, not cluster config. Delete this file once the issue is filed
> (link it from `docs/runbooks/volsync-mover-stuck.md` at that point).
> Checked 2026-08-07: no existing issue at `fenio/tns-csi` matches.
> Everything below the line is paste-ready as a GitHub issue body.

---

**Title:** `CreateVolume` is not idempotent for snapshot-sourced volumes — provisioner rollback deletes a live, Bound volume's dataset

### Summary

When `CreateVolume` is called a second time for a volume created from a snapshot,
tns-csi returns a `CreateVolumeResponse` whose `volume.content_source` is unset.
`external-provisioner` treats that as a protocol violation, fails the claim with
`volume content source missing`, and rolls back by calling `DeleteVolume`.

Because the *first* `CreateVolume` already succeeded and the PV was created and
Bound, that rollback **deletes the ZFS dataset backing a live, in-use volume**.
The PVC remains `Bound` and the PV still exists, but its backing dataset is gone.
Any pod that had it mounted gets `ESTALE`; any pod that had not yet mounted gets
`ENOENT`. The data is unrecoverable without restoring from backup.

This is silent data destruction triggered by an ordinary, spec-legal retry.

### Environment

| | |
|---|---|
| tns-csi | **v0.17.6** (newest published tag as of 2026-08-07) |
| csi-provisioner | v6.1.0 |
| csi-snapshotter | v8.4.0 |
| Kubernetes | v1.36.2 (Talos v1.13.5) |
| Backing storage | TrueNAS SCALE, `apps/tns-csi/nfs` dataset tree |
| Protocols affected | **both `nfs` and `nvmeof`** |
| Workload | VolSync (Kopia mover), `copyMethod: Snapshot` |

### Expected behavior

Per the [CSI spec for `CreateVolume`](https://github.com/container-storage-interface/spec/blob/master/spec.md#createvolume):

> If the volume corresponding to the `volume_id` already exists and is compatible
> with the specified `capacity_range`, `volume_capabilities` and `parameters` in
> the `CreateVolumeRequest`, the Plugin MUST reply `0 OK` with the corresponding
> `CreateVolumeResponse`.

The "corresponding response" must include the `content_source` that the volume was
created from. `external-provisioner` explicitly validates this and will roll back
if it is missing.

### Actual behavior

The already-exists path returns the volume without populating
`volume.content_source`, so the provisioner rejects it and issues `DeleteVolume`
against a live volume.

### Reproduction

1. Create a `VolumeSnapshot` of an existing `tns-csi` PVC.
2. Create a PVC with that snapshot as `dataSource` (this is what VolSync's
   `copyMethod: Snapshot` does on every sync).
3. Arrange for `CreateVolume` to be slow enough that the provisioner issues a
   duplicate call — in our cluster this happened reliably under concurrent load
   (~39 snapshot-sourced PVCs provisioned simultaneously), where `CreateVolume`
   took 40–47s versus ~14s when uncontended.
4. Observe the dataset being deleted while the PVC is `Bound`.

### Logs

Single ~90 second window, `tns-csi-controller`. Note that the second
`CreateVolume` logs **no clone work at all** — it takes the already-exists path:

```
I0807 00:01:09.937168  controller.go:587]  === CreateVolume CALLED === Name: pvc-2b46a769-4d12-4592-be23-9352fa431ea6
I0807 00:01:09.937183  controller.go:590]  CreateVolume from Snapshot: SnapshotId=nfs:apps/tns-csi/nfs/pvc-b49d8c09-...@snapshot-2c988355-...
I0807 00:01:13.407300  controller_snapshot_clone.go:327] Cloning snapshot ... to new volume pvc-2b46a769-...
I0807 00:01:28.113712  controller_snapshot_clone.go:364] Successfully cloned snapshot to dataset: apps/tns-csi/nfs/pvc-2b46a769-...
I0807 00:01:49.679682  controller_nfs.go:836]  Created NFS volume from snapshot: pvc-2b46a769-...
I0807 00:01:49.680089  controller.go:971]  successfully created PV pvc-2b46a769-... for PVC volsync-readarr-audiobooks-r2-src
I0807 00:01:50.386489  event.go:389]  ... reason="ProvisioningSucceeded" message="Successfully provisioned volume pvc-2b46a769-..."

I0807 00:01:52.417811  controller.go:587]  === CreateVolume CALLED === Name: pvc-2b46a769-4d12-4592-be23-9352fa431ea6   # <-- duplicate
I0807 00:01:52.417863  controller.go:590]  CreateVolume from Snapshot: SnapshotId=nfs:apps/tns-csi/nfs/pvc-b49d8c09-...@snapshot-2c988355-...
                                                                                    # <-- no clone work logged
I0807 00:02:03.205021  client.go:987]   DeleteDataset: Starting deletion of dataset apps/tns-csi/nfs/pvc-2b46a769-...
I0807 00:02:46.158617  client.go:1007]  DeleteDataset: TrueNAS API returned result=true for dataset apps/tns-csi/nfs/pvc-2b46a769-...
I0807 00:02:46.158656  controller_nfs.go:738] Deleted NFS volume: apps/tns-csi/nfs/pvc-2b46a769-...
E0807 00:02:46.159013  controller.go:1009]  "Unhandled Error" err="error syncing claim \"2b46a769-...\": volume content source missing"
I0807 00:02:46.159051  event.go:389]  ... type="Warning" reason="ProvisioningFailed" message="volume content source missing"
```

Aftermath — the PVC is still `Bound` to a PV whose dataset no longer exists:

```console
$ kubectl get pvc -n media volsync-readarr-audiobooks-r2-src
NAME                                STATUS   VOLUME                                     STORAGECLASS
volsync-readarr-audiobooks-r2-src   Bound    pvc-2b46a769-4d12-4592-be23-9352fa431ea6   tns-csi-nfs

$ ssh nas 'zfs list -r apps/tns-csi/nfs' | grep pvc-2b46a769
(no output — dataset gone)
```

### Three distinct symptoms, one cause

Which error surfaces depends only on the protocol and on whether a node had
mounted the volume before the rollback deleted it. All three are the same bug,
which is what makes it easy to misfile as three separate storage problems:

**Not yet mounted** →

```
MountVolume.MountDevice failed for volume "pvc-2b46a769-..." : rpc error: code = Internal
desc = Failed to mount NFS share for staging: exit status 32, output: mount.nfs: mounting
vault:/mnt/apps/tns-csi/nfs/pvc-2b46a769-... failed, reason given by server:
No such file or directory
```

**Already mounted** →

```
MountVolume.SetUp failed for volume "pvc-045d4a3b-..." : applyFSGroup failed for vol
apps/tns-csi/nfs/pvc-045d4a3b-...: lstat /var/lib/kubelet/pods/.../mount: stale file handle
```

**NVMe-oF** → `NodeStageVolume` never returns, because the subsystem/namespace for
the deleted ZVOL cannot be attached:

```
MountVolume.MountDevice failed for volume "pvc-a25b419b-..." : rpc error:
code = DeadlineExceeded desc = context deadline exceeded

MountVolume.MountDevice failed for volume "pvc-a25b419b-..." : rpc error:
code = DeadlineExceeded desc = stream terminated by RST_STREAM with error code: CANCEL
```

Same aftermath as the NFS cases — the PVC stays `Bound` while the ZVOL is gone:

```console
$ kubectl get pvc -n games volsync-satisfactory-r2-src
NAME                          STATUS   VOLUME                                     STORAGECLASS
volsync-satisfactory-r2-src   Bound    pvc-a25b419b-0bd2-4881-9715-5a4c34ed4e78   tns-csi-nvmeof

$ ssh nas 'zfs list -r apps/tns-csi/nvmeof' | grep a25b419b
(no output — ZVOL gone)
```

In the already-mounted NFS case the driver's own log confirms a client had the dataset
open — `DeleteDataset` hit `EBUSY` twice and retried until it succeeded:

```
E0806 00:02:09.781885  client.go:1003] DeleteDataset: API call failed for apps/tns-csi/nfs/pvc-045d4a3b-...:
  Storage API error -32001: {"error":16,"errname":"EBUSY","reason":"[EBUSY] Failed to delete dataset:
  cannot unmount '/mnt/apps/tns-csi/nfs/pvc-045d4a3b-...': pool or dataset is busy"}
I0806 00:02:22.066924  client.go:987]  DeleteDataset: Starting deletion of dataset apps/tns-csi/nfs/pvc-045d4a3b-...
I0806 00:03:04.704234  client.go:1007] DeleteDataset: TrueNAS API returned result=true
```

Deleting a dataset the driver has just been told is busy is itself worth guarding
against, independent of the `content_source` bug.

### Frequency

18 days of controller logs, 9 incidents, 6 different apps, both protocols —
roughly one every two days:

```
2026-07-22 00:02:23  volsync-jellyfin-r2-src            (nfs)
2026-07-22 00:02:29  volsync-readarr-ebooks-r2-src      (nfs)
2026-07-28 00:03:06  volsync-tdarr-r2-src               (nfs)
2026-08-02 00:02:10  volsync-satisfactory-r2-src        (nvmeof)
2026-08-03 00:02:56  volsync-tdarr-r2-src               (nfs)
2026-08-06 00:03:04  volsync-readarr-ebooks-r2-src      (nfs)
2026-08-07 00:02:46  volsync-readarr-audiobooks-r2-src  (nfs)
2026-08-09 00:02:33  volsync-satisfactory-r2-src        (nvmeof)
2026-08-09 00:02:33  volsync-valheim-r2-src             (nvmeof)
```

Every occurrence fell between 00:02:10 and 00:03:06 — the window in which all our
snapshot-sourced PVCs were provisioned concurrently. Note the final pair: two
volumes destroyed in the *same second*, so a single burst can take out multiple
volumes at once.

We have staggered that workload as a mitigation, on the theory that the duplicate
`CreateVolume` is latency-dependent. That is a workaround for the trigger, not a
fix for the bug — any deployment where `CreateVolume` is slow enough to earn a
provisioner retry can lose data.

### Suggested fix

In the `CreateVolume` already-exists path, populate `content_source` on the
returned `Volume` with the same `VolumeContentSource` given in the request,
exactly as the create path does. Roughly:

```go
// already-exists path
return &csi.CreateVolumeResponse{
    Volume: &csi.Volume{
        VolumeId:      volumeID,
        CapacityBytes: capacity,
        VolumeContext: ctx,
        ContentSource: req.GetVolumeContentSource(), // <-- currently missing
    },
}, nil
```

Two hardening suggestions beyond the immediate fix:

1. Treat `EBUSY` from `DeleteDataset` as fatal rather than something to retry
   past. If the dataset is mounted by a client, deleting it destroys live data.
2. Consider refusing `DeleteVolume` for a volume whose PV is still `Bound`, as a
   backstop against provisioner-driven rollback of a successfully published volume.

I am happy to test a patch against the reproduction above.
