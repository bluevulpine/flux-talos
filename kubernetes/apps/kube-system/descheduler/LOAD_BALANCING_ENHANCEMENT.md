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
(Table is a 2026-01-10 snapshot and has drifted; as of 2026-09-06 the counts are
brokkr01 86, brokkr02 89, brokkr03 64 pods in phase `Running`, out of 110 allocatable each.
Re-measured 2026-09-06; these drift daily and the ordering flips, so treat any figure here
as a sample. The durable point is that all three sit far above the `pods: 20` threshold.)

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

**Update 2026-09-06 — `evictedPods=0` is the common case, not an invariant.** Over the
retained log window (2026-08-24 → 2026-09-06) the descheduler evicted 62 pods: 55 by
`RemovePodsViolatingNodeTaints`, which is ordinary drain behaviour, and 7 by
`LowNodeUtilization` — all seven of them the same Job pod, in one 32-minute window on
2026-09-04. Reason 3 above did not hold for it. See the next section.

## Job pods: eviction is a restart from scratch, not a retry

`evictLocalStoragePods: true` makes any pod with an `emptyDir` evictable, and that
includes Job pods. For a Job this is not a retry of the failed step: the pod is
deleted, the Job controller creates a **replacement**, and a replacement pod re-runs
every `initContainer` from the beginning.

On 2026-09-04 that hit `kube-system/talos-s3-backup`. Its prune container was
OOMKilling in a loop (`xargs -P 8`, since fixed), which kept a pod that normally lives
~60s alive across descheduler passes. `LowNodeUtilization` then evicted it seven times,
exactly five minutes apart, `18:12:31Z` through `18:42:30Z`. Each replacement re-ran the
`talos-backup` initContainer, so the window produced six 288 MB etcd snapshots instead
of one — a job whose entire purpose is deleting old snapshots raised the object count
by five. Snapshot timestamps line up one-for-one with the evictions; seven evictions
yield six snapshots because the seventh pod was evicted at `18:42:30Z`, the same second
the Job hit `BackoffLimitExceeded`, and logged none.

The objects are still in the `talos` bucket (nothing prunes below 120, ~30 days), so this
is checkable rather than remembered — re-verified 2026-09-06. Sizes are included because
they are part of the evidence: all six are full ~288 MB snapshots, so the missing seventh
is genuinely absent rather than present-but-truncated by the eviction.

```
talos-2026-09-04T18:10:01Z.snap.age   288224168   <- the scheduled 18:10 run
talos-2026-09-04T18:12:34Z.snap.age   292640744   <- eviction 1
talos-2026-09-04T18:17:33Z.snap.age   288224168   <- eviction 2
talos-2026-09-04T18:22:34Z.snap.age   288224168   <- eviction 3
talos-2026-09-04T18:27:59Z.snap.age   288224168   <- eviction 4
talos-2026-09-04T18:34:22Z.snap.age   299421272   <- eviction 5
                                                     evictions 6 and 7: no object
```

Six objects where the schedule called for one, so five extra — and the gap after
`18:34:22Z` is the evidence for the last pod producing nothing. What is *not* verifiable
this far out is the `18:42:30Z` `BackoffLimitExceeded` coincidence itself: those events
and pod logs have long since aged out, so that detail rests on the original observation.

Two things to know before tuning any of this:

- **Every replacement landed back on `brokkr02`**, the node it had just been evicted
  from — all seven times, and all three post-fix runs since. The evictions rebalanced
  nothing.
- **`nodeFit: true` did not prevent that.** The pod carries
  `nodeSelector: kubernetes.io/arch: amd64`, so its only candidates are brokkr01-03,
  and all three were far above the `pods: 20` underutilization threshold — 79/76/61%
  of pod capacity at 18:20Z on 2026-09-04 per Thanos, and 86/89/64 of 110 when
  re-counted on 2026-09-06 — different nodes lead on different days, but none of
  them has ever been near 20. Why `LowNodeUtilization` selected this pod anyway is **not
  established**. The descheduler runs at default verbosity and does not log its
  under/over-utilized node lists; `-v=4` would show them.

**Deliberately not mitigated (2026-09-06).** A Job's `backoffLimit` bounds this: each
eviction is one `.status.failed` increment and one replacement pod, so initContainer
runs are capped at `backoffLimit + 1`. `talos-s3-backup` sets it to 1, and its post-fix
runs finish in 62-94s — roughly 20x under the descheduler's pass interval. The
alternative, a `DefaultEvictor.labelSelector` opt-out label, changes evictability for
every workload in the cluster in order to protect one Job. Revisit if a second
long-running Job gets bitten, or add `backoffLimit` to any new Job whose first step is
expensive.

## Monitoring

```bash
# Pod distribution. Not `-o wide | awk '{print $8}'`: a RESTARTS value rendered as
# "5 (46d ago)" occupies three fields and shifts the node into $10, so that form
# silently miscounts every pod that has ever restarted.
kubectl get pods -A --field-selector=status.phase=Running \
  -o custom-columns=NODE:.spec.nodeName --no-headers | sort | uniq -c | sort -rn

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
| 2026-09-06 | Documented Job-pod eviction re-running initContainers; declined an opt-out |
