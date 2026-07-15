# Tier 1: dcsi → Longhorn Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate 20 apps from democratic-csi (truenas-nfs/truenas-iscsi) to longhorn-1-replica, eliminating the TrueNAS REST API dependency for these workloads.

**Architecture:** VolSync's Kopia backend is storage-class agnostic — it stores backups in an S3 bucket (MinIO/local), not on the source PVC's storage system. For each app: trigger a current backup, stop the app, delete the dcsi PVC, update the GitOps ks.yaml to target Longhorn, push and let Flux reconcile (which recreates the ReplicationSource/Destination targeting Longhorn, plus a Pending claim PVC), trigger a restore via the ReplicationDestination, wait for the PVC to bind, then resume the app.

**Tech Stack:** kubectl, Flux CD (kustomize.toolkit.fluxcd.io), VolSync (volsync.backube, Kopia engine), Longhorn (driver.longhorn.io), git, GitHub CLI

## Global Constraints

- **Never delete ReplicationSources or ReplicationDestinations** — Flux owns them; deleting them loses the backup linkage between runs
- **NFS apps: add 5 new vars. iSCSI apps: change 3 existing vars.** See the Substitution Changes section below — the two patterns are mutually exclusive
- **kometa lives inside `kubernetes/apps/media/plex/ks.yaml`** — edit that file's `kometa` Kustomization block only; do NOT touch the plex, plex-auto-languages, or plex-image-cleanup blocks in the same file
- **Longhorn is RWO-only** — `VOLSYNC_ACCESSMODES: ReadWriteOnce` and `VOLSYNC_COPYMETHOD: Snapshot` are mandatory; Longhorn does not support ReadWriteMany
- **Run `lefthook run pre-commit` before every commit** — yamlfmt and gitleaks enforced; do not skip hooks
- **One app at a time** — confirm Running before starting the next; do not pipeline migrations
- **If a restore fails or PVC stays Pending >20 min**: check `kubectl describe replicationdestination ${APP}-dst-local -n ${NS}` and the mover pod logs before retrying

---

## Substitution Changes Reference

### NFS apps — ADD these 5 lines to postBuild.substitute

```yaml
VOLSYNC_STORAGECLASS: longhorn-1-replica
VOLSYNC_CLONE_STORAGECLASS: longhorn-1-replica
VOLSYNC_SNAPSHOTCLASS: longhorn-snapclass
VOLSYNC_ACCESSMODES: ReadWriteOnce
VOLSYNC_COPYMETHOD: Snapshot
```

### iSCSI apps (qbittorrent, sabnzbd) — CHANGE these 3 existing lines

```yaml
VOLSYNC_STORAGECLASS: longhorn-1-replica        # was: truenas-iscsi
VOLSYNC_CLONE_STORAGECLASS: longhorn-1-replica  # was: truenas-iscsi
VOLSYNC_SNAPSHOTCLASS: longhorn-snapclass       # was: truenas-iscsi-snapclass
```

Leave unchanged: `VOLSYNC_ACCESSMODES: ReadWriteOnce`, `VOLSYNC_COPYMETHOD: Snapshot`, `VOLSYNC_CACHE_CLASS: longhorn-1-replica`

---

## App Inventory

### media namespace (13 apps — all NFS)

| App | ks.yaml | Notes |
|-----|---------|-------|
| bazarr | `kubernetes/apps/media/bazarr/ks.yaml` | |
| sonarr | `kubernetes/apps/media/sonarr/ks.yaml` | |
| radarr | `kubernetes/apps/media/radarr/ks.yaml` | |
| lidarr | `kubernetes/apps/media/lidarr/ks.yaml` | |
| prowlarr | `kubernetes/apps/media/prowlarr/ks.yaml` | |
| recyclarr | `kubernetes/apps/media/recyclarr/ks.yaml` | |
| notifiarr | `kubernetes/apps/media/notifiarr/ks.yaml` | |
| jellyseerr | `kubernetes/apps/media/jellyseerr/ks.yaml` | |
| tautulli | `kubernetes/apps/media/tautulli/ks.yaml` | |
| calibre | `kubernetes/apps/media/calibre/ks.yaml` | |
| calibre-web | `kubernetes/apps/media/calibre-web/ks.yaml` | |
| audiobookshelf | `kubernetes/apps/media/audiobookshelf/ks.yaml` | |
| kometa | `kubernetes/apps/media/plex/ks.yaml` | nested Kustomization block |

