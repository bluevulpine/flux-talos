# VolSync Storage Migration: openebs-hostpath → vault-nfs

## Overview

This migration changes the default cache storage class for VolSync backup operations from `openebs-hostpath` to `vault-nfs` to address disk I/O pressure on worker nodes and leverage centralized NFS storage for backup cache operations.

## Migration Details

### What Changed
- **Default Cache Storage Class**: `openebs-hostpath` → `vault-nfs`
- **Affected Components**: All VolSync ReplicationSource and ReplicationDestination resources
- **Destination Storage**: Remains `longhorn` (unchanged)
- **Backup Schedules**: Unchanged (daily at midnight)
- **Retention Policies**: Unchanged

### Files Modified
- `kubernetes/components/volsync/r2.yaml`
- `kubernetes/templates/volsync/r2.yaml`
- `kubernetes/templates/volsync/minio.yaml`

### Applications Affected
All applications using VolSync backup:
- **Plex** (100Gi cache → vault-nfs)
- **Valheim** (8Gi cache → vault-nfs)
- **Satisfactory** (8Gi cache → vault-nfs)
- **Mosquitto** (10Gi cache → vault-nfs)
- **Tautulli** (10Gi cache → vault-nfs)

## Benefits

### Technical
- **Reduced Node I/O**: Offloads cache I/O from local storage to NFS
- **Network Storage Efficiency**: NFS optimized for large sequential transfers
- **Centralized Management**: All cache volumes in one location

### Operational
- **Addresses brokkr01 I/O Issues**: Reduces disk queue pressure
- **Simplified Monitoring**: Single NFS server to monitor
- **Better Resource Utilization**: Distributes I/O load across network

## Rollback Plan

If issues arise, revert by changing defaults back to `openebs-hostpath`:

```yaml
# In all modified files, change:
cacheStorageClassName: "${VOLSYNC_CACHE_SNAPSHOTCLASS:-vault-nfs}"
# Back to:
cacheStorageClassName: "${VOLSYNC_CACHE_SNAPSHOTCLASS:-openebs-hostpath}"
```

## Override Capability

Applications can still override cache storage class if needed:

```yaml
# In application ks.yaml postBuild.substitute:
VOLSYNC_CACHE_SNAPSHOTCLASS: longhorn  # or openebs-hostpath
```

## Monitoring

Monitor the following after migration:
- Backup success rates and duration
- NFS server performance and capacity
- Network utilization during backup windows
- Node disk I/O reduction (especially brokkr01)

## Migration Date
Applied: 2025-11-28
