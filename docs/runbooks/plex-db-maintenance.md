# Plex: config volume RWX → RWO, and library database maintenance

Two jobs that both need Plex stopped, so they share one window:

1. **Re-bind** the `media/plex` config claim from ReadWriteMany to ReadWriteOnce on
   the **same** Longhorn volume (`pvc-62b3e407-e403-4287-8c06-c0e1d8b9c37d`), no
   restore.
2. **Rebuild** the two library databases (`com.plexapp.plugins.library.db`,
   `…library.blobs.db`) with [`plexdb-maint.sh`](plex-db-maintenance/plexdb-maint.sh).

Step 2 alone (database maintenance) can be repeated any time: skip to
[Database maintenance](#database-maintenance).

## Why

**RWO.** Longhorn serves an RWX volume as NFS from a `share-manager` pod
(`nfs4 … local_lock=none`), so every SQLite lock Plex takes is a network round
trip. On 2026-11-02 Plex's view-state writes (`MetadataItemSetting.cpp:459/409`)
queued at 0.6–1.0 s each whenever anyone was watching, `/identity` stopped
answering (30 s timeouts from inside the pod), and the probes failed 330 times
over 3d17h. Sync writes to the volume itself were fast (2.2 ms per 4k
`dsync`), and the errors stopped when nobody was watching (0 between 19:20 and
03:02), so the cause was the lock round trips, not the disk. Jellyfin hit the
same problem on NFS and moved to RWO in #1703.

RWX was only ever the `components/volsync-claim` default (written for VolSync's
Direct mover). Plex's backups use `KOPIUR_COPYMETHOD: Snapshot`, and the only
other pod that mounts the claim, the `plex-image-cleanup` CronJob, is
podAffinity-pinned to Plex's node. RWO is enough for both.

**Rebuild, not DBRepair.** DBRepair.sh was retired upstream on 2026-11-02 and
removed from public view (it was never open source: "personal use only, may not
be modified"); the replacement (v26.10.00, first released 2026-10-16) is a
proprietary compiled binary with a no-reverse-engineering clause. Upstream's
stated reasons are PMS 1.43.4's schema changes and FTS handling, and Windows
support (ChuckPa/DBRepair#293). `plexdb-maint.sh` is the standard SQLite rebuild
(integrity check → `.dump` → import into a fresh file → verify → swap), written
from scratch with Plex's own `Plex SQLite`, so every operation against the only
live copy is readable. Keep DBRepair as the fallback for real corruption: it
rebuilds the FTS tables version-aware, and a plain dump/import can fail on them
(upstream #247). Note `Plex SQLite` in the 2026-11 image reports SQLite 3.39.4,
older than the 3.44+ that validates FTS4 in `integrity_check`. It also checkpoints the write-ahead logs, which had grown to
522 MB (`library.db-wal`) and 1.1 GB (`blobs.db-wal`): SQLite never shrinks a
WAL file on its own (`journal_size_limit` unset).

## Before the window

- [ ] PR merged (`VOLSYNC_ACCESSMODES: ReadWriteOnce` + the temporary
      `volumeName` pin). Merging changes nothing live: the claim carries
      `ssa: IfNotPresent`, so Flux leaves the existing claim alone.
- [ ] The live substitution shows the new value **before** the claim is deleted.
      Otherwise Flux re-creates it RWX, and with `IfNotPresent` never corrects it:
      ```sh
      kubectl -n media get ks plex -o jsonpath='{.spec.postBuild.substitute.VOLSYNC_ACCESSMODES}'   # ReadWriteOnce
      kubectl -n media get ks plex -o jsonpath='{.status.lastAppliedRevision}'                       # the merge commit
      ```
- [ ] No streams (Tracearr), and not inside a kopiur slot: `plex-r2` runs at
      `H 4 * * *` UTC, `plex-local` at `H 7 * * *` UTC.
- [ ] Budget ~25 min of Plex downtime. Rehearsal 2026-11-02 on a copy of the
      10-31 backup, over the RWX/NFS volume: checkpoint + integrity 46 s, copy
      originals 24 s, main dump + import 60 s, blobs dump + import 172 s
      (2.15 GB of SQL), **rebuild 321 s total**; row counts identical, both
      rebuilt files `integrity_check ok`. The block device should be faster.
      Plus ~2 min Plex startup and the re-bind steps. Scratch needed: ~7 GB on
      the volume (68 GB free).

## Window

> **Steps 2, 3 and 6 were the one-time RWX → RWO re-bind, done 2026-11-03.** A
> later maintenance night runs only **1 (Quiesce) → 4 (Database maintenance) → 5
> (Bring Plex back)**. Never re-run step 3 as written: the `volumeName` pin it
> relied on was removed in #2371, so Flux would re-create the claim unpinned, with
> its inert VolSync `dataSourceRef`: an empty volume or a `Pending` claim instead
> of Plex's config (the old PV is `Retain`, so recoverable, but Plex stays down).
> Re-add a pin first if the claim ever has to be re-created.

All commands use `--context admin@home-kubernetes`; omitted below.

### 1. Quiesce

```sh
flux -n media suspend ks plex
flux -n media suspend hr plex
kubectl -n media patch cronjob plex-image-cleanup -p '{"spec":{"suspend":true}}'
for p in plex-local plex-r2; do
  kubectl -n media patch snapshotpolicies.kopiur.home-operations.com $p --type merge -p '{"spec":{"suspend":true}}'
done
kubectl -n media scale deploy/plex --replicas=0
kubectl -n media wait --for=delete pod -l app.kubernetes.io/name=plex --timeout=120s
```

The parent `cluster-apps` reconcile can revert these suspends at any moment
(seen twice during the 2026-10 re-binds). Re-check `.spec.suspend` on the ks, hr
and both policies before each destructive step below. The deployment staying at
0 is what actually protects the data.

Wait for the volume to detach (the share-manager pod goes away):

```sh
kubectl -n longhorn-system get volumes.longhorn.io pvc-62b3e407-e403-4287-8c06-c0e1d8b9c37d \
  -o jsonpath='{.status.state} {.spec.accessMode}{"\n"}'     # detached rwx
```

### 2. Switch the volume and PV to RWO

Both patches passed `--dry-run=server` on 2026-11-02 (Longhorn v1.13.0).

```sh
V=pvc-62b3e407-e403-4287-8c06-c0e1d8b9c37d
kubectl -n longhorn-system patch volumes.longhorn.io $V --type merge -p '{"spec":{"accessMode":"rwo"}}'
kubectl patch pv $V --type merge -p '{"spec":{"accessModes":["ReadWriteOnce"]}}'
kubectl get pv $V -o jsonpath='{.spec.persistentVolumeReclaimPolicy} {.spec.accessModes}{"\n"}'   # Retain ["ReadWriteOnce"]
```

The PV must be `Retain` (it is, since the 2026-10-03 re-bind). If it shows
`Delete`, set `Retain` first: deleting the claim would otherwise delete the volume.

### 3. Re-bind the claim

```sh
kubectl -n media delete pvc plex                  # ask rule: Derek approves
kubectl get pv $V -o jsonpath='{.status.phase}{"\n"}'   # wait for Released
kubectl patch pv $V --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
kubectl get pv $V -o jsonpath='{.status.phase}{"\n"}'   # Available
# re-check the live substitution (Before the window) and the suspends, then:
flux -n media resume ks plex
kubectl -n media get pvc plex -o jsonpath='{.status.phase} {.spec.volumeName} {.spec.accessModes}{"\n"}'
# Bound pvc-62b3e407-… ["ReadWriteOnce"]
```

Clear `claimRef` only after the PV is `Released`; cleared earlier, the PV
controller puts it back. Resuming the ks re-applies the kopiur SnapshotPolicies
from git, which **clears their `spec.suspend`** (it did on 2026-11-03); the
HelmRelease stayed suspended. Before step 4, re-suspend both policies and check
the deployment is still at 0 replicas.

### 4. Database maintenance

See [below](#database-maintenance). On the first run, also confirm the volume is
now a block device:

```sh
kubectl -n media exec plexdb-maint -- sh -c 'mount | grep " /config "'   # /dev/longhorn/… ext4, not nfs4
```

### 5. Bring Plex back

```sh
kubectl -n media delete pod plexdb-maint
flux -n media resume hr plex
kubectl -n media scale deploy/plex --replicas=1
kubectl -n media rollout status deploy/plex --timeout=10m
kubectl -n media patch cronjob plex-image-cleanup -p '{"spec":{"suspend":false}}'
for p in plex-local plex-r2; do
  kubectl -n media patch snapshotpolicies.kopiur.home-operations.com $p --type merge -p '{"spec":{"suspend":null}}'
done
```

Startup runs an analyze + vacuum before `/identity` answers (about 2 min on
2026-11-02). Verify:

- `curl -s -w '%{http_code} %{time_total}\n' -o /dev/null http://localhost:32400/identity`
  from inside the pod returns `200` in milliseconds.
- `mount | grep " /config "` in the Plex pod is ext4, and
  `kubectl -n longhorn-system get pod | grep share-manager-pvc-62b3` returns
  nothing.
- After an evening of streaming, `grep -c "Took too long"` in
  `Logs/Plex Media Server.log` stays near 0.
- The next `plex-local` kopiur snapshot succeeds.

### 6. Follow-up PR

Drop the `volumeName` pin from `app/kustomization.yaml` (a no-op on the live
claim with `IfNotPresent`). `grep -rn "volumeName: pvc-" kubernetes` must be
empty afterwards.

## Database maintenance

Plex must be stopped (deployment at 0, pod gone). The helper pod uses the same
image as Plex, so it has `Plex SQLite`; stock sqlite3 cannot import Plex's
schema.

```sh
kubectl apply -f docs/runbooks/plex-db-maintenance/helper-pod.yaml
kubectl -n media wait --for=condition=Ready pod/plexdb-maint --timeout=180s
kubectl -n media cp docs/runbooks/plex-db-maintenance/plexdb-maint.sh plexdb-maint:/tmp/plexdb-maint.sh
kubectl -n media exec plexdb-maint -- sh /tmp/plexdb-maint.sh rebuild   # changes only a WAL checkpoint
kubectl -n media exec plexdb-maint -- sh /tmp/plexdb-maint.sh swap      # makes the rebuilt files live
```

Update the image digest in `helper-pod.yaml` to whatever Plex runs
(`kubectl -n media get deploy plex -o jsonpath='{..image}'`) so the SQLite build
matches.

`rebuild` stops with `FAIL` and leaves the live files alone if:

- `integrity_check` is not `ok` on the original database, or a `.dump` ends in
  `ROLLBACK` (unreadable pages). This script does maintenance, not salvage: a
  corrupt library goes to DBRepair;
- `integrity_check` is not `ok` on a rebuilt database;
- a row count is missing or non-numeric (a table renamed by a PMS update), or the
  counts of the main tables (`metadata_items`, `media_parts`,
  `metadata_item_settings`, `metadata_item_views`, …) or any blobs table differ
  after the import.

Only a run that passed all of these gets a `VERIFIED` marker, and `swap` requires
it. `swap` also refuses unless the live `.db` files are byte-identical to the copies
the rebuild read **and** both WALs are still empty (`rebuild` truncates them;
uncheckpointed writes live only in the WAL), so a Plex start in between cannot
lose writes. Originals stay in
`/config/dbmaint/<timestamp>/orig`; delete the directory once Plex has run cleanly
for a few days.

**Rollback** (with Plex stopped): copy `orig/*` back into the `Databases`
directory over the rebuilt files. Older fallbacks: Plex's own copies every 3 days
(`*.db-YYYY-MM-DD` next to the live files) and the kopiur `plex-local` /
`plex-r2` snapshots.

## Run log

### 2026-11-03 (UTC), first run

Plex down 01:44:35 → Ready 01:55:24 (**10 min 49 s**).

| Step | Time |
|---|---|
| Quiesce + scale 0 | 3 s |
| Volume detach, share-manager `stopping` → `stopped` | ~40 s |
| Volume + PV → rwo, delete claim, `Released`, clear `claimRef`, resume ks, `Bound` | ~1 min |
| `rebuild` (on the block device) | 311 s (checkpoint + integrity 118 s, copy 16 s, main 44 s, blobs 131 s) |
| `swap` | 15 s |
| Plex startup to Ready | ~60 s (3.5 min on NFS the same evening) |

Observed:

- **Resuming the ks cleared both kopiur `spec.suspend`s** (the component re-applies
  the SnapshotPolicies from git). Re-suspend them before step 4, as this run did.
- After a clean Plex shutdown there were no `-wal`/`-shm` files at all: the
  522 MB / 1.1 GB WALs were folded in on close, so they had been bloat, not
  unflushed data.
- Rebuilt main DB 505.6 → 490.2 MB; blobs 1,094.6 → 1,124.3 MB. Row counts
  identical (`metadata_items` 72,404, `metadata_item_settings` 11,925).
- After startup `/identity` answered in < 1 ms; 0 `Took too long`, 0 busy-database.
  `ERROR - Unknown metadata type:` lines at startup come from parsing *other*
  servers' `/media/providers` (shared libraries), not this database.
- Plex's `Logs/` is an `emptyDir` (helmrelease `persistence`), so the log
  restarts empty on every pod start; compare across a restart via VictoriaLogs.
