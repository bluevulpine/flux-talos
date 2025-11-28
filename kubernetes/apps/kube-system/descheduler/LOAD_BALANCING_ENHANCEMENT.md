# Descheduler Load Balancing Enhancement

## Overview

This enhancement adds load balancing strategies to the Kubernetes Descheduler v0.34.0 configuration to address severe pod distribution imbalance in the homelab cluster.

## Problem Statement

**Current Pod Distribution:**
- **brokkr01**: 72 pods (severely overloaded)
- **brokkr02**: 21 pods (moderate load)
- **brokkr03**: 19 pods (underutilized)

**Root Cause:** The existing Descheduler configuration only handled constraint violations but lacked load balancing strategies for resource-based rebalancing.

## Configuration Changes

### ✅ **New Strategies Added**

#### 1. **LowNodeUtilization Strategy**
```yaml
- name: LowNodeUtilization
  args:
    thresholds:
      cpu: 20      # Nodes below 20% are underutilized
      memory: 20   # Nodes below 20% are underutilized  
      pods: 20     # Nodes below 20% pod capacity are underutilized
    targetThresholds:
      cpu: 50      # Evict from nodes above 50% CPU
      memory: 50   # Evict from nodes above 50% memory
      pods: 50     # Evict from nodes above 50% pod capacity
```

**How it works:**
- Identifies nodes below 20% utilization as underutilized
- Evicts pods from nodes above 50% utilization
- Moves pods from high-utilization to low-utilization nodes

#### 2. **RemoveDuplicates Strategy**
```yaml
- name: RemoveDuplicates
```

**How it works:**
- Identifies multiple replicas of the same workload on a single node
- Evicts duplicate pods to spread replicas across different nodes
- Improves fault tolerance and resource distribution

### ⚠️ **Safety Enhancement**
```yaml
evictSystemCriticalPods: false  # Changed from true
```

**Rationale:** Safer for homelab environment - prevents eviction of critical system pods.

### ✅ **Preserved Existing Strategies**
- RemovePodsViolatingInterPodAntiAffinity
- RemovePodsViolatingNodeAffinity  
- RemovePodsViolatingNodeTaints
- RemovePodsViolatingTopologySpreadConstraint

## Expected Impact

### **Immediate Effects (24-48 hours)**
| Node | Current Pods | Expected Pods | Change |
|------|--------------|---------------|---------|
| **brokkr01** | 72 pods | ~35-40 pods | -45% |
| **brokkr02** | 21 pods | ~35-40 pods | +70% |
| **brokkr03** | 19 pods | ~35-40 pods | +85% |

### **Performance Improvements**
- **Reduced I/O pressure** on brokkr01 (addresses disk saturation issues)
- **Better resource utilization** across all brokkr nodes
- **Improved fault tolerance** through replica spreading
- **More even CPU/memory distribution**

### **Threshold Analysis**
**Current brokkr01 utilization:**
- CPU: 7% (1.3/16 cores) - Below 20% threshold ✅
- Memory: 18% (10.7/61GB) - Below 20% threshold ✅  
- Pods: 72 pods - Above 50% threshold ❌ (triggers eviction)

**The pod count threshold will be the primary trigger for rebalancing.**

## Monitoring & Validation

### **Success Metrics**
```bash
# Monitor pod distribution
kubectl get pods -A -o wide | awk '{print $8}' | grep brokkr | sort | uniq -c

# Check Descheduler logs
kubectl logs -n kube-system deployment/descheduler --tail=100

# Monitor node utilization
kubectl top nodes
```

### **Expected Log Messages**
- "Evicted pod" messages for pods moved from brokkr01
- "LowNodeUtilization" strategy execution logs
- "RemoveDuplicates" strategy execution logs

## Rollback Plan

If issues arise, revert by removing the new strategies:

```yaml
# Remove these sections from pluginConfig:
- name: LowNodeUtilization
- name: RemoveDuplicates

# Remove from plugins.balance.enabled:
- LowNodeUtilization

# Remove from plugins.deschedule.enabled:  
- RemoveDuplicates

# Revert safety setting:
evictSystemCriticalPods: true
```

## Implementation Date
Applied: 2025-11-28

## Validation Checklist
- [ ] Configuration syntax validated against descheduler/v1alpha2 schema
- [ ] LowNodeUtilization thresholds confirmed (20%/50% are valid percentages)
- [ ] RemoveDuplicates strategy confirmed as supported in v0.34.0
- [ ] Safety setting (evictSystemCriticalPods: false) applied
- [ ] All existing strategies preserved
- [ ] 5-minute descheduling interval maintained
