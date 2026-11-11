# kopiur-claim: app PVCs that restore themselves

`kubernetes/components/kopiur-claim` creates an app's data PVC together with a kopiur
`Restore` in populator mode (`<app>-claim`). The PVC names the Restore in
`spec.dataSourceRef`, so whenever the PVC is created, kopiur fills it from the latest
snapshot of `<app>-local` before it binds. With no snapshot yet, it binds empty. It is the
successor to the VolSync-era `components/volsync-claim`, built at decommission step 5 (2026-11-11; see
`kopiur-migration.md`).

**Use it for:**

- every new app with a data PVC, together with `components/kopiur`;
- an existing app (on `volsync-claim`, or paperclip's plain `pvc.yaml`) only when its PVC is
  being deleted and recreated anyway, following "Recreating a PVC" below.

Never swap a bound PVC in place: `dataSourceRef` is immutable, so server-side apply fails on
the PVC and the app's whole Kustomization stops reconciling.

## Why a Restore can live in Git permanently

kopiur resolves a Restore's snapshot once, and the CRD docs say "never re-resolved". In
populator mode that holds **per claiming PVC**, though, not per Restore. kopiur keeps one
record per claim, keyed by the PVC's uid. A recreated PVC has a new uid, so kopiur resets that
claim's record under the new uid and resolves again (`ClaimDrive::ReArm`, `restore/mod.rs` in 0.10.17, reason
`ClaimRecreated`).

**Tested 2026-11-11** with throwaway claims in `media` (test objects deleted afterwards):

- **Existing identity** (`calibre-web-local`): the first claim restored the then-latest snapshot
  `e76ed813…`. After a manual backup, the PVC was deleted and recreated. It restored the new
  snapshot `13e3a7d5…`: 7 entries `568:568`, plus the volume's own `lost+found`.
- **New identity** (no snapshots): the first claim bound empty (`NoSnapshotContinue`). After a
  file was written as 568 in a `2775` directory and backed up, the PVC was deleted and
  recreated. It restored that file, with its owner and setgid bit.
- Both Restores read `Completed` once populated, and `Pending` while no PVC claimed them.

## New app

In `app/kustomization.yaml`:

```yaml
components:
  - ../../../../components/kopiur
  - ../../../../components/kopiur-claim
```

In `ks.yaml`, `dependsOn: kopiur-repositories` (namespace `kopiur-system`) as for any
`components/kopiur` app, and the claim's sizing in `postBuild.substitute`:

| Variable | Default | Note |
|---|---|---|
| `VOLSYNC_CAPACITY` | `20Gi` | names kept from `volsync-claim`, so a swap renames nothing |
| `VOLSYNC_STORAGECLASS` | `tns-csi-nfs` | |
| `VOLSYNC_ACCESSMODES` | `ReadWriteMany` | RWX lets a Direct-copy backup mover mount it beside the app |
| `KOPIUR_CLAIM_SOURCE` | `local` | `r2` fills a recreated PVC from the offsite repository |

The namespace needs `kopiur.home-operations.com/privileged-movers: "true"`. The restore mover
runs as root with `CHOWN`, `FOWNER`, `FSETID` and `DAC_OVERRIDE`, or ownership is lost; see
the comment in `restore.yaml`. Every namespace that already runs `components/kopiur` has the
annotation.

On first deploy, expect the Restore at `Completed` with the claim's reason
`NoSnapshotContinue`. That is the empty start.

## Recreating a PVC

Use this to change the storage class, to recover a corrupted volume, to restore after the
volume was lost, or to move an existing app onto `kopiur-claim`. Throughout, `<ns>`, `<app>`
and `<workload>` are the app's.

1. **Hold Flux off and stop the app.** With the Kustomization suspended, Flux cannot recreate
   the PVC between the delete and the merge, and an unmerged manifest change cannot stall it.

   ```sh
   flux -n <ns> suspend ks <app>
   flux -n <ns> suspend hr <app>
   kubectl -n <ns> get deploy <workload> -o jsonpath='{.spec.replicas}'   # or sts; note it
   kubectl -n <ns> scale deploy/<workload> --replicas=0
   ```

2. **Take a fresh backup, unless the volume itself is lost or corrupted.** A backup taken
   now, with the app stopped, is the snapshot the new PVC gets:

   ```sh
   snap=$(kubectl -n <ns> create -o name -f - <<'EOF'
   apiVersion: kopiur.home-operations.com/v1alpha1
   kind: Snapshot
   metadata:
     generateName: <app>-local-manual-
   spec:
     policyRef:
       name: <app>-local
   EOF
   )
   kubectl -n <ns> wait "$snap" --for=jsonpath='{.status.phase}'=Succeeded --timeout=30m
   kubectl -n <ns> get "$snap" -o jsonpath='{.status.snapshot.kopiaSnapshotID}'
   ```

   `kubectl wait` does not stop on `Failed`: if it runs long, check
   `kubectl -n <ns> get "$snap" -o jsonpath='{.status.phase} {.status.failure}'`.

   For a lost or corrupted volume, skip the backup. Instead, find the last good snapshot in
   `kubectl -n <ns> get snapshots.kopiur.home-operations.com`. If it is not the latest, read
   "Restoring an older snapshot" first.

