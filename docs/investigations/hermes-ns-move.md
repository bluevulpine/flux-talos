# Investigation: moving hermes `develop` → `ai` without data loss

Read-only. Repo state: branch `hermes-to-ai` @ `4c46e4e6`. Cluster: context `admin@home-kubernetes`,
`kubectl get/describe` only, queried 2026-09-23. **Verified** = seen in a manifest or live object.
**Inferred** = reasoning, not observed; labelled where it matters.

## TL;DR

1. Data is **one Longhorn PVC** (`hermes`, 20Gi, `longhorn-1-replica-local`, PV reclaim **Delete**). Not NFS/tns-csi.
2. Backup is **VolSync + kopia** (`components/volsync-backup`), *not* kopiur yet (hermes is planned wave W6).
   Kopia identity is **`hermes@develop:/data`** — the **namespace IS part of the identity** (hostname).
3. A restore in `ai` will **not** find the old snapshots as written. The shared component's
   ReplicationDestination sets only `sourceIdentity.sourceName`, so it looks for `hermes@ai`. It needs
   `sourceIdentity.sourceNamespace: develop`.
4. **The data-loss trap:** the PVC is in the `hermes` Flux Kustomization inventory, `prune: true`, PV reclaim `Delete`.
   Removing the Kustomization deletes the PVC, then the PV, then the Longhorn volume.
5. If hermes is on kopiur by the time it moves, `ai` is missing from both `ClusterRepository.allowedNamespaces` and
   has no per-namespace `kopiur-*` ExternalSecrets.

## (1) Volumes / PVCs

| Object | Where | Detail |
| --- | --- | --- |
| PVC `develop/hermes` | `kubernetes/components/volsync-claim/claim.yaml:3-17` (name `${APP}`) | 20Gi RWO, live SC `longhorn-1-replica-local` (WaitForFirstConsumer, `dataLocality: best-effort`, 1 replica), PV `pvc-12f54114-9e99-442b-bae4-53a9cb239d69`, Longhorn volume attached/healthy on brokkr03 |
| Mounted at | `helmrelease.yaml:124-128` `persistence.data.existingClaim: *app` → `/opt/data` (= `HERMES_HOME`, `:40`) | **The only durable state.** |
| `/tmp` | `helmrelease.yaml:132-135` | emptyDir, disposable |
| VolSync-created extras | live: `volsync-hermes-dst-local-dest` (20Gi), 3 cache PVCs (`volsync-src-hermes-local-cache`, `-r2-cache`, `volsync-dst-hermes-dst-local-cache`) | scratch, not app data. `volsync-hermes-dst-local-dest` is the restore target of the 2026-09-05 restore; VolumeSnapshot `volsync-hermes-dst-local-dest-20260905051844` exists |

Storage class values come from `ks.yaml:42-48`. There is no NFS/tns-csi involvement for hermes; the
tns-csi bug in `docs/runbooks/volsync-mover-stuck.md` is not on this path (Longhorn CSI variant is,
see `:150-160`).

The live PVC carries `spec.dataSourceRef` → `ReplicationDestination/hermes-dst-local` (populator, immutable once bound).

## (2) Backup and snapshot identity

**Engine:** VolSync (kopia mover), via `develop/hermes/app/kustomization.yaml:10-12`
(`components/volsync-claim` + `components/volsync-backup`). Live: `ReplicationSource/hermes-local`
(hourly `23 * * * *`, last sync 2026-09-23T17:24Z OK), `hermes-r2` (`29 6 * * *`, OK),
`ReplicationDestination/hermes-dst-local` (`trigger.manual: restore-once`, last run 2026-09-05). No kopiur
`SnapshotPolicy` exists for hermes (`kubectl get snapshotpolicy -A` shows only media/jellyseerr, media/recyclarr).

**Identity derivation (Verified three ways):**

- `components/volsync-backup/local.yaml:45` and `r2.yaml:67`: `username: "${APP:=temp}"` → `hermes`.
  Comment at `:43-44` says "app@namespace" but the manifest sets only the *username*.
- Hostname is **not set** anywhere in the component. Live CRD
  (`replicationsources.volsync.backube`, `.spec.kopia.hostname`): *"If not specified, defaults to the namespace name."*
  Live `hermes-local` has `hostname: null`, `sourcePathOverride: null`.
- Path is the mover's `/data` mount.
- Mover log (live `status.latestMoverStatus.logs`): `Setting policy for hermes@develop:/data`.
- kopiur's catalog independently discovered 11 hermes snapshots in namespace `develop` with
  `identity: {username: hermes, hostname: develop, sourcePath: /data}`.