### download namespace (4 apps)

| App | ks.yaml | Source |
|-----|---------|--------|
| autobrr | `kubernetes/apps/download/autobrr/ks.yaml` | NFS |
| cross-seed | `kubernetes/apps/download/cross-seed/ks.yaml` | NFS |
| qbittorrent | `kubernetes/apps/download/qbittorrent/ks.yaml` | iSCSI |
| sabnzbd | `kubernetes/apps/download/sabnzbd/ks.yaml` | iSCSI |

### productivity namespace (3 apps — all NFS)

| App | ks.yaml |
|-----|---------|
| n8n | `kubernetes/apps/productivity/n8n/ks.yaml` |
| mealie | `kubernetes/apps/productivity/mealie/ks.yaml` |
| node-red | `kubernetes/apps/productivity/node-red/ks.yaml` |

---

## Task 1: Prerequisites

**Files:** none modified

**Interfaces:**
- Produces: confirmed cluster readiness before any migration starts

- [ ] **Step 1.1: Verify Longhorn has capacity (need ~120 Gi combined for all 20 apps)**

  ```bash
  kubectl get nodes.longhorn.io -n longhorn-system \
    -o custom-columns="NODE:.metadata.name,DISK_STATE:.status.diskStatus"
  ```

  Expected: each node shows disk entries with schedulable space; combined available > 120 Gi

- [ ] **Step 1.2: Verify all 20 target apps have a recent volsync backup**

  ```bash
  kubectl get replicationsource -n media \
    -o custom-columns="APP:.metadata.name,LAST:.status.lastSyncTime,COND:.status.conditions[0].message"
  kubectl get replicationsource -n download \
    -o custom-columns="APP:.metadata.name,LAST:.status.lastSyncTime,COND:.status.conditions[0].message"
  kubectl get replicationsource -n productivity \
    -o custom-columns="APP:.metadata.name,LAST:.status.lastSyncTime,COND:.status.conditions[0].message"
  ```

  Expected: all 20 apps have a non-null LAST timestamp within the last 4 hours; COND column is empty (no errors)

- [ ] **Step 1.3: Verify longhorn-snapclass exists**

  ```bash
  kubectl get volumesnapshotclass longhorn-snapclass
  ```

  Expected: `longhorn-snapclass   driver.longhorn.io   Delete`

- [ ] **Step 1.4: Verify longhorn-1-replica StorageClass exists**

  ```bash
  kubectl get storageclass longhorn-1-replica
  ```

  Expected: `longhorn-1-replica   driver.longhorn.io   ...`

- [ ] **Step 1.5: Confirm working tree is clean and up to date**

  ```bash
  git status
  git pull origin main
  ```

  Expected: `nothing to commit, working tree clean` and `Already up to date.`

---

## Task 2: media Namespace Migration (13 apps)

**Files modified:**
- `kubernetes/apps/media/bazarr/ks.yaml`
- `kubernetes/apps/media/sonarr/ks.yaml`
- `kubernetes/apps/media/radarr/ks.yaml`
- `kubernetes/apps/media/lidarr/ks.yaml`
- `kubernetes/apps/media/prowlarr/ks.yaml`
- `kubernetes/apps/media/recyclarr/ks.yaml`
- `kubernetes/apps/media/notifiarr/ks.yaml`
- `kubernetes/apps/media/jellyseerr/ks.yaml`
- `kubernetes/apps/media/tautulli/ks.yaml`
- `kubernetes/apps/media/calibre/ks.yaml`
- `kubernetes/apps/media/calibre-web/ks.yaml`
- `kubernetes/apps/media/audiobookshelf/ks.yaml`
- `kubernetes/apps/media/plex/ks.yaml` (kometa block only)

**Interfaces:**
- Consumes: Task 1 (prerequisites verified)
- Produces: all 13 media apps running on longhorn-1-replica PVCs with updated GitOps definitions

> Recommended order: start with low-impact apps (recyclarr, notifiarr) to build confidence, then indexers (prowlarr), then arr apps, then UI apps.

### 2.1 — bazarr (full worked example; §§ 2.2–2.12 reference this pattern)

- [ ] **Step 2.1.1: Trigger immediate backup before touching the app**

  ```bash
  kubectl patch replicationsource bazarr-local -n media \
    --type merge -p '{"spec":{"trigger":{"manual":"pre-migrate"}}}'
  ```

  Expected: `replicationsource.volsync.backube/bazarr-local patched`

