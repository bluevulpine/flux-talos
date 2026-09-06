# jellyseerr kopiur pilot — second workload

The [recyclarr pilot](../recyclarr-kopiur-pilot/README.md) passed all four of its
success criteria (see that README for the verdicts). This is the promotion: a second
workload, chosen to test what the first one deliberately could not.

**VolSync still backs jellyseerr up exactly as before.** Nothing in
`kubernetes/apps/media/jellyseerr/` is touched, and `jellyseerr-local` /
`jellyseerr-r2` keep their own schedules. This is parallel, not a replacement.

## What this adds over the recyclarr pilot

| | recyclarr | jellyseerr |
|---|---|---|
| source PVC | 1 Gi, **84 MB**, 2,651 files | 4 Gi, **566 MB**, 9,904 entries |
| workload | CronJob — PVC unattached most of the day | **Deployment — attached and writing continuously** |
| payload | flat config + logs | **live SQLite in WAL mode** (`db.sqlite3` + `-wal` + `-shm`) |
| repository | bootstrapped `pilot-local` | **second source in the same repository** |

Three things follow from that, and they are the point:

1. **Snapshotting an attached, actively-written volume.** recyclarr's volume was
   idle at snapshot time, so the staged VolumeSnapshot was taken with no writer.
   This one always has one.
2. **A live SQLite database in WAL mode.** A filesystem snapshot must capture the
   database, its `-wal` and its `-shm` coherently or the restore is a torn database.
   This is the risk VolSync already carries here and never verifies; it is the
   reason the success criterion below is an integrity check rather than a byte
   comparison. **Byte-identity is not available for a live writer** — the source
   changes between snapshot and comparison, so equality would be a coincidence and
   inequality would prove nothing.
3. **Two sources in one kopia repository.** Shared blobs, shared maintenance,
   separate identities, and a repository-level fan-out cap that has never had more
   than one source to cap.

## Why jellyseerr and not something else

Everything above wants a continuously-attached workload with a live database, small
enough to restore-verify cheaply and cheap to lose. jellyseerr is a request frontend
whose state is rebuildable from Jellyfin and the *arrs, so the blast radius is close
to zero while the failure modes are the real ones.

Explicitly **not** chosen:

- **The `*arr`s** (`sonarr`, `radarr`, …) — their databases are in CloudNativePG, not
  on the PVC. `sonarr`'s 451 MB `/config` is MediaCover images and logs, with no
  `.db` file at all. It would have tested size and nothing else.
- **`vaultwarden`** — the right shape, the wrong volume to put in a pilot bucket
  whose Garage key is still a copy of the shared VolSync credential.
- **Anything on `tns-csi-nfs` / `tns-csi-nvmeof`** — that is the *other* open
  question (does bounded staging convert the `volsync-mover-stuck.md` wedge into a
  clean terminal failure?) and it deserves its own change, not a confounder inside
  this one. kopiur does not fix the `CreateVolume` bug; `copyMethod: Snapshot` takes
  the same CSI path into the same driver.

## Success criteria

1. The `SnapshotSchedule` fires and its `Snapshot` reaches `Succeeded` against a
   volume that has a live writer on it.
2. `status.stats` shows non-zero `filesNew` and `sizeBytes`, and
   `status.snapshot.kopiaSnapshotID` is populated.
3. **`H` puts this schedule on a different minute from `recyclarr-pilot`.** Same cron
   string, two schedules — compare `status.nextSchedule.at` on both. This is the
   grid argument at N=2.
4. **A restore into a scratch PVC yields a database that opens and passes
   `PRAGMA integrity_check`** (expected output: the single word `ok`), with the
   `-wal` recovered rather than discarded.
5. VolSync's `jellyseerr-local` and `jellyseerr-r2` are unaffected throughout, and
   the recyclarr pilot's own snapshots keep succeeding once it is sharing the
   repository.

## Notes

- **`$schema` points at `k8s-schemas.home-operations.com`**, not the
  `kubernetes-schemas.pages.dev` host used elsewhere in this repo. That host does not
  carry the `kopiur.home-operations.com` group and answers **200 with an HTML page**
  rather than 404, so a status-code-only check "passes" on a schema that isn't there.
- **The mover runs 568:568**, matching the app. Checked before relying on it: exactly
  one entry under `/app/config` is root-owned — the PVC mount root, which a restore
  target recreates anyway — and the other 9,903 are `568`. A non-root mover cannot
  `chown` to root, so root-owned *content* would silently come back owned by the
  mover uid. Verify that before pointing this at a third workload.
- **No new secret and no new bucket.** This reuses `pilot-local` and the
  `recyclarr-kopiur-pilot-secret` ExternalSecret, which is why `ks.yaml` depends on
  `recyclarr-kopiur-pilot` rather than on OpenBao.

## Rollback

Delete this directory and its line from `kubernetes/apps/media/kustomization.yaml`.
Nothing else is affected — the repository, the bucket and the recyclarr pilot all
outlive it, and jellyseerr's own manifests were never touched.
