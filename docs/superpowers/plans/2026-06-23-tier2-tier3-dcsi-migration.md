# Tier 2 + Tier 3 Democratic-CSI Migration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate all remaining democratic-csi PVCs off `truenas-nfs` / `truenas-iscsi` StorageClasses — most to `tns-csi-nfs` or `tns-csi-iscsi` (Tier 2), mosquitto to `longhorn-1-replica` (Tier 3).

**Architecture:** Same VolSync-based restore flow as Tier 1. Change StorageClass/SnapshotClass vars in ks.yaml, trigger a fresh Kopia restore into the new storage class, let Flux create the claim PVC from the resulting snapshot. Special case: `sf-gamedata` has no VolSync backup — use pv-migrate.

**Storage class reference:**

| Old | New | SnapshotClass |
|-----|-----|---------------|
| `truenas-nfs` | `tns-csi-nfs` | `tns-csi-nfs-snapshot` |
| `truenas-iscsi` | `tns-csi-iscsi` | `tns-csi-iscsi-snapshot` |
| any → Longhorn | `longhorn-1-replica` | `longhorn-snapclass` |

**Verified:** tns-csi StorageClasses live and healthy (`tns-csi-nfs`, `tns-csi-iscsi`, `tns-csi-nvmeof` — all 2d+ old, parentDataset fix applied in `ecd5b78d`).

---

## Critical Lessons from Tier 1

**Read this before touching any app.**

1. **Delete the claim PVC BEFORE unsuspending the KS.** If the old claim PVC still exists when Flux reconciles, it hits "spec is immutable after creation" and the RD never gets updated. Scale to 0 → delete claim PVC → then unsuspend.

2. **Flux SSA overwrites manual `kubectl patch` on RD fields.** The only safe window to patch the RD is while the KS is suspended AND the parent KS has not reconciled it. After unsuspending, Flux becomes field manager again.

3. **Do not run `flux reconcile source git` while migration is in progress.** The parent `cluster-apps` KS will reconcile ALL children within ~30s and remove suspensions set manually.

4. **Delete the old dest PVC and wrong-class VolumeSnapshot** before triggering the restore. If a prior restore created a `truenas-nfs-snapclass` snapshot, the RD's `latestImage` points to it. Deleting the old dest PVC forces a fresh restore.

5. **Deployments scaled to 0 stay at 0 after Helm upgrade.** After Flux reconciles, manually scale up: `kubectl scale deployment <app> -n <ns> --replicas=1`.

6. **Use a new `trigger.manual` key each restore attempt** (e.g., `migrate-tns-csi`, `migrate-tns-csi-v2`). VolSync skips restore if `lastManualSync` already matches.

---

## Tier 2A: tns-csi-nfs — Media + Develop + Home/Frigate

### Apps in scope

| App | Namespace | ks.yaml path | Current state |
|-----|-----------|--------------|---------------|
| jellyfin | media | `kubernetes/apps/media/jellyfin/ks.yaml` | No VOLSYNC_STORAGECLASS vars (defaults to truenas-nfs) |
| readarr-audiobooks | media | `kubernetes/apps/media/readarr-audiobooks/ks.yaml` | No VOLSYNC_STORAGECLASS vars |
| readarr-ebooks | media | `kubernetes/apps/media/readarr-ebooks/ks.yaml` | No VOLSYNC_STORAGECLASS vars |
| tdarr | media | `kubernetes/apps/media/tdarr/ks.yaml` | No VOLSYNC_STORAGECLASS vars |
| gitea | develop | `kubernetes/apps/develop/gitea/ks.yaml` | Has STORAGECLASS/SNAPSHOTCLASS/CLONE_STORAGECLASS set to truenas-nfs |
| frigate | home | `kubernetes/apps/home/frigate/ks.yaml` | Has STORAGECLASS/SNAPSHOTCLASS set to truenas-nfs |

### Task 1: Edit ks.yaml files for Tier 2A apps