- [ ] **Step 2.1.2: Wait for backup to complete**

  ```bash
  watch -n 10 kubectl get replicationsource bazarr-local -n media
  ```

  Expected: LAST SYNC TIME column updates to a timestamp within the last 2 minutes. Ctrl+C once updated. Typical duration: 2–5 min for a 4 Gi volume.

  Verify backup succeeded (no error condition):
  ```bash
  kubectl get replicationsource bazarr-local -n media \
    -o jsonpath='{.status.conditions[0].message}{"\n"}'
  ```
  Expected: empty output (no error message)

- [ ] **Step 2.1.3: Suspend HelmRelease and wait for pod termination**

  ```bash
  kubectl patch helmrelease bazarr -n media \
    --type merge -p '{"spec":{"suspend":true}}'
  kubectl wait pod -n media -l app.kubernetes.io/name=bazarr \
    --for=delete --timeout=120s
  ```

  Expected: `pod/bazarr-xxxxxxxxx condition met`

- [ ] **Step 2.1.4: Delete old dcsi PVCs**

  ```bash
  kubectl delete pvc bazarr -n media
  kubectl delete pvc volsync-bazarr-dst-local-dest -n media --ignore-not-found
  ```

  Expected: `persistentvolumeclaim "bazarr" deleted`; second line either deletes or says not found (both OK)

- [ ] **Step 2.1.5: Edit `kubernetes/apps/media/bazarr/ks.yaml` — add 5 Longhorn vars**

  Add these 5 lines to `postBuild.substitute`:
  ```yaml
  VOLSYNC_STORAGECLASS: longhorn-1-replica
  VOLSYNC_CLONE_STORAGECLASS: longhorn-1-replica
  VOLSYNC_SNAPSHOTCLASS: longhorn-snapclass
  VOLSYNC_ACCESSMODES: ReadWriteOnce
  VOLSYNC_COPYMETHOD: Snapshot
  ```

  The existing lines (APP, NS, VOLSYNC_CAPACITY, VOLSYNC_LOCAL_SCHEDULE) stay unchanged.

- [ ] **Step 2.1.6: Run pre-commit checks and commit**

  ```bash
  lefthook run pre-commit
  git add kubernetes/apps/media/bazarr/ks.yaml
  git commit -m "chore(bazarr): migrate volsync PVC from dcsi NFS to longhorn-1-replica"
  ```

  Expected: pre-commit passes (yamlfmt, gitleaks); commit created

- [ ] **Step 2.1.7: Push to origin**

  ```bash
  git push origin main
  ```

  If SSH push fails, use HTTPS fallback:
  ```bash
  git -c credential.helper='!gh auth git-credential' \
    push https://github.com/$(git remote get-url origin | sed 's|.*github.com[:/]\(.*\)\.git|\1|')
  ```

- [ ] **Step 2.1.8: Wait for Flux to reconcile the bazarr Kustomization**

  ```bash
  kubectl get kustomization bazarr -n flux-system --watch
  ```

  Expected: READY=True, STATUS shows `Applied revision: main@sha1:<new-commit>` (within ~2 min)

- [ ] **Step 2.1.9: Confirm ReplicationDestination now targets Longhorn**

  ```bash
  kubectl get replicationdestination bazarr-dst-local -n media \
    -o jsonpath='storageClass={.spec.kopia.storageClassName} snapshotClass={.spec.kopia.volumeSnapshotClassName}{"\n"}'
  ```

  Expected: `storageClass=longhorn-1-replica snapshotClass=longhorn-snapclass`

- [ ] **Step 2.1.10: Trigger restore into the new Longhorn PVC**

  ```bash
  kubectl patch replicationdestination bazarr-dst-local -n media \
    --type merge -p '{"spec":{"trigger":{"manual":"migrate-longhorn"}}}'
  ```

  Expected: `replicationdestination.volsync.backube/bazarr-dst-local patched`

  Watch the mover pod appear and the claim PVC transition from Pending:
  ```bash
  kubectl get pods -n media | grep bazarr
  kubectl get pvc bazarr -n media
  ```

- [ ] **Step 2.1.11: Wait for restore to complete**

  ```bash
  watch -n 10 kubectl get replicationdestination bazarr-dst-local -n media
  ```

  Expected: LAST SYNC TIME updates; mover pod disappears. Typical duration: 2–15 min.

  If the restore fails, check mover pod logs:
  ```bash
  kubectl logs -n media -l app.kubernetes.io/component=volsync,volsync.backube/destination=bazarr-dst-local
  ```

