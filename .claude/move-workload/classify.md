# P0 — classify the workload FIRST

Goal: decide whether `<APP>` in `<OLD>` is covered by this workflow. **Only one class is covered: VolSync + Longhorn PVC.** Everything else is refused or
escalated with a reason — do not "adapt" the workflow to it. All commands here are **read-only** (`get`/`describe`/`grep`); nothing mutates.

Placeholders: `APP` `OLD` `NEW`. Full names for VolSync kinds: `replicationsource.volsync.backube` (bare `rs` resolves to ReplicaSets).

## Discovery (run all; paste the output into the P0 status)

```bash
# 1. what the app owns: PVCs, pods, RS/RD, controllers
kubectl -n OLD get pvc,deploy,statefulset,cronjob,job,pod -o wide | grep -E "APP|NAME"
kubectl -n OLD get pvc -o json | jq -r '.items[]|"\(.metadata.name) vol=\(.spec.volumeName) sc=\(.spec.storageClassName) \(.status.phase) cap=\(.status.capacity.storage) ds=\(.spec.dataSourceRef.kind // "-")"'
# 2. StorageClass + PV reclaim (Delete + prune:true = trap 2)
SC=$(kubectl -n OLD get pvc APP -o jsonpath='{.spec.storageClassName}'); PV=$(kubectl -n OLD get pvc APP -o jsonpath='{.spec.volumeName}')
kubectl get sc "$SC" -o jsonpath='{.provisioner} reclaim={.reclaimPolicy} binding={.volumeBindingMode}{"\n"}'
kubectl get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy} {.status.phase} {.spec.csi.driver} {.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}'
# 3. backup engine + schedules (the schedule sets the window's clock rules, workflow P5)
kubectl -n OLD get replicationsource.volsync.backube,replicationdestination.volsync.backube 2>&1 | grep -E "APP|NAME"
kubectl -n OLD get replicationsource.volsync.backube -o json | jq -r '.items[]|"\(.metadata.name) \(.spec.trigger) last=\(.status.lastSyncTime) \(.status.latestMoverStatus.result)"'
kubectl get snapshotpolicy -A 2>&1 | grep -i APP || echo "no kopiur SnapshotPolicy for APP"         # kopiur => class C, escalate
kubectl get crd | grep -E "kopiur|volsync"                                                        # which engines exist at all
# 4. secrets / ExternalSecrets (kopiur adds per-namespace repo secrets; VolSync ones are ns-independent)
kubectl -n OLD get externalsecret | grep -E "APP|NAME"
# 5. ingress + dashboards keyed by namespace (gatus key becomes NEW_APP; homepage group)
kubectl get httproute -A | grep -E "APP|NAMESPACE"
kubectl -n OLD get httproute APP -o jsonpath='{.metadata.annotations}{"\n"}' 2>/dev/null
# 6. consumers in the repo: other apps pointing at OLD/APP (service DNS, refs, comments)
grep -rnE "APP\.OLD(\.svc)?|OLD/APP|apps/OLD/APP" kubernetes docs --include='*' 2>/dev/null | grep -v "^kubernetes/apps/OLD/APP/"
grep -rn "APP" kubernetes/apps/OLD/kustomization.yaml kubernetes/apps/NEW/kustomization.yaml kubernetes/flux 2>/dev/null
# 7. target namespace: exists? PSA? the VolSync privileged-movers annotation must be LIVE (not just in a manifest)
kubectl get ns NEW -o json | jq '{labels:.metadata.labels,annotations:.metadata.annotations}'
kubectl get ns NEW -o jsonpath='{.metadata.annotations.volsync\.backube/privileged-movers}{"\n"}'   # want: true (same as OLD if OLD has it)
kubectl -n NEW get all,pvc,externalsecret,httproute 2>&1 | grep -E "APP" || echo "nothing named APP in NEW"
# 8. open PRs / Renovate touching the app or the shared paths (must be none, or held)
gh pr list -R bluevulpine/flux-talos --state open --json number,title,author,files --jq '.[]|select(.files[]?.path|test("apps/(OLD|NEW)/(APP|kustomization)|components/volsync"))|"#\(.number) \(.author.login) \(.title)"'
# 9. free Longhorn space (transient need ~ RD dest + cache + creation-time syncs; hermes 20Gi app => ~116Gi — INFERRED in the hermes review, not measured)
kubectl -n longhorn-system get nodes.longhorn.io -o json | jq -r '.items[]|"\(.metadata.name) \((.status.diskStatus // {})|to_entries|map("\((.value.storageAvailable/1073741824)|floor)Gi free")|join(","))"'
# 10. anything Pending that requests the same StorageClass (trap 10 thief)
kubectl get pvc -A -o json | jq -r '.items[]|select(.status.phase=="Pending")|"\(.metadata.namespace)/\(.metadata.name) sc=\(.spec.storageClassName)"'
```

