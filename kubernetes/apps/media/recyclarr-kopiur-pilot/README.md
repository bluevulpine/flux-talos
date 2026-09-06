# recyclarr kopiur pilot

A **parallel, non-replacing** trial of [kopiur](https://github.com/home-operations/kopiur)
against one small PVC. VolSync keeps backing `recyclarr` up exactly as before; nothing in
`kubernetes/apps/media/recyclarr/` is touched by this directory.

The longer evaluation this came out of lives **outside this repository**, in the operator's
working notes, and is not fetchable from a clone. Everything needed to run, judge, or revert
the pilot is in this file deliberately — treat that document as provenance, not as a
dependency.

## Why this exists

Two questions, both driver-independent, neither answerable from documentation:

1. **Does `H` scheduling remove the slot grid?** `components/volsync/r2.yaml` maintains a
   hand-assigned 8-minute grid across hours 00,01,02,04,05 with hour 03 reserved. It is 40
   slots and holds 43 sources — three had to be wedged between grid points, and PR #1736
   had to clean up 11 exact collisions the grid never modelled, because it spaces R2
   sources from *each other* and never accounted for local movers.
2. **Does bounded staging convert a silent wedge into a failed backup?** VolSync's staging
   wait is unbounded: `docs/runbooks/volsync-mover-stuck.md` records kubelet retrying an
   identical doomed mount `x849 over 28h`. kopiur puts `spec.staging.timeout` (10m default)
   on both the VolumeSnapshot `readyToUse` wait and the staged-PVC bind, failing terminally
   with a named reason.

**What this pilot deliberately does NOT test:** whether kopiur fixes the tns-csi
`CreateVolume` bug. It does not — `copyMethod: Snapshot` takes the same CSI path into the
same driver. `recyclarr` was chosen *because* it is on `longhorn-1-replica`, so the broken
driver is not a confounder.

## Why `recyclarr`

1 Gi, `longhorn-1-replica`, RWO, config-only and git-managed — the cheapest volume in the
cluster to lose and the cheapest to restore-verify.

## Prerequisites — this will not reconcile until both are done

**1. A dedicated Garage bucket.** kopiur does not create buckets.

```
bucket: kopiur-pilot           endpoint: 10.0.10.11:30188   (plain HTTP, LAN)
```

It must be a **new bucket, not a prefix inside `kopia`**. kopiur does support sharing one
bucket via a key prefix, but the existing repository sits at the *root* of `kopia`
(`KOPIA_REPOSITORY = s3://kopia` on both the local and R2 secrets), so a prefixed second
repo would land inside the keyspace of a live repository whose own maintenance enumerates
blobs. Give the access key access to `kopiur-pilot` only — `s3:DeleteObject` included, or
snapshots succeed and maintenance fails later.

**2. An OpenBao entry at key `kopiur-pilot`** with these three fields:

| field | what |
|---|---|
| `Kopiur__Pilot__AwsAccessKeyId` | Garage key ID, scoped to `kopiur-pilot` |
| `Kopiur__Pilot__AwsSecretKey` | its secret |
| `Kopiur__Pilot__KopiaPassword` | a new long random value — **not** the existing repo password |

> Losing `KOPIA_PASSWORD` loses the repository; kopia cannot decrypt without it and there is
> no recovery. It does not matter much for a pilot, but the habit does.

## Success criteria — all four, or the answer is no

**All four passed, verified 2026-09-06 after two days of scheduled runs.**

1. The `SnapshotSchedule` fires and its `Snapshot` reaches `Succeeded`.
   → **Pass.** 7 retained snapshots, 7 `Succeeded`, `consecutiveFailures: 0`, operator
   pods at 0 restarts.
2. `status.stats` shows non-zero `filesNew`/`bytesNew`, and `status.snapshot.kopiaSnapshotID`
   is populated — an empty backup reports zeros and would otherwise look like success.
   → **Pass.** 2,651 files / 84,262,929 bytes, `kopiaSnapshotID` populated on every one.
   Note `filesNew` reports the file count *in* the snapshot, not files newly uploaded: the
   whole bucket holds **88.1 MB across 7 snapshots** of an 84.3 MB source, so content is
   stored once and deduped. Do not read that field as a cost signal.
3. **A real restore** into a scratch PVC produces byte-identical content. A backup that has
   never been restored is a hypothesis.
   → **Pass.** Restored into a scratch PVC and compared against the live volume with both
   mounted read-only in one pod: 2,651 files, sha256 manifests identical
   (`7cf3c73dca4b703b…` on both sides), `diff -r` reports no differences.
   **Two fidelity gaps worth carrying forward**, from a full mode/uid/gid/size/mtime
   comparison of all 3,154 entries — 36 differ:
   - 35 **directory** mtimes are not preserved (they take the newest child's). All 2,651
     file mtimes are.
   - 1 **ownership** change: a `uid 0` file returns as `uid 568`. The mover runs non-root
     and cannot `chown` to root, so **any root-owned content restores owned by the mover
     uid**. Check for root-owned content before pointing kopiur at a new volume.
4. VolSync's own `recyclarr-local` and `recyclarr-r2` are unaffected throughout.
   → **Pass.** Both still on their own schedules; across the whole `media` namespace, zero
   ReplicationSources have a null `lastSyncTime`.

Worth watching, though not pass/fail: what minute `H */6 * * *` actually resolves to —
`status.nextSchedule.at` on the `SnapshotSchedule`. That number is the entire argument for
dropping the grid.
→ Fired at 12:37, 18:25, 00:33, 06:22, 12:28 and 18:23 UTC — hours {0,6,12,18} with the
20m jitter spreading the minute. It picked its own slot and never needed the grid. The
real test of that is two schedules sharing one cron string, which is what
[`jellyseerr-kopiur-pilot`](../jellyseerr-kopiur-pilot/README.md) adds.

## Rollback

Delete this directory and its line from `kubernetes/apps/media/kustomization.yaml`, and the
`kopiur-system` tree if the operator is going too. Nothing here is shared with VolSync: a
separate operator, a separate bucket, a separate repository password, and no edit to any
existing manifest. The Garage bucket can then be dropped whole.

**One ordering constraint, added when the pilot was promoted.** This directory now owns the
`Repository` and the `ExternalSecret` that
[`jellyseerr-kopiur-pilot`](../jellyseerr-kopiur-pilot/README.md) depends on. Removing this
one alone would prune the repository out from under it. Remove `jellyseerr-kopiur-pilot`
first, or remove both together.

## Notes for whoever picks this up

- **The CRDs are the sharp edge, and this repo already handles it — do not re-add it here.**
  Helm installs the chart's `crds/` directory once and never touches it on upgrade. The
  `cluster-apps` Kustomization patch in `kubernetes/flux/cluster/ks.yaml` injects
  `crds: CreateReplace` into *every* HelmRelease cluster-wide, which is why this chart's
  HelmRelease sets nothing (CLAUDE.md: "do not add it to individual HelmRelease manifests").
  It matters more for this chart than most: upstream documents the failure mode as *silent* —
  an apiserver on an old schema **prunes** unknown fields, the object admits cleanly,
  `kubectl get -o yaml` shows no trace, and the feature you configured never happens. If a
  field here looks ignored, check the live CRD before anything else.
- **Field names were validated against `deploy/crds/` at the pinned tag**, not against the
  upstream docs examples, for exactly that reason. Worth repeating if you add fields.
- **The `$schema` lines point at `k8s-schemas.home-operations.com`**, not the
  `kubernetes-schemas.pages.dev` host used everywhere else — that host does not carry the
  `kopiur.home-operations.com` group, and answers **200 with an HTML page** rather than 404,
  so a status-code-only check silently "passes" on a schema that isn't there.
- **`readOnly` must stay absent** from the SnapshotPolicy. See the comment there.
- **Maintenance is pinned off hour 03** — kopiur's default is full at `0 3 * * *`, which is
  the hour this repo reserves.
- The chart tag is pinned and should stay pinned: `v1alpha1`, and 0.10.5 → 0.10.7 shipped
  five days apart.
