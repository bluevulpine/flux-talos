# kopiur restore verification kit

The per-wave restore gate from [`kopiur-migration.md`](../kopiur-migration.md#gates). It
restores one app's snapshots from **both** repositories (`kopia-local`, `kopia-r2`) into
scratch PVCs. A pod then mounts the live volume and both restores **read-only**, and
compares them. As committed, it is the W1 run that passed on 2026-09-25: calibre-web on
`longhorn-1-replica`, an always-running app with two files it keeps writing. The W0 run
(recyclarr, a static volume) is at `b625ac57:docs/runbooks/kopiur-restore-verify/`.

These are hand-applied manifests, not Flux-managed. Nothing under `docs/` is reconciled.

| file | what |
| --- | --- |
| `restores.yaml` | two `Restore`s (one per repository) into new PVCs, root mover **plus added capabilities** |
| `compare-pod.yaml` | read-only comparison of live vs local, live vs R2 and local vs R2: sha256 of every file; type/mode/owner/size of every entry; file mtimes; directory mtimes (informational). Files matching `WRITERS` are left out of the strict comparison and checked separately: the SQLite databases with `PRAGMA integrity_check` (in the app's own image), the rest shown for information |
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
3. **Names.** Replace `calibre-web` throughout all three files: the Restore/PVC names,
   `claimName: calibre-web` in the compare pod, the pod-label/node guard in `run.sh`, and
   `NS`. For a CronJob app like recyclarr, restore the W0 guard (refuse while the job is
   active) and drop `nodeName`.
4. **Window.** The live PVC is RWO. Run when the app's own pod, its VolSync movers and its
   kopiur movers are not using it. For an always-attached Deployment, set
   `spec.nodeName` on the compare pod to the node the app runs on. Otherwise the pod can
   land elsewhere and sit in `Multi-Attach` until `run.sh`'s 10-minute wait fails.
5. **Live writers.** For a file with an active writer (for example a SQLite DB), byte
   identity against live is not a valid test, because the source changes after the
   snapshot. List those files in `WRITERS` and the SQLite files in `DBS` (the only two
   lists in `compare-pod.yaml`; everything else derives from them);
   find them with `ls -la --time-style=full-iso` in the app pod (mtime after the
   snapshots). Use the app's own image, by the running pod's digest, so `sqlite3` matches
   what the app uses. The local and R2 restores still have to match each other, so pick
   two snapshots with no write between them (same `stats.sizeBytes` is a good sign). The
   method is the jellyseerr pilot's (criterion 4 in
   `b625ac57:kubernetes/apps/media/jellyseerr-kopiur-pilot/README.md`).

`restores.yaml` and `compare-pod.yaml` are server-dry-run clean in `media`. Use
`kubectl apply --dry-run=server --validate=false`, because the client-side OpenAPI fetch
times out when the apiserver is busy.
