# Smoke test: hermes `develop` → `ai` move mechanics (2026-09-23)

Follow-up to `hermes-ns-move.md`. Throwaway namespaces `smoke-src` / `smoke-dst` (label `smoke-test=hermes-ns-move`),
Longhorn `longhorn-1-replica-local`, VolSync kopia mover (`ghcr.io/perfectra1n/volsync:v0.17.11`, kopia v0.22.3) against the
**local Garage repo**, kopia username `smoketest` (`smoketest-perm` for one extra test). Manifests are hand-rendered under
`docs/investigations/smoke/` (no Flux, no kustomize|apply). The repo Secret was copied by pipe only
(`kubectl get secret … | jq '{apiVersion,kind,type,data,metadata:{name,namespace,labels}}' | kubectl apply -f -`); no secret value was printed or written.
Nothing in `develop` was modified; hermes objects were never touched (the only `develop` read was `get secret hermes-volsync-local-secret` for the copy).
Mirrors `components/volsync-backup/local.yaml`: Snapshot copy, `longhorn-snapclass`, RWO, mover root (uid/gid/fsGroup 0), cache on `longhorn-1-replica`.
Deviations: 1Gi volume / 2Gi cache, `retain: {latest: 2}`, manual triggers.

## Results at a glance

| | Question | Answer |
| --- | --- | --- |
| a | Identity of a backup from `smoke-src` | `smoketest@smoke-src:/data` ✅ |
| b | Restore in another ns **without** `sourceNamespace` | **Silent empty volume.** RD `Successful`, PVC `Bound`, no error, `lost+found` only ⚠️ |
| c | Restore **with** `sourceNamespace: smoke-src` | ✅ sha256 of marker + 1 MiB blob matches |
| d | Forward backup from `smoke-dst` | New identity `smoketest@smoke-dst:/data`; **both series coexist and both restore** ✅ |
| e | Approach B (Retain PV, rebind via `volumeName`) | ✅ Rebinds; **a `dataSourceRef` on a pre-bound PVC is ignored**, data intact (even pointing at an empty RD image) |
| — | PVC delete with PV `Retain` vs `Delete` | Retain: PV `Released`, Longhorn volume kept. Delete: PV **and** Longhorn volume gone within seconds |
| — | `privileged-movers` annotation needed? | **No for backup/restore to work**, but it changes file **ownership** on restore (see below) |

## (a) Source backup and identity

```
$ kubectl apply -f 01-src.yaml            # PVC + writer Job + ReplicationSource (manual: run-1)
writer log:
0ab29c96630fce715de834f7090a5d336e4797bfb47564e5a7b1046d449df1d6  marker.txt
174454d225c0da908ce47293a40b20a4d989399d95e81a2892c3bc0307d20ca0  blob.bin
```

**Side finding, run-1:** the ReplicationSource fired the instant it was created and the mover logged
`=== Checking directory for content === / == Directory is empty skipping backup ===` with
`OPERATION_RESULT: FAILURE, EXIT_CODE: 0` — yet `latestMoverStatus.result: Successful` and `lastManualSync: run-1`.
(The snapshot was taken before the writer finished.) An empty source produces **no snapshot and a green status**. This is the same
class of "green with no backup" as `docs/runbooks/volsync-mover-stuck.md:275-290`.

run-2 (after data existed):

```
$ kubectl -n smoke-src patch replicationsource.volsync.backube smoke-local --type merge -p '{"spec":{"trigger":{"manual":"run-2"}}}'
INFO: Creating snapshot for smoketest@smoke-src:/data
Snapshotting smoketest@smoke-src:/data ...
 * 0 hashing, 3 hashed (1 MB), 0 cached (0 B), uploaded 196 B, estimating...
Created snapshot with root k11681aee37fa1a67d96961d0acc0d038 and ID d5aa5b00cc368db2ce10fea5e9065025 in 0s
Setting policy for smoketest@smoke-src:/data
```

Confirms: username = `spec.kopia.username`, hostname = **namespace** (unset in the manifest), path = `/data`.

## (b) Restore into `smoke-dst` WITHOUT `sourceNamespace` — the key unknown

`02-dst-b-no-sourcens.yaml`: RD with `sourceIdentity: {sourceName: smoketest}` + PVC `dataSourceRef` → RD (exactly the shape of `local.yaml:80-83` + `claim.yaml:10-13`). `smoke-dst` is unannotated, PSA `baseline` (mirrors `ai`).

