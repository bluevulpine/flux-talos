# kopiur: one kopia repository per app (plan)

**Status: plan, nothing moved.** Written 2026-10-23T06:00Z (+00:00) from measurements taken
the same night. Supersedes nothing; it is the "new repository" step that
`kopiur-migration.md` leaves for after the VolSync decommission, reshaped into a split.
Companion changes already landed: #2256 (yardstick cache), #2260 (hourly maintenance,
`epoch.checkpointFrequency: 48`, `metadataCacheSizeMb: 2048`).

## Why: the shared repository's index is an append-only log

`kopia-local` (Garage, bucket `kopia`, bucket root) serves 50 local SnapshotPolicies at
1,135 runs a day. Measured 2026-10-23 from a read-only connect (kopia v0.22.3):

| fact | value |
| --- | --- |
| index blobs / bytes | 1,028 / 722 MB; 61 range checkpoints (`xr…`) carry 707 MB |
| live contents | 1.81 M (383 GB), 16.5 k tombstones in the merged view |
| index entries | ~20.6 M at 35 B each (5,597,850 B ÷ 159,711 entries in `xr306_313`), ~11× the live set |
| growth | ~10 MB/day of new range-checkpoint bytes (`xr482_489` = 13.9 MB for 32 h) |
| cold connect | 12 s, 693 MiB downloaded, per mover, per empty cache |
| per-cache cost | 1.4 GiB live index duplicate in each of the 49 Persistent cache PVCs |

The bytes never shrink because kopia's epoch manager writes range checkpoints as
**disjoint** spans and never re-merges them: `getRangeToCompact` starts at the previous
range's `MaxEpoch + 1` (v0.22.3 and master), `kopia index optimize` under the epoch manager
only advances the deletion watermark, and tombstones are dropped at read time, not on disk.
kopia's own design (kopia/kopia#1090, "Append-only index management") specified a periodic
cumulative `w` "state of the world" checkpoint that supersedes everything before it. That
part did not ship. The pre-epoch index manager (v0) rewrote the whole index and dropped
deleted entries, so this is a regression against the design, not a tuning problem. No kopia
issue names it yet (searched 2026-10-23); one should be filed.

What #2260 bought: the blob **count** stays under the 1,000 warning (hourly epochs instead of
4 h; 48-epoch checkpoints so hourly epochs do not triple the permanent blob count), and the
cache PVCs stop filling to kopia's 5,000 MiB budgets. It did nothing for the bytes, which
reach 1.5 GiB in roughly three months and then force the budget up again.

## What a split does and does not do

A per-app repository does not stop the growth. It partitions it, and partitioning is what
removes the costs actually paid:

- each mover connects to an index that holds only its own app's entries; plex's index lives
  only in plex's cache. The 49 copies of one 700 MB index become 49 small ones
- no app's write rate can push another app over the warning, and one slow maintenance stalls
  nothing else
- a reset becomes local: when one app's index bloats, recreate that app's repository and
  re-copy that app, not 380 GB
- precedent: Velero's kopia integration creates one repository per namespace per storage
  location for exactly these reasons

It does not change the write rate. The twelve half-hourly apps produce 576 of the 1,135
daily runs and most of the index growth; that is a retention decision, separate from this.

**Per app, not per namespace.** media holds 22 of the 50 policies including the three
heaviest writers (plex 25.7 GB logical, jellyfin 15.7 GB, tdarr), so a per-namespace split
would leave the hard case intact. kopiur makes repositories cheap enough that per app is the
simpler shape.

## Cross-app dedup: measured, 4 %, concentrated in media

Method (2026-10-23, read-only pod, `/tmp/walk.py` in the session scratchpad): for each of the
51 sources with a snapshot in the last 3 days, `kopia ls -l -r <root>` of the latest
snapshot, indirect objects (`I…`) resolved through `kopia show <content>` to their chunk
lists, then one content-ID → owners map across all sources. Bytes are the chunk lengths.

| measure | value |
| --- | --- |
| sum of per-source unique bytes (what per-app repos would store for the latest snapshots) | 80.19 GB |
| union across all sources (what the shared repo stores for them) | 76.84 GB |
| saving from cross-app dedup | **3.36 GB (4.2 %)**, 7,901 contents |
| jellyfin ↔ plex | 1,114 MB |
| kometa ↔ plex | 946 MB |
| jellyfin ↔ radarr | 917 MB |
| lidarr ↔ plex | 156 MB |
| gitea ↔ hermes | 101 MB |
| everything else combined | < 100 MB |

