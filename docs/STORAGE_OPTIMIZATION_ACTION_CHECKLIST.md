# Storage Optimization - Action Checklist

**Status:** Ready for implementation  
**Priority:** CRITICAL - Disk space exhaustion  
**Estimated Time:** 5 minutes per phase

---

## PHASE 1: CRITICAL (Immediate - 5 minutes)

### Step 1: Reduce Calibre-web Volume Size

- [ ] Open file: `kubernetes/apps/media/calibre-web/ks.yaml`
- [ ] Find line 23: `VOLSYNC_CAPACITY: 2Gi`
- [ ] Change to: `VOLSYNC_CAPACITY: 1Gi`
- [ ] Save file

### Step 2: Commit and Push Changes

```bash
cd /mnt/home/Users/bluevulpine/repositories/flux-talos
git add kubernetes/apps/media/calibre-web/ks.yaml
git commit -m "chore: reduce calibre-web volume from 2Gi to 1Gi to free disk space"
git push origin main
```

- [ ] Commit successful
- [ ] Push successful

### Step 3: Monitor Disk Space Recovery

```bash
export KUBECONFIG=/mnt/home/Users/bluevulpine/repositories/flux-talos/kubeconfig
kubectl get nodes.longhorn.io brokkr01 -n longhorn-system -o json | \
  jq '.status.diskStatus."data-2" | {storageMaximum, storageScheduled, conditions}'
```

- [ ] Disk space increased
- [ ] Disk becomes schedulable (check conditions)
- [ ] Wait 2-3 minutes for Flux reconciliation

### Step 4: Verify Volsync Pods Start

```bash
kubectl get pods -n media | grep volsync-src | grep -v Running
```

- [ ] No pods in ContainerCreating state
- [ ] All volsync pods in Running state
- [ ] Check pod logs if any issues: `kubectl logs -n media <pod-name>`

### Step 5: Verify Volumes Become Healthy

```bash
kubectl get volumes -n longhorn-system pvc-dc18c89b-8cbd-4531-9c84-c21df0168645 -o json | \
  jq '.status | {state, robustness, ready}'
```

- [ ] Volume state: "healthy"
- [ ] Robustness: "healthy"
- [ ] Ready: "true"

**Phase 1 Complete!** ✅

---

## PHASE 2: MEDIUM (This Week - 10 minutes)

### Step 1: Reduce Plex Cache Volume

- [ ] Open file: `kubernetes/apps/media/plex/ks.yaml`
- [ ] Find line 30: `VOLSYNC_CACHE_CAPACITY: 100Gi`
- [ ] Change to: `VOLSYNC_CACHE_CAPACITY: 30Gi`
- [ ] Save file

### Step 2: Reduce Jellyfin Volume

- [ ] Open file: `kubernetes/apps/media/jellyfin/ks.yaml`
- [ ] Find line 26: `VOLSYNC_CAPACITY: 20Gi`
- [ ] Change to: `VOLSYNC_CAPACITY: 10Gi`
- [ ] Save file

### Step 3: Reduce Tautulli Volume

- [ ] Open file: `kubernetes/apps/media/tautulli/ks.yaml`
- [ ] Find line 27: `VOLSYNC_CAPACITY: 10Gi`
- [ ] Change to: `VOLSYNC_CAPACITY: 4Gi`
- [ ] Save file

### Step 4: Commit and Push

```bash
git add kubernetes/apps/media/plex/ks.yaml \
        kubernetes/apps/media/jellyfin/ks.yaml \
        kubernetes/apps/media/tautulli/ks.yaml
git commit -m "chore: optimize pvc sizes - plex-cache 50Gi->30Gi, jellyfin 20Gi->10Gi, tautulli 10Gi->4Gi"
git push origin main
```

- [ ] Commit successful
- [ ] Push successful

### Step 5: Monitor Changes

```bash
kubectl get pvc -n media -o wide | grep -E "plex|jellyfin|tautulli"
```

- [ ] PVC sizes updated
- [ ] All pods still running
- [ ] No errors in pod logs

**Phase 2 Complete!** ✅

---

## PHASE 3: LOW (Next 2 Weeks - 15 minutes)

### Step 1: Reduce Lidarr, Radarr, Sonarr, Readarr, Tdarr

For each app, open `kubernetes/apps/media/{APP}/ks.yaml`:

- [ ] **lidarr/ks.yaml** line 28: `10Gi` → `4Gi`
- [ ] **radarr/ks.yaml** line 28: `10Gi` → `4Gi`
- [ ] **sonarr/ks.yaml** line 28: `10Gi` → `4Gi`
- [ ] **readarr-audiobooks/ks.yaml** line 28: `10Gi` → `4Gi`
- [ ] **readarr-ebooks/ks.yaml** line 28: `10Gi` → `4Gi`
- [ ] **tdarr/ks.yaml** line 28: `10Gi` → `4Gi`

### Step 2: Commit and Push

```bash
git add kubernetes/apps/media/lidarr/ks.yaml \
        kubernetes/apps/media/radarr/ks.yaml \
        kubernetes/apps/media/sonarr/ks.yaml \
        kubernetes/apps/media/readarr-audiobooks/ks.yaml \
        kubernetes/apps/media/readarr-ebooks/ks.yaml \
        kubernetes/apps/media/tdarr/ks.yaml
git commit -m "chore: optimize pvc sizes - reduce 10Gi volumes to 4Gi"
git push origin main
```

- [ ] Commit successful
- [ ] Push successful

### Step 3: Monitor and Verify

```bash
kubectl get pvc -n media -o wide | grep -E "lidarr|radarr|sonarr|readarr|tdarr"
```

- [ ] All PVC sizes updated
- [ ] All pods running
- [ ] No errors

**Phase 3 Complete!** ✅

---

## Verification Checklist

### After Each Phase

- [ ] Disk space on brokkr01 data-2 increased
- [ ] All pods in media namespace running
- [ ] No pending or failed pods
- [ ] Volsync backups resuming
- [ ] No errors in pod logs

### Long-term Monitoring

- [ ] Set up disk space alerts (>80% usage)
- [ ] Set up PVC usage alerts (>70% utilization)
- [ ] Review usage quarterly
- [ ] Document sizing decisions
- [ ] Plan for growth

---

## Rollback Procedure (If Needed)

If any phase causes issues:

1. Revert the ks.yaml file to original value
2. Commit and push: `git commit -m "revert: restore original pvc size"`
3. Flux will automatically reconcile
4. PVC will be recreated with original size

---

## Success Criteria

### Phase 1 Success
- ✅ Disk data-2 becomes schedulable
- ✅ Volsync pods transition to Running
- ✅ Calibre-web volumes healthy

### Phase 2 Success
- ✅ 84 GB freed
- ✅ All pods running
- ✅ No performance issues

### Phase 3 Success
- ✅ 207+ GB freed
- ✅ Cluster has healthy disk headroom
- ✅ Sustainable long-term capacity

---

## Support Documents

- **STORAGE_CAPACITY_OPTIMIZATION_ANALYSIS.md** - Detailed analysis
- **STORAGE_OPTIMIZATION_TECHNICAL_REFERENCE.md** - Technical details
- **STORAGE_USAGE_METRICS_DETAILED.md** - Detailed metrics
- **STORAGE_OPTIMIZATION_EXECUTIVE_SUMMARY.md** - Executive summary

---

## Questions?

Refer to the detailed analysis documents for:
- Why each size was chosen
- Actual usage metrics
- Risk assessment
- Configuration file locations
- Verification commands