## Decision tree

Answer in order; the **first** match decides. State the class, the evidence line, and the action.

| # | If … | Class | Action |
| --- | --- | --- | --- |
| 1 | No PVC (no `volumeName` anywhere) and no RS/RD | **A. Stateless** | Simple move: `git mv` the app dir + the two kustomization lists + `ks.yaml` (`path`, `targetNamespace`, `NS`); run the pre-merge gate with `want=0`. No PV, no window, no guards. Check consumers (discovery 6) and the route hand-over (trap 13: oldest route wins → brief blip). **Not this workflow** — say so and do it inline. |
| 2 | Exactly one PVC on a Longhorn StorageClass **and** exactly one `ReplicationSource` pair (`APP-local`, `APP-r2`) + one `ReplicationDestination` (`APP-dst-local`), from `components/volsync-claim` + `components/volsync-backup` | **B. VolSync + Longhorn PVC** | **COVERED — this workflow.** Preconditions: `privileged-movers` live on NEW (§6.5), no kopiur policy, no open PR, free space, PV name captured. Continue to P1. |
| 3 | The app has a kopiur `SnapshotPolicy` / `components/kopiur` (identity `hostname: ${NS}`, `allowedNamespaces`, per-namespace `kopiur-local`/`kopiur-r2` ExternalSecrets) | **C. kopiur-backed** | **Differs — ESCALATE.** Runbook §6.4: `NEW` must be added to both `ClusterRepository.allowedNamespaces` lists and the per-namespace ExternalSecret pair; `NS: NEW` forks the identity (decoupling from `NS` is an open question). Not tested. Do not run this workflow's B3/B9 checks (they assume `RS/APP-local`). |
| 4 | PVC on an NFS / tns-csi / `democratic-csi` StorageClass (any non-Longhorn CSI), or an `nfs` volume in the pod | **D. NFS / tns-csi PVC** | **ESCALATE — not covered.** The Retain/re-point mechanics were proven on Longhorn only; tns-csi has its own snapshot/clone semantics (see `docs/runbooks/volsync-mover-stuck.md`). Bare NFS *mounts* (media libraries) with no owned PVC are fine to move like class A. |
| 5 | The app owns a CNPG `Cluster`/`Database` or bootstraps via `postgres-init` (`INIT_POSTGRES_*`) | **E. Database-backed** | **ESCALATE.** The Postgres data does not move with a namespace; only the app's PVC does. `postgres-init` re-creates the role/DB (and **resets the role password** on every start). Decide: does the DB stay on `postgres18` (usual: nothing to move) or is the CNPG cluster itself moving (separate project, not this). |
| 6 | The workload is a **StatefulSet** with `volumeClaimTemplates` | **F. StatefulSet PVCs** | **ESCALATE.** Claims are named `<tpl>-<sts>-<n>`, not `APP`; the guards assume claim name = `APP`; per-ordinal PVs. Not covered. |
| 7 | **More than one** PVC or RD/RS pair in the app build (e.g. a config PVC + a data PVC) | **G. Several PVCs** | **REFUSE.** The kind-targeted patches (`target: {kind: PersistentVolumeClaim}` / `ReplicationDestination`) apply to **every** object of the kind: they would pin all claims to one `volumeName` and stamp one `sourceNamespace` on all RDs. Name-targeting is silently dropped (trap 5). Needs a redesigned patch — not this workflow. |
| 8 | The claim is not `Bound`, or a RS has never succeeded, or the PVC is Pending/Terminating | **not ready** | Stop. Fix the app's health first (`docs/runbooks/volsync-mover-stuck.md`). (A PV that is *already* `Retain` is **not** a reason to stop — it is the state T-1.3 creates, an aborted earlier window leaves it, and a Retain StorageClass starts there; then T-1.3 is a read-back.) |
| 9 | Anything else | **unknown** | Stop and ask. |

**Verify class B mechanically** before `CLASSIFIED`:
`flux build ks APP -n OLD --path ./kubernetes/apps/OLD/APP/app --kustomization-file ./kubernetes/apps/OLD/APP/ks.yaml --dry-run | yq -N 'select(.kind)|.kind' | sort | uniq -c | grep -E "PersistentVolumeClaim|ReplicationDestination|ReplicationSource"`
must show **1** PVC, **1** ReplicationDestination, **2** ReplicationSource (`-local`, `-r2`). Any other count is class G (or a variant) — refuse.

## What to hand the human at `CLASSIFIED`

Class + the evidence line, PV name / capacity / StorageClass, both RS schedules, the consumers list, the NEW-namespace state (exists, annotation, PSA), open PRs, free space, and every UNVERIFIED point. Then **wait**.
