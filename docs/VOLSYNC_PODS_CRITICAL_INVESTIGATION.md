# CRITICAL: Volsync Pods Investigation - Root Cause Found
**Date:** 2025-12-21 07:50 UTC
**Status:** ⚠️ **CRITICAL ISSUE IDENTIFIED**

---

## 🚨 ROOT CAUSE: DISK SPACE EXHAUSTION

The volsync pods are stuck because **Longhorn disk data-2 on brokkr01 is out of space**.

---

## Critical Finding

**Disk: data-2 on brokkr01**
- Status: **NOT SCHEDULABLE** ❌
- Reason: **DiskPressure**
- Message: "Disk data-2 (/var/mnt/data-2) on the node brokkr01 is not schedulable for more replica"
- Scheduled Total: 2,002,528,501,760 bytes
- Provisioned Limit: 1,999,404,269,568 bytes
- **OVER LIMIT BY: 3,124,232,192 bytes (~3 GB)**

---

## Why Pods Are Stuck

1. **Calibre-web volumes need replicas on brokkr01**
   - pvc-dc18c89b: Needs replica on brokkr01 (currently stopped)
   - pvc-44e351dd: Needs replica on brokkr01 (currently stopped)

2. **Disk data-2 on brokkr01 is full**
   - Cannot schedule new replicas
   - Cannot start stopped replicas
   - Longhorn prevents replica rebuilding

3. **Pods cannot attach volumes**
   - Volumes remain degraded (missing replicas)
   - Pods get "not ready for workloads" error
   - Pods stuck in ContainerCreating

4. **Concurrent rebuild limit is hit**
   - 5 rebuilds per node at limit
   - Calibre-web replicas queued behind others
   - Cannot progress without disk space

---

## Affected Replicas (Stopped on brokkr01)

- pvc-dc18c89b-8cbd-4531-9c84-c21df0168645-r-42820a46 (brokkr03)
- pvc-44e351dd-2946-4cd0-b9da-ebf8608966ad-r-018ca5d0 (brokkr01) ← **STUCK HERE**
- pvc-44e351dd-2946-4cd0-b9da-ebf8608966ad-r-819e8f22 (brokkr02)

---

## Disk Space Analysis

**brokkr01 - data-2:**
- Storage Maximum: 1.99 TB
- Storage Scheduled: 2.00 TB (OVER LIMIT)

---

## Remediation Steps

### Step 1: Identify Safe Replicas to Delete

The safest approach is to delete stopped replicas that have running copies on other nodes.

**Replicas with running copies on other nodes can be safely deleted:**
- Any stopped replica where the volume has at least one running replica elsewhere
- Stopped replicas older than 2 days (likely from previous operations)
- Stopped replicas not currently being rebuilt

### Step 2: Delete Stopped Replicas

**Command to delete a stopped replica:**
```bash
kubectl delete replica <replica-name> -n longhorn-system
```

**Example:**
```bash
kubectl delete replica pvc-0014ae32-5715-42ac-a269-1970b4f12d10-r-91d0500c -n longhorn-system
```

### Step 3: Monitor Disk Space Recovery

After deleting replicas, monitor disk space:
```bash
kubectl get nodes.longhorn.io brokkr01 -n longhorn-system -o json | \
  jq '.status.diskStatus."data-2"'
```

### Step 4: Verify Replica Rebuilding Resumes

Once disk space is freed:
```bash
kubectl get replicas -n longhorn-system | grep pvc-44e351dd
kubectl get replicas -n longhorn-system | grep pvc-dc18c89b
```

### Step 5: Verify Volumes Become Healthy

```bash
kubectl get volumes -n longhorn-system pvc-dc18c89b-8cbd-4531-9c84-c21df0168645 -o json | \
  jq '.status | {state, robustness, ready}'
```

### Step 6: Verify Pods Start

```bash
kubectl get pods -n media | grep volsync-src | grep -v Running
```

---

## Monitoring Commands

**Check disk status:**
```bash
kubectl get nodes.longhorn.io brokkr01 -n longhorn-system -o json | \
  jq '.status.diskStatus | keys[] as $disk | {disk: $disk, schedulable: .[$disk].conditions[] | select(.type=="Schedulable") | .status}'
```

**Check volume status:**
```bash
kubectl get volumes -n longhorn-system -o wide | grep -E "pvc-dc18c89b|pvc-44e351dd"
```

**Check pod status:**
```bash
kubectl get pods -n media | grep volsync-src
```

---

## Prevention for Future

1. **Monitor disk space regularly**
   - Set alerts for disk usage > 80%
   - Plan capacity expansion before hitting limits

2. **Implement replica rebalancing**
   - Distribute replicas more evenly across nodes
   - Prevent single node from becoming bottleneck

3. **Cleanup old stopped replicas**
   - Implement automated cleanup of old stopped replicas
   - Keep disk space buffer for new volumes

4. **Increase concurrent rebuild limit**
   - If hardware allows, increase from 5 to 10
   - Speeds up replica rebuilding process

- Storage Available: 1.62 TB
- **Status: FULL** ❌

**brokkr01 - data-1:**
- Storage Maximum: 915 GB
- Storage Scheduled: 649 GB
- Storage Available: 799 GB
- **Status: OK** ✅

---

## Why This Happened

1. **Cleanup script deleted 96 orphaned snapshots**
   - Freed some space but not enough
   - Disk was already near capacity

2. **Calibre-web recovery created 2 new volumes**
   - Each 2 GB in size
   - Replicas scheduled to brokkr01
   - Pushed disk over limit

3. **Concurrent rebuild limit prevents cleanup**
   - 5 rebuilds per node at limit
   - Cannot delete old replicas to free space
   - Cannot start new replicas due to no space

---

## Solution Required

**Immediate Action: Free disk space on brokkr01 data-2**

Options:
1. **Delete unused replicas** (safest)
   - Identify stopped replicas not needed
   - Delete to free ~3 GB minimum

2. **Expand disk** (if possible)
   - Add more storage to brokkr01
   - Rebalance replicas

3. **Rebalance replicas** (after freeing space)
   - Move replicas from brokkr01 to other nodes
   - Reduce pressure on full disk

---

## Impact

- ✅ Snapshot deletion did NOT cause this
- ✅ Cleanup script worked correctly
- ❌ Disk space was already critical
- ❌ New volumes pushed it over limit
- ❌ 32 volsync pods stuck indefinitely
- ❌ Backups cannot resume

---

## Next Steps

1. Identify which replicas can be safely deleted
2. Delete stopped replicas to free space
3. Monitor disk space recovery
4. Restart replica rebuilding
5. Pods will automatically start when volumes healthy

---

**Investigation Status:** COMPLETE
**Root Cause:** Disk space exhaustion on brokkr01 data-2
**Severity:** CRITICAL
**Action Required:** YES - Free disk space immediately