- [ ] **Step 2.1.12: Verify PVC is Bound on Longhorn**

  ```bash
  kubectl get pvc bazarr -n media
  ```

  Expected:
  ```
  NAME     STATUS   VOLUME         CAPACITY   ACCESS MODES   STORAGECLASS
  bazarr   Bound    pvc-xxxxxxxx   4Gi        RWO            longhorn-1-replica
  ```

- [ ] **Step 2.1.13: Unsuspend HelmRelease**

  ```bash
  kubectl patch helmrelease bazarr -n media \
    --type merge -p '{"spec":{"suspend":false}}'
  ```

- [ ] **Step 2.1.14: Verify app is Running**

  ```bash
  kubectl get pods -n media -l app.kubernetes.io/name=bazarr
  ```

  Expected: `STATUS=Running READY=1/1`

### 2.2–2.12 — Remaining media apps (NFS pattern, same 14 steps as §2.1)

For each app: trigger backup → wait → suspend → delete PVCs → add 5 vars to ks.yaml → lefthook + commit + push → wait Flux → confirm dst updated → trigger restore → wait → verify PVC Bound longhorn-1-replica → unsuspend → verify Running.

**Recommended order:**

| Sub-task | App | ks.yaml | HelmRelease | ReplicationSource | ReplicationDestination |
|----------|-----|---------|-------------|-------------------|------------------------|
| 2.2 | recyclarr | `kubernetes/apps/media/recyclarr/ks.yaml` | recyclarr | recyclarr-local | recyclarr-dst-local |
| 2.3 | notifiarr | `kubernetes/apps/media/notifiarr/ks.yaml` | notifiarr | notifiarr-local | notifiarr-dst-local |
| 2.4 | prowlarr | `kubernetes/apps/media/prowlarr/ks.yaml` | prowlarr | prowlarr-local | prowlarr-dst-local |
| 2.5 | sonarr | `kubernetes/apps/media/sonarr/ks.yaml` | sonarr | sonarr-local | sonarr-dst-local |
| 2.6 | radarr | `kubernetes/apps/media/radarr/ks.yaml` | radarr | radarr-local | radarr-dst-local |
| 2.7 | lidarr | `kubernetes/apps/media/lidarr/ks.yaml` | lidarr | lidarr-local | lidarr-dst-local |
| 2.8 | tautulli | `kubernetes/apps/media/tautulli/ks.yaml` | tautulli | tautulli-local | tautulli-dst-local |
| 2.9 | jellyseerr | `kubernetes/apps/media/jellyseerr/ks.yaml` | jellyseerr | jellyseerr-local | jellyseerr-dst-local |
| 2.10 | audiobookshelf | `kubernetes/apps/media/audiobookshelf/ks.yaml` | audiobookshelf | audiobookshelf-local | audiobookshelf-dst-local |
| 2.11 | calibre | `kubernetes/apps/media/calibre/ks.yaml` | calibre | calibre-local | calibre-dst-local |
| 2.12 | calibre-web | `kubernetes/apps/media/calibre-web/ks.yaml` | calibre-web | calibre-web-local | calibre-web-dst-local |

Commit message pattern: `chore(<app>): migrate volsync PVC from dcsi NFS to longhorn-1-replica`

### 2.13 — kometa (special case: nested Kustomization block in plex/ks.yaml)

kometa's Kustomization is the second block in `kubernetes/apps/media/plex/ks.yaml` (`metadata.name: &app kometa`). Do NOT create a separate file.

- [ ] **Step 2.13.1: Trigger backup**
  ```bash
  kubectl patch replicationsource kometa-local -n media \
    --type merge -p '{"spec":{"trigger":{"manual":"pre-migrate"}}}'
  ```

- [ ] **Step 2.13.2: Wait for backup**
  ```bash
  watch -n 10 kubectl get replicationsource kometa-local -n media
  ```
  Expected: LAST SYNC TIME updates

- [ ] **Step 2.13.3: Suspend kometa HelmRelease**
  ```bash
  kubectl patch helmrelease kometa -n media --type merge -p '{"spec":{"suspend":true}}'
  kubectl wait pod -n media -l app.kubernetes.io/name=kometa --for=delete --timeout=120s
  ```