- `kopiur/local.yaml:14-23` records the same finding: "The fork wrote every snapshot as `<app>@<namespace>:/data`".

So: **app name → username; namespace → hostname; both feed the identity.** `NS: develop`
in `ks.yaml:26` does **not** feed the VolSync identity (VolSync never reads it). It feeds the *kopiur* component only
(`kopiur/local.yaml:23` `hostname: "${NS}"`).

Both repos (local Garage S3 `10.0.10.11:30188`, R2) share the same `hermes@develop:/data` series.
Snapshots live outside the cluster, so **deleting the develop objects does not delete them**.

## (3) Will a restore under `ai` find the existing snapshots?

**No, not as configured.**

- `components/volsync-backup/local.yaml:80-83` RD: `sourceIdentity.sourceName: hermes` and nothing else. Live CRD:
  `sourceNamespace` *"defaults to the namespace of this ReplicationDestination"*. In `ai` this requests
  `hermes@ai`. Live RD status shows this mechanism: `requestedIdentity: hermes@develop`.
- The PVC's `dataSourceRef` (`claim.yaml:10-13`) will make the populator run that RD when the new PVC is created.

**Needed:** an RD patch/override setting `spec.kopia.sourceIdentity.sourceNamespace: develop`. The shared component
does not template it, so it needs a kustomize patch in `develop→ai/hermes/app/kustomization.yaml` (or a new
`${VOLSYNC_SOURCE_NS}` substitution in the component, which touches all ~46 apps).
The R2 restore variant (`components/volsync-r2-restore`, not read in detail) will need the same.

**Unverified — test before relying on it:** what the VolSync kopia restore does when the requested identity has *no*
snapshots (fail vs. empty volume). If it yields an empty bound PVC, hermes boots as a fresh install and the next
backup starts a new `hermes@ai` series, with the real data stranded under `hermes@develop`. Nothing would error.

**Forward direction after the move (VolSync path):** the ReplicationSources in `ai` write `hermes@ai:/data`,
a **new identity**. Old `hermes@develop` snapshots stay but get no further retention applied
(**inferred**: VolSync applies retention when its own identity snapshots; nothing else touches the old one).
They must be aged out by hand later. Pin `hostname: develop` on the sources to keep one series — not exposed by the component
(would need a patch); trade-off is a permanently stale name.

**If moved *after* the kopiur cutover:** `kopiur/local.yaml:22-23` pins `username: ${APP}`, `hostname: ${NS}`,
`sourcePathOverride: /data` (`:30`). Changing `NS` to `ai` forks the history (same trap as
`docs/runbooks/kopiur-migration.md:310-320`); keeping `NS: develop` in a `targetNamespace: ai` Kustomization keeps it,
but `NS` is also used elsewhere — check before decoupling. Adoption/`catalog` behaviour: `catalog.adoption: Ignore` on
both ClusterRepositories.

## (4) References to `develop` for hermes

Inside `kubernetes/apps/develop/hermes/` (moves with the directory):

| File:line | Reference | Action |
| --- | --- | --- |
| `ks.yaml:15` | `path: ./kubernetes/apps/develop/hermes/app` | → `apps/ai/...` |
| `ks.yaml:21` | `targetNamespace: develop` | → `ai` |
| `ks.yaml:26` | `NS: develop` | → `ai` (see (3) for kopiur implication) |
| `httproute.yaml:9` | gatus `group: develop` | → `ai` (hindsight/litellm use `AI`-group homepage; gatus group in their routes not read — check `hindsight/app/httproute.yaml:66-67`) |
| `httproute.yaml:12` | homepage group `"Development"` | probably → `"AI"` (`hindsight:71`, `litellm:35`) |
| `README.md` | `kubectl -n develop exec -it deploy/hermes -- hermes setup` | update ns |
| `ks.yaml:34` | comment "06:13 → 06:21 → 06:29" grid | comment only |

Outside:

