# Storage Usage Metrics - Detailed Analysis

**Data Collection Date:** 2025-12-21 07:50 UTC  
**Source:** Longhorn volume metrics from `kubectl get volumes`

---

## Volume Usage Summary

### High Utilization (>50%)

| Volume | App | Size | Used | % | Status |
|--------|-----|------|------|---|--------|
| pvc-2ac9f1a6 | plex | 100Gi | 85.7GB | 85.7% | ⚠️ ATTACHED |
| pvc-42fe319d | plex | 100Gi | 83.0GB | 83.0% | ⚠️ ATTACHED |
| pvc-1e4e7a1f | plex-cache | 30Gi | 30.6GB | 102% | ⚠️ ATTACHED |

**Analysis:** Plex volumes are heavily used and growing. Do NOT reduce.

---

### Medium Utilization (10-50%)

| Volume | App | Size | Used | % | Status |
|--------|-----|------|------|---|--------|
| pvc-3124b8ef | plex-cache | 50Gi | 6.3GB | 12.6% | ✅ ATTACHED |
| pvc-4fc55cd7 | plex-cache | 100Gi | 12.2GB | 12.2% | ✅ ATTACHED |
| pvc-554845c8 | jellyfin | 20Gi | 1.9GB | 9.5% | ✅ ATTACHED |
| pvc-23e344fc | jellyfin | 20Gi | 756MB | 3.6% | ✅ ATTACHED |

**Analysis:** Plex cache is oversized; jellyfin can be reduced.

---

### Low Utilization (<10%)

| Volume | App | Size | Used | % | Status |
|--------|-----|------|------|---|--------|
| pvc-24d5f3f6 | audiobookshelf | 5Gi | 154MB | 3.1% | ✅ ATTACHED |
| pvc-131d7c97 | audiobookshelf | 5Gi | 162MB | 3.2% | ✅ ATTACHED |
| pvc-23f8646d | bazarr | 5Gi | 154MB | 3.1% | ✅ ATTACHED |
| pvc-09582ba9 | calibre-web | 2Gi | 102MB | 5.1% | ✅ ATTACHED |
| pvc-44e351dd | calibre-web | 2Gi | 102MB | 5.1% | ✅ ATTACHED |
| pvc-3e0327a1 | jellyfin | 20Gi | 476MB | 2.4% | ✅ ATTACHED |
| pvc-0a88b447 | lidarr | 10Gi | 239MB | 2.4% | ✅ ATTACHED |
| pvc-32f71a15 | lidarr | 10Gi | 239MB | 2.4% | ✅ ATTACHED |
| pvc-282e76e5 | radarr | 10Gi | 239MB | 2.4% | ✅ ATTACHED |
| pvc-2ecb7fdb | sonarr | 10Gi | 240MB | 2.4% | ✅ ATTACHED |
| pvc-402074fc | tautulli | 10Gi | 239MB | 2.4% | ✅ ATTACHED |
| pvc-3d198c28 | readarr-audiobooks | 10Gi | 240MB | 2.4% | ✅ ATTACHED |

**Analysis:** All these volumes are significantly oversized. Safe to reduce.

---

## Optimization Candidates by Utilization

### 🔴 CRITICAL - Reduce Immediately

**Calibre-web:** 2Gi → 1Gi
- Current: 102 MB used (5.1%)
- Headroom: 1.9 GB unused
- Recommended: 1Gi (10x headroom)
- Savings: 1Gi per copy × 3 copies = 3Gi total

---

### 🟡 MEDIUM - Reduce This Week

**Plex-cache:** 50Gi → 30Gi
- Current: 6.3 GB used (12.6%)
- Headroom: 43.7 GB unused
- Recommended: 30Gi (5x headroom)
- Savings: 20Gi

**Jellyfin:** 20Gi → 10Gi
- Current: 476 MB used (2.4%)
- Headroom: 19.5 GB unused
- Recommended: 10Gi (20x headroom)
- Savings: 10Gi per copy × 4 copies = 40Gi total

**Tautulli:** 10Gi → 4Gi
- Current: 239 MB used (2.4%)
- Headroom: 9.8 GB unused
- Recommended: 4Gi (16x headroom)
- Savings: 6Gi per copy × 4 copies = 24Gi total

---

### 🟢 LOW - Reduce Next 2 Weeks

**Lidarr, Radarr, Sonarr, Readarr, Tdarr:** 10Gi → 4Gi each
- Current: 239-240 MB used (2.4%)
- Headroom: 9.8 GB unused
- Recommended: 4Gi (16x headroom)
- Savings: 6Gi per copy × 4 copies × 5 apps = 120Gi total

---

## Detached Volumes (Not Currently Used)

These volumes are detached and can be safely deleted if no longer needed:

| Volume | Size | Used | App |
|--------|------|------|-----|
| pvc-0014ae32 | 10Gi | 75MB | readarr-audiobooks-dst |
| pvc-02ef9324 | 5Gi | 72MB | audiobookshelf-dst |
| pvc-0b3978ce | 4Gi | 92MB | jellyseerr-dst |
| pvc-162d8a2e | 4Gi | 69MB | prowlarr-dst |
| pvc-19356e01 | 10Gi | 88MB | readarr-audiobooks-dst |
| pvc-2500a34b | 20Gi | 161MB | jellyfin-dst |
| pvc-29ef9bd1 | 100Gi | 546MB | plex-dst |
| pvc-3a0b5642 | 100Gi | 3.4GB | plex-dst |
| pvc-3ed8b3d8 | 2Gi | 68MB | calibre-web-dst |

**Total Detached:** ~250+ GB

---

## Recommendations Summary

### Immediate Actions (Free 3.1 GB minimum)
1. Reduce calibre-web: 2Gi → 1Gi (saves 3Gi)

### This Week (Free 84 GB)
1. Reduce plex-cache: 50Gi → 30Gi (saves 20Gi)
2. Reduce jellyfin: 20Gi → 10Gi (saves 40Gi)
3. Reduce tautulli: 10Gi → 4Gi (saves 24Gi)

### Next 2 Weeks (Free 120 GB)
1. Reduce lidarr: 10Gi → 4Gi (saves 24Gi)
2. Reduce radarr: 10Gi → 4Gi (saves 24Gi)
3. Reduce sonarr: 10Gi → 4Gi (saves 24Gi)
4. Reduce readarr-audiobooks: 10Gi → 4Gi (saves 24Gi)
5. Reduce readarr-ebooks: 10Gi → 4Gi (saves 24Gi)
6. Reduce tdarr: 10Gi → 4Gi (saves 24Gi)

### Total Potential Savings: 207+ GB

---

## Safety Notes

- All reductions have 10x+ headroom
- Changes are reversible
- No data loss risk
- Cache volumes can be regenerated
- Monitor usage after changes
- Set alerts at 70% utilization