**jellyfin, readarr-audiobooks, readarr-ebooks, tdarr** — add 5 vars after `VOLSYNC_LOCAL_SCHEDULE`:
```yaml
      VOLSYNC_STORAGECLASS: tns-csi-nfs
      VOLSYNC_CLONE_STORAGECLASS: tns-csi-nfs
      VOLSYNC_SNAPSHOTCLASS: tns-csi-nfs-snapshot
      VOLSYNC_ACCESSMODES: ReadWriteMany
      VOLSYNC_COPYMETHOD: Snapshot
```

**gitea** — change 3 existing vars (ACCESSMODES and COPYMETHOD are not set, leave absent — default RWX is correct for NFS):
```yaml
      VOLSYNC_STORAGECLASS: tns-csi-nfs          # was: truenas-nfs
      VOLSYNC_CLONE_STORAGECLASS: tns-csi-nfs    # was: truenas-nfs
      VOLSYNC_SNAPSHOTCLASS: tns-csi-nfs-snapshot # was: truenas-nfs-snapclass
      # VOLSYNC_CACHE_CLASS stays longhorn-1-replica — do not change
```

**frigate** — change 2 existing vars, add 3 more:
```yaml
      VOLSYNC_STORAGECLASS: tns-csi-nfs          # was: truenas-nfs
      VOLSYNC_SNAPSHOTCLASS: tns-csi-nfs-snapshot # was: truenas-nfs-snapclass
      VOLSYNC_CLONE_STORAGECLASS: tns-csi-nfs    # add new
      VOLSYNC_ACCESSMODES: ReadWriteMany          # add new
      VOLSYNC_COPYMETHOD: Snapshot               # add new
```

- [ ] Edit `kubernetes/apps/media/jellyfin/ks.yaml` — add 5 VOLSYNC vars after VOLSYNC_LOCAL_SCHEDULE
- [ ] Edit `kubernetes/apps/media/readarr-audiobooks/ks.yaml` — add 5 VOLSYNC vars after VOLSYNC_LOCAL_SCHEDULE
- [ ] Edit `kubernetes/apps/media/readarr-ebooks/ks.yaml` — add 5 VOLSYNC vars after VOLSYNC_LOCAL_SCHEDULE
- [ ] Edit `kubernetes/apps/media/tdarr/ks.yaml` — add 5 VOLSYNC vars after VOLSYNC_LOCAL_SCHEDULE
- [ ] Edit `kubernetes/apps/develop/gitea/ks.yaml` — change 3 storage class vars
- [ ] Edit `kubernetes/apps/home/frigate/ks.yaml` — change 2 vars, add 3 vars
- [ ] Run `lefthook run pre-commit` — verify yamlfmt/gitleaks pass
- [ ] Ask user to commit when ready

### Task 2: Migrate each Tier 2A app (repeat per app)

Run this procedure per app in any order. Frigate should be done last (depends on mosquitto being stable, though mosquitto migration is Tier 3 — frigate still works while mosquitto is on democratic-csi).

**Variables for each app (fill in before running):**
```bash
APP=jellyfin          # e.g. jellyfin, readarr-audiobooks, readarr-ebooks, tdarr, gitea, frigate
NS=media              # media, develop, or home
KS_NAME=jellyfin      # matches metadata.name in ks.yaml (same as APP usually)
CLAIM_PVC=$APP        # usually same as APP
```

**Step-by-step:**

- [ ] Verify current PVC is on truenas-nfs: `kubectl get pvc $CLAIM_PVC -n $NS -o jsonpath='{.spec.storageClassName}'`
- [ ] Scale down app deployment: `kubectl scale deployment $APP -n $NS --replicas=0`
  - For tdarr (StatefulSet): `kubectl scale statefulset $APP -n $NS --replicas=0`
  - Wait for pods to terminate: `kubectl get pods -n $NS -l app.kubernetes.io/name=$APP -w`
- [ ] Delete old claim PVC: `kubectl delete pvc $CLAIM_PVC -n $NS`
  - If stuck on pvc-protection finalizer: `kubectl patch pvc $CLAIM_PVC -n $NS --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'`