| File:line | Reference | Action |
| --- | --- | --- |
| `kubernetes/apps/develop/kustomization.yaml:13` | `./hermes/ks.yaml` | remove |
| `kubernetes/apps/ai/kustomization.yaml:10-11` | resource list | add `./hermes/ks.yaml` |
| `kubernetes/apps/ai/namespace.yaml:9-21,50-52` | already `baseline`; comment says hermes will move here | already satisfies hermes' caps (CHOWN/DAC_OVERRIDE/SETGID/SETUID); comment can be updated |
| `kubernetes/apps/ai/hindsight/app/helmrelease.yaml:167` | comment "separate pod in `develop`" | update comment |
| `kubernetes/components/kopiur/{local,r2}.yaml:60` | comment "`develop/hermes` is the one exception" | update comment |
| `docs/runbooks/kopiur-migration.md:281,324` | W6 row `develop/hermes` | update |
| `docs/runbooks/volsync-mover-stuck.md:158,281` | historical `develop/hermes-local` | leave (history) |
| `kubernetes/apps/home/ev-charge-tracker/ks.yaml:60` | comment "develop/hermes-r2" | comment only |
| `kubernetes/apps/kopiur-system/repositories/app/clusterrepository-local.yaml:47-55`, `-r2.yaml:31-39` | `allowedNamespaces.list` lacks `ai` | **add `ai`** if hermes goes to kopiur (live: 8 namespaces each) |
| `kubernetes/apps/kopiur-system/repositories/app/externalsecrets.yaml` (per-ns pairs, e.g. `:116,:138` for develop) | no `ai` pair | **add `kopiur-local`/`kopiur-r2` in `ai`** if kopiur (**inferred** need; each other ns has one) |
| `kubernetes/apps/identity/authentik/app/referencegrant.yaml:33-43` | ReferenceGrant for SecurityPolicy incl. `develop`, no `ai` | `ai` already has a live `authentik-forward-auth` SecurityPolicy (16d), from `components/common`; hermes' route does not use forward-auth (own OIDC) |

Checked and **clean** (no hermes reference): ExternalSecret (ns-independent — `hermes-secret` pulls OpenBao key `hermes`),
HTTPRoute (parent `internal` in `network`; live `allowedRoutes.namespaces.from: All`; hostname `hermes.${SECRET_DOMAIN}`
unchanged, so Authentik redirect URI `…/auth/callback` and `HERMES_DASHBOARD_PUBLIC_URL` (`helmrelease.yaml:46`) unaffected),
no NetworkPolicy/CiliumNetworkPolicy in `develop` or `ai`, no ServiceMonitor/PrometheusRule mentioning hermes, no gatus/homepage
config files naming it (both driven by HTTPRoute annotations), no cross-app `hermes.develop.svc` DNS reference anywhere in
`kubernetes/`. Service `hermes` (ClusterIP, 9119) is only used by the HTTPRoute.

**Namespace differences to handle:** `develop` has `volsync.backube/privileged-movers: "true"` (`develop/namespace.yaml:8`)
and PSA `privileged`; `ai` has neither annotation and is `baseline`. ~~`media` (baseline, no annotation) and `games` already run root
VolSync movers, so this is likely fine~~ — **CORRECTION 2026-09-24: this was wrong.** `media`, `games` and `productivity` all carry
`privileged-movers: "true"` in their own `namespace.yaml`, and all 8 namespaces with a ReplicationSource have it; `ai` would have been the
only one without. The smoke test later showed PSA `baseline` admits the unannotated root mover, so admission was never the issue, but
restored ownership differs (runbook §6.5). Decided: add it to `ai` first. Movers run
`runAsUser: 0` (`local.yaml:59`); hermes `ks.yaml` doesn't override.

Other per-namespace things that will be recreated in `ai` by Flux: `hermes-volsync-local`/`-r2` ExternalSecrets and their Secrets,
ServiceAccounts/Roles for the movers, helm release secrets (`sh.helm.release.v1.hermes.v5–v9`; **the HelmRelease is in the
namespace, so the release restarts at v1**), the `hermes` OCIRepository.

## (5) How `ai` apps wire it (to match)

`kubernetes/apps/ai/hindsight/ks.yaml:1-34` and `litellm/ks.yaml:1-33`:
`commonMetadata.labels`, `dependsOn` (`cloudnative-pg-cluster18`/database — hermes doesn't need this, and
`external-secrets-openbao-store`/external-secrets — hermes has it, `ks.yaml:11-13`), `targetNamespace: ai`,
`prune: true`, `wait: false`, `interval: 30m`, `retryInterval: 1m`, `timeout: 5m`, `postBuild.substitute: {APP, NS: ai}`.
Hermes currently has `interval: 1h` and no `retryInterval`/`timeout`.

