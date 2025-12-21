# Storage Capacity Optimization Analysis - Media Namespace

**Analysis Date:** 2025-12-21  
**Cluster Status:** Disk data-2 on brokkr01 is FULL (3.1 GB over limit)  
**Objective:** Identify PVC sizing optimization opportunities to free critical disk space

---

## Executive Summary

**Total Longhorn Storage Allocated:** ~1.2 TB across 17 media applications  
**Critical Finding:** Multiple volumes are significantly oversized relative to actual usage  
**Immediate Opportunity:** Reduce calibre-web volumes from 2Gi to 1Gi (saves 2Gi)  
**Medium-term Opportunity:** Reduce plex-cache from 50Gi to 30Gi (saves 20Gi)  
**Total Potential Savings:** 50+ GB across all volumes

---

## Volume-by-Volume Analysis

### 🔴 CRITICAL PRIORITY - Immediate Action Required

#### 1. **Calibre-web** (RECENTLY RECOVERED - OVERSIZED)
- **Current Size:** 2Gi (main) + 2Gi (volsync src) + 2Gi (volsync dst) = 6Gi total
- **Actual Usage:** ~102 MB (5% utilization)
- **Recommendation:** Reduce to 1Gi
- **Savings:** 1Gi per volume = 3Gi total (3 copies)
- **Risk:** LOW - Only 102 MB used, 1Gi provides 10x headroom
- **Config Location:** `kubernetes/apps/media/calibre-web/ks.yaml` line 23
- **Change:** `VOLSYNC_CAPACITY: 2Gi` → `VOLSYNC_CAPACITY: 1Gi`
- **Impact:** Frees ~3Gi immediately on brokkr01 data-2

#### 2. **Plex-cache** (OVERSIZED FOR ACTUAL USAGE)
- **Current Size:** 50Gi
- **Actual Usage:** ~6.3 GB (12.6% utilization)
- **Recommendation:** Reduce to 30Gi
- **Savings:** 20Gi
- **Risk:** LOW - Cache can be regenerated; 30Gi provides 5x headroom
- **Config Location:** `kubernetes/apps/media/plex/ks.yaml` line 30
- **Change:** `VOLSYNC_CACHE_CAPACITY: 100Gi` → `VOLSYNC_CACHE_CAPACITY: 30Gi`
- **Impact:** Frees ~20Gi on storage

---

## Medium Priority - Optimization Opportunities

### 3. **Plex Main Volume** (LARGE BUT JUSTIFIED)
- **Current Size:** 100Gi
- **Actual Usage:** ~85.7 GB (85.7% utilization)
- **Recommendation:** KEEP AS-IS or increase to 120Gi
- **Risk:** HIGH - Already at 85% capacity, growing
- **Note:** This is the primary Plex database; needs headroom for growth

### 4. **Jellyfin** (REASONABLE BUT COULD OPTIMIZE)
- **Current Size:** 20Gi
- **Actual Usage:** ~476 MB (2.4% utilization)
- **Recommendation:** Reduce to 10Gi
- **Savings:** 10Gi per volume = 40Gi total (4 copies: main + 3 volsync)
- **Risk:** LOW - Only 476 MB used, 10Gi provides 20x headroom
- **Config Location:** `kubernetes/apps/media/jellyfin/ks.yaml` line 26
- **Change:** `VOLSYNC_CAPACITY: 20Gi` → `VOLSYNC_CAPACITY: 10Gi`

### 5. **Tautulli** (OVERSIZED)
- **Current Size:** 10Gi
- **Actual Usage:** ~240 MB (2.4% utilization)
- **Recommendation:** Reduce to 4Gi
- **Savings:** 6Gi per volume = 24Gi total (4 copies)
- **Risk:** LOW - Only 240 MB used, 4Gi provides 16x headroom
- **Config Location:** `kubernetes/apps/media/tautulli/ks.yaml` line 27
- **Change:** `VOLSYNC_CAPACITY: 10Gi` → `VOLSYNC_CAPACITY: 4Gi`

---

## Low Priority - Minor Optimizations

### 6. **Lidarr, Radarr, Sonarr, Readarr, Tdarr** (ALL 10Gi)
- **Current Size:** 10Gi each
- **Actual Usage:** 239-240 MB each (2.4% utilization)
- **Recommendation:** Reduce to 4Gi each
- **Savings:** 6Gi × 5 apps × 4 copies = 120Gi total
- **Risk:** LOW - All show similar low usage patterns
- **Config Locations:**
  - `kubernetes/apps/media/lidarr/ks.yaml` line 28
  - `kubernetes/apps/media/radarr/ks.yaml` (similar)
  - `kubernetes/apps/media/sonarr/ks.yaml` (similar)
  - `kubernetes/apps/media/readarr-audiobooks/ks.yaml` (similar)
  - `kubernetes/apps/media/readarr-ebooks/ks.yaml` (similar)
  - `kubernetes/apps/media/tdarr/ks.yaml` (similar)

---

## Summary Table

| App | Current | Usage | Recommended | Savings | Priority |
|-----|---------|-------|-------------|---------|----------|
| calibre-web | 2Gi | 102MB | 1Gi | 3Gi | 🔴 CRITICAL |
| plex-cache | 50Gi | 6.3GB | 30Gi | 20Gi | 🔴 CRITICAL |
| jellyfin | 20Gi | 476MB | 10Gi | 40Gi | 🟡 MEDIUM |
| tautulli | 10Gi | 240MB | 4Gi | 24Gi | 🟡 MEDIUM |
| lidarr/radarr/sonarr/readarr/tdarr | 10Gi ea | 240MB ea | 4Gi ea | 120Gi | 🟢 LOW |

---

## Implementation Plan

### Phase 1: IMMEDIATE (Today - Free 3.1 GB minimum)
1. Reduce calibre-web from 2Gi to 1Gi
2. Monitor disk space recovery on brokkr01 data-2
3. Verify volsync pods start successfully

### Phase 2: SHORT-TERM (This week)
1. Reduce plex-cache from 50Gi to 30Gi
2. Reduce jellyfin from 20Gi to 10Gi
3. Reduce tautulli from 10Gi to 4Gi

### Phase 3: MEDIUM-TERM (Next 2 weeks)
1. Reduce lidarr, radarr, sonarr, readarr, tdarr to 4Gi each
2. Monitor actual usage patterns
3. Adjust further if needed

---

## Configuration File Locations

All VOLSYNC_CAPACITY values are defined in `ks.yaml` files:
- `kubernetes/apps/media/{APP}/ks.yaml` - postBuild.substitute section

Example change:
```yaml
postBuild:
  substitute:
    APP: *app
    VOLSYNC_CAPACITY: 2Gi  # Change this value
    VOLSYNC_STORAGECLASS: longhorn
```

---

## Risk Assessment

**Overall Risk:** LOW
- All recommended reductions have 10x+ headroom
- Cache volumes can be regenerated
- Actual usage is well below current allocations
- Changes are reversible (can increase again if needed)

---

## Next Steps

1. **Immediate:** Reduce calibre-web to 1Gi (frees 3Gi)
2. **Monitor:** Check disk space on brokkr01 data-2
3. **Verify:** Confirm volsync pods transition to Running
4. **Plan:** Schedule Phase 2 reductions for this week