- [ ] **Step 2.13.4: Delete old PVCs**
  ```bash
  kubectl delete pvc kometa -n media
  kubectl delete pvc volsync-kometa-dst-local-dest -n media --ignore-not-found
  ```

- [ ] **Step 2.13.5: Edit the kometa block in `kubernetes/apps/media/plex/ks.yaml`**

  Locate the Kustomization with `name: &app kometa` (approximately lines 38–67). Add to its `postBuild.substitute`:
  ```yaml
  VOLSYNC_STORAGECLASS: longhorn-1-replica
  VOLSYNC_CLONE_STORAGECLASS: longhorn-1-replica
  VOLSYNC_SNAPSHOTCLASS: longhorn-snapclass
  VOLSYNC_ACCESSMODES: ReadWriteOnce
  VOLSYNC_COPYMETHOD: Snapshot
  ```

  **Do NOT modify the plex, plex-auto-languages, or plex-image-cleanup blocks in the same file.**

- [ ] **Step 2.13.6: Run pre-commit and commit**
  ```bash
  lefthook run pre-commit
  git add kubernetes/apps/media/plex/ks.yaml
  git commit -m "chore(kometa): migrate volsync PVC from dcsi NFS to longhorn-1-replica"
  ```

- [ ] **Step 2.13.7: Push**
  ```bash
  git push origin main
  ```

- [ ] **Step 2.13.8: Wait for Flux to reconcile kometa Kustomization**
  ```bash
  kubectl get kustomization kometa -n flux-system --watch
  ```
  Expected: READY=True with new commit SHA

- [ ] **Step 2.13.9: Confirm ReplicationDestination targets Longhorn**
  ```bash
  kubectl get replicationdestination kometa-dst-local -n media \
    -o jsonpath='storageClass={.spec.kopia.storageClassName}{"\n"}'
  ```
  Expected: `storageClass=longhorn-1-replica`

- [ ] **Step 2.13.10: Trigger restore**
  ```bash
  kubectl patch replicationdestination kometa-dst-local -n media \
    --type merge -p '{"spec":{"trigger":{"manual":"migrate-longhorn"}}}'
  ```

- [ ] **Step 2.13.11: Wait for restore**
  ```bash
  watch -n 10 kubectl get replicationdestination kometa-dst-local -n media
  ```
  Expected: LAST SYNC TIME updates; mover pod disappears

- [ ] **Step 2.13.12: Verify PVC is Bound on Longhorn**
  ```bash
  kubectl get pvc kometa -n media
  ```
  Expected: `STATUS=Bound STORAGECLASS=longhorn-1-replica ACCESS MODES=RWO`

- [ ] **Step 2.13.13: Unsuspend and verify**
  ```bash
  kubectl patch helmrelease kometa -n media --type merge -p '{"spec":{"suspend":false}}'
  kubectl get pods -n media -l app.kubernetes.io/name=kometa
  ```
  Expected: Running (kometa is a CronJob-style app; it may show as Completed between runs — that is normal)

---

## Task 3: download Namespace Migration (4 apps)

**Files modified:**
- `kubernetes/apps/download/autobrr/ks.yaml` (NFS — add 5 vars)
- `kubernetes/apps/download/cross-seed/ks.yaml` (NFS — add 5 vars)
- `kubernetes/apps/download/qbittorrent/ks.yaml` (iSCSI — change 3 existing vars)
- `kubernetes/apps/download/sabnzbd/ks.yaml` (iSCSI — change 3 existing vars)

**Interfaces:**
- Consumes: Task 2 complete (all media apps running on Longhorn)
- Produces: all 4 download apps running on longhorn-1-replica

### 3.1 — autobrr (NFS — same 14-step pattern as §2.1)

- [ ] **Steps 3.1.1–3.1.14:** Follow the §2.1 pattern with:
  - APP=autobrr, NS=download
  - ks.yaml: `kubernetes/apps/download/autobrr/ks.yaml`
  - Add the 5 NFS vars to `postBuild.substitute`
  - Commit: `chore(autobrr): migrate volsync PVC from dcsi NFS to longhorn-1-replica`

### 3.2 — cross-seed (NFS — same 14-step pattern as §2.1)

