# Descheduler Configuration

## Overview

The Kubernetes Descheduler is configured with load balancing and constraint violation strategies to maintain balanced pod distribution across the homelab cluster's worker nodes.

## Cluster Architecture

### Node Roles
| Node | Role | Taint |
|------|------|-------|
| brokkr01-03 | Worker | None |
| jormungandr1-03 | Control Plane | `node-role.kubernetes.io/control-plane:NoSchedule` |
| jormungandr4 | Control Plane | `node.kubernetes.io/low-power:NoSchedule` |

**Key constraint:** Pods can only be balanced across brokkr worker nodes. Control plane nodes are tainted and won't accept workloads.

## Current Configuration

### LowNodeUtilization Strategy
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
- Identifies nodes below thresholds as underutilized
- Evicts pods from nodes above targetThresholds
- Only evicts if there's a valid destination node (`nodeFit: true`)

### Constraint Violation Strategies
- **RemovePodsViolatingInterPodAntiAffinity** - Fixes anti-affinity violations
- **RemovePodsViolatingNodeAffinity** - Fixes node affinity violations
- **RemovePodsViolatingNodeTaints** - Removes pods from tainted nodes
- **RemovePodsViolatingTopologySpreadConstraint** - Balances topology spread

### Safety Settings
```yaml
evictFailedBarePods: true       # Clean up failed pods
evictLocalStoragePods: true     # Can evict pods with emptyDir
evictSystemCriticalPods: false  # Protect critical system pods
nodeFit: true                   # Only evict if pod can reschedule
```

## Current State (2026-01-10)

### Pod Distribution
| Node | Pods | CPU | Memory |
|------|------|-----|--------|
| brokkr01 | 55 | 9% | 20% |
| brokkr02 | 69 | 12% | 20% |
| brokkr03 | 53 | 51% | 31% |

**Status:** ✅ Balanced - The original imbalance (72/21/19) from Nov 2025 has been resolved.

### Why Evictions Are Limited Now

The descheduler logs show:
```
"Skipping eviction for pod, doesn't tolerate node taint"
"Total number of evictions/requests" evictedPods=0
```

**Reasons:**
1. Pod distribution is already balanced across worker nodes
2. Pods can't move to control plane nodes (taint)
3. `nodeFit: true` prevents evicting pods with nowhere to go
4. Resource utilization is below targetThresholds

## Monitoring

```bash
# Pod distribution
kubectl get pods -A -o wide --no-headers | awk '{print $8}' | grep brokkr | sort | uniq -c

# Node utilization
kubectl top nodes

# Descheduler logs
kubectl logs -n kube-system -l app.kubernetes.io/name=descheduler --tail=100

# Check for evictions
kubectl logs -n kube-system -l app.kubernetes.io/name=descheduler | grep -i evict
```

## Configuration Notes

### Not Enabled (Available Options)
- **RemoveDuplicates** - Spreads replicas across nodes (useful if added)
- **HighNodeUtilization** - Consolidates pods (opposite of LowNodeUtilization)
- **PodLifeTime** - Evicts long-running pods

### Threshold Considerations
With only 3 worker nodes, aggressive thresholds can cause thrashing. Current 20/50 thresholds are conservative.

| Scenario | Recommendation |
|----------|----------------|
| More headroom needed | Raise targetThresholds to 60-70 |
| More aggressive balancing | Lower thresholds to 15/40 |
| Protect emptyDir data | Set `evictLocalStoragePods: false` |

## History

| Date | Change |
|------|--------|
| 2025-11-28 | Added LowNodeUtilization, disabled evictSystemCriticalPods |
| 2026-01-10 | Documented current balanced state, removed outdated predictions |
