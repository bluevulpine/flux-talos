# Storage Optimization - Technical Reference

## How PVC Sizes Are Defined

### 1. **Kustomization Substitution (Primary Method)**

Each media app has a `ks.yaml` file with `postBuild.substitute` section:

```yaml
# kubernetes/apps/media/{APP}/ks.yaml
postBuild:
  substitute:
    APP: *app
    VOLSYNC_CAPACITY: 10Gi          # Main volume size
    VOLSYNC_CACHE_CAPACITY: 4Gi     # Cache volume size (optional)
    VOLSYNC_STORAGECLASS: longhorn
    VOLSYNC_SNAPSHOTCLASS: longhorn-snapclass
```

### 2. **Component Template (Volsync)**

The actual PVC is created from a template:

```yaml
# kubernetes/components/volsync/claim.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: "${APP}"
spec:
  resources:
    requests:
      storage: "${VOLSYNC_CAPACITY:-20Gi}"  # Uses substituted value
  storageClassName: "${VOLSYNC_STORAGECLASS:-longhorn}"
```

### 3. **ReplicationSource/Destination (Volsync)**

Cache volumes are defined in volsync resources:

```yaml
# kubernetes/components/volsync/local.yaml
spec:
  kopia:
    cacheCapacity: ${VOLSYNC_CACHE_CAPACITY:-4Gi}
    cacheStorageClassName: "${VOLSYNC_CACHE_SNAPSHOTCLASS:-vault-nfs}"
```

---

## Current Configuration by Application

### Longhorn Volumes (Main + Volsync Source/Dest)

| App | VOLSYNC_CAPACITY | Total Copies | Total Size |
|-----|------------------|--------------|-----------|
| audiobookshelf | 5Gi | 4 | 20Gi |
| bazarr | 4Gi | 4 | 16Gi |
| calibre-web | 2Gi | 4 | 8Gi |
| jellyfin | 20Gi | 4 | 80Gi |
| jellyseerr | 4Gi | 4 | 16Gi |
| lidarr | 10Gi | 4 | 40Gi |
| notifiarr | 1Gi | 4 | 4Gi |
| plex | 100Gi | 4 | 400Gi |
| prowlarr | 4Gi | 4 | 16Gi |
| radarr | 10Gi | 4 | 40Gi |
| readarr-audiobooks | 10Gi | 4 | 40Gi |
| readarr-ebooks | 10Gi | 4 | 40Gi |
| recyclarr | 1Gi | 4 | 4Gi |
| sonarr | 10Gi | 4 | 40Gi |
| tautulli | 10Gi | 4 | 40Gi |
| tdarr | 10Gi | 4 | 40Gi |

**Total Longhorn:** ~1.2 TB

### NFS Volumes (Volsync Cache)

| App | VOLSYNC_CACHE_CAPACITY | Total Copies | Total Size |
|-----|------------------------|--------------|-----------|
| plex | 100Gi | 2 | 200Gi |
| tautulli | 10Gi | 2 | 20Gi |
| Others | 4-8Gi | 2 | 8-16Gi each |

**Total NFS Cache:** ~400+ GB

---

## Files to Modify for Optimization

### Phase 1: CRITICAL (Calibre-web)

**File:** `kubernetes/apps/media/calibre-web/ks.yaml`

```yaml
# Line 23 - Change from:
VOLSYNC_CAPACITY: 2Gi
# To:
VOLSYNC_CAPACITY: 1Gi
```

**File:** `kubernetes/apps/media/plex/ks.yaml`

```yaml
# Line 30 - Change from:
VOLSYNC_CACHE_CAPACITY: 100Gi
# To:
VOLSYNC_CACHE_CAPACITY: 30Gi
```

### Phase 2: MEDIUM (Jellyfin, Tautulli)

**File:** `kubernetes/apps/media/jellyfin/ks.yaml`

```yaml
# Line 26 - Change from:
VOLSYNC_CAPACITY: 20Gi
# To:
VOLSYNC_CAPACITY: 10Gi
```

**File:** `kubernetes/apps/media/tautulli/ks.yaml`

```yaml
# Line 27 - Change from:
VOLSYNC_CAPACITY: 10Gi
# To:
VOLSYNC_CAPACITY: 4Gi
```

### Phase 3: LOW (Lidarr, Radarr, Sonarr, Readarr, Tdarr)

**Files:** All follow same pattern in `kubernetes/apps/media/{APP}/ks.yaml`

```yaml
# Change from:
VOLSYNC_CAPACITY: 10Gi
# To:
VOLSYNC_CAPACITY: 4Gi
```

---

## Verification Commands

### Check current PVC sizes:
```bash
kubectl get pvc -n media -o wide | grep -E "calibre|plex|jellyfin|tautulli"
```

### Check actual usage:
```bash
kubectl get volumes -n longhorn-system -o json | \
  jq '.items[] | select(.metadata.name | contains("pvc-")) | 
  {name: .metadata.name, size: .spec.size, used: .status.actualSize}'
```

### Monitor disk space after changes:
```bash
kubectl get nodes.longhorn.io brokkr01 -n longhorn-system -o json | \
  jq '.status.diskStatus."data-2"'
```

---

## Rollback Procedure

If a reduction causes issues:

1. Revert the ks.yaml file to original value
2. Commit and push changes
3. Flux will automatically reconcile
4. PVC will be recreated with original size

**Note:** Existing data is preserved; only the requested capacity changes.

---

## Monitoring After Changes

1. **Disk Space:** Should increase on brokkr01 data-2
2. **Pod Status:** Volsync pods should transition to Running
3. **Volume Status:** Volumes should become Healthy
4. **Backup Operations:** Volsync should resume normal backups

---

## Long-term Recommendations

1. **Implement monitoring** for PVC usage
2. **Set alerts** when usage exceeds 70% of allocated size
3. **Review quarterly** and adjust allocations based on trends
4. **Document** why each size was chosen
5. **Plan capacity** with 20-30% headroom for growth