```
RD .status.kopia.requestedIdentity : smoketest@smoke-dst          # <- not smoke-src
RD .status.latestMoverStatus.result: Successful
RD .status.latestImage             : VolumeSnapshot volsync-smoke-dst-local-dest-20260923174352 (readyToUse true)
PVC smokedata-b                    : Bound (after a consumer Pod appeared; WaitForFirstConsumer)
$ ls -la /data           →  lost+found only
$ cat /data/SHA256SUMS   →  No such file or directory
```

**Answer: it does not fail. It produces an empty, healthy-looking volume**, the RD reports `Successful` and the PVC binds. In the
hermes move this would boot a fresh agent (no `auth.json`, no sessions, no memory) with no error anywhere. The old series would be untouched but stranded.
(Not visible in status: the mover's log tail lists other apps' snapshots and says nothing about "no snapshots for identity".)

## (c) WITH `sourceNamespace`

`04-dst-c-with-sourcens.yaml`: `sourceIdentity: {sourceName: smoketest, sourceNamespace: smoke-src}` (smoke-dst still unannotated).

```
requestedIdentity: smoketest@smoke-src      result: Successful
$ sha256sum -c SHA256SUMS
marker.txt: OK
blob.bin: OK
0ab29c96…df1d6  marker.txt      174454d2…20ca0  blob.bin       # identical to (a)
```

✅ Existing snapshots are found with the override. This is the exact override needed for `hermes@develop`
(`sourceIdentity.sourceNamespace: develop`, `sourceName: hermes`).

## (d) Forward direction

`06-dst-source.yaml`: RS in `smoke-dst` on the restored PVC, same `username: smoketest`.

```
INFO: Creating snapshot for smoketest@smoke-dst:/data
Created snapshot with root k11681aee37fa1a67d96961d0acc0d038 …   # same root hash as (a): content deduped against the old series
Setting policy for smoketest@smoke-dst:/data
```

Then `07-dst-d-newseries.yaml` (RD, **no** `sourceNamespace`, in `smoke-dst`): `requestedIdentity: smoketest@smoke-dst`, sha256 -c → `marker.txt: OK / blob.bin: OK`.
So `smoketest@smoke-src` (restorable via (c)) and `smoketest@smoke-dst` (restorable via this) **coexist in the repository**; the move forks the series, does not break the old one.
Consequence for the hermes plan: once the first backup runs in `ai`, a `sourceNamespace`-less RD works again, but the override is needed **until then**, and the RD must not fire before that first backup.

## (e) Approach B: retain the PV and rebind

```
$ kubectl patch pv pvc-129735b6-… -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
$ kubectl -n smoke-src delete replicationsource.volsync.backube smoke-local ; kubectl -n smoke-src delete pvc smokedata
after delete:  PV phase=Released, reclaim=Retain, claimRef still smoke-src/smokedata;  Longhorn volume state=detached (kept)
$ kubectl patch pv pvc-129735b6-… --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'   →  phase Available
$ kubectl apply -f 08-approachB-rebind.yaml     # PVC smoke-dst/smokedata-e: volumeName=<pv>, storageClassName same,
                                                #   dataSourceRef → RD smoke-dst-local  (whose latestImage is the EMPTY snapshot from (b))
PVC smokedata-e: Bound to pvc-129735b6… in ~20s;  PV claimRef → smoke-dst/smokedata-e
events for smokedata-e: none (no VolSyncPopulator* events, no vs-prime PVC created)
$ sha256sum -c SHA256SUMS   →  marker.txt: OK   blob.bin: OK
```

✅ **The populator ignores a PVC that is pre-bound with `volumeName`.** It did not clobber the data even though the referenced RD
holds an empty image (worst case). The unmodified `volsync-claim` component's PVC (`claim.yaml`) can therefore be used with a
`volumeName` patch. The PV's `storageClassName` must equal the PVC's. Also observed: `dataSourceRef` is echoed back on the PVC unchanged.

Gotcha seen: `kubectl delete pvc` sat in `Terminating` (pvc-protection) while a **Completed** Job pod still referenced the PVC
(`describe` listed "Used By: writer-…"); it cleared after deleting the Job. For hermes the Deployment's pod must be gone first.

## PVC delete: Retain vs Delete (the Flux-prune scenario)

Flux prune = deleting the PVC object, nothing more.