3. **Delete the PVC:** `kubectl -n <ns> delete pvc <app> --wait`.

4. **Merge the manifest change, if there is one.** It could be a new storage class or size in
   `ks.yaml`. Or it could be the move onto the component: in `app/kustomization.yaml`, replace
   `../../../../components/volsync-claim` with `../../../../components/kopiur-claim`. A
   `volsync-claim` app's `ks.yaml` needs no change, since the claim reads the same `VOLSYNC_*`
   variables. **paperclip** has an app-local `pvc.yaml` and no `VOLSYNC_*` variables: drop the
   file and set `VOLSYNC_CAPACITY: 20Gi`, `VOLSYNC_STORAGECLASS: longhorn-2-replica` and
   `VOLSYNC_ACCESSMODES: ReadWriteOnce`, or the defaults (tns-csi-nfs, RWX) apply.
   **dispatcharr** is on `volsync-claim` with a patch that strips `dataSourceRef`: swap the
   component and drop that patch. For a plain recovery there is nothing to merge.

5. **Let Flux create the Restore and the new PVC:** `flux -n <ns> resume ks <app>`. Resuming
   reconciles the latest commit. From step 3 until the claim is populated the Restore reads
   `Pending`, which holds tuppr's upgrades and fires `KopiurRestoreStuck` after 1h. Have the
   step-4 PR approved before step 3 so that window stays short.

   **WaitForFirstConsumer classes** (`longhorn-1-replica-local`, `longhorn-2-replica-local`,
   `openebs-hostpath` on 2026-11-11; check with `kubectl get sc`) populate only once a pod
   that uses the PVC is scheduled. kopiur parks the claim at `AwaitingPodSchedule` meanwhile.
   With the app scaled to 0, nothing schedules it, so start a placeholder pod that mounts the
   PVC and does nothing. It picks the node, kopiur populates it there, and you can check
   step 6 before the app starts:

   ```sh
   kubectl -n <ns> run <app>-claim-hold --image=busybox:1.37 --restart=Never \
     --overrides='{"spec":{"containers":[{"name":"h","image":"busybox:1.37","command":["sleep","86400"],"volumeMounts":[{"name":"d","mountPath":"/d"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"<app>"}}]}}'
   ```

   If the app needs a particular node, add the app's `nodeSelector` or affinity to the
   override. Delete the pod after step 6 and before step 7. A local volume stays on the node
   the placeholder landed on.

6. **Check what it restored before the app starts writing:**

   ```sh
   kubectl -n <ns> get restores.kopiur.home-operations.com <app>-claim -o json \
     | jq '{phase: .status.phase, claims: .status.claims}'
   kubectl -n <ns> get pvc <app>
   ```

   You want `phase: Completed`, the claim at `Populated` / `RestoreSucceeded`, and
   `resolved.resolution: Snapshot` with the `kopiaSnapshotID` from step 2.
   **`NoSnapshot` or `NoSnapshotContinue` on an existing app means it came up EMPTY.** Do not
   start the app. The usual causes are a wrong `KOPIUR_CLAIM_SOURCE` or an `${APP}` that no
   longer matches the identity. Fix the cause, suspend the Kustomization, and delete the PVC
   again (steps 3 and 5): the new uid re-arms the claim.

7. **Start the app:** `flux -n <ns> resume hr <app>`, then scale back to the count from
   step 1. Without drift detection, helm-controller does not undo the manual scale-to-0.

## Restoring an older snapshot

`kopiur-claim` always takes the latest snapshot (`offset: 0`). Don't edit its Restore for a
one-off: whether a spec edit re-resolves an existing claim was not tested. Instead:

- **into the existing PVC**, with the app stopped: a one-off Restore with `target.pvcRef`
  naming the PVC and `source.snapshotRef` (or `fromPolicy` with `asOf` / `offset`). It needs
  the same mover block as `components/kopiur-claim/restore.yaml`. Delete the Restore when it
  is `Completed`.
- **for a snapshot older than the catalog keeps:** see "Restoring an aged-out snapshot" in
  `kopiur-migration.md` (`source.identity` plus `spec.repository`).

## Alerts and the upgrade gate

tuppr holds Talos and Kubernetes upgrades while any Restore is `Pending`, `Resolving` or
`Restoring` (`kubernetes/apps/system-upgrade/tuppr/upgrades/`). A `kopiur-claim` Restore
reads `Pending` (`AwaitingClaim`) from the moment its PVC is deleted until the new one is
populated. A recreate left half done therefore blocks upgrades indefinitely.

- `KopiurRestoreStuck`: `Pending` or `Resolving` for 1h.
- `KopiurRestoreSlow`: `Restoring` for 6h. A large volume can legitimately take hours, so
  check the mover Job's log for progress first.
- kopiur's own `KopiurRestoreFailed` covers `Failed`. A failed claim is retried by deleting
  and recreating its PVC ("Recreating a PVC", steps 3 and 5). The re-arm deletes the failed Job and its leftover prime
  PVC, except after `PopulateHijacked`, whose prime kopiur keeps on purpose as evidence.

All three read `kopiur_resource_phase{kind="Restore"}`, which the kopiur controller exports.
