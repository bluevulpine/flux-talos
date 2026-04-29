# democratic-csi

Two CSI driver instances backed by the TrueNAS API — one for NFS (ReadWriteMany) and one for iSCSI (ReadWriteOnce).

## Storage Classes

| Storage Class   | Access Mode    | FS    | Use Case                          |
|-----------------|----------------|-------|-----------------------------------|
| `truenas-nfs`   | ReadWriteMany  | NFS   | Media libraries, shared mounts    |
| `truenas-iscsi` | ReadWriteOnce  | XFS   | Databases, block storage workloads |

## Why two instances?

The two drivers must have distinct `csiDriver.name` values. The NFS driver is named `org.democratic-csi.truenas` and the iSCSI driver `org.democratic-csi.truenas-iscsi`. Using a single HelmRelease for both is not supported; they are deployed as separate releases sharing the same OCI chart source.

## iSCSI Snapshot Caveat

Detached snapshots (`detachedSnapshots: "false"`) are disabled on the iSCSI driver. TrueNAS SCALE encrypts child datasets with inherited keys, which breaks snapshot promotion/cloning when datasets are detached from their parent encryption context.

## TrueNAS Configuration

The driver connects to TrueNAS via HTTPS API (v2). ZFS datasets are provisioned under:
- NFS volumes: `apps/democratic-csi/nfs/v`
- iSCSI volumes: `apps/democratic-csi/iscsi/v`
