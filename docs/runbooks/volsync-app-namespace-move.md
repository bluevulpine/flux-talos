# Runbook: moving a VolSync + Longhorn app to another namespace without data loss

**Use when:** an app that carries `components/volsync-claim` + `components/volsync-backup` has to change namespace
(first user: `develop/hermes` → `ai/hermes`). **Scope:** VolSync engine, Longhorn-backed PVC. kopiur and tns-csi/NFS apps are
called out where they differ but are not covered.

**Status: reviewed AND rehearsed.** The procedure was run end to end under Flux on a throwaway app (`moveprobe`, `rehearsal-old` → `rehearsal-new`) on 2026-09-23 — see **Rehearsal** and
`docs/rehearsal/results.md`. This revision matches what was **observed**; statements the rehearsal confirmed carry **CONFIRMED [Rh-n]**, and **Known untested** now lists only what is still open
(notably: a restore at hermes' real size, the HTTPRoute hand-over, the `git revert` rollback and the un-run rollback rows, approach A end to end, and the literal hermes-form gate on the real branch).

**Evidence base.**

- `docs/investigations/hermes-ns-move.md` — read-only survey of repo + cluster (2026-09-23).
- `docs/investigations/hermes-ns-move-smoke.md` — throwaway `smoke-src`/`smoke-dst` namespaces, same day. Tags **[S-x]**.
- `docs/investigations/hermes-ns-move-review.md` — adversarial review, verified against `kustomize` v5.8.1 / `flux build` 2.9.5 output,
  kustomize-controller v1.9.1 and helm-controller v1.6.1 source, and live objects. Tags **[R-n]** point at its numbered findings.
- `docs/rehearsal/plan.md` + `docs/rehearsal/results.md` — the Flux-level rehearsal on a throwaway app (Longhorn manager v1.12.1, kustomize-controller v1.9.1, the deployed `perfectra1n` VolSync fork). Tags **[Rh-n]** point at its results.

| Tag | Result |
| --- | --- |
| **[S-a]** | backup from `smoke-src` wrote identity `smoketest@smoke-src:/data`; an empty source is green with no snapshot |
| **[S-b]** | restore in another namespace **without** `sourceNamespace` → silent empty volume |
| **[S-c]** | restore **with** `sourceNamespace` → sha256 identical |
| **[S-d]** | backup after the move writes a new identity; old and new series coexist and both restore |
| **[S-e]** | Retain PV → delete PVC → clear `claimRef` → **hand-written** PVC with `volumeName` in the new namespace rebinds; its `dataSourceRef` is **ignored** |
| **[S-ret]** | PVC delete with PV `Retain` keeps the volume; with `Delete` PV **and** Longhorn volume vanish in seconds |
| **[S-priv]** | `privileged-movers` annotation adds `DAC_OVERRIDE, CHOWN, FOWNER` to the mover; restored ownership differs |
| **[R-1]** | kind-targeted patches apply, name-targeted patches are silently dropped (build-verified) |
| **[R-2]** | a **suspended** Kustomization that is deleted orphans its whole inventory (controller source) |
| **[R-3]** | `latestMoverStatus.logs` is a truncated tail: `Creating snapshot for …` is absent on a real-size volume (live) |
| **[R-4]** | `lastManualSync` is stamped by **whichever sync finishes next** (VolSync source) |
| **[R-5]** | a PV with `claimRef` removed is claimable by any matching PVC; re-point the claimRef instead |
| **[R-6]** | `git revert` is not a rollback (it restores a stock claim, no `volumeName`) |
| **[R-7]** | the `ai` RD's `restore-once` runs a full restore on creation (live) |
| **[R-8 … R-14]** | see the corresponding steps; each is cited where it applies |
| **[Rh-1]** | SSA accepts the initial `volumeName` add on a pre-bound claim, keeps it across reconciles and a spec change; removing the patch later stalls the ks (verbatim error) — **CONFIRMED** (S2, S1, S4/4c) |
| **[Rh-2]** | B6 order: both "PVC first" and "OLD pruned first (actual)" bind cleanly via the re-point — **CONFIRMED** (S2, S1) |
| **[Rh-3]** | the claimRef re-point (`uid`/`resourceVersion: null`) binds a `Released` PV; a claimRef-less PV is taken by any matching claim — **CONFIRMED** (S2, S3, S1, S8) |
| **[Rh-4]** | the "B8–B9" rollback row (quiesce → forward commit with `volumeName` → re-point) preserves post-move writes — **CONFIRMED at fixture size** (S3); the other rows are still untested |
| **[Rh-5]** | Longhorn `kubernetesStatus` follows the rebind; a `best-effort` replica follows the pod — **CONFIRMED** at 1 MiB (S6) |
| **[Rh-6]** | a resumed ks does not strip the CLI-set HR `spec.suspend` or the scale-down — **CONFIRMED** (S3A, S1 B4b) |
| **[Rh-7]** | a merge-patched `manual` leaves both trigger keys; **Flux removes `manual`** (on `flux resume ks` immediately, else within one ks interval) — **CONFIRMED** (S10b, S10a) |
| **[Rh-8]** | `controllers.<app>.replicas: 0` is honoured by app-template with `Recreate`, and removes cleanly — **CONFIRMED** (S2, S1) |
| **[Rh-9]** | the RD restore drill is byte-identical on 1 MiB; ownership `0:0` mode 664 in an unannotated ns — **CONFIRMED mechanics** (S1 B5b); size/time still open |
| **[Rh-11]** | `Delete` patch accepted on a Bound PV and re-arms trap 2 (~19 s to lose PV + Longhorn volume); a deleted RD dest PVC is recreated on the next trigger — **CONFIRMED** (S1 B10, teardown, S1 B5b) |
| **[Rh-12]** | R-4 on the deployed fork: an in-flight sync stamps the `manual` tag and no second sync starts; also for a creation-time first sync — **CONFIRMED** (S10a, S1 B9) |
| **[Rh-13]** | in-cluster kustomize-controller honours the kind-targeted patches (live `requestedIdentity`, `.spec.volumeName`); the gate fails name targets — **CONFIRMED** (S7, S2, S1 B5b) |
| **[Rh-O]** | suspended-ks deletion orphans the whole inventory (13 objects, all `deletionTimestamp: null`); suspended-HR deletion orphans Deployment/SA/Helm Secrets — **CONFIRMED** (S2, S3, S1 B11) |
| **[Rh-B1]** | the populator/Longhorn stall reproduced on a first deploy; `VolumeSnapshot readyToUse` is not proof — **OBSERVED** (baseline) |
| **[Rh-B2]** | a helper that caches the app PV goes stale after the claim is re-provisioned — **OBSERVED**; the guards now re-read on every call |
| **[Rh-P]** | unannotated-namespace restore returns `0:0` mode 664 (originals `10000:10000` 644) — **CONFIRMED** (S1 B5b) |
| **[Rh-X]** | Longhorn v1.12.1 online PVC expansion 1Gi→2Gi with the pod running: ~28 s, no restart, nothing recreated — **CONFIRMED** (S4) |
| **[Rh-F]** | command defects found while running (`--field-selector=status.phase`, `--show-managed-fields`, `get -w` on an absent object, stale same-name events) — fixed in the steps |

Anything **not** exercised by smoke, review **or the rehearsal** is marked **UNVERIFIED** or **UNTESTED** and collected in **Known untested**.

## 1. Why the kopia identity changes

A VolSync kopia snapshot is `username@hostname:path`.

- **username** = `spec.kopia.username`. The components set `username: "${APP}"` (`components/volsync-backup/local.yaml:45`, `r2.yaml:67`).
- **hostname** = **the namespace**. Nothing in the components sets it; the live CRD says *"If not specified, defaults to the namespace name"*.
  The `NS:` substitution in `ks.yaml` does **not** feed VolSync (it only feeds the kopiur component's `hostname: "${NS}"`, `components/kopiur/local.yaml:23`).
- **path** = `/data` (the mover's mount).

So hermes' snapshots are `hermes@develop:/data`, in both the local Garage repo and R2 (mover log: `Setting policy for hermes@develop:/data`;
kopiur's catalog independently discovered 11 rows with `hostname: develop, username: hermes`). Moving to `ai` means the ReplicationSources write
**`hermes@ai:/data`** — a new series **[S-d]**. The old series is not touched; it is simply never written again, so no retention runs on it
(inferred: retention is applied by the writer of that identity; UNVERIFIED that nothing else expires it).

The snapshots live outside the cluster (Garage S3 + R2). Deleting Kubernetes objects does not delete them.

## 2. Traps (each produces a plausible wrong answer)

1. **A missing `sourceNamespace` is a SILENT empty restore [S-b].** The shared RD (`local.yaml:80-83`) sets only `sourceIdentity.sourceName: <app>`;
   `sourceNamespace` defaults to the RD's own namespace, so after the move it asks for `<app>@<new ns>`, which has no snapshots. It does **not** fail:
   the RD reports `result: Successful`, publishes a `latestImage`, the PVC binds, and the volume holds only `lost+found`. The app boots as a fresh install
   with no error anywhere. **Verify by content, never by RD or PVC status.**
2. **PV reclaim `Delete` + Flux `prune: true` = instant, total loss [S-ret].** The app PVC is in the Kustomization inventory
   (`develop_hermes__PersistentVolumeClaim`); hermes' PV `pvc-12f54114-9e99-442b-bae4-53a9cb239d69` and the StorageClass `longhorn-1-replica-local` are both `Delete`.
   Pruning the PVC deletes the PV, then the Longhorn volume — seconds, no confirmation; finalizers on the PV do not stop it.
   Only the last hourly snapshot remains. This is the hazard `components/volsync-claim/kustomization.yaml:8-13` warns about.
   **CONFIRMED [Rh-11]** at the rehearsal teardown: with the PV patched `Delete`, deleting the PVC removed the PV **and** the Longhorn volume within ~19 s.
3. **Completed Job pods block PVC deletion [S-e].** A `Succeeded` pod that mounted the PVC keeps `kubernetes.io/pvc-protection` on it
   (`describe pvc` shows "Used By"), so the PVC sits in `Terminating` until the Job is deleted. Delete every helper Job (B2, B7 checksum readers, drill readers) before the step that deletes the PVC.
4. **An empty-source backup is green with no snapshot [S-a run-1].** A source mounted while the data isn't there logs
   `== Directory is empty skipping backup ===` / `OPERATION_RESULT: FAILURE, EXIT_CODE: 0` and still reports `result: Successful` with a fresh `lastSyncTime`.
   Same family as `volsync-mover-stuck.md` "Verify a *backup*, not a cleared alert".
   **Reproduced live [Rh-B1]:** while the app claim was wedged, both RS ran against the unfinished volume and reported `result: Successful` with `== Directory is empty skipping backup ===` / `OPERATION_RESULT: FAILURE`; no bogus series was written.
5. **kustomize patches by *name* are silently dropped [R-1] — the first-draft blocker.** Patch `target.name` is matched at `kustomize build`; Flux's `postBuild.substitute` runs **after**.
   At build time the resources are literally named `${APP}` (`components/volsync-claim/claim.yaml:5`) and `${APP:=temp}-dst-local` (`components/volsync-backup/local.yaml:75`),
   so `name: hermes` / `name: hermes-dst-local` match nothing, and kustomize does not error on a zero-match target. Result: no `volumeName`, no `sourceNamespace`, and trap 1 by construction.
   Reproduced: the first-draft patch gave `grep -c -E "volumeName|sourceNamespace"` = **0**. **Target by kind**, and gate the merge on a build (B5).
   The kind-only target is only unambiguous while the app has exactly one PVC and one RD (verified for hermes: `r2.yaml` adds only an ExternalSecret + RS). If someone adds a second PVC (e.g. a media NFS claim), the patch will hit both — revisit it.
   **CONFIRMED [Rh-13]:** the local gate fails name-targeted patches (0 lines) and passes kind-targeted ones (S7), and the **in-cluster** kustomize-controller honoured the kind targets (live RD `requestedIdentity: <app>@<old ns>`, live PVC `.spec.volumeName`).
6. **A suspended Kustomization that is deleted orphans everything [R-2] — ANSWERED.** kustomize-controller v1.9.1 `internal/controller/kustomization_controller.go`:
   `finalizerShouldDeleteResources` returns `false` when `obj.Spec.Suspend`. Removing `./hermes/ks.yaml` makes `cluster-apps` (`prune: true`, live) delete the `develop/hermes` Kustomization; if it is suspended
   its finalizer deletes **none** of the 10 inventory entries (PVC, 3 ExternalSecrets, HTTPRoute, HelmRelease, OCIRepository, RD, both RSes). The old PVC never goes away, the PV never becomes `Released`,
   and the old HTTPRoute stays. **The Kustomization must be resumed before the merge** (B4b). PV `Retain` remains the guard against the *un*-suspended deletion (trap 2).
   **CONFIRMED live [Rh-O]** (S2, run the wrong way on purpose): the child Kustomization object was pruned, yet **all 13 listed objects survived with `deletionTimestamp: null`** (not a slow prune), the HR stayed `suspend: true`, the PV stayed `Bound` — and the orphaned old RS kept its schedule (for hermes, `hermes-local` would keep syncing `hermes@develop` from the idle old PVC until deleted).
7. **A suspended HelmRelease that is deleted is not uninstalled [R-12].** helm-controller v1.6.1 `helmrelease_controller.go:455`: `reconcileDelete` runs the uninstall only `if !obj.Spec.Suspend`.
   We deliberately keep the HR suspended (it is what keeps the Deployment at 0), so the Deployment, Service, ServiceAccount and `sh.helm.release.v1.hermes.*` Secrets in `develop` are **orphaned**. They are harmless (replicas 0, no pvc-protection hold) but must be cleaned up (B11).
   **CONFIRMED live [Rh-O]** (S2, S3, S1): orphaned `deployment`, `serviceaccount`, `sh.helm.release.v1.<app>.v*` Secrets (no Service in the fixture; hermes' chart may add one). If they are **not** cleaned before the app returns, the new HelmRelease upgrades onto the old release storage instead of a fresh install (S3D).
8. **`lastManualSync` is stamped by whichever sync finishes next [R-4].** VolSync `statemachine/machine.go` sets `lastManualTag` at the end of **every** sync. A scheduled `:23` sync that took its VolumeSnapshot before the scale-down
   and finishes after your patch satisfies the "did my manual run finish" loop with a **live-app** snapshot. Gate on no-sync-in-flight and `lastSyncTime > T0` (B3).
   **CONFIRMED on the deployed `perfectra1n` fork [Rh-12]** (S10a): the scheduled `:47` sync was caught in flight, `manual` was patched at 22:47:01, the sync finished 22:47:53 and `lastManualSync` **already equalled the tag — no second sync ever started**. `lastSyncTime > T0` alone **also passes** on a sync that *started before* T0; only the "no sync in flight" pre-check discriminates.
   Same for a **creation-time first sync**: a newly created RS whose claim is `Pending` stays "in flight" for minutes and satisfies a `manual` tag patched meanwhile (S1 B9, `lastSyncDuration` 8m14s/8m30s). While `manual` is set the RS reports `WaitingForManual` (manual-over-schedule precedence holds on the fork).
9. **The mover status log is a truncated tail [R-3].** `latestMoverStatus.logs` on a real 570 MB volume starts mid-upload: `Creating snapshot for …` is **absent** even for a good backup; `Created snapshot with root …`,
   `Setting policy for <identity>:/data` and `OPERATION_RESULT: SUCCESS` are present. Do not use the first line as an acceptance test (it passed in [S-a] only because the smoke volumes were tiny).
10. **Removing `claimRef` makes the PV claimable by any matching PVC [R-5].** The likeliest thief is the `ai` RD's own dest PVC `volsync-hermes-dst-local-dest` (20Gi RWO `longhorn-1-replica-local`, `local.yaml:90`). **Re-point** the claimRef at `<new ns>/<app>` instead of removing it.
    **CONFIRMED live [Rh-3]** (S8, Block-mode bait PV): with the claimRef **removed** an unrelated matching claim (`thief`) bound the PV and read the previous owner's data back; with the claimRef **re-pointed** to `wanted`, when both claims competed at once only `wanted` bound it and `thief` provisioned its own volume.
11. **The `ai` RD is not inert [R-7].** `trigger.manual: restore-once` runs a **full restore** the moment the RD is created (live: the develop RD shows `lastManualSync: restore-once`). Patched correctly this is a free restore drill; unpatched it is the empty-restore generator.
    It creates a 20Gi dest PVC + 24Gi cache (`local.yaml:89`) — budget ~44Gi. **CONFIRMED [Rh-13]:** in the rehearsal the new-namespace RD restored at creation (45 s for 1 MiB) and `requestedIdentity` showed the patched identity; the new HelmRelease was a fresh `v1`.
    **But** the restore rides the Longhorn snapshot path and is exposed to trap 14.
12. **A pre-bound PVC's `volumeName` must stay in the manifest — CONFIRMED under Flux [Rh-1].** kustomize-controller owns the field via server-side apply (`managedFields`: `kustomize-controller (Apply)` owns `f:accessModes, f:dataSourceRef, f:resources, f:storageClassName, f:volumeName`); removing the patch later makes SSA try to unset an immutable field and stalls the Kustomization —
    the failure `volsync-claim/kustomization.yaml:14-20` describes for `dataSourceRef`. **Observed verbatim (S4 4c):** the ks went `Ready=False` with `PersistentVolumeClaim/<ns>/<app> dry-run failed (Invalid): … spec: Forbidden: spec is immutable after creation except resources.requests and volumeAttributesClassName for bound claims` (diff `-"VolumeName": "pvc-…"` / `+"VolumeName": ""`).
    The failure is at the **dry-run**, so nothing else in that Kustomization is applied; the live PVC stayed `Bound` and the PV untouched; restoring the patch cleared it. Keep the patch for the life of that PVC. The initial add on a claim whose `dataSourceRef` the component owns was **accepted** (S2), the field survived two forced reconciles and a spec change (1Gi→2Gi, online, no object recreated).
    **Do not add `force: true` to the child ks** — with it this failure would become a delete/recreate of the PVC.
13. **Two `hermes.${SECRET_DOMAIN}` routes: the OLDEST wins [R-11].** Gateway API resolves host conflicts to the route with the oldest `creationTimestamp` — `develop`'s (18d). Brief blip if the old one is pruned; a **permanent 503** if it is orphaned (trap 6).
14. **The Longhorn populator/clone path can wedge — OBSERVED on the rehearsal's very first deploy [Rh-B1]** (`volsync-mover-stuck.md` §"Fifth/Sixth fingerprint"). Sequence seen: the RD finished `Successful` and published a `latestImage`; the populator's `vs-prime-*` PVC never bound
    (`failed to verify data source: snapshot … is not ready to use`, then `snapshot.longhorn.io "snapshot-…" not found`); the HelmRelease timed out; ~1 h to a healthy app. Four things to know:
    - **(a) `VolumeSnapshot readyToUse: true` is not proof.** The `VolumeSnapshotContent` handle (`snap://<volume>/snapshot-<uid>`) can point at a Longhorn snapshot that **does not exist**. Check the snapshot behind the handle: `kubectl -n longhorn-system get snapshots.longhorn.io snapshot-<uid>` (and that it is `readyToUse`). In the rehearsal, 2 of 5 RD runs had no Longhorn snapshot behind the image; what distinguishes them is **not established** (open).
    - **(b) A hand-patched RD `spec.trigger.manual` is reverted by Flux** (observed: `restore-2` → `restore-once` within ≤5 min), which **re-runs the restore and replaces `latestImage`**. A manual RD retrigger is only stable once `spec.trigger.manual == status.lastManualSync` again — **suspend the ks first**, patch, wait for equality, then resume.
    - **(c) After a retrigger the populator does not re-prime by itself:** delete the `vs-prime-*` PVC (`kubectl -n <ns> delete pvc vs-prime-…`); it re-primed and bound in ~11 s.
    - **(d) The bound app volume can then fail its own clone** (`cloneStatus.state: failed, attemptCount: 1` — never retried; `FailedAttachVolume … volume request cloning data but has not finished copying data`; Longhorn `VolumeCloneFailed … cannot find snapshot … in the source replica`). **The only cure observed was deleting the claim** (PV `Delete` ⇒ the wedged PV/volume go too) **and letting Flux/the populator re-create it** from a verified good snapshot.
    **Scope:** this hits **approach A** (§3A) and **the `ai` RD's `restore-once`** (the B5b drill; the RD's own dest volume). It does **not** hit **approach B's app claim** — a pre-bound `volumeName` claim involves no populator [Rh-1, S-e]. A stalled B5b drill therefore does **not** block approach B, but never "fix" it by touching the app PV, and never trust the drill's result without (a).
15. **Restored ownership depends on the namespace annotation [S-priv, Rh-P].** Without `volsync.backube/privileged-movers: "true"` a restore returns files as **`0:0` and mode 664** (observed in an unannotated namespace: originals `10000:10000` mode 644, `lost+found` `0:0`); with the annotation, uid 10000 is preserved (smoke: `10000:root`). Backup reads work either way and PSA `baseline` admits the unannotated root mover.
    Under approach B the filesystem is the original, so this only matters for approach A or a later restore [R-14]. A checksum drill on a restored tree should run as **uid 0** (`runAsUser: 0`); here mode 664 was still world-readable — whether an unannotated restore of **owner-only (600)** files is unreadable to uid 10000 was **not** tested.

## 3. Procedure — generic

Variables (hermes values):

```bash
APP=hermes; OLD=develop; NEW=ai
PV=$(kubectl -n $OLD get pvc $APP -o jsonpath='{.spec.volumeName}'); echo "$PV"     # pvc-12f54114-9e99-442b-bae4-53a9cb239d69
SC=$(kubectl get pv "$PV" -o jsonpath='{.spec.storageClassName}'); echo "$SC"        # longhorn-1-replica-local
```

**Re-read `$PV` from the PVC every time you need it — never from a shell variable or file saved earlier [Rh-B2].** Anything that re-provisions the claim (a populator retry, trap 14) changes the PV name; the rehearsal's helper cached the first PV and then "protected" a deleted one while the live one was unrecorded.

A helper used below (define it once; it encodes the [R-3] acceptance rule — do **not** loosen it):

```bash
# check_backup <namespace> <replicationsource> <identity>   e.g.  check_backup develop hermes-local hermes@develop
check_backup() {
  local L; L=$(kubectl -n "$1" get replicationsource.volsync.backube "$2" -o jsonpath='{.status.latestMoverStatus.logs}')
  echo "Created snapshot lines : $(grep -c 'Created snapshot with root' <<<"$L")   (want >=1)"
  echo "Setting policy          : $(grep -cF "Setting policy for $3:/data" <<<"$L")   (want >=1)"
  echo "OPERATION_RESULT SUCCESS: $(grep -cF 'OPERATION_RESULT: SUCCESS' <<<"$L")   (want >=1)"
  echo "Directory is empty      : $(grep -c 'Directory is empty' <<<"$L")   (want 0)"
}
```

Use the **full** resource name `replicationsource.volsync.backube`; `rs` resolves to ReplicaSets (it bit the smoke test).

**Primary path: approach B — keep the bytes.** The Longhorn volume never moves; it is retained, released and re-claimed **[S-e]** (with hand-written manifests — see Known untested).
**Fallback: approach A (§3A)** — restore from kopia via the RD, only if the volume is lost or B fails.

### Preconditions

- Both repos healthy; `hermes-local` and `hermes-r2` last synced OK. No open Renovate PR touching the app. Quiet window (the agent is down for the duration).
- No competing claim for the PV [R-5] — **nothing Pending that requests `$SC`**. (`kubectl get pvc -A --field-selector=status.phase=Pending` is **rejected by the API server**: `"status.phase" is not a known field selector` [Rh-F].) Use:
  `kubectl get pvc -A -o json | jq -r '.items[]|select(.status.phase=="Pending")|"\(.metadata.namespace)/\(.metadata.name) sc=\(.spec.storageClassName)"'` — expect nothing (the rehearsal's only Pending claim before the re-point was the moving app's own).
- The `ai` `privileged-movers` annotation (§6.5) is **decided: add it**, and it must already be merged to `main` **before** the B5 commit (verify: `kubectl get ns ai -o jsonpath='{.metadata.annotations.volsync\.backube/privileged-movers}'` prints `true`).
- The branch with the moved app directory is checked out locally (needed for the B5 build gate).

### Steps

**B0. Record the baseline (read-only).** `$PV`, `$SC`, capacity (20Gi), and the two `lastSyncTime`s. The new PVC's StorageClass **must equal `$SC`** or it will not bind [S-e].

**B1. Quiesce.** Suspend **both** the Kustomization and the HelmRelease. **The ks suspension is mandatory, not tidy [Rh-7]:** a running or resumed ks removes a hand-patched `spec.trigger.manual` within one interval (immediately on `flux resume`), which would undo B3's trigger mid-flight. The HR suspension is what keeps the Deployment at 0.

```bash
flux suspend kustomization $APP -n $OLD
flux suspend helmrelease   $APP -n $OLD
kubectl -n $OLD scale deploy/$APP --replicas=0
kubectl -n $OLD wait --for=delete pod -l app.kubernetes.io/name=$APP --timeout=180s
# nothing may still reference the PVC — including Completed pods [trap 3]
kubectl -n $OLD get pods -o json | jq -r --arg c "$APP" '.items[]|select(.spec.volumes[]?.persistentVolumeClaim.claimName==$c)|.metadata.name'   # expect: empty
```

*Rollback (UNTESTED):* `flux resume helmrelease/kustomization`; scale up (or let Flux).

**B2. Content baseline — MANDATORY [R-10].** B7 is the only content gate before the pod writes again, and it diffs against this.
A read-only Job in `$OLD` (hand-render; do **not** `kubectl apply` a repo app):

```yaml
apiVersion: batch/v1
kind: Job
metadata: {name: baseline, namespace: develop}
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: r
          image: busybox:1.37
          command: [sh, -c, "cd /data && find . -type f -print0 | sort -z | xargs -0 sha256sum && echo ---COUNTS && for d in sessions memories skills cron; do echo $d $(find $d -type f 2>/dev/null | wc -l); done"]
          volumeMounts: [{name: d, mountPath: /data, readOnly: true}]
      volumes: [{name: d, persistentVolumeClaim: {claimName: hermes, readOnly: true}}]
```

Save the output to the scratchpad (file names + hashes, no contents). **Assert the named files exist in the baseline** — at minimum whichever of `.env`, `SOUL.md`, `config.yaml`, `auth.json` are present, plus non-zero counts for `sessions/` and `memories/`.
If any of those is absent *now*, understand why before continuing; B7 must not be the first time you notice. Compare only **static** files later; do not byte-compare live SQLite (`state.db`) across a start.
**Delete the Job before B5** (trap 3): `kubectl -n $OLD delete job baseline`.

**B3. Forced final backup under the OLD identity, gated against in-flight syncs [R-3, R-4].**

```bash
for RS in $APP-local $APP-r2; do
  echo "$RS in-flight start: [$(kubectl -n $OLD get replicationsource.volsync.backube $RS -o jsonpath='{.status.lastSyncStartTime}')]"    # must be [] — if not, wait for it to finish first
done
T0=$(date -u +%FT%TZ)                       # AFTER the pod is gone (B1)
TAG=pre-move-$(date +%s)
for RS in $APP-local $APP-r2; do
  kubectl -n $OLD patch replicationsource.volsync.backube $RS --type merge -p '{"spec":{"trigger":{"manual":"'"$TAG"'"}}}'
done
for RS in $APP-local $APP-r2; do
  for i in $(seq 1 50); do        # bounded: 50 x 10s; a timeout means the manual run did NOT complete — do not proceed
    [ "$(kubectl -n $OLD get replicationsource.volsync.backube $RS -o jsonpath='{.status.lastManualSync}')" = "$TAG" ] && break; sleep 10
  done
  LST=$(kubectl -n $OLD get replicationsource.volsync.backube $RS -o jsonpath='{.status.lastSyncTime}')
  [[ "$LST" > "$T0" ]] && echo "$RS OK lastSyncTime $LST > T0 $T0" || echo "$RS STALE — $LST <= $T0 (a pre-quiesce sync stamped the tag); trigger again"
  check_backup $OLD $RS $APP@$OLD
done
```

Accept **only** if, for **both** RS: `lastSyncTime > T0`, `Created snapshot with root` ≥ 1, `Setting policy for hermes@develop:/data` ≥ 1, `OPERATION_RESULT: SUCCESS` ≥ 1 and `Directory is empty` = 0.
The empty-source case logs `OPERATION_RESULT: FAILURE` [S-a run-1], so the SUCCESS line discriminates it.
**CONFIRMED [Rh-7, Rh-12]:** a `--type merge` patch leaves **both** trigger keys — `{"manual":"<TAG>","schedule":"<cron>"}` — and while `manual` is set the RS reports `WaitingForManual` (manual-over-schedule precedence holds on the deployed fork). **Flux removes `manual`** — immediately at B4b's `flux resume ks`, or within one ks interval if the ks is running — after which the RS is back on `{"schedule":…}` with a `nextSyncTime`. That is why B1's ks suspension is mandatory. (In the hermes move the old RS is pruned at B5 anyway.)
**The in-flight gate is not optional [Rh-12]:** a scheduled sync running when you patch stamps `lastManualSync` itself and **no second sync starts** (trap 8). `lastSyncTime > T0` alone is not enough — it also passes on a sync that started before `T0`. Avoid the `:23` slot (± a few minutes) for `hermes-local` and `06:29` for `hermes-r2`.
If a mover wedges, `volsync-mover-stuck.md` applies; do not proceed on a wedged source.

*Rollback:* none needed; a backup is additive.

**B4. Make the PV survive: `Retain`.**

```bash
kubectl patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'          # must print Retain   [S-ret, S-e]
```

**Do not proceed until this prints `Retain`.** *Rollback:* patch back to `Delete` (**accepted on a Bound PV [Rh-11]**; read it back).

**B4b. Resume the OLD Kustomization; keep the HelmRelease suspended and the Deployment at 0 [R-2].** Otherwise the merge prunes nothing (trap 6).

```bash
flux resume kustomization $APP -n $OLD
kubectl -n $OLD get helmrelease $APP -o jsonpath='{.spec.suspend}{"\n"}'                # must print true
kubectl -n $OLD get deploy $APP -o jsonpath='{.spec.replicas}{"\n"}'                    # must print 0
kubectl -n $OLD get kustomization.kustomize.toolkit.fluxcd.io $APP -o jsonpath='{.spec.suspend}{"\n"}'    # must print false (empty) 
```

**CONFIRMED [Rh-6]** (S3A, S1 B4b, twice): after `flux resume ks`, the HelmRelease stayed `suspend=true`, the Deployment stayed `replicas=0`, and the ks read `suspend=[]` — kustomize-controller's server-side apply does not strip `spec.suspend` set by the flux CLI (a different field manager). Keep the two checks anyway: stop if either is wrong.
The resume also reverts the RS trigger to its schedule ([Rh-7], B3); the RS may sync `hermes@develop` from the idle old PVC before the merge; harmless.

**B5. The ONE commit** (only now: PV `Retain`, both suspends verified, app at 0, backup accepted). Contents:

1. `git mv kubernetes/apps/$OLD/$APP kubernetes/apps/$NEW/$APP`; remove `./$APP/ks.yaml` from `apps/$OLD/kustomization.yaml`; add it to `apps/$NEW/kustomization.yaml`.
2. In the moved `ks.yaml`: `path`, `targetNamespace: $NEW`, `postBuild.substitute.NS: $NEW`; match the destination namespace's `ks.yaml` shape.
3. In the moved `app/kustomization.yaml`, pin the volume and the restore identity — **by kind, never by name [R-1]**:

   ```yaml
   patches:
     # Target by KIND, not name. The names are ${APP}/${APP}-dst-local at build time and only become
     # hermes/hermes-dst-local after Flux postBuild substitution, so a name target matches nothing and is
     # silently dropped (kustomize does not error on zero matches). Kind-only is safe ONLY while this app has
     # exactly one PVC and one ReplicationDestination — re-check if a second claim is ever added.
     - target: {kind: PersistentVolumeClaim}
       patch: |-
         - op: add
           path: /spec/volumeName
           value: pvc-12f54114-9e99-442b-bae4-53a9cb239d69     # keep permanently (trap 12)
     - target: {kind: ReplicationDestination}
       patch: |-
         - op: add
           path: /spec/kopia/sourceIdentity/sourceNamespace
           value: develop                                        # NOT inert: the RD runs a restore on creation (trap 11)
   ```

4. **Gate the pod:** temporary `controllers.hermes.replicas: 0` in the moved HelmRelease values so nothing writes to the volume before B7. **CONFIRMED [Rh-8]:** app-template honours it with `strategy: Recreate` (Deployment `replicas=0`, no pod), and removing it starts the pod cleanly.
5. Any label/comment/docs changes (see the app's appendix).

**PRE-MERGE GATE (mandatory) — three assertions, on the COMMITTED tree [R-1, rehearsal N1].** A pre-commit hook (lefthook/yamlfmt) can rewrite YAML, and a `grep` for `volumeName` alone passes a commit whose `ks.yaml` still says `targetNamespace: develop` or `path: …/develop/…`
(the app then renders into the OLD namespace, and two Kustomizations fight over one PVC/RS/RD set) — or one that forgot to list `./hermes/ks.yaml` in the new namespace's `kustomization.yaml`. So, after `git commit` and before `git push`:

```bash
# 0. the whole tree is committed (covers apps/develop/kustomization.yaml and apps/ai/kustomization.yaml)
test -z "$(git status --porcelain -- kubernetes)" && echo committed
# 1. the patches rendered: BOTH lines (kind-targeted patches, trap 5)
flux build ks $APP -n $NEW --path ./kubernetes/apps/$NEW/$APP/app \
  --kustomization-file ./kubernetes/apps/$NEW/$APP/ks.yaml --dry-run > /tmp/$APP-build.yaml
grep -n -E "volumeName|sourceNamespace" /tmp/$APP-build.yaml
# want BOTH:   <n>:  volumeName: pvc-12f54114-9e99-442b-bae4-53a9cb239d69
#              <n>:      sourceNamespace: develop
# 2. every object in the app build lands in the NEW namespace (catches a stale targetNamespace)
yq -N 'select(.kind)|.metadata.namespace // "NONE"' /tmp/$APP-build.yaml | sort -u        # want exactly one line:  ai
# 3. the PARENT build has exactly ONE child Kustomization for the app, in the new namespace, with the new path and targetNamespace
flux build ks cluster-apps -n flux-system --path ./kubernetes/apps \
  --kustomization-file ./kubernetes/flux/cluster/ks.yaml --dry-run \
  | yq -N 'select(.kind=="Kustomization")|[.metadata.namespace,.metadata.name,.spec.path,.spec.targetNamespace]|join(" ")' | grep -F " $APP "
# want EXACTLY ONE line:   ai hermes ./kubernetes/apps/ai/hermes/app ai
#   (zero lines = the new namespace kustomization does not list ks.yaml; two = the old one still does; a `develop` in either path/targetNamespace = a stale edit)
```

If any assertion fails, **do not merge**. (Reviewer's run showed `222: volumeName:…` and `383: sourceNamespace: develop`; the first-draft patch showed 0 matches; the rehearsal's `move_gate` implements all of the above and was tested against stale-`targetNamespace`, stale-`path` and unlisted-`ks.yaml` commits — each fails — and **PASSED on every real rehearsal move, with the same three assertions using rehearsal paths** [Rh-13].)
Local `kustomize` 5.8.1 / flux 2.9.5 were used. **CONFIRMED [Rh-13]:** kustomize-controller 1.9.1's embedded kustomize behaves the same (live `requestedIdentity` and `.spec.volumeName` matched the local build).
**STILL OPEN (literal hermes-form gate):** the rehearsal ran the equivalent `move_gate`; assertion **3** above (the `cluster-apps` parent build with `--kustomization-file ./kubernetes/flux/cluster/ks.yaml`) was **not run literally on the real branch**. It was checked only on the current `main` tree (159 child Kustomizations, prints `develop hermes ./kubernetes/apps/develop/hermes/app develop`). **Run all three literally once on the real branch before merging.**

Merging to `main` auto-reconciles (repo `CLAUDE.md`); do **not** `flux reconcile`. Commit as the bot identity per `CLAUDE.md`. Flux prunes the old inventory and creates the new one in parallel.

*Rollback:* see §5 — a `git revert` is **not** a rollback [R-6].

**B5b. Direct test that the patches applied — before touching the PV [R-1, R-7].** The `ai` RD starts its restore immediately.

```bash
kubectl -n $NEW get replicationdestination.volsync.backube $APP-dst-local -o jsonpath='{.status.kopia.requestedIdentity}{"\n"}'   # must print hermes@develop  (hermes@ai = the patch was dropped: STOP)
kubectl -n $NEW get pvc $APP -o jsonpath='{.spec.volumeName}{"\n"}'                                                                # must print $PV
```

`requestedIdentity: hermes@develop` is the direct proof `sourceNamespace` reached the object — **CONFIRMED [Rh-13]** live in the rehearsal (`moveprobe@rehearsal-old`, `.spec.volumeName == $PV`). Then wait for the RD's `latestMoverStatus.result: Successful`.

**Free restore drill [R-7, Rh-9] — trust it only after verifying the Longhorn snapshot [Rh-B1, trap 14a].** That restore is the end-to-end proof of `hermes@develop` (~570 MB, the first restore of the real series since 2026-09-05). Before reading anything into `Successful`:

```bash
# the VolumeSnapshot the RD published, and the Longhorn snapshot BEHIND it (readyToUse on the VolumeSnapshot is not proof)
VS=$(kubectl -n $NEW get replicationdestination.volsync.backube $APP-dst-local -o jsonpath='{.status.latestImage.name}')
VSC=$(kubectl -n $NEW get volumesnapshot "$VS" -o jsonpath='{.status.boundVolumeSnapshotContentName}')
kubectl get volumesnapshotcontent "$VSC" -o jsonpath='{.status.snapshotHandle}{"\n"}'            # snap://<volume>/snapshot-<uid>
kubectl -n longhorn-system get snapshots.longhorn.io snapshot-<uid>                              # must EXIST and be readyToUse; NotFound = the drill result is worthless
```

If it exists: mount the RD's dest PVC `volsync-hermes-dst-local-dest` **read-only as uid 0** in `$NEW` in a Job (an unannotated `ai` returns files `0:0` mode 664 [Rh-P]; a uid-0 reader also copes with owner-only files), list checksums, and diff against B2 (content only). Record `ls -ln` separately (`0:0`, mode 664 vs 644 in the original is expected in an unannotated namespace).
Budget ~44Gi (20Gi dest + 24Gi cache). Delete the drill Job. **Deleting the dest PVC afterwards is optional and VERIFIED tolerated [Rh-11]:** VolSync recreated it on the next trigger (bound in ≤31 s) and the restore was `Successful`.
**If the snapshot behind the image is missing, or the RD/prime stalls (trap 14): the drill is void, but approach B is unaffected** (the app claim is pre-bound; no populator). Do not "fix" the drill by touching the app PV. If you want the drill anyway, follow §3A step 5.
**Do not run B6 while this dest PVC is still being provisioned/bound**, and note the claimRef re-point below is what stops it from binding the app's PV [Rh-3].

**B6. Free the PV and reserve it for the new claim [S-e, R-2, R-5, Rh-2, Rh-3].**

```bash
SINCE=$(date -u +%FT%TZ)                                                                 # take this just BEFORE the B5 push, so stale events can be excluded below
kubectl get pv "$PV" -o jsonpath='{.status.phase}{"\n"}'                                 # wait for Released (needs B4b; if it stays Bound the develop ks was still suspended — trap 6)
kubectl -n $OLD get pvc $APP 2>&1 | tail -1                                              # NotFound (if Terminating: trap 3 — delete Completed pods/Jobs)
# what else is waiting for a volume — expect ONLY the moving claim (jq; the --field-selector form is rejected by the API server [Rh-F])
kubectl get pvc -A -o json | jq -r '.items[]|select(.status.phase=="Pending")|"\(.metadata.namespace)/\(.metadata.name) sc=\(.spec.storageClassName)"'
# RE-POINT, do not remove: only ai/hermes can bind
kubectl patch pv "$PV" --type merge -p '{"spec":{"claimRef":{"namespace":"'"$NEW"'","name":"'"$APP"'","uid":null,"resourceVersion":null}}}'
kubectl -n $NEW get pvc $APP -o wide                                                     # Bound to $PV  (rehearsal: Released -> Available (reserved) -> Bound in 9-12 s)
# populator events for THIS claim only — Events outlive objects (~1h), so a bare `--field-selector involvedObject.name=` also counts a previous same-named claim [Rh-F]
kubectl -n $NEW get events --field-selector involvedObject.name=$APP -o json \
  | jq --arg since "$SINCE" '[.items[]|select(.reason|startswith("VolSyncPopulator"))|select((.lastTimestamp // .eventTime // "") >= $since)]|length'    # want 0 [S-e]
```

**The order you will actually see [Rh-2] (S1, timestamps):** the OLD ks prunes the old PVC → the PV goes `Released` (its `claimRef` still names the OLD claim) → the NEW ks creates the claim **~6 s later** → it sits `Pending` with event **`FailedBinding … volume "<pv>" already bound to a different claim`** until the re-point (3 min 16 s in the rehearsal) → `Bound` 12 s after it. **That `FailedBinding` is expected, not a fault.**
The other order — the NEW claim created while the PV is still `Bound` to the old claim (S2, ~1.5 min `Pending` with `volumeName` set) — also binds cleanly after `delete old PVC → Released → re-point`. **Both orders CONFIRMED.** With the re-point the order does not matter.
If `ai/hermes` stays `Pending` after the re-point: `kubectl -n $NEW describe pvc $APP` first. Deleting it and letting Flux recreate it is safe **because the B5 gate proved the `volumeName` patch**; without that proof it would recreate an unpinned claim (not needed in the rehearsal).
**Watchers:** `kubectl get pvc <name> -w` on a claim that does not exist yet exits immediately (`NotFound`) — watch the whole namespace (`kubectl -n $NEW get pvc -w`) or poll timestamps [Rh-F]. Kill background watchers after B6.

**B7. Verify by content, pod still at 0 [S-e, S-c, R-10].** A read-only checksum Job in `$NEW` (same manifest as B2 with `namespace: ai`) on the PVC; diff its output against the B2 file.
Assert the B2 named files exist and match, and the `sessions/`/`memories/` counts equal. **Delete the Job.** Do not trust `kubectl get pvc`, RD status, or an app that comes up "healthy" — a fresh agent also comes up healthy [S-b].

**B8. Start the pod.** Second commit: remove `replicas: 0`. Verify: dashboard login (Authentik OIDC is host-based, unaffected), sessions/memory present, `kubectl -n $NEW exec deploy/$APP -- ls -la /opt/data`, and exactly one route [R-11]:

```bash
kubectl get httproute -A | grep hermes                                                   # exactly ONE line, in ai
```

**B9. First backup in the new namespace; confirm the new series [S-d].** The RS fires on its schedule (it may already have snapshotted the verified data while the pod was at 0 — harmless). Check **both** sources:

```bash
for RS in $APP-local $APP-r2; do
  kubectl -n $NEW get replicationsource.volsync.backube $RS -o jsonpath='{.status.lastSyncTime} {.status.latestMoverStatus.result}{"\n"}'
  check_backup $NEW $RS $APP@$NEW          # Setting policy for hermes@ai:/data — NOT hermes@develop; Directory is empty = 0
done
```

`-r2` is nightly (`29 6 * * *`), so wait for it. Optional end-to-end proof [S-d]: a scratch RD in `$NEW` with **no** `sourceNamespace` now finds `hermes@ai`.
**Newly created RS in `$NEW`: mind the creation-time first sync [Rh-12].** Both RS start a first sync **at creation**; while the claim is `Pending` (B5→B6) it stays in flight for minutes. In the rehearsal the two RS were already 7 min into that sync (`lastSyncStartTime` set) when B9 patched a `manual` tag, and the older sync completed and **stamped the tag** (`lastSyncDuration` 8m14s/8m30s) — no separate B9 run happened. If you patch a tag here, first require `lastSyncStartTime` **empty**; otherwise rely on the log check (`Setting policy for hermes@ai:/data`, snapshot created, SUCCESS, no `Directory is empty`), which is what proved `moveprobe@rehearsal-new`. Do not read `lastManualSync == TAG` as "my run finished".

**B10. Return the PV to `Delete` — only when all are true:** B7 passed; the app has run a soak period you choose (suggest ≥1 nightly R2 run); both `hermes@ai` series exist (B9, both RS); and (optional) one restore drill passed.
Otherwise a later PVC deletion in `ai` leaves an orphaned Longhorn volume that nothing will ever clean up.
**This patch re-arms trap 2 [Rh-11]:** after it, deleting the PVC removes the PV **and** the Longhorn volume within ~19 s (proved at the rehearsal teardown). Do it last, deliberately.

```bash
kubectl patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'          # accepted on a Bound PV, PV stays Bound [Rh-11]
```

**B11. Cleanup of the old namespace [R-8, R-12].** Replace the first draft's "leftovers" list with this:

- **Expect gone:** the RD/RS-owned objects — `volsync-hermes-dst-local-dest`, the three cache PVCs, VolumeSnapshot `volsync-hermes-dst-local-dest-20260905051844` — are **ownerRef'd** to the RS/RD, so Kubernetes GC removes them when Flux prunes those (their StorageClass is `Delete`). They are **not** a rollback copy (the dest volume is the 2026-09-05 restore, 18 days stale).
  The real rollback assets are the Retained `$PV` and the `hermes@develop` kopia series; nothing here deletes either. **CONFIRMED [Rh-O]:** the RD/RS-owned PVCs and snapshots were already GC'd at B11 in the rehearsal.
- **Expect orphaned** (the suspended HelmRelease was pruned without an uninstall — trap 7; **CONFIRMED [Rh-O]**: Deployment, ServiceAccount and `sh.helm.release.v1.<app>.v1…v2` Secrets in the rehearsal; no Service — hermes' chart may add one). List and delete: `kubectl -n $OLD get deploy,svc,sa,secret | grep -E "hermes"` → Deployment `hermes` (0 replicas), Service `hermes`, ServiceAccount `hermes`, `sh.helm.release.v1.hermes.v*`.
  No Helm ownership conflict with `ai` (the PVC is kustomize-owned via `existingClaim`; the chart has no hooks). Also verify `kubectl -n $OLD get ks,hr,ocirepository,externalsecret,httproute,replicationsource.volsync.backube,replicationdestination.volsync.backube | grep hermes` is empty.
- **Before deleting anything**, confirm the PV's claimRef is the new claim: `kubectl get pv "$PV" -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}'` → `ai/hermes`.
- **Assert empty, with a bounded retry** (owner-GC of the RS/RD-owned objects may still be finishing; terminating PVCs still match a name grep):

  ```bash
  kubectl -n $OLD delete deploy,svc,sa -l app.kubernetes.io/instance=$APP --ignore-not-found
  kubectl -n $OLD get secret -o name | grep "sh.helm.release.v1.$APP" | xargs -I{} kubectl -n $OLD delete {} || true
  for i in $(seq 1 12); do
    left=$(kubectl -n $OLD get all,secret,sa,pvc,hr,ks,externalsecret,replicationsource.volsync.backube,replicationdestination.volsync.backube,httproute -o name | grep -E "$APP" || true)
    [ -z "$left" ] && { echo "OLD clean"; break; }; echo "still present: $left"; sleep 10
  done
  ```
- Never delete the `hermes@develop` kopia series.

### 3A. Fallback — approach A: restore from kopia

Use if the volume is gone or B fails. The data is as old as the B3 backup (or the last hourly snapshot if B3 was skipped).

1. Do B0–B4b anyway (they keep the old volume as a second copy). **Still set the old PV to `Retain`** — it stays, `Released`, as a copy.
2. In B5 **omit the `volumeName` patch** but keep the RD patch **by kind** (`sourceNamespace: develop`, gate on the build). It is mandatory here. The first draft's approach A relied on a name-targeted RD patch that is silently dropped [R-1], so A restored **empty by construction**; with the gate, the build line `sourceNamespace: develop` must be present.
3. The `ai` RD restores at creation (trap 11); confirm `requestedIdentity: hermes@develop` (B5b). The PVC is WaitForFirstConsumer, so it populates only when a consumer exists — use a read-only checksum Job as that consumer, with `replicas: 0` still in place.
4. **Verify by content against B2** before scaling up: the RD reports `Successful` even for an empty image [S-b].
5. **If the populator PVC stalls** (`snapshot … is not ready to use` / `snapshot.longhorn.io … not found`, trap 14) — bounded recovery, all on the app's own objects, **observed to work** in the rehearsal baseline [Rh-B1]:
   1. **Check first:** the Longhorn snapshot behind the RD's `latestImage` (B5b snippet). `VolumeSnapshot readyToUse` is not proof.
   2. **Suspend the ks** (and HR, scale 0) so Flux cannot revert your RD patch: `flux suspend ks/hr $APP -n $NEW`.
   3. Retrigger the RD (`spec.trigger.manual: restore-N`, a **new** value) and **wait until `spec.trigger.manual == status.lastManualSync`**. **Verify the Longhorn snapshot behind the new `latestImage` exists and is `readyToUse`** before going on.
   4. **Delete the `vs-prime-*` PVC** — the populator does not re-prime by itself; it re-primed and bound in ~11 s.
   5. If the **app volume fails its own clone** (`cloneStatus.state: failed`, `FailedAttachVolume … has not finished copying data`), the only observed cure is **deleting the claim** (PV `Delete` ⇒ the wedged PV/volume go too; **never do this to a PV you have set `Retain` for approach B**) and letting the populator re-create it from the verified snapshot.
   6. Resume the ks; resume the HR (WaitForFirstConsumer needs the pod as consumer); re-verify by content.
   Expect to fight this more than once: the rehearsal needed five RD runs. This applies to approach A and the `ai` RD only — **not** to approach B [trap 14].
6. Ownership: an unannotated destination restores as `root:root` [S-priv]; the hermes entrypoint re-chowns on start. (Only relevant here, not under B [R-14].)
7. Then B8–B11. Forward backups create `hermes@ai` [S-d]. **Never** flip the retained PV to `Delete` until B10's criteria hold.

## 4. Verification checklist (exact commands)

Run after **each** of B3, B5b, B7 and B9; a step is not done until its line passes. `NS` below is the namespace in question (`$OLD` for B3, `$NEW` after).

```bash
NS=$OLD   # or $NEW
# identity actually written — use the R-3 helper, NOT a 'Creating snapshot for' grep
check_backup $NS $APP-local $APP@$NS ; check_backup $NS $APP-r2 $APP@$NS
# volume identity and retention
kubectl get pv "$PV" -o json | jq -c '{reclaim:.spec.persistentVolumeReclaimPolicy,phase:.status.phase,claim:.spec.claimRef|{namespace,name}}'
kubectl -n longhorn-system get volumes.longhorn.io "$PV" -o json | jq -c '{state:.status.state,robust:.status.robustness,ns:.status.kubernetesStatus.namespace,pvc:.status.kubernetesStatus.pvcName}'
# the patches reached the objects (B5b) — the direct test for R-1
kubectl -n $NEW get replicationdestination.volsync.backube $APP-dst-local -o jsonpath='{.status.kopia.requestedIdentity}{"\n"}'   # hermes@develop
kubectl -n $NEW get pvc $APP -o jsonpath='{.spec.volumeName}{"\n"}'                                                                # $PV
# populator did not touch an [S-e] PVC — this claim only (stale same-name events exist for ~1h [Rh-F]); $SINCE from B6
kubectl -n $NEW get events --field-selector involvedObject.name=$APP -o json | jq --arg since "$SINCE" '[.items[]|select(.reason|startswith("VolSyncPopulator"))|select((.lastTimestamp // .eventTime // "") >= $since)]|length'   # want 0
# one route only
kubectl get httproute -A | grep hermes
# data: checksum Job output vs B2 (static files + named-file assertions), then application-level check
```

| Check | Pass | Fail means |
| --- | --- | --- |
| B3, both RS: `lastSyncTime > T0`, Created ≥1, Setting policy `hermes@develop`, SUCCESS ≥1, empty = 0 | all | no consistent verified last backup → stop; do not cut over |
| `pv … reclaim` after B4 | `Retain` | stop; do not merge |
| B4b: HR `.spec.suspend`, Deployment replicas | `true`, `0` | the resume undid the quiesce → stop |
| pre-merge `flux build` grep | both `volumeName` and `sourceNamespace` lines | do not merge [R-1] |
| B5b `requestedIdentity` | `hermes@develop` | patch dropped → the RD is generating an empty restore; stop, fix, do not proceed to B6 |
| B5b drill: Longhorn snapshot behind `latestImage` exists | yes | drill result void (trap 14a) — approach B is unaffected; do not touch the app PV |
| B6 Pending claims (jq) | only the moving claim | a competing claim could take the PV if the claimRef were ever cleared (trap 10) |
| `pv … phase` after old PVC gone | `Released` → (re-point) → `Bound` to `ai/hermes` | still `Bound` to develop = ks was suspended (trap 6); see trap 3/10 |
| checksums B7 vs B2 | identical (static files), named files present | wrong volume or empty restore [S-b] → roll back |
| B9 log | `Setting policy for hermes@ai:/data` | still writing the old identity / wrong ns |
| `get httproute -A \| grep hermes` | exactly one, in `ai` | old route orphaned [R-11] |

## 5. Rollback at every step — ONE ROW TESTED (fixture size); the rest UNTESTED

**A `git revert` is not a rollback [R-6].** It restores `develop/hermes/app/kustomization.yaml` **without** a `volumeName` patch, so the develop claim comes back as a stock populator PVC and the develop RD (`restore-once`, recreated) restores
the **last `hermes@develop` snapshot into a new volume**. Meanwhile the revert prunes `ai/hermes` and the retained PV (holding everything written since B8) goes `Released` and is left behind. Nothing errors; the post-move work is silently abandoned.
The way back is a **forward** commit that puts the app in `develop` again *with the kind-targeted `volumeName` patch*, plus a claimRef re-point to `develop/hermes`, then a content check.

The old kopia series (`hermes@develop:/data`, local and R2) is **never deleted** by this procedure, and the PV stays `Retain` until B10.

| Point | State | Rollback (**UNTESTED** unless marked — only the B8–B9 row was exercised, in the rehearsal) |
| --- | --- | --- |
| B1–B3 | app down, nothing else changed | resume HelmRelease + Kustomization; scale up |
| B4–B4b | PV `Retain`; ks resumed, HR suspended | patch PV back to `Delete`; resume the HR; scale up |
| B5 merged, before B6 | old inventory pruned (PVC `Terminating`/gone), PV `Released` (**UNTESTED** as a rollback; the state itself was produced in S2/S1) | **forward-commit** the app back into `develop` (`git mv` back **with** the kind-targeted `volumeName` patch and the build gate); re-point claimRef to `develop/hermes` (same command as B6 with `$OLD`); verify by content. Do **not** `git revert` |
| B6–B7 | PV bound to `ai/hermes`, pod at 0 | same forward-commit; re-point claimRef to `develop/hermes`; or approach A into `$OLD` from `hermes@develop` (with `sourceNamespace` **unset**, since the RD is in the same namespace as the series) |
| B8–B9 | pod running in `ai`, writing to the PV | **TESTED [Rh-4] (S3, 1 MiB fixture):** suspend HR, scale to 0, no pod references the PVC, resume ks; **forward commit** moving the app back with the kind-targeted `volumeName` patch (gate `want=1`: `volumeName` only — the RD is in the series' own namespace, so **no** `sourceNamespace`); wait for the PV `Released`; re-point the claimRef to the old namespace/name; the claim bound in ~10 s; `starts.log` **kept the line written while the app ran in the new namespace** — the retained PV came back, not a restore from the older snapshot. Then clean the orphans left by the suspended HR in the namespace you left (trap 7) **before** any later move. Data written since B8 lives **on the PV** (kept); the newest snapshot of it is `hermes@ai`, which the forward path never reads — take a fresh backup in `ai` first if the post-move work matters |
| after B10 (`Delete`) | PV deletable again | restore from **either** series into a fresh PVC (approach A). To flip back before anything is deleted, set `Retain` again |

When to flip back to `Delete`: only per B10. Until then a deleted PVC in `$NEW` is recoverable [S-ret]; after, it is not.

## 6. Hermes-specific appendix (`develop/hermes` → `ai/hermes`)

### Hermes-move go/no-go preconditions (derived from the rehearsal — every line must be true before B5)

- [ ] **B3 accepted for BOTH RS, with no sync in flight** [Rh-12]: `lastSyncStartTime` empty on `hermes-local` **and** `hermes-r2` at patch time (avoid `:23` ± a few minutes and `06:29`); `T0` taken after the pod is gone; both `lastManualSync == TAG`, `lastSyncTime > T0`; `check_backup` clean under **`hermes@develop`** (Created snapshot ≥1, `Setting policy for hermes@develop:/data` ≥1, `OPERATION_RESULT: SUCCESS` ≥1, `Directory is empty` = 0). A `lastManualSync == TAG` alone proves nothing.
- [ ] **A snapshot verified under `hermes@develop`** — the `check_backup` lines above are the proof; the mover log tail (not `Creating snapshot for …`) is what you read [R-3].
- [ ] **PV `Retain` read back** (`kubectl get pv $PV -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'` prints `Retain`) **and `$PV` re-read from the live PVC** in the same session, not from a saved variable [Rh-B2].
- [ ] **B4b outputs:** HR `suspend=true`, Deployment `replicas=0`, ks `suspend` empty/false [Rh-6]; **no pod (including Completed) references the PVC** [trap 3].
- [ ] **Pre-merge gate, all three assertions, on the committed tree**, including: the app build's `metadata.namespace` set is exactly `ai`; the parent build has exactly one child `ai hermes ./kubernetes/apps/ai/hermes/app ai`; both `volumeName` and `sourceNamespace: develop` lines present [Rh-13]. **And the literal `cluster-apps` parent-build command run once on the real branch** (still OPEN).
- [ ] **Pending-claims `jq` check is empty** (or only the moving claim) before B6 — the `--field-selector` form does not work [Rh-F]; the claimRef is **re-pointed, never removed** [Rh-3].
- [ ] **Pod at 0 through B5, B6 and B7** (`replicas: 0` in the commit; confirmed honoured [Rh-8]); B7's content check against the B2 baseline (named files, `sessions/`/`memories/` counts) passes **before** B8.
- [ ] **Do not trust the B5b restore drill unless the Longhorn snapshot behind `latestImage` is verified** (trap 14a); a stalled RD/`vs-prime` does **not** block approach B (pre-bound claim), but never fix it by touching the app PV. If approach A is ever needed, budget for the §3A step 5 recovery.
- [ ] Old-namespace orphan cleanup is ready (B11 block) so the app can return later without release-history contamination [Rh-O].
- [ ] `ai` namespace already carries `volsync.backube/privileged-movers: "true"` **live** (merged before this move, §6.5 — read it back with kubectl, not the manifest); `kubectl get snapshotpolicy -A | grep hermes` re-checked (§6.4); no Renovate PR touching hermes; hermes pod Running and both RS healthy at the start.
- [ ] Alerting: the orphaned/manual old RS can trip `VolSyncVolumeOutOfSync` — silence `obj_namespace=develop, obj_name=~hermes-.*` for the window if you want a quiet pager (the rehearsal silenced its scratch namespaces the same way).

### 6.1 Current state (2026-09-23; re-check before starting)

- Engine: **VolSync**. `ReplicationSource/hermes-local` (`23 * * * *`), `hermes-r2` (`29 6 * * *`), `ReplicationDestination/hermes-dst-local`. **No kopiur `SnapshotPolicy` exists for hermes**
  (only media/jellyseerr and media/recyclarr). `docs/runbooks/kopiur-migration.md:281` schedules hermes as wave **W6**. Re-check with `kubectl get snapshotpolicy -A | grep hermes`; if it has moved to kopiur, use §6.4.
- PVC `develop/hermes` 20Gi RWO `longhorn-1-replica-local`, PV `pvc-12f54114-9e99-442b-bae4-53a9cb239d69`, reclaim **Delete**, in the Kustomization inventory (`prune: true`).
- Kustomization `hermes` sits in namespace `develop` **because** `apps/develop/kustomization.yaml` sets `namespace: develop`; the new one lands in `ai` for the same reason.
- Live build check: the app builds to exactly one PVC and one RD (`r2.yaml` adds only an ExternalSecret + RS) — the precondition for the kind-only patch target.

### 6.2 Change list

Inside the app directory (moves with `git mv kubernetes/apps/develop/hermes kubernetes/apps/ai/hermes`):

| File:line | Change |
| --- | --- |
| `ks.yaml:15` | `path: ./kubernetes/apps/ai/hermes/app` |
| `ks.yaml:21` | `targetNamespace: ai` |
| `ks.yaml:26` | `NS: ai` (does not affect the VolSync identity; see §6.4 for kopiur) |
| `ks.yaml` shape | match `ai/litellm/ks.yaml` and `ai/hindsight/ks.yaml`: add `interval: 30m`, `retryInterval: 1m`, `timeout: 5m` (hermes has `interval: 1h`, no retry/timeout). `dependsOn` stays `external-secrets-openbao-store` only (no Postgres; do **not** copy `cloudnative-pg-cluster18`). `commonMetadata.labels`, `prune: true`, `wait: false`, `sourceRef home-kubernetes` already match |
| `ks.yaml:30-48` | keep every `VOLSYNC_*` value unchanged (`VOLSYNC_STORAGECLASS` must keep matching the retained PV's class). Comment at `:34` (8-minute grid) — leave |
| `app/kustomization.yaml` | append the **kind-targeted** patches below, with the comment |
| `app/helmrelease.yaml` | temporary `controllers.hermes.replicas: 0` for B5→B8 |
| `app/httproute.yaml:9` | gatus `group: develop` → `group: ai` (verify the string against `hindsight/app/httproute.yaml:66-67`) |
| `app/httproute.yaml:12` | homepage `gethomepage.dev/group: "Development"` → `"AI"` (`hindsight:71`, `litellm:35`) |
| `README.md` | `kubectl -n develop exec -it deploy/hermes -- hermes setup` → `-n ai` |
| Hostname `hermes.${SECRET_DOMAIN}`, `HERMES_DASHBOARD_PUBLIC_URL` (`helmrelease.yaml:46`), Authentik redirect URI, OpenBao key `hermes` | **unchanged** — ns-independent |

The `app/kustomization.yaml` addition (**kinds, not names** — see trap 5):

```yaml
patches:
  # Target by KIND. The component resources are named ${APP} / ${APP:=temp}-dst-local at build time; the names only
  # become hermes / hermes-dst-local after Flux postBuild substitution, so a name target is silently dropped.
  # Kind-only is safe ONLY while this app has exactly one PVC and one RD. Gate: flux build ks … | grep volumeName\|sourceNamespace.
  - target: {kind: PersistentVolumeClaim}
    patch: |-
      - op: add
        path: /spec/volumeName
        value: pvc-12f54114-9e99-442b-bae4-53a9cb239d69
  - target: {kind: ReplicationDestination}
    patch: |-
      - op: add
        path: /spec/kopia/sourceIdentity/sourceNamespace
        value: develop
```

Outside it:

| File:line | Change |
| --- | --- |
| `kubernetes/apps/develop/kustomization.yaml:13` | remove `./hermes/ks.yaml` |
| `kubernetes/apps/ai/kustomization.yaml:10-11` | add `./hermes/ks.yaml` (alphabetical: hermes, hindsight, litellm) |
| `kubernetes/apps/ai/namespace.yaml` | see 6.5; update the comment blocks `:9-21` and `:50-52` ("Hermes is expected to move here") to past tense once done |
| `kubernetes/apps/ai/hindsight/app/helmrelease.yaml:167` | comment "separate pod in `develop`" → `ai` |
| `kubernetes/components/kopiur/local.yaml:60`, `r2.yaml:60` | comment "`develop/hermes` is the one exception" → `ai/hermes` |
| `docs/runbooks/kopiur-migration.md:281,324` | W6 row and the "Only `develop/hermes` is affected" note → `ai/hermes` |
| `kubernetes/apps/home/ev-charge-tracker/ks.yaml:60` | comment mentions `develop/hermes-r2` (schedule-grid note) → `ai/hermes-r2` |
| `docs/runbooks/volsync-mover-stuck.md:158,281` | historical incidents — **leave** |

Checked clean: no NetworkPolicy/CiliumNetworkPolicy in either namespace, no ServiceMonitor/PrometheusRule/gatus/homepage file naming hermes (both driven by the HTTPRoute annotations),
no `hermes.develop.svc` reference anywhere, `ClusterSecretStore`/ExternalSecret are ns-independent, Gateway `internal` allows routes from all namespaces.

### 6.3 `ai` is not yet a backup namespace — hermes is the first

Neither `ai/litellm` nor `ai/hindsight` uses VolSync or kopiur (`hindsight/app/pvc.yaml:1-40`: "Deliberately NO components/volsync"; durable state is Postgres). Nothing in `ai` can be copied for backup wiring; only the `ks.yaml` shape.
Check on first apply: `ai` PSA is `baseline` (`namespace.yaml:53`), which admits the root mover [S-priv]; the `hermes-volsync-local`/`-r2` ExternalSecrets and Secrets, mover ServiceAccounts/Roles and the Helm release (fresh v1; `develop` reached v9) are recreated in `ai`;
the `ai` RD immediately runs its restore (trap 11) — **CONFIRMED [Rh-13]**: in the rehearsal it restored at creation (45 s for 1 MiB), `requestedIdentity` showed the patched identity, and the HelmRelease was a fresh `v1`.
Also observed [Rh-X]: Longhorn v1.12.1 online PVC expansion (1Gi→2Gi with the pod running) took ~28 s with no restart and recreated nothing, so a kustomize-managed capacity bump is safe on a pre-bound claim (hermes: 20Gi).

### 6.4 If hermes has moved to kopiur by then (as of 2026-09-23 it has not — re-check)

- `kubernetes/apps/kopiur-system/repositories/app/clusterrepository-local.yaml:47-55` and `clusterrepository-r2.yaml:31-39`: `allowedNamespaces.list` has 8 namespaces and **no `ai`** — add it (live: `NAMESPACES 8`).
- `kubernetes/apps/kopiur-system/repositories/app/externalsecrets.yaml`: each allowed namespace has a `kopiur-local` + `kopiur-r2` ExternalSecret pair (e.g. `develop` at `:116,:138`); `ai` has none — add the pair (inferred to be required).
- Identity: `components/kopiur/local.yaml:22-23,30` pins `username: ${APP}`, `hostname: ${NS}`, `sourcePathOverride: /data`. `NS: ai` forks the series exactly as VolSync does here (`kopiur-migration.md:310-320`).
  Keeping `hostname: develop` by decoupling it from `NS` is an open question (`NS` may be used elsewhere in the component — check first).
- Order: either move first (VolSync, this runbook) then cut over to kopiur in `ai`, or cut over in `develop` first. Doing both in one window doubles the identity forks and is not recommended.
- The W6 note (`kopiur-migration.md:281`, `staging.storageClassName: longhorn-1-replica` patch) travels with the app.

### 6.5 Decision: `volsync.backube/privileged-movers` on `ai` — DECIDED: add it, as its own commit BEFORE the move

**Decided 2026-09-24: add it.** It lands on branch `ai-privileged-movers` as a separate commit that merges to `main` **before** the B5 move commit, so it is already in place when hermes' first mover runs in `ai`. Do not fold it into the move commit. `ai` has no VolSync today, so the annotation affects nothing until hermes arrives.

**Correction (verified live 2026-09-24):** an earlier draft of this runbook, the investigation and the smoke notes said `media`, `productivity` and `games` run movers *without* the annotation. That is **wrong**. All three set it in their own `namespace.yaml`, and **all 8 namespaces that have a ReplicationSource carry it** (`database, develop, download, games, home, identity, media, productivity`). Without the change `ai` would be the only backup namespace lacking it.

`develop` has it (`develop/namespace.yaml:8`); `ai` did not (`ai/namespace.yaml:6-8`, before the change). Smoke evidence [S-priv]:

| | mover caps | restored uid-10000 files |
| --- | --- | --- |
| unannotated (like `ai` today) | none added (drop ALL) | **`0:0`, mode 664** in the rehearsal's B5b drill (originals `10000:10000`, 644) [Rh-P]; smoke saw `root:root` 660/770 for owner-only files |
| `privileged-movers: "true"` | `DAC_OVERRIDE, CHOWN, FOWNER` | `10000:root`, mode 660/770 (smoke) |

Both variants back up owner-only uid-10000 files correctly (content verified), and PSA `baseline` admits the root mover either way. Approach B needs neither, and under B ownership is not affected at all (same filesystem) [R-14].
It matters for restores (approach A, the `ai` RD's own restore drill in B5b, a later disaster restore — including a full-cluster rebuild, which restores every app through the populator) and for parity with the other 8 backup namespaces. Hermes' s6 entrypoint chowns `/opt/data` on start (`helmrelease.yaml:51-52`), so a restore without the annotation probably self-heals — **inferred from the manifest, never tested on a restored volume**.
**Why the risk is low:** hermes' own pod already adds `CHOWN, DAC_OVERRIDE, SETGID, SETUID` under the same `baseline` PSA, so the mover's three capabilities are a subset of what the app already holds. The mover's real exposure is the shared kopia repository credentials, which it has regardless of the annotation. It is per-namespace, so it also covers any later `ai` app with VolSync; revert by deleting one line.
**Result:** added (see the decision at the top of this section), so the first restore drill in `ai` behaves like `develop`'s does today. Record the restored ownership in the B5b drill: `10000:root` expected now, not `root:root`.

## Known untested

The smoke test, the review **and the rehearsal** have now covered the rest (see the **[Rh-n]** tags). Only these are still open — treat each as a place to slow down:

1. **A restore of the real ~570 MB `hermes@develop` series** — none since 2026-09-05. The rehearsal proved the mechanics on 1 MiB (byte-identical drill listing [Rh-9]); duration, the ~44Gi budget and Longhorn replica-rebuild time at real size are unmeasured. The populator/clone wedge (trap 14) makes this the item most likely to bite.
2. **HTTPRoute hand-over** (trap 13): whether Envoy blips or Gatus flaps; oldest-wins conflict resolution is Gateway API behaviour, not observed here (the fixture has no route; outside the blast radius by design). Verify by hand: `kubectl get httproute -A | grep hermes` → exactly one, in `ai`.
3. **The `git revert` rollback (R-6)** and **every rollback row except B8–B9**: B1–B4b, "B5 merged, before B6", "B6–B7" (incl. approach A back into the old namespace) and "after B10". The rehearsal's optional 3b (`git revert`) was skipped, so R-6 remains a source-reading claim.
4. **Approach A end to end on a real series.** The populator path was exercised only on an empty first-deploy series (and it wedged, trap 14); a restore of `hermes@develop` into a fresh `ai` claim with the app started was never run. The §3A recovery recipe is what worked once.
5. **The literal hermes-form pre-merge gate** — the `cluster-apps` parent-build assertion on the real branch (the equivalent `move_gate` passed on every rehearsal move).
6. **Why some RD runs publish a snapshot that does not exist on Longhorn** (trap 14a) — root cause **not established** (2 of 5 rehearsal RD runs; nothing the fixture did differently from hermes).
7. **Decisions, not tests:** kopiur (§6.4 — `allowedNamespaces`, per-namespace ExternalSecrets, identity decoupling from `NS`). The `ai` `privileged-movers` annotation is **decided** (§6.5: add it, merged first). Still untested: whether hermes' entrypoint really re-chowns a restored volume, and whether an unannotated restore of **owner-only** files is unreadable to a uid-10000 reader — now moot for `ai`, but relevant if the annotation is ever removed.
8. **Real-size timing of B3/B9 syncs** (the rehearsal's were seconds; hermes' are ~1½ min hourly / longer on R2) — relevant to the no-sync-in-flight window and to the creation-time first-sync overlap in B9.

## Confirmed by the rehearsal (formerly "Known untested" 1–13)

| # (old) | Item | Verdict | Where |
| --- | --- | --- | --- |
| 1 | SSA ownership of `volumeName` under real Flux | **CONFIRMED** (+ trap 12 observed verbatim) [Rh-1] | S2/S1/S4, 4c |
| 2 | B6 ordering | **CONFIRMED, both orders bind** [Rh-2] | S2, S1 |
| 3 | claimRef re-point binds a `Released` PV | **CONFIRMED** [Rh-3] | S2, S3, S1, S8 |
| 4 | rollback paths | **PARTIAL** [Rh-4] — B8–B9 row confirmed; rest open (item 3 above) | S3 |
| 5 | Longhorn `kubernetesStatus`, `best-effort` locality | **CONFIRMED** at 1 MiB [Rh-5] | S6 |
| 6 | resumed ks vs HR `spec.suspend` | **CONFIRMED** [Rh-6] | S3A, S1 |
| 7 | schedule→manual on a live RS, revert after B4b | **CONFIRMED** [Rh-7] | S10b, S10a |
| 8 | `replicas: 0` with `Recreate` | **CONFIRMED** [Rh-8] | S2, S1 |
| 9 | restore of the real 570 MB series | **OPEN** (mechanics confirmed [Rh-9]) | S1 B5b |
| 10 | route hand-over | **OPEN** | — |
| 11 | `Delete` on a bound PV; deleting the RD's dest PVC | **CONFIRMED** [Rh-11] | S1 B10, teardown, B5b |
| 12 | fork's manual/tag semantics | **CONFIRMED** [Rh-12] | S10a, S1 B9 |
| 13 | in-cluster kustomize-controller vs local build | **CONFIRMED** [Rh-13] | S7, S2, S1 B5b |

## Rehearsal (done)

A Flux-level rehearsal of this runbook ran on **2026-09-23** (≈20:50–23:25 UTC) against the live cluster on a throwaway app, `moveprobe` (`APP=moveprobe`, kopia username `moveprobe`), under `docs/rehearsal/plan.md` (rev 3) with the guards file `~/.herdr/worktrees/flux-talos/rehearsal-guards.sh`. A reference copy is committed as `docs/rehearsal/rehearsal-guards.sh` (see `docs/rehearsal/README.md`: it hard-codes rehearsal names and paths, so treat it as a pattern for the real move's guards, not as something to run against hermes).
**Full record: `docs/rehearsal/results.md`.** Shape: a scratch `GitRepository` (`rehearsal`, branch `rehearsal-move`) and a scratch parent Kustomization (`rehearsal-apps`) with the **same patches as `cluster-apps`**, two namespaces (`rehearsal-old` annotated like `develop`, `rehearsal-new` unannotated like `ai`), an app-template HelmRelease + `volsync-claim`/`volsync-backup` mirroring hermes; everything reached the cluster only through Flux.

Outcome: **all scenarios PASS**, hermes untouched throughout (pod never restarted, PV `Delete`/`Bound`), teardown verified.

| Scenario | Result |
| --- | --- |
| Baseline | PASS after a recovery — SURPRISE: populator/Longhorn stall on the first deploy (trap 14, [Rh-B1]); guard cache sharp edge ([Rh-B2]) |
| 7 name-targeted patch: gate fires | PASS [Rh-13] |
| 2 orphan behaviour without resuming the old ks | PASS — traps 6/7 confirmed live [Rh-O] |
| 3 rollback by forward commit + re-point | PASS [Rh-4] |
| 1 full B0–B11 | PASS |
| 4 SSA ownership / spec change (+4c) | PASS; 4c produced the verbatim error [Rh-1], [Rh-X] |
| 5 B6 ordering | SURPRISE — the actual order is OLD prune → `Released` → NEW claim ~6 s later → `FailedBinding` until the re-point [Rh-2] |
| 6 `kubernetesStatus` + locality | PASS [Rh-5] |
| 8 re-point with a competing claim | PASS — R-5 confirmed [Rh-3] |
| 9 `Delete` on a bound PV | PASS [Rh-11] |
| 10 schedule/manual + in-flight race | PASS — R-4 confirmed on the fork; Flux removes `manual` [Rh-7], [Rh-12] |
| Not run | 3b (`git revert`), 6b, a second annotated drill |

**Residue:** kopia series `moveprobe@rehearsal-old` and `moveprobe@rehearsal-new` remain in the shared local (Garage) and R2 repositories (a handful of tiny snapshots each; deleting them needs a kopia client) — as do the smoke test's `smoketest*`. **A re-run must use `APP=moveprobe2`.**
Guards fixes made afterwards: `app_pv` now re-reads the PVC on every call (never a cached file), and the `Claude-Session` commit trailer comes from the optional `CLAUDE_SESSION_URL` environment variable (omitted if unset).

## Procedure hygiene for the hermes move [Rh-F, Rh-B2]

- **Re-read the PV** from the live PVC whenever you need it; never reuse a variable/file saved before anything re-provisioned the claim.
- `kubectl get pvc -A --field-selector=status.phase=Pending` is invalid — use the `jq` form (Preconditions, B6).
- `kubectl get -o json` returns null `managedFields` unless you pass **`--show-managed-fields`** — needed for every "who owns this field" query (`kubectl -n $NEW get pvc $APP --show-managed-fields -o json | jq '.metadata.managedFields[]|{manager,operation,spec:((.fieldsV1["f:spec"] // {})|keys)}'`).
- `kubectl get <kind> <name> -w` on an object that does not exist yet exits immediately with `NotFound` — watch the namespace, or poll timestamps.
- `kubectl get events --field-selector involvedObject.name=<claim>` includes events from previous same-named claims (they live ~1 h) — filter by `lastTimestamp` (B6) or by the claim's UID.
- Every wait loop is **bounded** (`for i in $(seq 1 N)`); a wait that returns on timeout must stop the procedure.
- Completed helper Jobs block PVC deletion (trap 3): delete them before the step that deletes the PVC.

## Open questions

Answered since the first draft: **suspended-Kustomization deletion** (trap 6, [R-2], confirmed live [Rh-O]); **helm-controller uninstall of a suspended HR** (trap 7, [R-12], [Rh-O]); **schedule→manual precedence and RS revert** (B3, [Rh-7], [Rh-12] — confirmed on the fork); **kind-targeted patches in-cluster** ([Rh-13]).

1. Everything under **Known untested**.
2. Old `hermes@develop` series: never written again, so never expired (inferred). Decide a date to age it out by hand; it is the rollback for the first weeks.
3. Should the empty-source case (trap 4) get an alert (`OPERATION_RESULT: FAILURE` alongside `result: Successful`)? Reproduced live [Rh-B1]; still invisible.
4. Residue: kopia series `smoketest@smoke-src`, `smoketest@smoke-dst`, `smoketest-perm@smoke-dst` **and** `moveprobe@rehearsal-old`, `moveprobe@rehearsal-new` remain in the shared repositories (small, distinct identities); deleting them needs a kopia client.
5. ~~Annotation decision for `ai` (§6.5)~~ — **decided 2026-09-24: add it, merged before the move.**
6. Kopiur identity: keep `hostname: develop` (decouple from `NS`) or accept the fork (§6.4).
7. What makes an RD publish a `latestImage` with no Longhorn snapshot behind it (trap 14a)? Worth an upstream Longhorn/VolSync issue if it recurs.

## Changes since rehearsal

Maps each numbered correction in `docs/rehearsal/results.md` § "Statements to change" to what changed here.

| # | Correction (results.md) | Changed in this runbook |
| --- | --- | --- |
| 1 | `--field-selector=status.phase=Pending` rejected | **Preconditions** (jq form, expected result) and **B6** (jq form); §4 table row "B6 Pending claims"; **Procedure hygiene** [Rh-F] |
| 2 | Populator stall: (a) `readyToUse` not proof, (b) Flux reverts RD `manual`, (c) delete `vs-prime`, (d) app clone can fail; scope A/`ai` RD, not B | **Trap 14** rewritten (a)–(d) + scope; **§3A step 5** rewritten as a bounded six-step recovery; **B5b free restore drill** (Longhorn snapshot check, void-if-missing, approach B unaffected); §4 table row; go/no-go item; Known untested 1, 4, 6 |
| 3 | Sharpen B3/B4b (both keys; Flux removes `manual`; ks suspension mandatory) | **B1** (ks suspension mandatory, why); **B3** prose + bounded loop (both keys, `WaitingForManual`, Flux removal); **B4b** ([Rh-6] confirmed, RS reverts on resume); trap 8 |
| 4 | In-flight race shown; same warning for B9 newly created RS | **Trap 8** (S10a evidence: no second sync; `lastSyncTime > T0` insufficient; creation-time sync); **B3**; **B9** warning; go/no-go item 1 |
| 5 | Orphan case, B11 list confirmed | **Trap 6, trap 7** (CONFIRMED [Rh-O]); **B11** (observed orphans, GC'd RD/RS objects, bounded assert-empty block) |
| 6 | §6.3 / trap 11 confirmations (fresh v1, RD restores at creation) | **Trap 11**, **§6.3** |
| 7 | Ownership `0:0` mode 664; drill as uid 0 | **Trap 15**, **B5b drill** (uid 0, `ls -ln`), **§6.5 table** |
| 8 | Dest-PVC delete verified | **B5b** ("optional … VERIFIED tolerated [Rh-11]"); Confirmed table row 11 |
| 9 | `Delete` patch accepted; ~19 s effect | **B4 rollback**, **B10** (comment + "re-arms trap 2"), **trap 2** |
| 10 | Actual B6 order + expected `FailedBinding` | **B6** (the order you will actually see; both orders confirmed); Confirmed table row 2 |
| 11 | Longhorn v1.12.1 online expansion datum | **§6.3** ([Rh-X]); trap 12; tag legend |
| 12 | Keep OPEN: literal `cluster-apps` parent-build gate | **B5 gate** ("STILL OPEN" paragraph); go/no-go item 5; **Known untested 5** |
| 13 | Hygiene list (PV re-read, `get -w`, `--show-managed-fields`, stale events) | **§3 variables block** (re-read `$PV`), **Procedure hygiene** section, **B6** (watchers, events filter), §4 events line |
| — | Every UNVERIFIED/inferred the rehearsal settled | traps 5/12; B3, B4 rollback, B4b, B5 step 4, B5 gate, B5b, B6, B10; §5 table (one row tested); Known untested rewritten to open items only; **Rehearsal** rewritten as done; tag legend gains **[Rh-*]**; **Hermes-move go/no-go preconditions** added at the top of §6 |
