# recyclarr kopiur pilot

A **parallel, non-replacing** trial of [kopiur](https://github.com/home-operations/kopiur)
against one small PVC. VolSync keeps backing `recyclarr` up exactly as before; nothing in
`kubernetes/apps/media/recyclarr/` is touched by this directory.

Background and the decision this is meant to inform:
`~/.buzz/PLANS/KOPIUR_EVALUATION_AND_PILOT.md`.

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

1. The `SnapshotSchedule` fires and its `Snapshot` reaches `Succeeded`.
2. `status.stats` shows non-zero `filesNew`/`bytesNew`, and `status.snapshot.kopiaSnapshotID`
   is populated — an empty backup reports zeros and would otherwise look like success.
3. **A real restore** into a scratch PVC produces byte-identical content. A backup that has
   never been restored is a hypothesis.
4. VolSync's own `recyclarr-local` and `recyclarr-r2` are unaffected throughout.

Worth watching, though not pass/fail: what minute `H */6 * * *` actually resolves to —
`status.nextSchedule.at` on the `SnapshotSchedule`. That number is the entire argument for
dropping the grid.

## Rollback

Delete this directory and its line from `kubernetes/apps/media/kustomization.yaml`, and the
`kopiur-system` tree if the operator is going too. Nothing here is shared with VolSync: a
separate operator, a separate bucket, a separate repository password, and no edit to any
existing manifest. The Garage bucket can then be dropped whole.

## Notes for whoever picks this up

- **The CRDs are the sharp edge.** Helm installs the chart's `crds/` directory once and
  never touches it on upgrade. The HelmRelease sets `crds: CreateReplace` on both install
  and upgrade for that reason. Upstream documents the failure mode as *silent*: an apiserver
  on an old schema **prunes** unknown fields, the object admits cleanly, and the feature you
  configured simply never happens. If a field here looks ignored, check the live CRD first.
- **`readOnly` must stay absent** from the SnapshotPolicy. See the comment there.
- **Maintenance is pinned off hour 03** — kopiur's default is full at `0 3 * * *`, which is
  the hour this repo reserves.
- The chart tag is pinned and should stay pinned: `v1alpha1`, and 0.10.5 → 0.10.7 shipped
  five days apart.
