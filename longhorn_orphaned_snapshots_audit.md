# Longhorn Orphaned Snapshots & Volumes Audit Report
**Generated:** 2025-12-21  
**Cluster:** flux-talos

## Executive Summary

✅ **GOOD NEWS:** All 139 Longhorn volumes have valid source volumes.  
⚠️ **ISSUE FOUND:** 96 VolumeSnapshot objects reference non-existent PVCs (orphaned snapshots).  
✅ **CLONE STATUS:** All 46 volumes in "copy-completed-awaiting-healthy" state have valid sources.

---

## 1. Orphaned VolumeSnapshots (96 Total)

**Criteria:** VolumeSnapshots referencing non-existent source PVCs

### Root Cause
These are **temporary snapshots created by volsync** during backup/restore operations. The source PVCs they reference are:
1. **Destination PVCs** created temporarily during restore operations
2. **Source PVCs** that may be in different namespaces or deleted

### Affected Applications (24 apps, 4 snapshots each)
- download: autobrr, cross-seed, qbittorrent, sabnzbd
- games: satisfactory, valheim
- infrastructure: mosquitto
- media: audiobookshelf, bazarr, calibre-web, jellyfin, jellyseerr, lidarr, notifiarr, plex, prowlarr, radarr, readarr-audiobooks, readarr-ebooks, recyclarr, sonarr, tautulli, tdarr

---

## 2. VolumeSnapshotContent Analysis

**Total objects:** 96  
**Bound to VolumeSnapshots:** 96 (100%)  
**Unbound (orphaned):** 0

✅ **All snapshot content is properly bound**

---

## 3. Volumes in "copy-completed-awaiting-healthy" State

**Total volumes:** 46  
**All have valid source volumes:** ✅ YES

All 23 unique source volumes exist and are healthy.

---

## 4. Failed Clone Volumes

**Total volumes with failed clones:** 0  
✅ **No volumes stuck in "copy-failed" state**

---

## 5. Recommendations

### Safe to Delete
The 96 orphaned VolumeSnapshots are **SAFE TO DELETE** because:
1. They reference non-existent PVCs (temporary snapshots)
2. All snapshot content is properly managed
3. No active clones depend on them
4. Volsync will recreate them as needed

### Cleanup Script
```bash
# Delete all orphaned snapshots
kubectl delete volumesnapshot -n download \
  volsync-autobrr-dst-local-dest-20251219205828 \
  volsync-autobrr-dst-r2-dest-20251219205841 \
  volsync-autobrr-local-src \
  volsync-autobrr-r2-src \
  # ... (repeat for all 96)
```

### No Action Required
- ✅ All clone operations are healthy
- ✅ All source volumes exist
- ✅ No failed clones detected
- ✅ Snapshot content is properly bound

---

## 6. Detailed Orphaned Snapshots List

### Download Namespace (16 snapshots)
```
volsync-autobrr-dst-local-dest-20251219205828 (31h old)
volsync-autobrr-dst-r2-dest-20251219205841 (31h old)
volsync-autobrr-local-src (6h18m old)
volsync-autobrr-r2-src (4h18m old)
volsync-cross-seed-dst-local-dest-20251219205828 (31h old)
volsync-cross-seed-dst-r2-dest-20251219205906 (31h old)
volsync-cross-seed-local-src (8h old)
volsync-cross-seed-r2-src (4h18m old)
volsync-qbittorrent-dst-local-dest-20251219205832 (31h old)
volsync-qbittorrent-dst-r2-dest-20251219205840 (31h old)
volsync-qbittorrent-local-src (6h18m old)
volsync-qbittorrent-r2-src (4h18m old)
volsync-sabnzbd-dst-local-dest-20251219205828 (31h old)
volsync-sabnzbd-dst-r2-dest-20251219205839 (31h old)
volsync-sabnzbd-local-src (6h18m old)
volsync-sabnzbd-r2-src (4h18m old)
```

### Games Namespace (8 snapshots)
```
volsync-satisfactory-dst-local-dest-20251219205803 (31h old)
volsync-satisfactory-dst-r2-dest-20251219205647 (31h old)
volsync-satisfactory-local-src (8h old)
volsync-satisfactory-r2-src (4h17m old)
volsync-valheim-dst-local-dest-20251219205852 (31h old)
volsync-valheim-dst-r2-dest-20251217033734 (4d old) ⚠️ OLDEST
volsync-valheim-local-src (8h old)
volsync-valheim-r2-src (4h18m old)
```

### Infrastructure Namespace (4 snapshots)
```
volsync-mosquitto-dst-local-dest-20251219205647 (31h old)
volsync-mosquitto-dst-r2-dest-20251219205712 (31h old)
volsync-mosquitto-local-src (8h old)
volsync-mosquitto-r2-src (4h17m old)
```

### Media Namespace (64 snapshots)
All 16 media apps have 4 snapshots each (dst-local, dst-r2, local-src, r2-src)

---

## Conclusion

**Cluster Health:** ✅ GOOD
**Action Required:** Optional (cleanup orphaned snapshots)
**Risk Level:** LOW
**Cleanup Script:** See `cleanup_orphaned_snapshots.sh`