- [ ] **Steps 3.2.1–3.2.14:** Follow the §2.1 pattern with:
  - APP=cross-seed, NS=download
  - ks.yaml: `kubernetes/apps/download/cross-seed/ks.yaml`
  - Add the 5 NFS vars to `postBuild.substitute`
  - Commit: `chore(cross-seed): migrate volsync PVC from dcsi NFS to longhorn-1-replica`

### 3.3 — qbittorrent (iSCSI — 3 vars change, not add)

- [ ] **Step 3.3.1: Trigger backup**
  ```bash
  kubectl patch replicationsource qbittorrent-local -n download \
    --type merge -p '{"spec":{"trigger":{"manual":"pre-migrate"}}}'
  ```

- [ ] **Step 3.3.2: Wait for backup**
  ```bash
  watch -n 10 kubectl get replicationsource qbittorrent-local -n download
  ```
  Expected: LAST SYNC TIME updates

- [ ] **Step 3.3.3: Suspend HelmRelease**
  ```bash
  kubectl patch helmrelease qbittorrent -n download --type merge -p '{"spec":{"suspend":true}}'
  kubectl wait pod -n download -l app.kubernetes.io/name=qbittorrent --for=delete --timeout=120s
  ```

- [ ] **Step 3.3.4: Delete old PVCs**
  ```bash
  kubectl delete pvc qbittorrent -n download
  kubectl delete pvc volsync-qbittorrent-dst-local-dest -n download --ignore-not-found
  ```

- [ ] **Step 3.3.5: Edit `kubernetes/apps/download/qbittorrent/ks.yaml` — change 3 iSCSI vars**

  Find and change these existing lines in `postBuild.substitute` (do NOT add, change in-place):
  ```yaml
  # Before → After
  VOLSYNC_STORAGECLASS: truenas-iscsi        → VOLSYNC_STORAGECLASS: longhorn-1-replica
  VOLSYNC_CLONE_STORAGECLASS: truenas-iscsi  → VOLSYNC_CLONE_STORAGECLASS: longhorn-1-replica
  VOLSYNC_SNAPSHOTCLASS: truenas-iscsi-snapclass  → VOLSYNC_SNAPSHOTCLASS: longhorn-snapclass
  ```

  These lines stay unchanged: `VOLSYNC_ACCESSMODES: ReadWriteOnce`, `VOLSYNC_COPYMETHOD: Snapshot`, `VOLSYNC_CACHE_CLASS: longhorn-1-replica`

- [ ] **Step 3.3.6: Run pre-commit and commit**
  ```bash
  lefthook run pre-commit
  git add kubernetes/apps/download/qbittorrent/ks.yaml
  git commit -m "chore(qbittorrent): migrate volsync PVC from dcsi iSCSI to longhorn-1-replica"
  ```

- [ ] **Step 3.3.7: Push**
  ```bash
  git push origin main
  ```

- [ ] **Step 3.3.8: Wait for Flux**
  ```bash
  kubectl get kustomization qbittorrent -n flux-system --watch
  ```
  Expected: READY=True with new commit SHA

- [ ] **Step 3.3.9: Confirm ReplicationDestination targets Longhorn**
  ```bash
  kubectl get replicationdestination qbittorrent-dst-local -n download \
    -o jsonpath='storageClass={.spec.kopia.storageClassName} snapshotClass={.spec.kopia.volumeSnapshotClassName}{"\n"}'
  ```
  Expected: `storageClass=longhorn-1-replica snapshotClass=longhorn-snapclass`

- [ ] **Step 3.3.10: Trigger restore**
  ```bash
  kubectl patch replicationdestination qbittorrent-dst-local -n download \
    --type merge -p '{"spec":{"trigger":{"manual":"migrate-longhorn"}}}'
  ```

- [ ] **Step 3.3.11: Wait for restore**
  ```bash
  watch -n 10 kubectl get replicationdestination qbittorrent-dst-local -n download
  ```
  Expected: LAST SYNC TIME updates; mover pod disappears

- [ ] **Step 3.3.12: Verify PVC is Bound on Longhorn**
  ```bash
  kubectl get pvc qbittorrent -n download
  ```
  Expected: `STATUS=Bound STORAGECLASS=longhorn-1-replica ACCESS MODES=RWO`

- [ ] **Step 3.3.13: Unsuspend**
  ```bash
  kubectl patch helmrelease qbittorrent -n download --type merge -p '{"spec":{"suspend":false}}'
  ```