Against the repository's 383 GB of stored content the cross-app saving is under 1 %. The
shared pairs are artwork and metadata the media apps each keep a copy of. Conclusion: the
shared repository is not buying dedup worth keeping.

Side finding: the 51 latest snapshots total 77 GB unique but the repository holds 383 GB,
so ~80 % of stored bytes is retained history (48 latest + 96 hourly + 30 daily + 12 weekly +
12 monthly + 3 annual per source, at up to 48 snapshots a day). Not this plan's problem, but
it is the number to look at if Garage space matters.

## Target shape

Per app, in the app's own namespace, from a new component
`kubernetes/components/kopiur-perapp/` (local.yaml, r2.yaml) that an app's `ks.yaml` selects
instead of `components/kopiur`. The existing component keeps working for apps not yet moved,
which gives the same wave-by-wave cutover `kopiur-migration.md` used.

```yaml
apiVersion: kopiur.home-operations.com/v1alpha1
kind: Repository # namespaced; consumers must be in this namespace, which they are
metadata:
  name: "${APP}-local"
spec:
  backend:
    s3:
      bucket: kopia-apps            # NEW bucket, not a prefix under the old repo (see teardown)
      prefix: "${NS}/${APP}/"       # trailing slash required
      endpoint: 10.0.10.11:30188
      region: us-east-1
      tls: { disableTls: true }
      auth:
        secretRef: { name: kopiur-local-secret }  # already present in every app namespace
  encryption:
    passwordSecretRef: { name: kopiur-local-secret, key: KOPIA_PASSWORD }
  create:
    enabled: true
    # Match the shared repository so migrated history dedups against new writes:
    encryption: AES256-GCM-HMAC-SHA256
    splitter: DYNAMIC-4M-BUZHASH
    hash: BLAKE2B-256-128
    # no ecc: the shared repo has none; decide once, it is immutable per repository
  # maintenance: default (quick every 6 h, full daily, 30 m jitter). A 48-runs/day app
  # writes ~190 index blobs a day, so a 6 h quick pass compacts ~50 at a time; no need for
  # the hourly cadence or the epoch tuning the shared repository needed.
  moverDefaults:
    securityContext: { runAsUser: 0, runAsGroup: 0 }
    podSecurityContext: { fsGroup: 0, fsGroupChangePolicy: OnRootMismatch }
    cache:
      metadataCacheSizeMb: 1024   # per-app index is tens of MB; 1 GiB bounds metadata + index-blobs
  scheduleDefaults: { jitter: 20m }
```

The `SnapshotPolicy` and `SnapshotSchedule` are the existing component's, with
`repository: { kind: Repository, name: "${APP}-local" }` and the same identity
(`username: ${APP}`, `hostname: ${NS}`, `sourcePathOverride: /data`), so migrated history and
new snapshots share one kopia source. Keep `mover.cache.mode: Persistent` for the hourly and
half-hourly apps; for the 4-hourly ones and for every r2 policy `Ephemeral` without
`capacity` (an `emptyDir`) is now reasonable, because a per-app cold connect is a few MB, not
700. Cache `capacity` can drop from 16Gi to 4Gi either way.

R2 mirrors the shape: `${APP}-r2` with bucket `kopia-apps` on R2 and the same prefix.

## History: kopiur cannot filter a migrate seed, so history moves by hand

`Repository.spec.seed` migrate mode runs `kopia snapshot migrate` from another repository CR,
but its fields are `latestOnly`, `parallel`, `policies`, `throttle` only. There is no source
filter, so seeding `plex-local` from `kopia-local` would copy all 50 apps' history into
plex's repository. Two choices:

- **(A) Fresh start.** New repositories begin empty. The shared `ClusterRepository` flips to
  `mode: ReadOnly` and stays for restores by identity (`Restore.spec.source.identity`) until
  the retention tail Derek cares about has aged out (the annual bucket is 3 years). Costs
  380 GB of Garage until then, and restores older than the cutover come from the old repo.
- **(B) Migrate per app, recommended.** After kopiur creates and reports `${APP}-local`
  `Ready`, run a one-off Job (the kopia image, both repositories' Secrets, read-only connect to
  the source) with
  `kopia snapshot migrate --source-config /tmp/src.config --sources ${APP}@${NS}:/data --all --no-policies --parallel 1`,
  then flip the policy. Identity and times are preserved, so the new repository starts
  complete and the old one can go when every app is moved. The copy is each app's unique
  bytes across its history (plex is the largest) and runs on the LAN. kopiur's own seed
  then no-ops (`AlreadyInitialized`), which is the documented behaviour.