- [ ] Delete old dest PVC: `kubectl delete pvc volsync-${APP}-dst-local-dest -n $NS --ignore-not-found`
- [ ] Delete old wrong-class VolumeSnapshot (if any on truenas-nfs-snapclass):
  ```bash
  kubectl get volumesnapshot -n $NS | grep "${APP}-dst-local"
  kubectl delete volumesnapshot <name-of-truenas-snapclass-snapshot> -n $NS
  ```
- [ ] Suspend the KS: `kubectl patch kustomization $KS_NAME -n flux-system --type merge -p '{"spec":{"suspend":true}}'`
- [ ] Wait ~30s for current reconcile to finish, then push the git commit (Task 1) if not yet done
- [ ] Flux reconcile the source (only if commit is merged): `flux reconcile source git home-kubernetes`
  - **Do NOT do this if KS is suspended and other apps are mid-migration.**
- [ ] Unsuspend the KS: `kubectl patch kustomization $KS_NAME -n flux-system --type merge -p '{"spec":{"suspend":false}}'`
- [ ] Force reconcile the KS: `flux reconcile kustomization $KS_NAME --with-source`
  - Watch for RD to be updated: `kubectl get replicationdestination ${APP}-dst-local -n $NS -w`
- [ ] Patch RD trigger to start restore:
  ```bash
  kubectl patch replicationdestination ${APP}-dst-local -n $NS \
    --type merge -p '{"spec":{"trigger":{"manual":"migrate-tns-csi"}}}'
  ```
  - If patch is overwritten by Flux, the KS may still be unsuspended and reconciling — wait 30s and patch again
- [ ] Watch restore complete:
  ```bash
  kubectl get replicationdestination ${APP}-dst-local -n $NS -w
  # Waiting for lastManualSync: migrate-tns-csi and latestImage to appear
  ```
- [ ] Verify snapshot is on tns-csi-nfs-snapshot class:
  ```bash
  kubectl get replicationdestination ${APP}-dst-local -n $NS \
    -o jsonpath='{.status.latestImage.name}'
  # Then check the snapshot:
  kubectl get volumesnapshot <name-from-above> -n $NS \
    -o jsonpath='{.spec.volumeSnapshotClassName}'
  # Expected: tns-csi-nfs-snapshot
  ```
- [ ] Verify claim PVC was created on tns-csi-nfs:
  ```bash
  kubectl get pvc $CLAIM_PVC -n $NS -o jsonpath='{.spec.storageClassName}'
  # Expected: tns-csi-nfs
  ```
- [ ] Scale up app: `kubectl scale deployment $APP -n $NS --replicas=1`
- [ ] Verify pod comes up: `kubectl get pods -n $NS -l app.kubernetes.io/name=$APP`
- [ ] Check Gatus/app health (if applicable)

---

## Tier 2B: tns-csi-iscsi — Games

### Apps in scope

| App | Namespace | Current state | VolSync |
|-----|-----------|---------------|---------|
| satisfactory | games | truenas-iscsi, 2Gi | RS + RD exist |
| valheim | games | truenas-iscsi, 50Gi | RS + RD exist |
| sf-gamedata | games | truenas-iscsi, 30Gi | **No RS/RD — needs pv-migrate** |
| valheim-syncthing-config | games | truenas-iscsi, 1Gi | RS exists (valheim-syncthing), no RD |

### Task 3: Edit ks.yaml for iSCSI apps

**satisfactory** — change 3 vars (the other iSCSI-specific vars stay the same):
```yaml
      VOLSYNC_STORAGECLASS: tns-csi-iscsi        # was: truenas-iscsi
      VOLSYNC_CLONE_STORAGECLASS: tns-csi-iscsi  # was: truenas-iscsi
      VOLSYNC_SNAPSHOTCLASS: tns-csi-iscsi-snapshot # was: truenas-iscsi-snapclass
      # VOLSYNC_ACCESSMODES: ReadWriteOnce stays (iSCSI is still RWO)
      # VOLSYNC_COPYMETHOD: Snapshot stays
      # VOLSYNC_CACHE_CLASS: longhorn-1-replica stays
```

