# kopiur restore verification kit

The per-wave restore gate from [`kopiur-migration.md`](../kopiur-migration.md#gates). It
restores one app's snapshots from **both** repositories (`kopia-local`, `kopia-r2`) into
scratch PVCs. A pod then mounts the live volume and both restores **read-only**, and
compares them. As committed, it is the W0 run that passed on 2026-09-24: recyclarr on
`longhorn-1-replica`.

These are hand-applied manifests, not Flux-managed. Nothing under `docs/` is reconciled.

| file | what |
| --- | --- |
| `restores.yaml` | two `Restore`s (one per repository) into new PVCs, root mover **plus added capabilities** |
| `compare-pod.yaml` | read-only comparison: sha256 of every file; type/mode/owner/size of every entry, summarised per field; file mtimes; directory mtimes (informational) |
| `run.sh` | `./run.sh` restores and compares; `./run.sh compare` re-runs the comparison only; `./run.sh cleanup` deletes everything it created |

## Do not drop the capability block

`runAsUser: 0` alone restores every entry as `0:0`, and the Restore still reports
`Completed`. kopiur keeps `drop: [ALL]` under whatever you set, and `privilegedMode` does
not change that in 0.10.9. See "Restores need capabilities, not just root" in the runbook.

## Adapting it to another app

1. **Pick the snapshots.** Use the app's newest `Succeeded` kopiur Snapshot on each leg,
   taken **after** the app's last write if you want byte identity. `kubectl -n <ns> get
   snapshots.kopiur.home-operations.com` lists them. Set `source.snapshotRef.name` in both
   Restores.
2. **Size and class.** Set `target.pvc.capacity` to at least the source PVC's size, and
   `storageClassName` to the class being gated. The gate is per StorageClass.
3. **Names.** Replace `recyclarr` throughout all three files: the Restore/PVC names,
   `claimName: recyclarr` in the compare pod, the `cronjob recyclarr` guard in `run.sh`,
   and `NS`.
4. **Window.** The live PVC is RWO. Run when the app's own pod, its VolSync movers and its
   kopiur movers are not using it. For an always-attached Deployment, set
   `spec.nodeName` on the compare pod to the node the app runs on. Otherwise the pod can
   land elsewhere and sit in `Multi-Attach` until `run.sh`'s 10-minute wait fails.
5. **Live writers.** For a volume with an active writer (for example a SQLite DB), byte
   identity is not a valid test, because the source changes after the snapshot. Use the
   jellyseerr pilot's method instead: open the restored DB with the app's own driver and
   run `PRAGMA integrity_check`. See criterion 4 in
   `b625ac57:kubernetes/apps/media/jellyseerr-kopiur-pilot/README.md` (retired;
   `git show` it).

`restores.yaml` and `compare-pod.yaml` are server-dry-run clean in `media`. Use
`kubectl apply --dry-run=server --validate=false`, because the client-side OpenAPI fetch
times out when the apiserver is busy.
