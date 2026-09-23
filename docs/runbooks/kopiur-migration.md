# Runbook: VolSync → kopiur backup migration

**Status (2026-09-23): foundation and repositories landed (#1870, #1879, #1880), both
ClusterRepositories `Ready`; next is step 4 (epoch) then W0.** This is the single source of truth for the migration; the
decisions below were made with Derek and are not open for re-litigation without new
evidence.

| piece | state |
| --- | --- |
| Pilots (`media/recyclarr-kopiur-pilot`, `media/jellyseerr-kopiur-pilot`) | passed 4/4 and 5/5 (see their READMEs); still running `H */6` against `pilot-local` |
| PR #1870 — component split + `components/kopiur` | **merged** 2026-09-22 (eab49e12); verified inert live: all Kustomizations Ready on it, all 93 ReplicationSources intact. No app includes `components/kopiur` yet |
| Two `ClusterRepository` + 18 `ExternalSecret` | **landed** 2026-09-22 (#1879, e4539596), plus the `kopiur-system` Pod Security fix (#1880). Both `Ready`, all 18 secrets synced; catalog scanned 2026-09-23. See "The repositories" |
| Fleet cutover (W0–W8) | not started |

## Why kopiur

VolSync's staging wait is **unbounded**. kopiur bounds both staging phases
(`spec.staging.timeout`, VolumeSnapshot `readyToUse` + staged-PVC bind) and fails
terminally with a named reason, so the next slot retries instead of the source wedging.

Evidence from one week (2026-09-13 → 09-22), four wedged VolSync `-local` sources,
three distinct fingerprints, two CSI drivers:

| source | wedged for | fingerprint |
| --- | --- | --- |
| `media/readarr-ebooks-local` | 8d | tns-csi VolumeSnapshot never `readyToUse`; no staged PVC, no mover |
| `productivity/n8n-local` | 7d | Longhorn **stale handle**: VolumeSnapshot `readyToUse: true` but its `snapshot.longhorn.io` is gone; staged PVC Pending, `ProvisioningFailed … not found` |
| `productivity/node-red-local` | 7d | same |
| `database/timescaledb-local` | 2h18m | Longhorn clone `state: failed`, `attemptCount: 9` (the fifth fingerprint in `volsync-mover-stuck.md`) |

On 2026-09-15 the **pilots hit the same Longhorn stall**, failed with `StagingTimedOut` in
10 minutes, and recovered on their own at the next slot. All four VolSync sources above
needed manual pause-based recovery (done 2026-09-22; real backups of 1m28s–2m12s afterwards).

## Decisions (locked)

| # | decision | why |
| --- | --- | --- |
| Q1 | **Adopt the existing repositories in place**, no re-seed | fleet is the perfectra1n fork using `spec.kopia`; kopiur adopts fork repos and history continues |
| Q2 | identity `<app>@<namespace>:/data`, **pinned explicitly** per policy | verified three ways (fork logs, translator, `kopia snapshot list`); `kubectl kopiur migrate volsync --resolve-secrets` reproduced it for all 44 translatable sources |
| Q3 | **keep the retention asymmetry** → 92 single-repo SnapshotPolicies, no fan-out | `repositories[]` has no per-repo retention. **Effective** retention, verified live 2026-09-22 and matched exactly in `components/kopiur`: local 12×/day, latest/hourly/daily/weekly/monthly/annual = 48/96/30/12/12/**3**; R2 1×/day, 10/6/7/4/3/3. The bold/inherited values are kopia *global defaults* the fork never wrote (see the trap below) |
| — | **one SnapshotSchedule per policy, never `policySelector`** | live CRD: jitter "derived from (scheduleUID, slot)" — per schedule, so a selector schedule fires every matched policy at one instant (the 00:00 herd that destroyed ZFS datasets) |
| — | `ClusterRepository` ×2 (`kopia-local`, `kopia-r2`), not namespaced `Repository` | 8 namespaces, 2 repos; per-namespace repos = many Maintenance CRs contending for one lease |
| — | `catalog.retain`: **`perIdentity: 50`, `maxAgeDays: 120`**, set before first scan | uncapped = 5,242 Snapshot CRs; this gives ~2,179, and the 16 dead identities age out with no kopia data deleted. **Accepted cost:** 171 CRs of *live* identities (weekly/monthly tail) lose their CR — still restorable, see "Restoring an aged-out snapshot". **Actual first scan (2026-09-23): 1,108, not ~2,179.** R2 is complete (608, all 46 live identities). `kopia-local` got 500: the mover's hard 1,000-entry listing cap cuts before `perIdentity` applies, so only the first 10 identities by username came through. See the traps |
| Q5 | `epoch.minDuration: 1h` on `kopia-local` only, **as its own change** | local repo carries ~4,500 index blobs vs 1,000 warn at ~97 writes/h; R2 needs nothing |
| — | credentials: 18 ESO-minted Secrets (9 ns × 2) from the **same OpenBao keys** as VolSync | movers read creds via namespace-local `envFrom`; keeps "secrets only via ESO"; KOPIA_PASSWORD must match (it is the encryption key) |
| — | mover runs **root by default** (`moverDefaults`), 8 apps override | preserves today's VolSync behaviour exactly; uid-matching is a later, deliberate improvement |
| — | **same-identity dual writing** during each app's parallel run (Derek, 2026-09-22) | the only way to verify kopiur on real history before VolSync is removed; blobs are immutable and content-addressed, retention rules identical, one maintenance owner. **Accepted cost:** kopia applies retention per identity across *all* its snapshots, whichever engine wrote them, so while both run, `keepLatest` covers roughly half as much time. The hourly, daily, weekly and monthly buckets keep one snapshot per period, so they lose nothing. **The mechanics are subtler than this, and two consequences are still open.** See "Two deleters on one identity" |
| — | **`catalog.adoption: Ignore`** on both ClusterRepositories, for the migration (Derek, 2026-09-22) | with the default `Adopt` + `Delete`, W0 would have kopiur deleting VolSync-written kopia data outside its window, and retention prunes bypass `deletionProtection`. `Ignore` means kopiur never deletes history it didn't write. **Rejected: `defaultDeletionPolicy: Retain`**: it covers *every* snapshot a policy owns, so kopiur's GFS would only ever delete CRs, and once the fork's retention is cleared nothing would delete kopia data at all. **Accepted cost:** the VolSync history present at cutover stays in the repository indefinitely (frozen, not growing), and a deleted-then-recreated policy's history is not re-attached to retention. **Revisit at decommission:** flip to `Adopt` so GFS ages out the materialized tail (≤50/identity, ≤120 d). The older tail needs a one-off decision either way |
| — | **Clear the fork's path-scope retention at each app's cutover** (Derek, 2026-09-22) | the fork's `kopia policy set /data --keep-…` overrides kopiur's identity-scope `i32::MAX` pin, so kopia would otherwise keep expiring snapshots behind kopiur's CRs indefinitely. Clear only the six `keep-*` fields, not the whole path policy. Live, the path policies hold *only* `keep-*` (compression is disabled globally), so today the two are equivalent. The narrow clear stays correct if a path policy ever carries anything else. Must come **after** VolSync stops writing the identity, because the fork re-applies it on every run (`do_retention`) |
| — | **PVC ownership stays in `components/volsync-claim`** for the whole migration | removing the claim = Flux prunes the PVC; a replacement claim can't drop `dataSourceRef` (SSA-owned by kustomize-controller + immutable on a bound PVC) |

## Control plane (resolved 2026-09-22)

This was the blocker: the catalog scan's CR burst against the OOM-unstable Pi control
plane (controller-manager 41–80 restarts). The control plane now runs on the `freyja01` VM
(`docs/runbooks/controlplane-migration-to-vault-vm.md`). Measured through the actual burst
(1,108 CRs in about 60 s): apiserver peak 1.76 cores / 3.1 GiB, then back to baseline, 0
control-plane restarts.

## The repositories (landed #1879)

Validated by server dry-run against 0.10.8, then re-validated against 0.10.9. The server
dry-run could not catch the one failure that happened at landing: Pod Security admission
of the discovery Jobs (see the traps). Landing took three steps:

1. **#1879** landed the manifests. Discovery pods were rejected by `kopiur-system`'s
   `restricted` enforcement, and nothing ran.
2. **#1880** set `kopiur-system` to enforce `baseline` (`restricted` kept as warn/audit).
   Discovery then succeeded within a minute and both repositories went `Ready`.
3. The **first catalog scan had already been consumed** by the failed attempts. Derek
   requested one by hand, and 1,108 CRs materialized.

The change adds `kubernetes/apps/kopiur-system/repositories/` (ks.yaml, 2× ClusterRepository,
18× ExternalSecret) and registers it in `kubernetes/apps/kopiur-system/kustomization.yaml`.
Key properties, all commented in the manifests:

- **no `create` block** (adoption; a mis-parse fails instead of initialising an empty repo)
- **`catalog.adoption: Ignore`** on both (decided 2026-09-22, see "Two deleters on one
  identity"). kopiur never deletes kopia data it did not write, and it survives server
  defaulting
- `maintenance.enabled: false` — the fork's `volsync-system/kopia-maintenance-{local,r2}`
  still own maintenance; flip in the same change that retires them
- **no `parameters.epoch`** — its own windowed change (rewrites the format blob; other kopia
  clients' caches go stale for ~15 min, and live VolSync movers are other clients)
- R2 endpoint is `${SECRET_CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com` — Flux
  substitutes it; **never** `kustomize build | kubectl apply` this directory
- local endpoint is the literal `10.0.10.11:30188` (bare host:port; scheme via
  `tls.disableTls`), the same endpoint VolSync uses
- the webhook is **fail-closed on repository references**: SnapshotPolicies are rejected
  until the ClusterRepositories exist, so every app's `ks.yaml` needs `dependsOn:
  kopiur-repositories` at cutover

## Sequence

1. ~~**CP migration complete.**~~ Done 2026-09-22 (the `freyja01` VM).
2. ~~**Merge PR #1870.**~~ Done 2026-09-22.
3. ~~**Land the repositories.**~~ Done 2026-09-22/23 (#1879, #1880, a requested scan).
   Verified: both `Ready`; `indexBlobCount` populated (local 490, R2 278); 1,108
   discovered CRs (local 500 capped, R2 608 complete), all `deletionPolicy: Retain`,
   placed in each identity's own namespace.
4. **Epoch change** on `kopia-local` (`epoch.minDuration: 1h`), applied into a gap between
   VolSync runs. `minDuration` must be ≥ 3× `refreshFrequency` (default 20m), so 1h is
   exactly the floor. "Removing a value does not restore kopia's default" — set it once.
5. **W0 → W8** below, one wave at a time.
6. **Decommission** after the whole fleet is green for ≥ 30 days (one daily-retention
   cycle): retire `components/volsync-backup`, the R2 slot grid and hour-03 reservation, the
   fork's `KopiaMaintenance` (and flip kopiur `maintenance.enabled: true` in the same
   change), then the VolSync operator. Then decide the post-migration claim shape (below).

## Per-app cutover

```diff
 # kubernetes/apps/<ns>/<app>/app/kustomization.yaml
 components:
   - ../../../../components/volsync-claim
-  - ../../../../components/volsync-backup
+  - ../../../../components/kopiur
```

```yaml
# kubernetes/apps/<ns>/<app>/ks.yaml
  dependsOn:
    - name: kopiur-repositories
      namespace: kopiur-system
  postBuild:
    substitute:
      KOPIUR_LOCAL_CRON: "H */2 * * *"     # from the table
      KOPIUR_R2_CRON: "H 1 * * *"          # from the table
      KOPIUR_COPYMETHOD: Snapshot          # = VOLSYNC_COPYMETHOD (default Direct)
      KOPIUR_SNAPSHOTCLASS: longhorn-snapclass   # = VOLSYNC_SNAPSHOTCLASS
      # only where the table says so:
      KOPIUR_RUN_AS_USER / KOPIUR_RUN_AS_GROUP / KOPIUR_FS_GROUP
      KOPIUR_CACHE_CAPACITY
```

**After the swap has applied and no VolSync mover for the app is running**, clear the
fork's path-scope retention on the identity, in **both** repositories (a live kopia action,
so Derek runs it):

```bash
# against kopia-local, then again against kopia-r2
kopia policy set '<app>@<ns>:/data' \
  --keep-latest=inherit --keep-hourly=inherit --keep-daily=inherit \
  --keep-weekly=inherit --keep-monthly=inherit --keep-annual=inherit
kopia policy show '<app>@<ns>:/data'   # the keep-* lines must read as inherited from <app>@<ns>
```

Doing this any earlier gets undone: the fork re-sets it on every VolSync run.

**Syntax and precedence verified locally** (filesystem repo, 2026-09-22), on kopia 0.23.1 and
again on **0.22.3, the exact build the fork and the client Pod run** (`154bf568`, release
tarball checksum-verified). Both give identical results. With
kopiur's identity-scope pin and the fork's path-scope values both set, `policy show` on the
path reads `48 (defined for this target)`, so the path overrides the pin as claimed. After
the `inherit` command, all six read `2147483647 inherited from <app>@<ns>`, and compression
stays `zstd (defined for this target)` (0.23.1 run).

**Client:** a short-lived Pod running the fork's own image (`ghcr.io/perfectra1n/volsync:
v0.17.11`, `kopia` at `/usr/local/bin`) with `envFrom` the app's
`<app>-volsync-{local,r2}-secret`, connecting the way the fork's `entry.sh` does. The
read-only version of that Pod is `.handoff/verify-kopia-policies.sh` (connects `--readonly`;
a write fails with `storage is read-only`, verified locally). The write version is the
same Pod without `--readonly` and with the command above.

**Do NOT delete these VolSync vars at cutover** — `components/volsync-claim` still reads
them: `VOLSYNC_CAPACITY`, `VOLSYNC_STORAGECLASS`, `VOLSYNC_ACCESSMODES`,
`VOLSYNC_RESTORE_SOURCE`. The rest (`VOLSYNC_*_SCHEDULE`, `…_COPYMETHOD`,
`…_SNAPSHOTCLASS`, `…_CLONE_STORAGECLASS`, `…_CACHE_*`, `…_RUN_AS_*`) become dead once the
app has cut over.

**Parallel run.** Cutting an app over *removes* its VolSync sources. "Parallel until
verified" therefore means: **add `components/kopiur` alongside `volsync-backup` first**,
verify, and only then remove `volsync-backup`. Both write the **same kopia identity**
concurrently during that window (immutable content-addressed blobs, identical retention
rules, one maintenance owner). Approved 2026-09-22. See the Decisions table for the
`keepLatest` cost. It is the first time anything but VolSync writes those identities.

### Two deleters on one identity (found 2026-09-22, read from source, not yet observed live)

The dual-write approval above assumed one retention engine. There are two:

- **The fork's kopia-native retention outlives VolSync.** The fork writes its retention
  as a **path-scope** kopia policy (`kopia policy set /data --keep-…`,
  `mover-kopia/entry.sh:2138` at v0.17.11). kopiur pins all six `--keep-*` to `i32::MAX`
  at the **identity** scope before its first create, to make its own CR-driven GFS the
  only deleter (`crates/mover/src/workspec/mod.rs:1641` at 0.10.9). But a path-scope value
  overrides the identity scope, and `kopia snapshot create` applies the source's
  retention after *every* create. So the fork's rules keep expiring snapshots on
  kopiur's runs too, during the parallel run **and after VolSync is gone**, and they
  evaluate over the whole identity (both engines' snapshots). Consequence: kopia can
  expire a snapshot that a kopiur `Snapshot` CR still points to. The CR shows
  `Succeeded`, and it fails only at restore. That is the exact failure kopiur's pin exists
  to prevent. The rules match kopiur's GFS, so no history is lost beyond what VolSync
  already expires. The problem is dangling CRs.
- **Adoption turns kopiur into a real deleter of VolSync-written history.**
  `catalog.adoption` defaults to `Adopt` and `defaultDeletionPolicy` to `Delete`. When this
  was found, neither the parked repositories patch nor `components/kopiur` overrode either
  one. **Resolved:** the patch now sets `adoption: Ignore` (see below). Left at the defaults,
  at W0 each new policy adopts its identity's materialized `discovered` rows (≤50, ≤120 d)
  and GFS **deletes kopia data** outside `spec.retention` on the next reconcile. Retention
  prunes bypass `deletionProtection` by design (kopiur `docs/repositories.md`). With
  identical rules this should find little that kopia hasn't already expired. "Should" is
  unverified, because the two GFS implementations were never compared bucket-for-bucket.

**Decided 2026-09-22** (see the Decisions table): `catalog.adoption: Ignore` on both
ClusterRepositories, and clear the fork's path-scope `--keep-*` at each app's cutover.

### Gates

**Per app** — all four, or the app does not advance:
1. a scheduled `Snapshot` reaches `Succeeded`
2. `status.stats` non-zero **and** `status.snapshot.kopiaSnapshotID` populated
3. `status.snapshot.identity` is exactly `<app>@<ns>:/data` (not `/pvc/<app>` — that
   would be a forked history)
4. the app's VolSync sources are still on schedule (while both run)

**Per wave** — the first app of each StorageClass in the wave gets a **real restore** into a
scratch PVC, compared against live (method: the pilot READMEs). Check for root-owned
content first; root movers preserve it, non-root movers silently re-own it.

### Rollback

Per app: swap `components/kopiur` back to `components/volsync-backup`. Instant and lossless
while VolSync history is untouched. Whole migration: revert the components and delete the
repositories Kustomization — adoption never wrote a `create` block, so the kopia
repositories themselves are unchanged.

## Waves and per-app settings

Waves go from cheapest-to-lose to hardest: W0 pilots → config volumes → live embedded DBs →
*arrs → databases + vaultwarden → large volumes → node-local class → tns-csi-nfs →
tns-csi-nvmeof. `games/valheim-syncthing` is **out of scope** (Syncthing, not kopia).

**W0** also retires the pilots: remove `jellyseerr-kopiur-pilot` first (it depends on
recyclarr's `pilot-local` Repository and ExternalSecret), then `recyclarr-kopiur-pilot`,
then the `kopiur-pilot` Garage bucket and OpenBao key `kopiur-pilot`.

| wave | app | VolSync local → kopiur local | VolSync R2 → kopiur R2 | copy | StorageClass | extra vars |
|---|---|---|---|---|---|---|
| W0 | media/jellyseerr | `10 */2 * * *` → `H */2 * * *` | `41 1 * * *` → `H 1 * * *` | Snapshot | longhorn-1-replica |  |
| W0 | media/recyclarr | `0 6 * * *` → `H 6 * * *` | `49 4 * * *` → `H 4 * * *` | Snapshot | longhorn-1-replica | **`NS: media`** ³ |
| W1 | download/autobrr | `5 */4 * * *` → `H */4 * * *` | `11 0 * * *` → `H 0 * * *` | Snapshot | longhorn-1-replica |  |
| W1 | download/cross-seed | `10 */4 * * *` → `H */4 * * *` | `49 0 * * *` → `H 0 * * *` | Snapshot | longhorn-1-replica | **`NS: download`** ³ |
| W1 | home/ev-charge-ledger | `43 */2 * * *` → `H */2 * * *` | `53 6 * * *` → `H 6 * * *` | Snapshot | longhorn-1-replica | **`NS: home`** ³ |
| W1 | home/ev-charge-tracker | `9 */2 * * *` → `H */2 * * *` | `37 6 * * *` → `H 6 * * *` | Snapshot | longhorn-1-replica |  |
| W1 | media/calibre-web | `15 */4 * * *` → `H */4 * * *` | `33 0 * * *` → `H 0 * * *` | Snapshot | longhorn-1-replica |  |
| W1 | media/notifiarr | `35 */4 * * *` → `H */4 * * *` | `49 2 * * *` → `H 2 * * *` ² | Snapshot | longhorn-1-replica |  |
| W1 | media/sportarr | `53 */4 * * *` → `H */4 * * *` | `57 5 * * *` → `H 5 * * *` | Snapshot | longhorn-1-replica | uid/gid/fsGroup 568 |
| W1 | media/tautulli | `20 */4 * * *` → `H */4 * * *` | `27 5 * * *` → `H 5 * * *` | Snapshot | longhorn-1-replica |  |
| W2 | home/mosquitto | `50 * * * *` → `H * * * *` | `19 2 * * *` → `H 2 * * *` ² | Snapshot | longhorn-1-replica | cache 10Gi |
| W2 | media/calibre | `30 * * * *` → `H * * * *` | `27 0 * * *` → `H 0 * * *` | Snapshot | longhorn-1-replica |  |
| W2 | media/maintainerr | `38 */4 * * *` → `H */4 * * *` | `21 6 * * *` → `H 6 * * *` | Snapshot | longhorn-1-replica | uid/gid/fsGroup 1000 |
| W2 | productivity/grocy | `15 */2 * * *` → `H */2 * * *` | `11 1 * * *` → `H 1 * * *` | Direct | longhorn-1-replica |  |
| W2 | productivity/homebox | `20 */2 * * *` → `H */2 * * *` | `19 1 * * *` → `H 1 * * *` | Snapshot | longhorn-1-replica |  |
| W2 | productivity/karakeep | `25 */2 * * *` → `H */2 * * *` | `49 1 * * *` → `H 1 * * *` | Snapshot | longhorn-1-replica |  |
| W2 | productivity/mealie | `10,40 * * * *` → `25,55 * * * *` ¹ | `11 2 * * *` → `H 2 * * *` ² | Snapshot | longhorn-1-replica |  |
| W2 | productivity/n8n | `6,36 * * * *` → `21,51 * * * *` ¹ | `27 2 * * *` → `H 2 * * *` ² | Snapshot | longhorn-1-replica |  |
| W2 | productivity/nextcloud | `4,34 * * * *` → `19,49 * * * *` ¹ | `33 2 * * *` → `H 2 * * *` ² | Snapshot | longhorn-1-replica |  |
| W2 | productivity/node-red | `8,38 * * * *` → `23,53 * * * *` ¹ | `41 2 * * *` → `H 2 * * *` ² | Snapshot | longhorn-1-replica | uid/gid/fsGroup 1000 |
| W2 | productivity/obsidian | `12,42 * * * *` → `27,57 * * * *` ¹ | `57 2 * * *` → `H 2 * * *` ² | Direct | longhorn-1-replica |  |
| W3 | download/qbittorrent | `0 */2 * * *` → `H */2 * * *` | `19 4 * * *` → `H 4 * * *` | Snapshot | longhorn-1-replica |  |
| W3 | download/sabnzbd | `0 */4 * * *` → `H */4 * * *` | `57 4 * * *` → `H 4 * * *` | Snapshot | longhorn-1-replica |  |
| W3 | media/audiobookshelf | `40 * * * *` → `H * * * *` | `3 0 * * *` → `H 0 * * *` | Snapshot | longhorn-1-replica |  |
| W3 | media/bazarr | `5 */2 * * *` → `H */2 * * *` | `19 0 * * *` → `H 0 * * *` | Snapshot | longhorn-1-replica |  |
| W3 | media/kometa | `25 */4 * * *` → `H */4 * * *` | `57 1 * * *` → `H 1 * * *` | Snapshot | longhorn-1-replica |  |
| W3 | media/lidarr | `10 * * * *` → `H * * * *` | `3 2 * * *` → `H 2 * * *` ² | Snapshot | longhorn-1-replica |  |
| W3 | media/prowlarr | `15 * * * *` → `H * * * *` | `11 4 * * *` → `H 4 * * *` | Snapshot | longhorn-1-replica |  |
| W3 | media/radarr | `5 * * * *` → `H * * * *` | `27 4 * * *` → `H 4 * * *` | Snapshot | longhorn-1-replica |  |
| W3 | media/sonarr | `0 * * * *` → `H * * * *` | `19 5 * * *` → `H 5 * * *` | Snapshot | longhorn-1-replica |  |
| W3 | media/tracearr | `24,54 * * * *` → `39,9 * * * *` ¹ | `17 2 * * *` → `H 2 * * *` ² | Snapshot | longhorn-1-replica | uid/gid/fsGroup 1001 |
| W4 | database/couchdb | `14,44 * * * *` → `29,59 * * * *` ¹ | `41 0 * * *` → `H 0 * * *` | Direct | longhorn-1-replica |  |
| W4 | database/influxdb | `16,46 * * * *` → `31,1 * * * *` ¹ | `27 1 * * *` → `H 1 * * *` | Direct | longhorn-1-replica | uid/gid/fsGroup 1000 |
| W4 | database/timescaledb | `22,52 * * * *` → `37,7 * * * *` ¹ | `13 6 * * *` → `H 6 * * *` | Snapshot | longhorn-1-replica | uid/gid/fsGroup 1000 |
| W4 | identity/vaultwarden | `2,32 * * * *` → `17,47 * * * *` ¹ | `49 5 * * *` → `H 5 * * *` | Direct | longhorn-1-replica |  |
| W5 | media/jellyfin | `35 * * * *` → `H * * * *` | `33 1 * * *` → `H 1 * * *` | Snapshot | longhorn-1-replica |  |
| W5 | media/plex | `20,50 * * * *` → `35,5 * * * *` ¹ | `3 4 * * *` → `H 4 * * *` | Snapshot | longhorn-1-replica | cache 30Gi, **`NS: media`** ³ |
| W6 | develop/hermes | `23 * * * *` → `H * * * *` | `29 6 * * *` → `H 6 * * *` | Snapshot | longhorn-1-replica-local | **staging.storageClassName: longhorn-1-replica patch** |
| W6 | home/scrypted | `45 * * * *` → `H * * * *` | `11 5 * * *` → `H 5 * * *` | Snapshot | longhorn-1-replica-local | cache 10Gi |
| W7 | develop/gitea | `18,48 * * * *` → `33,3 * * * *` ¹ | `3 1 * * *` → `H 1 * * *` | Direct | tns-csi-nfs |  |
| W7 | home/frigate | `45 * * * *` → `H * * * *` | `57 0 * * *` → `H 0 * * *` | Snapshot | tns-csi-nfs |  |
| W7 | media/readarr-audiobooks | `20 * * * *` → `H * * * *` | `33 4 * * *` → `H 4 * * *` | Snapshot | tns-csi-nfs |  |
| W7 | media/readarr-ebooks | `25 * * * *` → `H * * * *` | `41 4 * * *` → `H 4 * * *` | Snapshot | tns-csi-nfs |  |
| W7 | media/tdarr | `30 */4 * * *` → `H */4 * * *` | `33 5 * * *` → `H 5 * * *` | Snapshot | tns-csi-nfs |  |
| W8 | games/satisfactory | `55 * * * *` → `H * * * *` | `3 5 * * *` → `H 5 * * *` | Direct | tns-csi-nvmeof | uid/gid/fsGroup 1000 |
| W8 | games/valheim | `58 * * * *` → `H * * * *` | `41 5 * * *` → `H 5 * * *` | Direct | tns-csi-nvmeof | uid/gid/fsGroup 1000 |

¹ **Twice-hourly apps.** kopiur has no stepped `H`. `substitute_h` (`crates/api/src/jitter.rs`
at 0.10.9) rewrites only a field that is *exactly* `H`, and `H/30` is passed through to
croner unexpanded. So these keep explicit minutes, shifted +15 from VolSync's so the two engines
don't snapshot the same volume in the same minute during the parallel run. Check
`status.nextSchedule.at` after applying.
² **R2 in hour 02.** `jitter: 20m` is a forward window, so an `H` near :59 can spill into
**hour 03, which stays reserved** while the fork's `kopia-maint-r2` runs at `0 3 * * *`
against the same repository. Read `status.nextSchedule.at` after applying and move any that
land past 02:40.
³ **Add `NS: <namespace>`** to `postBuild.substitute`. See the `NS` trap below.

## Traps found so far (each one produced a plausible wrong answer)

- **VolSync's retention manifest is not its effective retention.** The fork writes only
  the buckets a ReplicationSource sets to a path-scope kopia policy, and everything else
  falls through to kopia's **global defaults**. `policy show` on 2026-09-22: local
  `Annual 3 inherited from (global)`; R2 `Latest 10` and `Annual 3 inherited from
  (global)`. Translating the manifests 1:1 would have silently dropped all three once the
  path-scope clear hands retention to kopiur. `components/kopiur` now states them. Compare
  against `kopia policy show`, never against `retain:`.
- **Four apps set no `NS`** (`recyclarr`, `cross-seed`, `ev-charge-ledger`, `plex`). VolSync
  never needed it, because the fork takes the hostname from the namespace implicitly.
  `components/kopiur` pins `hostname: "${NS}"`, and unset it becomes `""`. The webhook
  **admits** that: the empty field drops out and kopiur falls back to its default hostname
  (the namespace). So the identity comes out right by accident, not through the explicit
  pin the design relies on. Add `NS` to the `ks.yaml` in the app's own wave (table ³).
- **Never put a `${…}` token in a `ks.yaml` comment.** `cluster-apps` runs postBuild
  substitution over the `ks.yaml` files themselves.
- **`sourcePathOverride: /data` is load-bearing.** kopiur's default is `/pvc/<name>`;
  omitting it silently creates a new identity — no error, a forked history.
- **`policySelector` does not spread** (per-schedule jitter). One schedule per policy.
- **The translator's reason string is wrong**: `UNMAPPABLE spec.kopia.storageClassName: … no
  per-policy staging-class override` — `SnapshotPolicy.spec.staging.storageClassName`
  exists in 0.10.8. Only `develop/hermes` is affected (see table). Worth an upstream issue.
- **The translator aborts a whole namespace** on one non-kopia source:
  `games/valheim-syncthing` makes `migrate volsync -n games` emit nothing, so
  `satisfactory` and `valheim` never translate. Second upstream issue.
- **40 of 46 apps inherit `externalsecret-refresh`** from the backup component rather than
  listing it; `components/kopiur` nests it for that reason. Keep it nested.
- **ClusterRepository Jobs run in `kopiur-system`, not the app's namespace.** Discovery
  and bootstrap inherit `moverDefaults` (root, to match VolSync), and kopiur has no
  per-Job override except for maintenance. Under `enforce: restricted` every discovery
  pod was rejected at admission. The namespace now enforces `baseline` (#1880). Dropping
  root `moverDefaults` would have made every Restore default to non-root instead.
- **kopiur reports the admission rejection as a timeout**: `BootstrapDeadlineExceeded:
  ... killed by its activeDeadlineSeconds (240s) before kopia connected`. The pods never
  existed. Read `kubectl -n kopiur-system get events` (look for `FailedCreate`) before
  trusting that reason. Upstream issue drafted.
- **A failed first bootstrap consumes the one-shot initial catalog scan.** The first scan
  runs only while `metadata.generation != status.observedGeneration`, and the failed
  attempts had already set `observedGeneration`. With `periodicRefresh` off, nothing
  retries it. Symptom: `Ready`, `storageStats.snapshotCount` populated,
  `status.catalog: null`. Fix: `kubectl annotate clusterrepository <name>
  kopiur.home-operations.com/catalog-scan-requested-at="$(date -u +%FT%TZ)" --overwrite`.
  Upstream issue drafted.
- **The catalog can't cover a repository with more than 1,000 snapshots.** The mover
  truncates kopia's raw listing to `MAX_RETURNED_SNAPSHOTS = 1000` before `catalog.retain`
  applies, and kopia lists grouped by source. `kopia-local` (5,276 snapshots)
  materialized 50 rows for each of `audiobookshelf` through `frigate` and **none for the
  other 36 apps**. `perIdentity` cannot fix this, because lowering it only shrinks the
  identities that already got through. The missing history stays restorable via
  `Restore.spec.source.identity`, the gates don't use the catalog, and `adoption: Ignore`
  means nothing prunes against it. Upstream issue drafted.
- **Catalog stats lag by design**: the 30-min probe refreshes `indexBlobCount` only;
  `snapshotCount`/`totalSizeBytes` freeze until a full bootstrap (`catalog.periodicRefresh`
  is off by default).
- **The mover can't `chown` to root when non-root** — a restore silently re-owns root-owned
  files. Root movers (the default here) avoid it.
- **`$schema` host**: `k8s-schemas.home-operations.com`, not `kubernetes-schemas.pages.dev`,
  which answers 200 with HTML for groups it doesn't host.
- **Client-side OpenAPI fetch times out** when the apiserver is struggling; use
  `kubectl apply --dry-run=server --validate=false` (server-side validation still runs).

## Restoring an aged-out snapshot

A Snapshot CR is a lifecycle handle, not the data path. For snapshots older than the
catalog keeps (`maxAgeDays: 120` / `perIdentity: 50`), a `Restore` can name the raw
identity: `spec.source.identity` (`username`, `hostname`, `sourcePath` plus one of
`asOf` / `offset` / `snapshotID`), which requires `spec.repository`. The CRD describes this
case as "aged-out catalog" explicitly.

## After the migration: the claim

Every migrated PVC keeps a `dataSourceRef` to `ReplicationDestination/<app>-dst-local`,
which disappears with `volsync-backup`. That is **inert on a bound PVC** — but if a PVC is
ever deleted and recreated, it will sit Pending forever. Plan: a `components/kopiur-claim`
whose `dataSourceRef` targets a kopiur `Restore` in populator mode
(`Restore.spec.target.populator`), used by newly created PVCs; existing PVCs move onto it
only when they are next recreated.

## Open items

- [x] Derek's OK on same-identity dual writing (2026-09-22; see Decisions)
- [x] `docs/runbooks/volsync-mover-stuck.md`: (a) **pause alone performs the whole
      teardown** — mover, staged PVC *and* VolumeSnapshot; the manual delete steps are
      unnecessary, and no orphaned VolumeSnapshotContent was left in four recoveries;
      (b) add a **sixth fingerprint**, the Longhorn stale handle (above) — the fifth
      fingerprint's `cloneStatus` check returns nothing because no Longhorn volume was ever
      created; (c) after recovery, trust `lastSyncDuration`, not `lastSyncTime` or the
      cleared alert: 180h/210h are wedge spans, ~1m30s is a real backup
- [ ] Upstream issues. Drafts for Derek's review are in `.handoff/upstream-issue-*.md`:
      (1) translator reason string; (2) translator per-namespace abort; (3) catalog listing
      cap cuts before `perIdentity` (`upstream-issue-catalog-cap.md`); (4) admission
      rejection reported as a deadline (`upstream-issue-admission-as-deadline.md`);
      (5) a failed first bootstrap consumes the initial scan
      (`upstream-issue-initial-scan-consumed.md`)
- [x] **Two deleters on one identity**: decided 2026-09-22 (adoption `Ignore`, clear
      path-scope retention at cutover). `catalog.adoption: Ignore` is in the parked patch
- [x] Path-scope clear: `inherit` syntax and path-over-identity precedence verified locally
      (see per-app cutover)
- [x] Live policy check (`.handoff/verify-kopia-policies.sh`, read-only, 2026-09-22, both
      repos, fork kopia 0.22.3). Path `jellyseerr@media:/data` has `keep-*` "defined for this
      target", and the identity `jellyseerr@media` defines nothing (everything inherited from
      global). **Found:** the inherited annual (both legs) and latest (R2) buckets, now added
      to `components/kopiur`. `policy list` shows exactly one path policy per live app. The
      extras are dead identities (`atuin@default`, `immich@media`, `karakeep@karakeep`,
      `mosquitto@infrastructure`, and in R2 `root@volsync-src-couchdb-r2-xhlmx`). Their policies
      are inert because retention only runs when something snapshots them, so they need no
      clear
- [x] W0 prepared as patches in `.handoff/` (git-excluded), each checked to apply cleanly on
      main, individually and stacked: `kopiur-w0-cutover.patch` (jellyseerr + recyclarr get
      `components/kopiur` alongside `volsync-backup`, plus `dependsOn: kopiur-repositories`,
      the `KOPIUR_*` vars, and `NS: media` for recyclarr; the render is byte-identical to main
      outside the 4 new kopiur objects, and identities render as `<app>@media:/data`) and
      `kopiur-w0-retire-pilots.patch` (removes both pilots together. All 24 pilot Snapshots
      carry `onScheduleDelete: Retain` and no `onPolicyDelete`, so the prune deletes only
      CRs, never kopia data. The pilot bucket and OpenBao key are dropped by hand
      afterwards). Order: repositories → W0 cutover → gates pass → retire pilots
- [ ] At decommission: flip `catalog.adoption` to `Adopt`? and decide on the pre-120 d
      VolSync tail
- [x] The cluster runs kopiur **0.10.9**. The repositories patch (2 ClusterRepositories with
      `adoption: Ignore`, 18 ExternalSecrets) re-passed server dry-run against it on
      2026-09-22. The translator results above are still from 0.10.8
- [ ] hermes: app-level patch setting `staging.storageClassName: longhorn-1-replica`