**valheim** — same 3-var change as satisfactory:
```yaml
      VOLSYNC_STORAGECLASS: tns-csi-iscsi        # was: truenas-iscsi
      VOLSYNC_CLONE_STORAGECLASS: tns-csi-iscsi  # was: truenas-iscsi
      VOLSYNC_SNAPSHOTCLASS: tns-csi-iscsi-snapshot # was: truenas-iscsi-snapclass
      # All other vars unchanged
```

Note: `sf-gamedata` has no VOLSYNC vars in ks.yaml — no ks.yaml edit needed (handled via pv-migrate).

- [ ] Edit `kubernetes/apps/games/satisfactory/ks.yaml` — change 3 storage class vars
- [ ] Edit `kubernetes/apps/games/valheim/ks.yaml` — change 3 storage class vars
- [ ] Run `lefthook run pre-commit`
- [ ] Ask user to commit when ready

### Task 4: Migrate satisfactory (VolSync restore)

Same procedure as Tier 2A. Key values:
- `APP=satisfactory NS=games KS_NAME=satisfactory`
- RD name: `satisfactory-dst-local`
- Trigger key: `migrate-tns-csi`
- Expected storageClassName after: `tns-csi-iscsi`
- Expected snapshotClass after: `tns-csi-iscsi-snapshot`

Note: `volsync-satisfactory-local-src` PVC is currently Pending (truenas-iscsi not provisioning). This is expected — ignore it during migration. It will resolve once satisfactory is on tns-csi-iscsi and the RS runs.

- [ ] Scale down satisfactory: `kubectl scale deployment satisfactory -n games --replicas=0` (or statefulset if applicable)
- [ ] Delete claim PVC: `kubectl delete pvc satisfactory -n games`
- [ ] Delete dest PVC: `kubectl delete pvc volsync-satisfactory-dst-local-dest -n games`
- [ ] Delete old wrong-class snapshot: `kubectl get volumesnapshot -n games | grep satisfactory-dst-local` then delete any on truenas-iscsi-snapclass
- [ ] Suspend KS, unsuspend, force reconcile (same flow as Task 2)
- [ ] Patch RD trigger: `migrate-tns-csi`
- [ ] Wait for restore, verify tns-csi-iscsi storageClass and tns-csi-iscsi-snapshot snapshotClass
- [ ] Scale up satisfactory
- [ ] Verify pod healthy
- [ ] Verify pending `volsync-satisfactory-local-src` PVC resolves (or delete and let RS recreate it)

### Task 5: Migrate sf-gamedata via pv-migrate

`sf-gamedata` has no VolSync backup. It's the 30Gi game installation directory for Satisfactory — the game server re-downloads binaries on startup if the PVC is empty, so recreating fresh is acceptable.

**Option A (recommended — recreate fresh):**
- Scale satisfactory to 0 (if not already)
- Delete the `sf-gamedata` PVC
- Let Flux create a new empty PVC on tns-csi-iscsi (it will be provisioned fresh)
- Scale satisfactory back up — the game server will re-populate

**Option B (pv-migrate — only if save data is critical):**
```bash
# Install pv-migrate if not available:
curl -L https://github.com/utkuozdemir/pv-migrate/releases/latest/download/pv-migrate_linux_amd64.tar.gz | tar xz
./pv-migrate migrate \
  --source-ns games \
  --source sf-gamedata \
  --dest-ns games \
  --dest sf-gamedata-new \
  --dest-storage-class tns-csi-iscsi
# Then swap the PVC (delete old, rename new)
```