- Upstream: ask kopiur for `seed.migrate.sources` so (B) becomes declarative. Until then the
  Job is a per-app step in the cutover.

Either way `catalog.adoption` stays default (`Adopt`) on the new repositories: nothing in
them was written by anything but kopiur and the migrate, and the "two deleters" hazard was
about VolSync-written history in a repository kopiur also prunes.

## Per-app cutover

Same gate discipline as `kopiur-migration.md` ("Per-app cutover", "Gates"), one app at a
time, heaviest writers last:

1. `ks.yaml` switches the component to `kopiur-perapp`; Flux creates `${APP}-local` and
   `${APP}-r2`; wait for `Ready` (`Bootstrapped`) on both.
2. (B only) run the migrate Job for local, then r2; check `kopia snapshot list` in the new
   repository shows the identity's full history.
3. The policy ref flips in the same component, so the next scheduled run writes to the new
   repository. Confirm one `Snapshot` `Succeeded` per repository and that it is incremental
   (cached files > 0 in the mover log), which proves the migrated history dedups.
4. Restore gate: `docs/runbooks/kopiur-restore-verify/` kit against the new repository.
5. `IndexBlobHealth=True` on the new repositories; cache PVC usage for the app a few hundred
   MB. The app's old identity in `kopia-local` is left alone; it ages out with the shared
   repository.

Waves: the twelve half-hourly apps first (they gain most and are small), media last, plex
alone.

## Replication and maintenance fan-out

- **pinas.** `RepositoryReplication` is per repository (`kopia repository sync-to`), so the
  one `kopia-local-to-pinas` becomes one per app, templated in the component with the
  destination prefix equal to the source prefix in pinas's `kopia-apps` bucket. 50 nightly
  jobs instead of 1, each small. The alternative, mirroring the bucket outside kopia (Garage
  to Garage), is one job but is no longer a kopia-verified copy; keep the per-repository
  form.
- **Maintenance.** kopiur manages one `Maintenance` per repository: 50 local × (4 quick +
  1 full) + 50 r2 × (4 quick + 1 full) ≈ 500 short Jobs a day. Each is seconds on a
  repository this size. If the pod churn matters, `spec.maintenance.schedule` on the
  component can stretch quick to 12 h for the 4-hourly apps.
- **R2 ops.** Per-app full maintenance lists each small prefix; well under a dollar a month
  at R2's class-A/B rates.

## Teardown of the shared repositories

Use a **new bucket** (`kopia-apps`) rather than a prefix under `kopia`: the old repository
lives at the bucket root, so deleting it later would mean deleting root keys around a live
prefix tree. With a separate bucket the end state is: all apps moved and gated → both
`ClusterRepository` CRs to `mode: ReadOnly` for whatever tail window is wanted → delete the
CRs, the `kopia-local-to-pinas` replication, the 18 ClusterRepository ExternalSecrets that
are no longer referenced, then the `kopia` bucket on Garage, pinas and R2. Nothing in the
new tree is touched.

## Prerequisites and Derek's steps

- **VolSync decommission first** (`kopiur-migration.md`, Open items, step 6). It removes the
  fork's `KopiaMaintenance` objects, so maintenance ownership of the shared repository is
  kopiur's before any of this starts and there is nothing to replicate per app.
- Garage: create bucket `kopia-apps` on vault and on pinas and allow the existing kopia keys
  on it (the keys in `kopiur-local-secret` / `kopiur-pinas-secret`); R2: create `kopia-apps`
  and grant the existing token. NAS and Cloudflare steps are Derek's.
- kopiur ≥ 0.10.16 (current) has everything used here: namespaced `Repository` with
  `create`, `prefix`, per-repository `Maintenance`, `RepositoryReplication`, `seed`.
- Decisions to take before the first app: (A) vs (B); ECC on create; whether the
  half-hourly retention stays as is.

## Open questions

- Does `kopia snapshot migrate` of one source into a fresh repository reproduce the shared
  repository's dedup for that app's history? Expected yes (same splitter and hash), verify on
  the first app by comparing `kopia content stats` before and after the first live snapshot.
- Whether to keep the r2 tier per app at all, or make the pinas mirror the second copy and
  R2 the third only for the identity/database tier. Out of scope here, but the split is the
  moment to decide, since it is 50 more R2 repositories otherwise.