- [ ] **Step 3.3.14: Verify pods Running (app + gluetun sidecar)**
  ```bash
  kubectl get pods -n download -l app.kubernetes.io/name=qbittorrent
  ```
  Expected: `READY=2/2 STATUS=Running` (app container + gluetun VPN sidecar)

### 3.4 — sabnzbd (iSCSI — same changes as §3.3)

- [ ] **Step 3.4.1: Trigger backup**
  ```bash
  kubectl patch replicationsource sabnzbd-local -n download \
    --type merge -p '{"spec":{"trigger":{"manual":"pre-migrate"}}}'
  ```

- [ ] **Step 3.4.2: Wait for backup**
  ```bash
  watch -n 10 kubectl get replicationsource sabnzbd-local -n download
  ```

- [ ] **Step 3.4.3: Suspend**
  ```bash
  kubectl patch helmrelease sabnzbd -n download --type merge -p '{"spec":{"suspend":true}}'
  kubectl wait pod -n download -l app.kubernetes.io/name=sabnzbd --for=delete --timeout=120s
  ```

- [ ] **Step 3.4.4: Delete old PVCs**
  ```bash
  kubectl delete pvc sabnzbd -n download
  kubectl delete pvc volsync-sabnzbd-dst-local-dest -n download --ignore-not-found
  ```

- [ ] **Step 3.4.5: Edit `kubernetes/apps/download/sabnzbd/ks.yaml` — change 3 iSCSI vars**

  Same change as qbittorrent step 3.3.5:
  ```yaml
  VOLSYNC_STORAGECLASS: longhorn-1-replica        # was: truenas-iscsi
  VOLSYNC_CLONE_STORAGECLASS: longhorn-1-replica  # was: truenas-iscsi
  VOLSYNC_SNAPSHOTCLASS: longhorn-snapclass       # was: truenas-iscsi-snapclass
  ```

- [ ] **Step 3.4.6: lefthook + commit + push**
  ```bash
  lefthook run pre-commit
  git add kubernetes/apps/download/sabnzbd/ks.yaml
  git commit -m "chore(sabnzbd): migrate volsync PVC from dcsi iSCSI to longhorn-1-replica"
  git push origin main
  ```

- [ ] **Step 3.4.7: Wait for Flux** (`kubectl get kustomization sabnzbd -n flux-system --watch` → READY=True)

- [ ] **Step 3.4.8: Trigger restore**
  ```bash
  kubectl patch replicationdestination sabnzbd-dst-local -n download \
    --type merge -p '{"spec":{"trigger":{"manual":"migrate-longhorn"}}}'
  ```

- [ ] **Step 3.4.9: Wait for restore** (`watch -n 10 kubectl get replicationdestination sabnzbd-dst-local -n download`)

- [ ] **Step 3.4.10: Verify PVC** (`kubectl get pvc sabnzbd -n download` → Bound, longhorn-1-replica, RWO)

- [ ] **Step 3.4.11: Unsuspend** (`kubectl patch helmrelease sabnzbd -n download --type merge -p '{"spec":{"suspend":false}}'`)

- [ ] **Step 3.4.12: Verify pod Running** (`kubectl get pods -n download -l app.kubernetes.io/name=sabnzbd` → 1/1 Running)

---

## Task 4: productivity Namespace Migration (3 apps)

**Files modified:**
- `kubernetes/apps/productivity/n8n/ks.yaml`
- `kubernetes/apps/productivity/mealie/ks.yaml`
- `kubernetes/apps/productivity/node-red/ks.yaml`

**Interfaces:**
- Consumes: Task 3 complete (all download apps running on Longhorn)
- Produces: all 3 productivity apps running on longhorn-1-replica

All 3 are NFS apps. Follow the §2.1 pattern for each.

| Sub-task | App | ks.yaml | Commit message |
|----------|-----|---------|----------------|
| 4.1 | n8n | `kubernetes/apps/productivity/n8n/ks.yaml` | `chore(n8n): migrate volsync PVC from dcsi NFS to longhorn-1-replica` |
| 4.2 | mealie | `kubernetes/apps/productivity/mealie/ks.yaml` | `chore(mealie): migrate volsync PVC from dcsi NFS to longhorn-1-replica` |
| 4.3 | node-red | `kubernetes/apps/productivity/node-red/ks.yaml` | `chore(node-red): migrate volsync PVC from dcsi NFS to longhorn-1-replica` |