**Neither ai app has backup wiring.** `litellm` app kustomization has no volsync component; `hindsight/app/pvc.yaml:1-40` is a
plain cache PVC with an explicit comment "Deliberately NO components/volsync" — durable state is Postgres (barman). So **hermes
would be the first `ai` app with VolSync (or kopiur)**; there is nothing in `ai` to copy for backup, only the general `ks.yaml` shape.
Namespace file: `ai/namespace.yaml` has `prune: disabled` annotation (`:7`), so it survives pruning; `ai/kustomization.yaml` adds
`components/common` and lists ks files.

## (6) Data-loss traps

1. **PVC in the Kustomization inventory, `prune: true`.** Live `hermes` Kustomization inventory (`status.inventory`) includes
   `develop_hermes__PersistentVolumeClaim`; `ks.yaml:16` `prune: true`; `deletionPolicy` unset (default MirrorPrune → delete on
   removal). Removing `./hermes/ks.yaml` from `develop/kustomization.yaml` (with `cluster-apps` `prune: true`) deletes the `hermes`
   Kustomization and then its PVC. **This is the mechanism the `volsync-claim` component's comments warn about (`kustomization.yaml:8-13`).**
2. **Reclaim policy `Delete` on both** the PV `pvc-12f54114…` (live) and the StorageClass `longhorn-1-replica-local` (live), so the PVC
   deletion removes the Longhorn volume. Finalizers on the PV (`external-provisioner…`, `external-attacher/driver-longhorn-io`,
   `pv-protection`) do **not** prevent this; they run as part of it. PVC has only `kubernetes.io/pvc-protection` (blocks while the pod
   is running, but Flux deletes the Deployment first).
3. **Ordering across namespaces:** the same path change in one commit makes Flux create `ai/hermes` (new PVC restoring from kopia)
   while pruning `develop/hermes`. If the restore identity is wrong (see (3)) the new PVC is empty (or the restore errors) *while
   the old volume is being destroyed*. The last hourly VolSync snapshot is the only remaining copy, and it is up to ~1h old.
4. **Two agents on one volume is not the risk** (RWO + Recreate, `helmrelease.yaml:30`), but the moved pod must not start until the
   restored PVC is populated, otherwise it initialises `/opt/data` fresh.
5. **`develop/namespace.yaml` has `prune: disabled`** (`:7`), so the namespace is safe. Other develop apps (gitea, nexus, drone,
   dev-shell) are untouched. `ai/namespace.yaml` likewise.
6. `kopiur` `Snapshot` rows discovered in `develop` are cluster objects; removing the namespace's objects does not affect the
   kopia data behind them.

## Safe-move approaches (options, not done)

**A. Restore from kopia into `ai`** (uses the existing pipeline). Pre-steps: suspend the develop `hermes` Kustomization and scale
to 0 (`prune` is still per-Kustomization; suspend prevents it from acting), force one final `hermes-local` sync and confirm
`latestMoverStatus.result: Successful` *and* a fresh `lastSyncTime` (see `volsync-mover-stuck.md:275-290` on false-positive syncs),
then create `ai` with the RD patch `sourceNamespace: develop`. Only after `ai/hermes` is Running with the data verified,
delete `develop/hermes` — and even then, first flip the PV to `Retain` (`kubectl patch pv …` — a mutation, not done here)
so a mistake is recoverable. Cost: data since the last snapshot must be quiesced first (hence scale-to-0).

**B. Re-bind the existing PV** (no copy). Patch PV `pvc-12f54114…` to `Retain`, let the PVC go, clear `claimRef`, then create the
`ai` PVC with `volumeName` pointing at it. **Unverified:** the component's PVC carries a `dataSourceRef` to an RD; whether a
pre-bound `volumeName` PVC plus `dataSourceRef` causes the populator to act is untested. Also needs the PV's `claimRef` namespace
rewritten. Higher risk if wrong; no snapshot fallback needed for the bytes themselves since the volume is untouched.

Either way keep `hermes@develop` snapshots (never delete them during the move); they are the rollback.

## Live state snapshot (2026-09-23)

- Pod `hermes-6f54b89c46-4jzdl` Running on brokkr03 (age 21m); HelmRelease `develop/hermes.v9` on app-template 5.2.1.
- Kustomization `hermes` Ready, `refs/heads/main@sha1:4c46e4e6`, `prune: true`, `wait: false`.
- ExternalSecrets `hermes-secret`, `hermes-volsync-local`, `hermes-volsync-r2` all SecretSynced.
- 23 PVs cluster-wide are `Retain`; the hermes PVs are **not** among them.
- kopiur ClusterRepositories `kopia-local`/`kopia-r2` Ready with 8 namespaces (no `ai`).
