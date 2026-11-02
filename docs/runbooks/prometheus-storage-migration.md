# Runbook: change Prometheus's storage class without a double outage

Applies to any change to `prometheusSpec.storageSpec.volumeClaimTemplate` in
`kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml`.
First used 2026-11-02 to move both TSDBs from `longhorn-1-replica` to
`longhorn-1-replica-local` (both replicas had landed on one disk, brokkr02 data-2).

## Why the obvious path is wrong

A StatefulSet's `volumeClaimTemplates` are immutable. prometheus-operator
(v0.93.1, `pkg/k8s/statefulset.go` `ForceUpdateStatefulSet`) answers the 422 by
deleting the StatefulSet with **Foreground** propagation, which deletes **both**
Prometheus pods together, then recreates it. With `podManagementPolicy: Parallel`
both come back together on their **old** PVCs: a full outage of both replicas
(each pays a ~2m40s shutdown snapshot plus WAL replay) and the class still unchanged.

The PVC names do not change, so a pod only gets a new-class volume when its PVC
is deleted while the new template is in force.

## The data-safety gate

Deleting an ordinal's PVC discards its unuploaded head. Those samples are safe only
if the **other** ordinal was scraping for that whole span, i.e. it has not
restarted since the head's oldest sample. Any restart leaves a scrape gap of a few
minutes (shutdown snapshot plus WAL replay) that only the surviving head covers.

**Gate before deleting ordinal X's PVC, with Y the other ordinal.** Query Thanos
(`kubectl -n observability port-forward svc/thanos-query-frontend 19092:10902`,
`dedup=false`). Both values below are Unix **seconds**. `head_min_time` is
milliseconds, hence the `/ 1000`:

```promql
prometheus_tsdb_head_min_time{namespace="observability",pod="prometheus-kube-prometheus-stack-X"} / 1000
kube_pod_container_state_started{namespace="observability",pod="prometheus-kube-prometheus-stack-Y",container="prometheus"}
```

Pass when the first value is later than the second. Also check that X's sidecar logged
`upload new block` after X's head last moved forward
(`kubectl -n observability logs prometheus-kube-prometheus-stack-X -c thanos-sidecar`).
Prometheus cuts a block once the head spans 3h, so the gate opens roughly 2-4h
after Y's last start.

## Procedure

Use a kubeconfig on the `admin@home-kubernetes` context. The runbook ships in
the PR it describes, so until step 3 read it from the PR branch, not `main`.

1. **Hold Flux and the operator.** `flux suspend hr -n observability kube-prometheus-stack`,
   then `kubectl -n observability scale deploy kube-prometheus-stack-operator --replicas=0`.
   If the operator is still running, it recreates an orphan-deleted StatefulSet from the
   old spec within seconds.
2. **Orphan the StatefulSet.** `kubectl -n observability delete sts
   prometheus-kube-prometheus-stack --cascade=orphan`. Both pods keep running.
3. **Merge the PR, then resume.** Do not reconcile by hand. Wait for the push
   webhook, until `kubectl -n observability get hr kube-prometheus-stack -o yaml`
   shows the new `storageClassName` in `spec.values` and `spec.suspend` is still
   `true`. Then `flux resume hr -n observability kube-prometheus-stack`. Scale the
   operator back to 1 if the Helm upgrade did not. The operator finds no
   StatefulSet, creates one from the new spec, and adopts the running pods. Any pod
   template change (the 2026-11-02 one added hard anti-affinity) makes it roll
   them, ordinal 1 then 0, onto their **old** PVCs.
   **Gate:** `kubectl -n observability rollout status sts prometheus-kube-prometheus-stack`
   completes, and both pods are Ready with `controller-revision-hash` equal
   to the StatefulSet's `status.updateRevision`.
4. **Migrate ordinal 1.** **Gate:** the data-safety gate with X=1, Y=0. Ordinal 0
   restarted during step 3's roll, so ordinal 1's head holds the only copy of that
   gap until it is uploaded.
   Cordon every node whose Longhorn disk holds ordinal 0's replica
   (`kubectl -n longhorn-system get replicas.longhorn.io -o wide | grep <ordinal 0 pv>`).
   Otherwise best-effort locality can put the new volume on that same disk. Then
   `kubectl -n observability delete pvc
   prometheus-kube-prometheus-stack-db-prometheus-kube-prometheus-stack-1 --wait=false`
   and `kubectl -n observability delete pod prometheus-kube-prometheus-stack-1`.
   The new PVC binds only after the pod is scheduled (WaitForFirstConsumer).
   **Check:** pod `-1` is Ready, and its PV's single Longhorn replica is on pod `-1`'s
   node, on a different node and disk from ordinal 0's replica. Then uncordon.
   If the replica landed elsewhere, repeat the step with the cordon widened, and do
   not move on.
5. **Hold ordinal 1 steady.** Do not restart, drain or evict ordinal 1 until step 6
   is done. A restart resets the gate's clock.
6. **Migrate ordinal 0.** **Gate:** the data-safety gate with X=0, Y=1, and
   pod `-1` Ready. Then do step 4 with the ordinals swapped: cordon the node holding
   ordinal 1's new replica, delete PVC `...-0` and pod `-0`, check that the new replica
   is on pod `-0`'s node and apart from ordinal 1's, and uncordon.
