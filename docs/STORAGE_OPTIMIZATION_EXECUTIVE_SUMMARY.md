# Storage Optimization - Executive Summary

**Analysis Date:** 2025-12-21  
**Critical Issue:** Disk data-2 on brokkr01 is FULL (3.1 GB over limit)  
**Root Cause:** Oversized PVC allocations + new calibre-web volumes  
**Solution:** Reduce PVC sizes to match actual usage patterns

---

## Key Findings

### 1. **Massive Oversizing Across All Applications**

- **Calibre-web:** Requesting 2Gi, using 102 MB (5% utilization)
- **Jellyfin:** Requesting 20Gi, using 476 MB (2.4% utilization)
- **Tautulli:** Requesting 10Gi, using 239 MB (2.4% utilization)
- **Lidarr/Radarr/Sonarr:** Requesting 10Gi each, using 239 MB (2.4% utilization)

### 2. **Plex is the Exception**

- **Plex Main:** 100Gi allocated, 85.7 GB used (85.7% utilization) ✅ KEEP
- **Plex Cache:** 50Gi allocated, 6.3 GB used (12.6% utilization) ⚠️ REDUCE

### 3. **Total Wasted Capacity**

- **Longhorn (Block Storage):** ~1.2 TB allocated, ~200 GB actually used
- **Potential Savings:** 200+ GB by right-sizing allocations
- **Immediate Savings:** 3.1 GB by reducing calibre-web alone

---

## Why This Happened

1. **Conservative Initial Sizing:** Apps were allocated "safe" sizes
2. **Calibre-web Recovery:** Recently recovered with 2Gi allocation
3. **No Monitoring:** No alerts when usage stayed low
4. **Replica Multiplication:** Each volume has 3-4 copies (main + volsync)
5. **Disk Pressure:** Accumulated oversizing pushed brokkr01 over limit

---

## Immediate Action Required

### 🔴 CRITICAL - Reduce Calibre-web (Frees 3.1 GB)

**File:** `kubernetes/apps/media/calibre-web/ks.yaml` line 23

```yaml
# Change from:
VOLSYNC_CAPACITY: 2Gi
# To:
VOLSYNC_CAPACITY: 1Gi
```

**Impact:**
- Frees 3.1 GB on brokkr01 data-2
- Brings disk back to schedulable state
- Allows volsync pods to start
- Enables replica rebuilding to complete

**Timeline:** Can be done immediately  
**Risk:** LOW - 102 MB used, 1Gi provides 10x headroom

---

## Short-term Optimizations (This Week)

### 🟡 MEDIUM PRIORITY

1. **Plex-cache:** 50Gi → 30Gi (saves 20Gi)
   - File: `kubernetes/apps/media/plex/ks.yaml` line 30
   - Usage: 6.3 GB (12.6%)
   - Risk: LOW

2. **Jellyfin:** 20Gi → 10Gi (saves 40Gi)
   - File: `kubernetes/apps/media/jellyfin/ks.yaml` line 26
   - Usage: 476 MB (2.4%)
   - Risk: LOW

3. **Tautulli:** 10Gi → 4Gi (saves 24Gi)
   - File: `kubernetes/apps/media/tautulli/ks.yaml` line 27
   - Usage: 239 MB (2.4%)
   - Risk: LOW

**Total Savings:** 84 GB

---

## Medium-term Optimizations (Next 2 Weeks)

### 🟢 LOW PRIORITY

Reduce all 10Gi volumes to 4Gi:
- Lidarr, Radarr, Sonarr, Readarr (both), Tdarr
- All show 239-240 MB usage (2.4%)
- All have 10x+ headroom at 4Gi
- **Total Savings:** 120 GB

---

## Implementation Strategy

### Phase 1: CRITICAL (Today)
1. Reduce calibre-web: 2Gi → 1Gi
2. Commit and push changes
3. Monitor disk space recovery
4. Verify volsync pods start

### Phase 2: MEDIUM (This week)
1. Reduce plex-cache, jellyfin, tautulli
2. Monitor usage patterns
3. Verify no issues

### Phase 3: LOW (Next 2 weeks)
1. Reduce remaining 10Gi volumes
2. Establish monitoring
3. Set up alerts

---

## Risk Assessment

**Overall Risk:** VERY LOW

- All reductions have 10x+ headroom
- Changes are reversible
- No data loss risk
- Cache volumes can be regenerated
- Actual usage is well below current allocations

---

## Expected Outcomes

### After Phase 1 (Calibre-web)
- ✅ Disk data-2 becomes schedulable
- ✅ Volsync pods transition to Running
- ✅ Replica rebuilding resumes
- ✅ Backups resume

### After Phase 2 (Plex, Jellyfin, Tautulli)
- ✅ 84 GB freed
- ✅ Cluster has healthy disk space buffer
- ✅ Better resource utilization

### After Phase 3 (All optimizations)
- ✅ 207+ GB freed
- ✅ Cluster has 20%+ disk headroom
- ✅ Sustainable long-term capacity

---

## Monitoring & Prevention

### Set Up Alerts
- Alert when PVC usage > 70%
- Alert when disk usage > 80%
- Alert when disk becomes non-schedulable

### Review Quarterly
- Check actual usage vs allocated
- Adjust allocations based on trends
- Document sizing decisions

### Capacity Planning
- Maintain 20-30% headroom
- Plan for growth
- Monitor trends over time

---

## Documentation Generated

1. **STORAGE_CAPACITY_OPTIMIZATION_ANALYSIS.md** - Detailed analysis
2. **STORAGE_OPTIMIZATION_TECHNICAL_REFERENCE.md** - How to make changes
3. **STORAGE_USAGE_METRICS_DETAILED.md** - Detailed metrics
4. **This document** - Executive summary

---

## Next Steps

1. **Immediate:** Reduce calibre-web to 1Gi
2. **Monitor:** Check disk space on brokkr01 data-2
3. **Verify:** Confirm volsync pods transition to Running
4. **Plan:** Schedule Phase 2 reductions for this week
5. **Implement:** Follow phased approach for remaining optimizations