- [ ] Confirm with user: is sf-gamedata safe to recreate fresh? (binaries re-download vs. custom config that must be preserved)
- [ ] Scale satisfactory to 0: `kubectl scale deployment satisfactory -n games --replicas=0`
- [ ] If Option A: `kubectl delete pvc sf-gamedata -n games` — Flux will recreate on next reconcile (after ks.yaml change is applied)
- [ ] If Option B: run pv-migrate, then delete old PVC and patch/rename new PVC
- [ ] Verify new sf-gamedata PVC is on tns-csi-iscsi: `kubectl get pvc sf-gamedata -n games -o jsonpath='{.spec.storageClassName}'`
- [ ] Scale satisfactory back up (after Task 4 also complete)

### Task 6: Migrate valheim (VolSync restore)

Same procedure as satisfactory. Key values:
- `APP=valheim NS=games KS_NAME=valheim`
- RD name: `valheim-dst-local`
- Main claim PVC: `valheim` (50Gi)
- Trigger key: `migrate-tns-csi`

**Valheim has two special considerations:**

1. **valheim-syncthing-config** (1Gi iSCSI PVC, `volsync-valheim-syncthing-config`): The `valheim-syncthing` RS exists but has no successful backup history and no corresponding RD. Treat as recreate-fresh: scale down, delete old PVC, let app recreate on tns-csi-iscsi. Syncthing will regenerate its device ID and config — reconfigure remote device pairing after migration.

2. **valheim KS uses `substituteFrom` with three Secrets** (cluster-secrets, cluster-settings, valheim-volsync-syncthing-secret). Ensure these exist before reconciling: `kubectl get secret -n games | grep valheim`

- [ ] Verify syncthing secret exists: `kubectl get secret valheim-volsync-syncthing-secret -n games`
- [ ] Scale down valheim: `kubectl scale statefulset valheim -n games --replicas=0` (confirm controller type first: `kubectl get deployment,statefulset -n games`)
- [ ] Delete `valheim` claim PVC: `kubectl delete pvc valheim -n games`
- [ ] Delete `volsync-valheim-dst-local-dest` PVC: `kubectl delete pvc volsync-valheim-dst-local-dest -n games`
- [ ] Delete `volsync-valheim-syncthing-config` PVC: `kubectl delete pvc volsync-valheim-syncthing-config -n games`
- [ ] Delete old wrong-class snapshot for valheim-dst-local (if any on truenas-iscsi-snapclass)
- [ ] Suspend valheim KS, unsuspend, force reconcile
- [ ] Patch RD trigger: `migrate-tns-csi`
- [ ] Wait for restore, verify tns-csi-iscsi storageClass on both `valheim` and `volsync-valheim-syncthing-config` PVCs
- [ ] Scale valheim back up
- [ ] Verify valheim pod healthy, world loads correctly
- [ ] Reconfigure Syncthing remote device if needed

---

## Tier 3: Longhorn — mosquitto

### Context

`mosquitto` is an MQTT broker in the `home` namespace. Its KS currently depends on `democratic-csi-nfs` (kube-system). Frigate depends on mosquitto being available. Home Assistant depends on mosquitto for device state.

Mosquitto's data (MQTT persistence files, ACLs) is small and can be restored from VolSync. No VOLSYNC storage vars are set — defaults to `truenas-nfs` / `truenas-nfs-snapclass`.

### Task 7: Edit mosquitto ks.yaml

Changes needed:
1. Remove `dependsOn: democratic-csi-nfs` entry (or replace with a Longhorn dep if one exists — check: `kubectl get kustomization -n flux-system | grep longhorn`)
2. Add 5 Longhorn VOLSYNC vars
3. Note: `VOLSYNC_CACHE_CAPACITY: 10Gi` stays as-is

```yaml
  dependsOn:
    # REMOVE: - name: democratic-csi-nfs
    #           namespace: kube-system
    # Replace with nothing — Longhorn has no KS dependency requirement
    - name: external-secrets-openbao-store
      namespace: external-secrets
```

Add after `VOLSYNC_LOCAL_SCHEDULE`:
```yaml
      VOLSYNC_STORAGECLASS: longhorn-1-replica
      VOLSYNC_CLONE_STORAGECLASS: longhorn-1-replica
      VOLSYNC_SNAPSHOTCLASS: longhorn-snapclass
      VOLSYNC_ACCESSMODES: ReadWriteOnce
      VOLSYNC_COPYMETHOD: Snapshot
```

