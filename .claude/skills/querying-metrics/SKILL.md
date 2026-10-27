---
name: querying-metrics
description: How to query this cluster's metrics history: Thanos query-frontend (raw 30d, 5m 1y, 1h 3y) instead of Prometheus (2d only), why short results usually mean the wrong endpoint or a halted Thanos compactor, and two traps when reading series (label churn, flat-looking windows). Use before running any PromQL query against the cluster, investigating a metric's history, or debugging Thanos store-gateway OOMs or missing long-range data.
---

# Querying metrics: use Thanos, not Prometheus

**Prometheus retains only 2 days.** That is deliberate — it is the standard
Thanos pattern (short local window, sidecar ships blocks to object storage).
Long-term history lives in Thanos:

| | endpoint | retention |
| --- | --- | --- |
| Prometheus (local) | `kube-prometheus-stack-prometheus.observability.svc:9090` | **2d only** |
| **Thanos (use this)** | `thanos-query-frontend.observability.svc:10902` | raw 30d / 5m 1y / **1h 3y** (since 2026-10-16) |

Both speak the same `/api/v1/query` and `/api/v1/query_range` API, so the only
difference is the host. Querying Prometheus for anything older than 48h returns
a truncated series that *looks* like "we don't collect that" rather than an
error — which is exactly how a 2026-08-13 gateway investigation initially
concluded there was no history, when 60 days of it existed in Thanos.

Do **not** "fix" this by raising `retention:` in the kube-prometheus-stack
HelmRelease. It would duplicate what Thanos already stores. (For sizing context
if it ever does come up: ~2.2 GB/day, on a 105 GB PVC using 5.8 GB.)

## Short long-range results or store-gateway OOMs

**If long ranges come back short, or the store-gateway OOMKills, check
`thanos_compact_halted` before touching memory limits.** The compactor runs
compaction, then downsampling, then retention; a compaction error halts it for
good (until a pod restart) and the later stages never run. That is how the
bucket silently grew to ten months of raw in 1,148 blocks during 2026 (ENOSPC on
a 20Gi PVC) while the store-gateway's limit was raised three times. The halt
message is in VictoriaLogs (`k_pod_name:"thanos-compact-0" AND "critical error
detected"`); the pod's own log rotates it away within days. `ThanosCompactHalted`
now alerts on it.

## Reading the results

- **Aggregate away label churn.** Exporters that restart with changed labels
  split one logical series into many. `unpoller_device_memory_utilization_ratio{name="Morpheus"}`
  was 7 separate series over 60d; without `max by(name)(...)` you silently get
  one fragment and misread the trend.
- **A flat series is not proof of no signal.** Check the multi-day shape before
  concluding a metric is useless — the same UDM memory ratio looked flat and
  uninformative over 44h but was a clean sawtooth over 60d.