| PV reclaim | After `kubectl delete pvc` | Longhorn volume |
| --- | --- | --- |
| `Retain` (set by hand, above) | PV `Released`, claimRef retained | kept (`detached`) — recoverable via (e) |
| `Delete` (default of `longhorn-1-replica-local`, and hermes' PV) | PV `pvc-91bd7c35-…` **NotFound** within seconds | `volumes.longhorn.io` **NotFound** — data gone |

So: **before removing the `develop` `hermes` Kustomization, set the hermes PV to `Retain`** (or suspend the Kustomization first).
This was tested on scratch PVs only.

## `privileged-movers` annotation (the `ai` namespace question)

Mover pod spec captured with the RS running in `smoke-dst`:

| ns annotation | mover container securityContext |
| --- | --- |
| none (like `ai`) | `runAsUser 0, allowPrivilegeEscalation false, capabilities drop [ALL], readOnlyRootFilesystem true` |
| `privileged-movers=true` | same **plus `capabilities.add: [DAC_OVERRIDE, CHOWN, FOWNER]`**, `runAsUser 0` |

- **PSA `baseline` admits the unannotated root mover**: backup (`smoke-dst` RS, run-1/run-2) and restore ran fine there. `ai` needs no annotation for movers to *run*.
- **Ownership on restore differs** (`10-perm-test.yaml`: files `chown 10000:10000`, mode 600/700, backed up as `smoketest-perm@smoke-dst`):
  - both variants **read** the owner-only files and restored content correctly (`perm-marker`, `top`);
  - **unannotated ns:** restored as `root:root` (`-rw-rw---- root root auth.json`);
  - **annotated ns:** restored as `10000:root` (`-rw-rw---- 10000 root auth.json`).
  Hermes' image entrypoint chowns `/opt/data` to 10000 on start (`helmrelease.yaml:51-52`, `fsGroup: 10000` + `OnRootMismatch`), so
  this should self-heal, but a restore into unannotated `ai` will not preserve uid 10000 by itself. Modes also show group-write/setgid drift vs. the source.
  Simplest match to today's behaviour is copying `volsync.backube/privileged-movers: "true"` to `ai/namespace.yaml` (as `develop`, `home`, `database` … have it; ~~`media`, `productivity`, `games` don't~~ — **CORRECTION 2026-09-24: they do**; all 8 namespaces with a ReplicationSource carry it, so `ai` would be the only exception. Decided: add it, see runbook §6.5).
- The populator PVC (`smokedata-g`) restore from RD-g got stuck ~7 min: `ProvisioningFailed … failed to verify data source: snapshot.longhorn.io "snapshot-…" not found`
  (Longhorn snapshot-handle failure — the same family as `volsync-mover-stuck.md`'s Longhorn note). Ownership evidence above was read from the RD's own
  destination PVC (`volsync-…-g-dest`) instead. Not reproduced elsewhere: (c), (d2) and the annotated variant provisioned normally. Retry/re-trigger would be the remedy.

## What this changes in the plan (`hermes-ns-move.md`)

1. (3) is **resolved and worse than feared**: the missing `sourceNamespace` does not error — it silently yields an empty volume. It is mandatory on the `ai` RD (`sourceNamespace: develop`), and must be verified by content (`auth.json`, `sessions/`) before the agent starts.
2. Approach B (rebind) works with the stock claim manifest; the populator will not touch it. It keeps the bytes; approach A restores from the ≤1h-old snapshot.
3. Set the PV to `Retain` first in either approach; deletion with `Delete` is immediate and total.
4. Forking the series is safe: both series coexist. The old `hermes@develop` snapshots are the rollback.
5. Give `ai` the `privileged-movers` annotation if uid preservation matters.

## Residue and cleanup

- Kopia snapshots `smoketest@smoke-src:/data`, `smoketest@smoke-dst:/data`, `smoketest-perm@smoke-dst:/data` **remain in the shared local repository** (a few KB each, mostly deduped): nothing here can delete kopia snapshots, and doing it would need a kopia client. They are distinct identities; retention policies apply only to those paths. The real `hermes@develop` series was not touched.
- Namespaces, the Retained PV and its Longhorn volume are deleted — see the confirmation at the end of this file.

## Cleanup confirmation (2026-09-23 ~18:20Z)

```
$ kubectl delete ns -l smoke-test=hermes-ns-move      → smoke-dst, smoke-src deleted;  kubectl get ns | grep smoke → none
$ kubectl delete pv pvc-129735b6-…  (the Retained one) → deleted;  kubectl -n longhorn-system delete volumes.longhorn.io pvc-129735b6-… → deleted
$ kubectl get pv / volumes.longhorn.io / volumesnapshotcontent filtered on smoke-* namespaces → nothing
$ kubectl get pv pvc-129735b6-…  → NotFound;  kubectl -n longhorn-system get volumes.longhorn.io pvc-129735b6-… → NotFound
```

Real hermes (`develop/hermes` PVC, `hermes-local` RS) checked afterwards: unchanged and still syncing. Manifests under `docs/investigations/smoke/` are kept (uncommitted).