- [ ] Check if Longhorn has a flux KS dependency: `kubectl get kustomization -n flux-system | grep longhorn`
- [ ] Edit `kubernetes/apps/home/mosquitto/ks.yaml`:
  - Remove/replace `dependsOn: democratic-csi-nfs` with appropriate dep (or none)
  - Add 5 Longhorn VOLSYNC vars after VOLSYNC_LOCAL_SCHEDULE
- [ ] Run `lefthook run pre-commit`
- [ ] Ask user to commit when ready

### Task 8: Migrate mosquitto to Longhorn

Key values:
- `APP=mosquitto NS=home KS_NAME=mosquitto`
- Claim PVC: `mosquitto`
- VOLSYNC_CACHE_CAPACITY is 10Gi — the cache PVC will be on whatever VOLSYNC_CACHE_CLASS is set to (check if it's set — if not, it defaults to same as VOLSYNC_STORAGECLASS, which would be longhorn-1-replica)

**Important:** frigate depends on mosquitto. If mosquitto goes down during migration, frigate will lose MQTT and may lose camera events. Plan for a brief outage window.

- [ ] Notify: frigate will be disconnected from MQTT during migration
- [ ] Scale down mosquitto: `kubectl scale deployment mosquitto -n home --replicas=0`
- [ ] Delete `mosquitto` claim PVC: `kubectl delete pvc mosquitto -n home`
- [ ] Delete `volsync-mosquitto-dst-local-dest` PVC: `kubectl delete pvc volsync-mosquitto-dst-local-dest -n home --ignore-not-found`
- [ ] Delete old wrong-class snapshot (if any on truenas-nfs-snapclass)
- [ ] Suspend mosquitto KS: `kubectl patch kustomization mosquitto -n flux-system --type merge -p '{"spec":{"suspend":true}}'`
- [ ] Ensure commit is merged, unsuspend KS, force reconcile
- [ ] Patch RD trigger: `migrate-longhorn`
- [ ] Wait for restore, verify `longhorn-1-replica` storageClass and `longhorn-snapclass` snapshotClass
- [ ] Scale mosquitto back up
- [ ] Verify MQTT broker is accepting connections: `kubectl logs -n home -l app.kubernetes.io/name=mosquitto --tail=20`
- [ ] Verify frigate reconnects to MQTT (check frigate logs)
- [ ] Verify Home Assistant device states update

---

## Post-Migration Cleanup

After all tiers complete:

### Task 9: Remove democratic-csi-nfs and democratic-csi-iscsi KS dependencies

Once no app depends on `democratic-csi-nfs` or `democratic-csi-iscsi` in kube-system, these KS objects (and the CSI driver pods) can be removed.

- [ ] Verify no remaining KS depends on democratic-csi: `grep -r "democratic-csi" kubernetes/apps/`
- [ ] Check if any PVC still uses truenas-nfs or truenas-iscsi: `kubectl get pvc -A | grep -E "truenas-nfs|truenas-iscsi"`
- [ ] If clear, remove `democratic-csi-nfs` and `democratic-csi-iscsi` KS from kube-system (their ks.yaml paths)
- [ ] Delete the orphan test PVC: `kubectl delete pvc democratic-csi-iscsi-test -n kube-system --ignore-not-found`
- [ ] Commit removal and verify Flux converges

### Task 10: Verify all migrated apps healthy

- [ ] `kubectl get pvc -A | grep -E "truenas"` — should return empty
- [ ] Check VolSync RS is creating snapshots on correct classes for each migrated app:
  ```bash
  kubectl get replicationsource -A
  kubectl get volumesnapshot -A | grep -v "truenas"
  ```
- [ ] Spot-check app functionality: jellyfin (stream a video), gitea (push/pull), frigate (camera events), satisfactory (server accessible), valheim (server accessible)
- [ ] Verify Gatus health checks are green for all migrated apps