For each: add the 5 NFS→Longhorn vars, then follow steps: backup trigger → wait → suspend → delete PVCs → edit ks.yaml → lefthook + commit + push → wait Flux READY=True → confirm dst storageClass=longhorn-1-replica → trigger restore → wait restore → verify PVC Bound longhorn-1-replica → unsuspend → verify Running.

- [ ] **Steps 4.1.1–4.1.14:** n8n (follow §2.1 pattern)
- [ ] **Steps 4.2.1–4.2.14:** mealie (follow §2.1 pattern)
- [ ] **Steps 4.3.1–4.3.14:** node-red (follow §2.1 pattern)

---

## Task 5: Final Verification

**Files:** none modified

**Interfaces:**
- Consumes: Tasks 2, 3, 4 complete (all 20 apps migrated)
- Produces: confirmed zero dcsi dependency for all 20 apps; volsync backup cycle validated on Longhorn

- [ ] **Step 5.1: Confirm no migrated apps still have dcsi PVCs**

  ```bash
  kubectl get pvc -n media -o custom-columns="NAME:.metadata.name,SC:.spec.storageClassName,STATUS:.status.phase" | \
    grep -E 'truenas-nfs|truenas-iscsi' || echo "CLEAN — no dcsi PVCs in media"

  kubectl get pvc -n download -o custom-columns="NAME:.metadata.name,SC:.spec.storageClassName,STATUS:.status.phase" | \
    grep -E 'truenas-nfs|truenas-iscsi' || echo "CLEAN — no dcsi PVCs in download"

  kubectl get pvc -n productivity -o custom-columns="NAME:.metadata.name,SC:.spec.storageClassName,STATUS:.status.phase" | \
    grep -E 'truenas-nfs|truenas-iscsi' || echo "CLEAN — no dcsi PVCs in productivity"
  ```

  Expected: all three print `CLEAN`

- [ ] **Step 5.2: Confirm all 20 app PVCs are on longhorn-1-replica and Bound**

  ```bash
  for ns in media download productivity; do
    kubectl get pvc -n $ns \
      -o custom-columns="NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName,STATUS:.status.phase" | \
      grep -v longhorn-1-replica | grep -v NAME || true
  done
  ```

  Expected: no rows printed (every PVC in these namespaces is on longhorn-1-replica)

- [ ] **Step 5.3: Confirm all 20 pods are Running**

  ```bash
  kubectl get pods -n media -l 'app.kubernetes.io/name in (bazarr,sonarr,radarr,lidarr,prowlarr,recyclarr,notifiarr,jellyseerr,tautulli,calibre,calibre-web,audiobookshelf,kometa)'
  kubectl get pods -n download -l 'app.kubernetes.io/name in (autobrr,cross-seed,qbittorrent,sabnzbd)'
  kubectl get pods -n productivity -l 'app.kubernetes.io/name in (n8n,mealie,node-red)'
  ```

  Expected: all Running; no CrashLoopBackOff, no Pending

- [ ] **Step 5.4: Validate new ReplicationSources can write to Longhorn (spot check 3 apps)**

  ```bash
  kubectl patch replicationsource bazarr-local -n media \
    --type merge -p '{"spec":{"trigger":{"manual":"post-migrate-verify"}}}'
  kubectl patch replicationsource qbittorrent-local -n download \
    --type merge -p '{"spec":{"trigger":{"manual":"post-migrate-verify"}}}'
  kubectl patch replicationsource n8n-local -n productivity \
    --type merge -p '{"spec":{"trigger":{"manual":"post-migrate-verify"}}}'

  # Watch all three complete
  watch -n 10 "kubectl get replicationsource -n media bazarr-local; \
               kubectl get replicationsource -n download qbittorrent-local; \
               kubectl get replicationsource -n productivity n8n-local"
  ```

  Expected: LAST SYNC TIME updates on all three within ~10 min; no error conditions in STATUS column

- [ ] **Step 5.5: Confirm ReplicationSources use Longhorn snapshot class**

  ```bash
  kubectl get replicationsource -A \
    -o custom-columns="APP:.metadata.name,NS:.metadata.namespace,SNAPSHOT_CLASS:.spec.kopia.volumeSnapshotClassName" | \
    grep -v longhorn-snapclass | grep -v NAME | grep -v 'plex-local\|plex-image-cleanup' || \
    echo "All migrated ReplicationSources use longhorn-snapclass"
  ```

  Expected: prints the confirmation line (the only non-longhorn entries would be plex and unmigrated apps)
