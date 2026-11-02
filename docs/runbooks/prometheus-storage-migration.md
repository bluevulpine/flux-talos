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

## Procedure

Use a kubeconfig on the `admin@home-kubernetes` context.

1. **Hold Flux and the operator.** `flux suspend hr -n observability kube-prometheus-stack`,
   then `kubectl -n observability scale deploy kube-prometheus-stack-operator --replicas=0`.
   Without the operator stopped, it recreates an orphan-deleted StatefulSet from the
   old spec within seconds.
2. **Orphan the StatefulSet.** `kubectl -n observability delete sts
   prometheus-kube-prometheus-stack --cascade=orphan`. Both pods keep running.
3. **Merge the PR, then resume.** `flux reconcile source git -n flux-system home-kubernetes`,
   `flux resume hr -n observability kube-prometheus-stack`. Scale the operator back
   to 1 if the Helm upgrade did not. The operator finds no StatefulSet, creates
   one from the new spec, and adopts the running pods. If the pod template changed
   too, it rolls them one at a time onto their old PVCs.
4. **Migrate ordinal 1.** `kubectl -n observability delete pvc
   prometheus-kube-prometheus-stack-db-prometheus-kube-prometheus-stack-1 --wait=false`,
   then delete pod `-1`. The new PVC binds only after the pod is scheduled
   (WaitForFirstConsumer). Check that the Longhorn replica is on the pod's node and
   on a different disk from ordinal 0, and that the pod is Ready. Ordinal 0 still
   holds everything, so nothing is lost.
5. **Wait before ordinal 0.** Deleting `-0`'s PVC discards its head, the samples
   after its last uploaded block. Those are safe only once `-1` has been scraping
   for that whole span. Wait until ordinal 0's
   `prometheus_tsdb_head_min_time` is later than the new `-1` pod's start time,
   and ordinal 0's Thanos sidecar has uploaded since then
   (`thanos_shipper_uploads_total` increased). Prometheus cuts a block once
   the head spans 3h, so expect roughly 2-4h.
6. **Migrate ordinal 0** the same way as step 4.
