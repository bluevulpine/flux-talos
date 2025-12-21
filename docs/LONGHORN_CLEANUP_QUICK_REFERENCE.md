# Longhorn Cleanup Quick Reference
**Generated:** 2025-12-21

---

## TL;DR

**96 orphaned VolumeSnapshots found** → **SAFE TO DELETE** → **No data loss risk**

---

## One-Line Cleanup

```bash
bash cleanup_orphaned_snapshots.sh
```

---

## What Was Found

### Orphaned Snapshots (96 total)
- **Pattern:** `volsync-{APP}-{dst-local|dst-r2|local-src|r2-src}-*`
- **Reason:** Reference non-existent PVCs (temporary volsync snapshots)
- **Age:** 4 hours to 4 days old
- **Risk:** NONE - safe to delete

### Healthy Volumes (139 total)
- **All have valid source volumes** ✅
- **46 volumes cloning successfully** ✅
- **0 failed clones** ✅

### Calibre-web Issue
- **Status:** RESOLVED ✅
- **Action Taken:** Deleted failed volumes, recreated fresh
- **Current State:** Syncing normally

---

## Cleanup Options

### Option 1: Automated (Recommended)
```bash
bash cleanup_orphaned_snapshots.sh
```

### Option 2: Manual by Namespace
```bash
# Download (16 snapshots)
kubectl delete volumesnapshot -n download \
  volsync-autobrr-dst-local-dest-20251219205828 \
  volsync-autobrr-dst-r2-dest-20251219205841 \
  volsync-autobrr-local-src \
  volsync-autobrr-r2-src \
  # ... (see cleanup_orphaned_snapshots.sh)

# Games (8 snapshots)
kubectl delete volumesnapshot -n games \
  volsync-satisfactory-dst-local-dest-20251219205803 \
  # ... (see cleanup_orphaned_snapshots.sh)

# Infrastructure (4 snapshots)
kubectl delete volumesnapshot -n infrastructure \
  volsync-mosquitto-dst-local-dest-20251219205647 \
  # ... (see cleanup_orphaned_snapshots.sh)

# Media (64 snapshots)
kubectl delete volumesnapshot -n media \
  volsync-audiobookshelf-dst-local-dest-20251219205713 \
  # ... (see cleanup_orphaned_snapshots.sh)
```

### Option 3: Delete All at Once
```bash
# WARNING: This deletes ALL volsync snapshots
# Only use if you're sure you want to delete everything
kubectl delete volumesnapshot -A \
  -l app.kubernetes.io/name=volsync \
  --field-selector metadata.namespace!=longhorn-system
```

---

## Verification

### Before Cleanup
```bash
kubectl get volumesnapshots -A | wc -l
# Should show ~96 orphaned snapshots
```

### After Cleanup
```bash
kubectl get volumesnapshots -A | wc -l
# Should show 0 (or only bound snapshots)
```

### Check Calibre-web Status
```bash
kubectl get volumes -n longhorn-system -o wide | grep calibre
# Should show: healthy or degraded (rebuilding)

kubectl get pvc -n media | grep calibre
# Should show: Bound
```

---

## Safety Checklist

Before running cleanup:
- [ ] Read LONGHORN_AUDIT_SUMMARY.md
- [ ] Verify all volumes have valid sources
- [ ] Confirm no active clones depend on snapshots
- [ ] Backup audit reports (already done)

After cleanup:
- [ ] Verify snapshots deleted: `kubectl get volumesnapshots -A`
- [ ] Check volume status: `kubectl get volumes -n longhorn-system`
- [ ] Monitor calibre-web: `kubectl get pods -n media | grep calibre`

---

## Troubleshooting

### Cleanup Fails
```bash
# Check if snapshots still exist
kubectl get volumesnapshots -A | grep volsync

# Force delete if stuck
kubectl delete volumesnapshot {NAME} -n {NAMESPACE} --grace-period=0 --force
```

### Snapshots Recreated
```bash
# This is normal - volsync recreates them
# Just run cleanup again if needed
bash cleanup_orphaned_snapshots.sh
```

### Volumes Not Healthy
```bash
# Check replica status
kubectl get replicas -n longhorn-system | grep pvc-

# Check events
kubectl get events -n longhorn-system --sort-by='.lastTimestamp'
```

---

## Key Metrics

| Metric | Value | Status |
|--------|-------|--------|
| Total Volumes | 139 | ✅ |
| Orphaned Snapshots | 96 | ⚠️ |
| Failed Clones | 0 | ✅ |
| Valid Source Volumes | 23/23 | ✅ |
| Calibre-web Status | Syncing | ✅ |

---

## Support

For detailed information, see:
- `LONGHORN_AUDIT_SUMMARY.md` - Full summary
- `longhorn_orphaned_snapshots_audit.md` - Detailed audit
- `cleanup_orphaned_snapshots.sh` - Cleanup script

