# Rehearsal results: moveprobe namespace move

Executed 2026-09-23 (≈20:50–23:25 UTC) against the live cluster by Claude (Sonnet 5) under `docs/rehearsal/plan.md` rev 3. **Complete; teardown verified.** Secrets: none printed or written.
Every command ran through `source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh` (kube-system UID check passes). Nothing committed to `hermes-to-ai`.
Commits on `rehearsal-move` carry the guards' hard-coded `Claude-Session` trailer (`session_011n8fwmnSb2pwCXEpoykL42`), which differs from this session's id; the guards file was not edited.

## Summary

| Scenario | Result |
| --- | --- |
| Baseline (first deploy) | PASS after recovery — **SURPRISE**: populator/Longhorn stall (B-1), guard sharp edge (B-2) |
| 7 name-targeted patch: gate fires | PASS |
| 2 orphan behaviour without resuming old ks | PASS (R-2 / traps 6, 7 confirmed live) |
| 3 rollback by forward commit + re-point | PASS (post-move writes preserved) |
| 1 full B0–B11 | PASS |
| 4 SSA ownership / spec change (+4c) | PASS; 4c confirmed trap 12 verbatim |
| 5 B6 ordering | SURPRISE (NEW claim created after PV Released; "PVC first" order covered by S2) |
| 6 Longhorn kubernetesStatus + locality | PASS (locality CLOSED) |
| 8 claimRef re-point with competing claim | PASS (R-5 hazard confirmed) |
| 9 `Delete` on a bound PV | PASS (effect proved at teardown) |
| 10 schedule/manual + in-flight race | PASS — R-4 CONFIRMED on the deployed fork; Flux reverts `manual` |
| Optional 3b (`git revert`), 6b, second annotated drill | SKIPPED |
| Teardown + verification | PASS; hermes untouched throughout |

## Hermes baseline (before starting)

| Check | Value |
| --- | --- |
| `develop/hermes` pod | `hermes-6f54b89c46-4jzdl` 1/1 Running (3h40m) |
| PV `pvc-12f54114-9e99-442b-bae4-53a9cb239d69` | reclaim `Delete`, phase `Bound`, claim `develop/hermes` |
| `hermes-local` last sync | `2026-09-23T20:23:56Z` Successful (the brief's 19:24Z was the previous hourly `:23` run; the schedule advances it, not a change) |
| Kustomizations | 161, notReady = 0 |
| `rehearsal-*` namespaces / flux objects / remote branch | none |

## Pre-flight and bootstrap (plan §5.2)

- `auth can-i`: `patch pv` yes; `delete volumes.longhorn.io -n longhorn-system` yes; `create pods/portforward -n observability` yes; `create persistentvolumeclaims -n rehearsal-old` yes.
- Schedule grid: no `ReplicationSource` at `47 * * * *` or `45 6 * * *` today (slot still free).
- `AM_HOURS=12 am_silence`: three silences created (`namespace=~rehearsal-.*`, `obj_namespace=~rehearsal-.*`, `name=~rehearsal-apps|rehearsal`); IDs recorded in `rehearsal-state/silences.txt`.
- `COMMIT "rehearsal: add moveprobe fixtures (throwaway)"` → `d7ff4cc2` (lefthook: yamlfmt + gitleaks OK, "no leaks found"). `move_gate rehearsal-old 0` → `parent children: 1`, `GATE PASS`. `PUSH` → new branch `rehearsal-move` (GitHub printed its "create a pull request" hint; no PR opened).
- Applied the two bootstrap CRs (`gitrepository.yaml`, `rehearsal-apps.yaml`); `flux reconcile` both; `inventory_ok` → ok; `others_ready` → all other ks Ready; `flux get ks rehearsal-apps` → Ready `Applied revision …@d7ff4cc2` (**SOPS decrypted the scratch `cluster-secrets`**, plan §3 "not provable by a build" now confirmed).

## Baseline (app healthy in `rehearsal-old`)

**Result: PASS after a recovery — with a SURPRISE (first-deploy populator stall, ~1h to a healthy app).** Final baseline: `flux get ks moveprobe` Ready; app pod Running; `data_check`: `marker.txt: OK`, `blob.bin: OK`, `starts=1`; `seed-1` on both RS: `Created snapshot: 1, Setting policy moveprobe@rehearsal-old: 1, RESULT SUCCESS: 1, Directory is empty: 0` for **both** `-local` and `-r2`; `inventory_ok` ok; `others_ready` ok.

### SURPRISE B-1: the first-deploy populator restore wedged on this cluster (runbook trap 14 / stuck-runbook 5th+6th fingerprints, reproduced on the very first deploy)

What happened, in order (times UTC):

1. 20:51 the RD `moveprobe-dst-local` (`restore-once`, empty series) finished `Successful` and published `latestImage volsync-moveprobe-dst-local-dest-20260923205102`. The populator created `vs-prime-…` from it. `VolumeSnapshot` was `readyToUse: true`.
2. The prime PVC never bound: `ProvisioningFailed … failed to verify data source: snapshot snapshot-6a0d5a8e-… is not ready to use` (x2) then `snapshot.longhorn.io "snapshot-6a0d5a8e-…" not found` (404). The HelmRelease timed out (`Helm install failed … Deployment InProgress`). 27+ min stalled (over the plan's 30-min time-box guardrail 10 → recorded).
3. Longhorn side: the VolumeSnapshotContent handle `snap://pvc-29f9c7ff…/snapshot-6a0d5a8e-…` had **no Longhorn snapshot CR**; the dest volume held only an unready system snapshot (`readyToUse=false`, `markRemoved=true`, `userCreated=false`). The dest volume was `detached`.
4. Remedy 1 (runbook §3A.5): `kn` patch RD `manual: restore-2` → new snapshot; the populator did **not** re-prime by itself; deleting the `vs-prime` PVC (`kn`) made it re-prime and it bound in ~11 s.
5. The bound app volume then failed its own clone: `cloneStatus.state: failed, attemptCount: 1` (never retried), pod `FailedAttachVolume … volume request cloning data but has not finished copying data`. Longhorn event: `VolumeCloneFailed … cannot find snapshot snapshot-789377ef-… in the source replica` — i.e. **again the snapshot the (then-latest) VolumeSnapshot points at did not exist on the replica**, same as step 3. Between steps 4 and 5 Flux had reverted `spec.trigger.manual` from `restore-2` back to `restore-once` (observed: spec read back as `restore-once`, and a third image `…212102` appeared 3 min after my patch), so that RD ran a third time; the clone used that third image's snapshot. Of the RD runs, images 1 and 3 (`…205102`, `…212102`) had **no** snapshot on the Longhorn side when cloned; images 2, 4, 5 (`…211837`, `…213444`, `…213644`) — the latter two checked explicitly — had a real `readyToUse=true` snapshot. What distinguishes them is **not established**.
6. Remedy 2 (bounded, all via `kn`/`flux` on `moveprobe`): `flux suspend ks/hr`, scale 0; `kn` patch RD `restore-3`; resume ks (Flux reverted to `restore-once` → one more run, then stable, `lastManualSync == spec.manual`); **verified the Longhorn snapshot behind the final `latestImage` exists and is `readyToUse=true`** (`snapshot-ea87d958-…`); `kn delete pvc moveprobe` (PV `Delete` ⇒ the wedged PV/Longhorn volume `pvc-dd48a365…` were removed — confirmed gone); reconcile; `flux resume hr` (WaitForFirstConsumer needs the pod) → PVC `Bound` (`pvc-b9b2a1d3-c67d-499f-9ffa-584f64ab3550`) in 69 s, pod Running in 47 s.
7. During the wedge both RS ran against the unfinished volume: `latestMoverStatus` = `== Directory is empty skipping backup === … OPERATION_RESULT: FAILURE` with `result: Successful` — **runbook trap 4 reproduced live** (green status, no snapshot; no bogus series was written).

Takeaways for the runbook: (a) the **B5b free restore drill and the `ai` RD's `restore-once`** are exposed to exactly this Longhorn behaviour; before trusting a populator/RD result, check that the Longhorn snapshot behind `latestImage` exists (`kubectl -n longhorn-system get snapshots.longhorn.io snapshot-<uid>`) — `VolumeSnapshot readyToUse: true` is not proof; (b) **a hand-patched `spec.trigger.manual` on a Flux-managed RD is reverted by Flux (observed), which re-runs the restore and replaces `latestImage`** — so a manual RD retrigger is not stable until `spec.manual == lastManualSync` again; wait for that before re-priming. (c) The Longhorn root cause of the original missing snapshot (step 3) was **not established**; it is not tied to anything the rehearsal did (fixtures mirror hermes).

### SURPRISE B-2: guards sharp edge — `app_pv` caches the first PV forever
`app_pv` records the app PV once in `rehearsal-state/app-pv-moveprobe.txt`. A block I ran while the first (later wedged) PVC was bound cached `pvc-dd48a365…`; after I deleted/re-provisioned the PVC, `app_pv` kept returning the deleted PV and `rehearsal_pv_ok` answered `gone:` (exit 0) — i.e. the guard would have protected/patched the **wrong (nonexistent)** PV while the live one was unrecorded. I removed my own state file (`rm rehearsal-state/app-pv-moveprobe.txt`, not the guards) and re-recorded; `rehearsal_pv_ok` → `ok pvc-b9b2a1d3-… (claim ns=[rehearsal-old])`. Anything that re-provisions the app PVC (S2 orphan recovery does **not**, but a populator retry does) needs that reset. The stale name stays in `rehearsal-pvs.txt`; teardown `pv_delete` handles `gone:`.

Baseline hermes recheck: `develop/hermes` pod `hermes-6f54b89c46-4jzdl` 1/1 Running; PV `pvc-12f54114-…` `Delete`/`Bound`/`hermes`; `hermes-local` last sync `2026-09-23T21:25:42Z` Successful (hourly `:23` run, unrelated); **163** Kustomizations (161 + `rehearsal-apps` + `moveprobe`), notReady 0.

Slot check: the moveprobe `-local` schedule is `47 * * * *` (`nextSyncTime` 21:47), `-r2` `45 6 * * *`.

## Scenario 7 — deliberate name-targeted patch: the gate fires (Known untested #13; validates R-1)

**Result: PASS.** Local only: scratch repo (`git archive` of `rehearsal-move` → `git init`, **no remote**, so `PUSH` was impossible; `R` re-pointed at it after sourcing the guards; nothing committed/pushed in the real worktree — `rehearsal-move` HEAD still `d7ff4cc2`, remote `d7ff4cc2`).

| Step | Command | Observed |
| --- | --- | --- |
| baseline layout | `move_gate rehearsal-old 0` | `parent children: 1` … `GATE PASS` |
| moved layout, **name**-targeted patches (`target: {kind: PersistentVolumeClaim, name: moveprobe}`, `{kind: ReplicationDestination, name: moveprobe-dst-local}`) | `move_gate rehearsal-new 2` | `GATE FAIL: 0 volumeName/sourceNamespace lines, want 2` … `GATE FAIL — DO NOT PUSH` |
| same move, **kind**-targeted patches | `move_gate rehearsal-new 2` | `117: volumeName: pvc-b9b2a1d3-c67d-499f-9ffa-584f64ab3550`, `278: sourceNamespace: rehearsal-old`, `parent children: 1 / rehearsal-new moveprobe ./kubernetes/rehearsal/rehearsal-new/moveprobe/app rehearsal-new`, `GATE PASS` |

Confirms trap 5 / [R-1] with the **local** flux 2.9.5 build: name targets are silently dropped, kind targets render both lines. (Whether the in-cluster kustomize-controller matches is closed by B5b's live `requestedIdentity` check in S1 / S2.)
Hermes baseline recheck: unchanged (read-only scenario; nothing touched the cluster).

## Scenario 2 — same move WITHOUT resuming the old ks: orphan behaviour (Known untested #6 orphan half; [R-2], traps 6/7)

**Result: PASS (orphan reproduced exactly as the source reading predicted; recovery by hand worked; data intact).** Commits `f4f11a18` (move), `0ec1d610` (start in NEW). Both via `COMMIT` → `move_gate rehearsal-new 2` (`GATE PASS`) → `PUSH`.

Commands (guards-sourced): `pv_patch "$PV" … Retain`; `flux suspend ks/hr moveprobe -n rehearsal-old`; `kn … scale deploy/moveprobe --replicas=0` + `wait --for=delete pod`; Step E (`stepE.sh rehearsal-old rehearsal-new "$PV" rehearsal-old`, a scripted `git mv` + sed edits; note the script's first `grep` matched the fixture's *comment* naming `moveprobe/ks.yaml` and so skipped adding the resource line — caught before commit and fixed by hand; the gate would also have failed it); Step C (commit/gate/push); observe; recover.

**Observed after the parent reconciled (the wrong runbook):**
- `kn rehearsal-old get ks moveprobe` → `Error from server (NotFound): kustomizations.kustomize.toolkit.fluxcd.io "moveprobe" not found` — the child Kustomization object was pruned by the parent.
- **All 13 listed old objects still existed, every one `del=null`**: PVC `moveprobe` + 4 volsync helper PVCs, HelmRelease, RS ×2, RD, ExternalSecret ×2, OCIRepository, Deployment (`ownerKs=moveprobe` label still on the Flux-applied ones). HR `spec.suspend=true`. PV `pvc-b9b2a1d3-…` `Bound` to `rehearsal-old/moveprobe`, `Retain`. **This confirms R-2 / trap 6 (a suspended Kustomization that is deleted orphans everything; the old PVC never goes away, the PV never becomes Released) with live objects, not only source.** No `deletionTimestamp` on anything → not a slow prune.
- The orphaned old RS kept its schedule (an orphaned RS keeps backing up `moveprobe@rehearsal-old` — for hermes, the old `hermes-local` would keep syncing from the idle old PVC until deleted).
- NEW namespace: ks `moveprobe` Ready, HR `Helm install succeeded … rehearsal-new/moveprobe.v1` (fresh **v1**, confirms §6.3 "release restarts at v1"), NEW PVC `Pending` **with `volumeName` set** and event `FailedBinding … volume "pvc-b9b2a1d3-…" already bound to a different claim`. **Known untested #1 (first half, live): SSA accepted the initial add of `volumeName` on a PVC whose `dataSourceRef` the component owns.** `--show-managed-fields`: `kustomize-controller (Apply)` owns `f:accessModes, f:dataSourceRef, f:resources, f:storageClassName, f:volumeName`.
- **Live proof the patches reached the objects (Known untested #13 / R-1 in-cluster):** NEW RD `spec.kopia.sourceIdentity.sourceNamespace: rehearsal-old`, `status.kopia.requestedIdentity: moveprobe@rehearsal-old`, restore `Successful`, `lastManualSync: restore-once`. So the in-cluster kustomize-controller honours kind-targeted patches exactly as the local build.

**Recovery (per plan):** deleted the old RS/RD/ExternalSecrets/OCIRepository/HelmRelease (suspended ⇒ no uninstall). **Orphans left by the suspended HR (trap 7 / R-12, live):** `deployment.apps/moveprobe`, `serviceaccount/moveprobe`, `secret/sh.helm.release.v1.moveprobe.v5 … v9` (**no Service** — the fixture has none; helm history was 5–9 because of the baseline retries). Deleted them by label/name; no pod referenced the PVC; `kn delete pvc moveprobe` → PV `Released` (`wait_pv_phase`) → `pv_repoint "$PV" rehearsal-new moveprobe` → NEW PVC `Bound` **(~9 s after the re-point; Known untested #2/#3: a Pending pre-bound PVC waiting on a PV that is still Bound elsewhere binds cleanly once the PV is freed and the claimRef re-pointed with `uid/resourceVersion: null`)**; `VolSyncPopulator*` events on the claim: 0.
- `data_check rehearsal-new` (app at 0): `marker.txt: OK`, `blob.bin: OK`, `starts=1` — bytes identical, retained PV, not a restore. `kn get deploy` → `replicas=0 strategy=Recreate`, no pod: **`controllers.moveprobe.replicas: 0` is honoured by app-template with `Recreate` (Known untested #8, first half).**
- Exit step: removed `replicas: 0` (`0ec1d610`, gate PASS), pod Running, `data_check`: sha OK, **`starts=2`** (the second `start` line at 21:46:41, first at 21:38:59).
- After recovery `rehearsal-old` holds only `cluster-settings`/`cluster-secrets`/`default` SA. `inventory_ok` ok, `others_ready` ok throughout.

Side observation (superseded by S10a below, which corrects it): at the S2 setup the baseline's `manual: seed-1` was still on both RS, but that was only ~4 min after the patch (patch ~21:40, look at ~21:44), i.e. before the ks's next 5-min reconcile; I first mis-described this as "persisted ~25 min". S10a shows Flux **does** revert a hand-set `manual` within one ks interval. `--show-managed-fields` at that moment: `kustomize-controller (Apply)` owns `f:trigger.f:schedule`, `kubectl-patch (Update)` owns `f:manual`.
The RD is likewise reverted (B-1: `restore-2` → `restore-once`).
Plan issue: the plan's `managedFields` queries (S4, S10b) omit `--show-managed-fields`; without it `kubectl get -o json` returns null `managedFields` and the `jq` aborts.

Hermes recheck after S2: `develop/hermes` 1/1 Running (`hermes-6f54b89c46-4jzdl`); PV `pvc-12f54114-…` `Delete`/`Bound`; `hermes-local` `2026-09-23T21:25:42Z` Successful; 163 ks, notReady 0.

## Scenario 3 — rollback by forward commit + claimRef re-point (Known untested #4; [R-6], runbook §5)

**Result: PASS (the §5 "B8–B9" rollback works as written: retained PV, not a kopia restore; post-move writes preserved).** Commits `3a758aa7` (move back, `move_gate rehearsal-old 1` = `GATE PASS`, `volumeName` only) and `3f1daed2` (start in OLD, gate `1` PASS). Start state: app running in NEW (`starts=2`, one line written in NEW).

- **3A quiesce (NEW):** `pv Retain` (ok); `flux suspend hr`; `scale 0`; pod gone; no pod referenced the PVC; `flux resume ks`. Read back: **`HR suspend=true`, Deployment `replicas=0`, ks `suspend=[]`** — the resumed ks did **not** strip the CLI-set `spec.suspend` nor scale the Deployment (**B4b inference confirmed live; Known untested #6 CLOSED**: SSA by kustomize-controller leaves the field owned by the flux CLI alone).
- **3B/3C:** the forward commit put the app in OLD; the NEW ks (resumed) pruned the NEW PVC → PV `Released` (`claimRef` still `rehearsal-new/moveprobe`); OLD's fresh ks/HR (`Helm install succeeded … rehearsal-old/moveprobe.v1`, i.e. release history really restarts at v1) and pre-bound claim `Pending` with `FailedBinding … already bound to a different claim`; `wait_pv_phase Released`; `pv_repoint "$PV" rehearsal-old moveprobe` → claim `Bound` within ~10 s. **Known untested #3 CLOSED (re-point with `uid/resourceVersion: null` binds a Released PV) and #4 rollback-after-B8 CLOSED for this fixture size.**
- `data_check rehearsal-old` (app at 0): `marker.txt: OK`, `blob.bin: OK`, **`starts=2` including the line written while the app ran in NEW** (`21:46:41`) — this is the crux: the retained PV came back, not a restore from the older `moveprobe@rehearsal-old` snapshot (which lacks that line).
- VolSyncPopulator events on the new OLD claim after its creation (21:48:49Z): **0**. **Plan defect:** the plan's `kn get events --field-selector involvedObject.name=$APP | grep -c VolSyncPopulator` also counts events of *previous incarnations* of a same-named claim (Events outlive objects ~1h; I got 6, all from 20:50–21:45). Filter by `lastTimestamp` (or the claim's UID) as done here.
- **3D NEW orphans (trap 7 / R-12, second live sample):** the suspended NEW HelmRelease was pruned with no uninstall, leaving `deployment.apps/moveprobe`, `serviceaccount/moveprobe`, `secret/sh.helm.release.v1.moveprobe.v1`, `…v2`. Cleaned (label/name); assert-empty passed (`NEW clean`; only `cluster-secrets`/`default` SA remain).
- **3D′ exit:** removed `replicas: 0` (gate PASS), pod Running, `data_check`: sha OK, **`starts=3`**, `HR suspend=false replicas=1`.
- `inventory_ok`/`others_ready` ok after every push. 3b (plain `git revert`) **SKIPPED** (optional; burns a move cycle) — [R-6] stays source-reading only.

Hermes recheck after S3: `develop/hermes` 1/1 Running; PV `Delete`/`Bound`; `hermes-local` `2026-09-23T21:25:42Z` Successful; 163 ks, notReady 0.

## Scenario 1 — full runbook B0–B11 incl. pre-merge gate (Known untested #1, #7, #8, #9, #10, #11, #12; embeds 4, 5, 6, 9, 10)

**Result: PASS end-to-end** (the runbook procedure, run verbatim with the guards, moved `moveprobe` `rehearsal-old → rehearsal-new` with the bytes intact and a correct new kopia identity). Commits: `c037f1bb` (move, gate `2`), `dbcd4681` (start), `0fd2f2c6` (capacity 2Gi), `6fb2c3a6`/`66d0fcef` (4c, see S4). Precondition (from S3D′) met: app running in OLD, `replicas: 1`, NEW clean.

| Step | Command / observation | Verdict |
| --- | --- | --- |
| B0 | `PV=pvc-b9b2a1d3-…`, `SC=longhorn-1-replica-local`, cap 1Gi, RS `-local` last `21:51:51Z`; baseline listing as **uid 0** (`ro_run`): `SHA256SUMS, blob.bin, marker.txt, starts.log` + `ls -ln` (`10000:10000`, mode 644; `lost+found 0:10000`) saved to `rehearsal-state/baseline.txt` | ok |
| S10a | see S10 | CONFIRMS R-4 |
| B1 | `flux suspend ks/hr`, scale 0, pod gone, **no pod references the PVC** (empty) | ok |
| B3 | see S10b. In-flight `lastSyncStartTime` `[]` on both; `T0=22:57:20Z`, `TAG=pre-move-1790204240`; both RS `lastManualSync == TAG`, `lastSyncTime` 22:58:19Z / 22:59:09Z `> T0`; `check_backup`: `Created snapshot: 1, Setting policy moveprobe@rehearsal-old: 1, RESULT SUCCESS: 1, Directory is empty: 0` **for both**; `B3 ACCEPTED` | PASS |
| B4 / B4b | PV `Retain` (already, from S2 — patch printed `patched (no change)`); `flux resume ks` → **HR `suspend=true`, Deployment `replicas=0`, ks `suspend=[]`** (Known untested #6 CLOSED, 2nd sample) | PASS |
| B5 | Step E + `COMMIT` + `move_gate rehearsal-new 2` = `118: volumeName: pvc-b9b2a1d3-…`, `279: sourceNamespace: rehearsal-old`, `parent children: 1 … GATE PASS` → `PUSH` (23:00:08) | PASS |
| B5b | NEW RD: `requestedIdentity: moveprobe@rehearsal-old`, `sourceNamespace: rehearsal-old`, restore `Successful` (log: `INFO: Snapshot restore completed successfully`, 45 s); NEW PVC `.spec.volumeName == $PV` | PASS (in-cluster proof of the kind-targeted patches) |
| B5b drill | `ro_run` (uid 0) on `volsync-moveprobe-dst-local-dest`: `sha256sum` list **IDENTICAL to `baseline-sums`** (incl. `starts.log`, `SHA256SUMS`, `blob.bin`, `marker.txt`) — the real end-to-end restore of the B3 snapshot. `ls -ln` recorded separately: `-rw-rw-r-- 0 0` (root:root, **mode 664 vs 644 in the original**), `lost+found 0:0` — **[S-priv] confirmed for an unannotated namespace** (the fixture files were `10000:10000`) | PASS; ownership SURPRISE (mode also differs, 644→664) |
| B5b dest-PVC delete (Known untested #11) | `kn delete pvc volsync-moveprobe-dst-local-dest` (drill Job already gone) → RD `manual: restore-2` → **VolSync recreated the dest PVC** (new volume `pvc-795c8f26…`, bound in ≤31 s) and the restore was `Successful`, new `latestImage`. **CLOSED: deleting the dest PVC is tolerated; it is recreated on the next trigger.** | PASS |
| B6 | `wait_pv_phase Released`; OLD PVC NotFound; Pending claims cluster-wide: only `rehearsal-new/moveprobe` (see defect below); `pv_repoint` at 23:03:22 → PV `Released → Available (reserved for rehearsal-new/moveprobe) → Bound` at 23:03:34 (**12 s**); 0 `VolSyncPopulator*` events on the NEW claim | PASS |
| B7 | `data_check rehearsal-new` (pod at 0): `marker.txt: OK`, `blob.bin: OK`, `starts=3` (== baseline) | PASS |
| B8 | pre: `replicas=0 strategy=Recreate`, no pod. Commit `dbcd4681` (gate `2` PASS), `wait_running`, `data_check`: sha OK, **`starts=4`** (new line `23:05:37`) | PASS (**Known untested #8 CLOSED**: `replicas: 0` + `Recreate` honoured, then removed cleanly) |
| S4 | see below | PASS + 4c observed |
| B9 | trigger `b9-1790204847` (both RS), `check_backup … moveprobe@rehearsal-new`: `Created snapshot: 1, Setting policy moveprobe@rehearsal-new: 1, RESULT SUCCESS: 1, Directory is empty: 0` **both**. **The new series is `moveprobe@rehearsal-new` — [S-d] confirmed under Flux.** Caveat/finding: both RS were **already 7 min into a creation-time first sync** (`lastSyncStartTime 23:00:18Z`, stalled while the claim was Pending); that older sync completed 23:08:32Z/23:08:48Z (`lastSyncDuration 8m14s`/`8m30s`) and stamped my `b9-…` tag — **second live R-4 sample** (a manual trigger is satisfied by an already-running sync). | PASS (with R-4 finding) |
| S6 | see below | kubernetesStatus PASS; locality CLOSED |
| B10 | `pv_patch Delete` on the **Bound** PV: accepted, read back `{"reclaim":"Delete","phase":"Bound","claim":{"namespace":"rehearsal-new","name":"moveprobe"}}`, PVC still `Bound` | PASS (S9 first half; **Known untested #11 first half CLOSED**) |
| B11 | evidence in OLD: `deployment.apps/moveprobe`, `serviceaccount/moveprobe`, `secret/sh.helm.release.v1.moveprobe.v1`, `…v2`; RD/RS-owned PVCs/snapshots already GC'd; cleaned; assert-empty passed (`OLD clean`: only `cluster-secrets`, `cluster-settings`, `default` SA, `kube-root-ca.crt`) | PASS (R-8/R-12 confirmed) |

`inventory_ok` and `others_ready` were ok after **every** push; `watch_stop_all` after B6.

### Scenario 5 (B6 ordering) — result: SURPRISE (the runbook's feared order did not occur here; the "PVC first" order is covered by S2)
- Watcher logs (`rehearsal-state/pvc-old.log`, `pv.log`, timestamps UTC): OLD PVC `Bound` until **23:00:04**, `Terminating` at **23:00:12**; PV `Bound → Released` at **23:00:12**. NEW ks created **23:00:11**; **NEW PVC `creationTimestamp` 23:00:18** — ~6 s *after* the PV was already `Released` (`FailedBinding … already bound to a different claim`, because `claimRef` still named the OLD claim/uid). So in the actual move the NEW claim is created *after* the OLD one is pruned; it then sat `Pending` for 3 min 16 s until the re-point at 23:03:22 and was `Bound` at 23:03:34.
- **Plan defect:** the `pvc-new` watcher (`kubectl get pvc moveprobe -w`) exited at once with `NotFound` because the object did not exist yet, so it captured nothing. Use a watch on the whole namespace (`get pvc -w` with no name) or poll timestamps as done here.
- The **"PVC created while the PV is still Bound to the old claim"** order (the runbook's Known untested #2 wording) *was* exercised in **S2**: NEW PVC `Pending` (with `volumeName`) for ~1.5 min while the OLD PVC was still `Bound`, bound after `delete OLD pvc` → `Released` → `pv_repoint`. Both orders bind cleanly via the re-point. **5b (delete + recreate the NEW claim) was not needed** (no stall).

### Scenario 4 — SSA ownership of `volumeName` (Known untested #1)
Longhorn manager `v1.12.1`. **PASS.**
- Ownership (`--show-managed-fields`): `kustomize-controller (Apply)` owns `f:accessModes, f:dataSourceRef, f:resources, f:storageClassName, f:volumeName`; `snapshot-controller` and `kube-controller-manager` (Updates) own no spec fields.
- Two forced `flux reconcile ks moveprobe --with-source`: ks stays `Ready`, `Applied revision …@dbcd4681`; UIDs of `pvc/moveprobe`, RD, RS ×2, dest PVC recorded before.
- Spec change `VOLSYNC_CAPACITY 1Gi → 2Gi` (`0fd2f2c6`, gate `2` PASS): ks Ready `Applied revision …@0fd2f2c6`; **`status.capacity` reached 2Gi in ≈28 s with the pod running (online expansion), `restartCount` 0** (pod name unchanged); `pv … cap=2Gi`; Longhorn `spec.size 2147483648`; RS `kopia.capacity=2Gi`, RD `capacity=2Gi`; `volumeName` unchanged. **UID diff: identical — nothing was recreated** (PVC, RD, both RS, dest PVC). The RD *dest* PVC stays `1Gi` (RD capacity changes only affect a new dest).
- **4c (done, sanctioned exception: pushed without `move_gate` — gate correctly `GATE FAIL — DO NOT PUSH`):** commit `6fb2c3a6` dropped the PVC `volumeName` patch (RD patch kept). ks → **`Ready=False`**, message verbatim: `PersistentVolumeClaim/rehearsal-new/moveprobe dry-run failed (Invalid): PersistentVolumeClaim "moveprobe" is invalid: spec: Forbidden: spec is immutable after creation except resources.requests and volumeAttributesClassName for bound claims` with a diff `-  "VolumeName": "pvc-b9b2a1d3-…"` / `+  "VolumeName": ""`. **Trap 12 CONFIRMED (observed, not inferred): removing the patch later stalls the Kustomization; the failure is at the *dry-run*, so nothing else in that ks is applied; the live PVC stayed `Bound`, PV untouched.** (`force` is not set on the child ks; with `force: true` this would be a delete/recreate — do not add it.) Reverted with `66d0fcef` (patch restored, gate `2` PASS) → ks `Ready` again.

### Scenario 6 — Longhorn `kubernetesStatus` + locality after the rebind
**PASS on both rows.**
- **`kubernetesStatus`**: `namespace=rehearsal-new`, `pvcName=moveprobe`, workload `moveprobe-6d55df6b68-v6vr9 Running` — read after the rebind and B9 (Known untested #5 part 1 **CLOSED**: it *does* update to the new namespace/PVC after the re-point; in the smoke test it had not been re-read after a rebind).
- **Locality (`dataLocality: best-effort`, 1 replica): CLOSED per the pre-stated criteria.** Before: pod on `brokkr02` (S1 baseline `data_check`/`ro_run` pins). After the B8 start the pod was on **`brokkr03`** and the single replica was **created at 23:05:35Z on `brokkr03`** — 5 s after the volume attached there (`brokkr02 → brokkr03`, i.e. a different brokkr node, replica rebuilt on the pod's node within seconds, tiny data). Then `kn delete pod moveprobe`: pod rescheduled `brokkr03 → brokkr02`, a replica appeared on `brokkr02` (`23:10:27Z`) next to the `brokkr03` one, and ~3 min later only `brokkr02@23:10:27Z` remained (surplus trimmed). `kubernetesStatus` kept `rehearsal-new/moveprobe`. Caveat: 1 MiB of data; a 570 MB hermes rebuild will take longer; the Pi workers (`jormungandr*`, 0 Longhorn disks) can never hold a replica, so a pod landing there always reads remotely.

### Scenario 9 (`Delete` on a bound PV) — first half PASS (B10, above). Effect proof at teardown (below).

### Scenario 10 — schedule → manual → schedule; in-flight `lastManualSync` race (Known untested #7, #12)
**10a — deterministic in-flight race: PASS, R-4 CONFIRMED on the deployed `perfectra1n` fork (Known untested #12 CLOSED).** Started at 22:44; minute 46 reached 22:46:03; **caught the scheduled sync in flight** (`lastSyncStartTime=2026-09-23T22:47:00Z`, seen at 22:47:01); patched `manual: race-1790203621` at 22:47:01 (`T1`). Poll log (`rehearsal-state/s10a-poll.log`, 48 samples / 8 min):
- `SyncInProgress` ×5 (22:47:09 → ~22:47:53): the **scheduled** sync finished at **22:47:53Z** (`lastSyncTime`); at the next poll `lastManualSync == race-1790203621` — **stamped by the sync that was already running when I patched**, i.e. the "did my manual run finish" loop would have passed on a scheduled sync. `lastSyncTime 22:47:53 > T1 22:47:01`: a bare `lastSyncTime > T0` test also passes on a sync that *started before* the patch — only the runbook's **"no sync in flight" gate** discriminates.
- **No second sync started** (`lastSyncStartTime` empty in every later poll): the manual trigger was consumed by the in-flight sync; nothing ran for it.
- Reason went `SyncInProgress → WaitingForManual` (19 samples, 22:48:00–~22:51:20) `→ WaitingForSchedule` (24): **with `manual` present the RS reports `WaitingForManual`, not the schedule (upstream manual-over-schedule precedence holds on the fork)**. The flip to `WaitingForSchedule` coincided with **Flux's next ks reconcile (22:51:05: `ReplicationSource/rehearsal-old/moveprobe-local configured`)**, after which `.spec.trigger == {"schedule":"47 * * * *"}` and `managedFields` no longer listed `kubectl-patch`/`f:manual`. So **the 10a→10b "cleanup" (`remove /spec/trigger/manual`) was unnecessary — Flux had already removed it** (correcting my earlier S2 note).
- Not observed: whether the *next* `:47` fires after `manual` is removed (23:47 falls after the OLD RS was pruned in this run). Evidence short of it: `WaitingForSchedule`, `nextSyncTime 2026-09-23T23:47:00Z` were set immediately after Flux removed `manual`; and the scheduled `22:47` sync itself proves the schedule fires when `manual` is absent.
- Second sample of the same trap: the B9 in-flight creation sync above.

**10b — schedule → manual → schedule inside B3/B4b: PASS.** Before B3 `.spec.trigger == {"schedule":"47 * * * *"}` (clean). After the B3 patch: **both keys present** — `{"manual":"pre-move-1790204240","schedule":"47 * * * *"}` — the schedule is *not* removed by a merge patch. `managedFields` before the resume: `kustomize-controller (Apply)` → `f:schedule`; `kubectl-patch (Update)` → `f:manual`. **`flux resume ks` (B4b) reverted it immediately**: `trigger right after resume: {"schedule":"47 * * * *"}` (t=22:59:31), `kubectl-patch` gone from `managedFields`, RS reason `WaitingForSchedule`, `nextSyncTime` set; `-r2` likewise. **Known untested #7 CLOSED: the RS returns to its schedule at the B4b resume** (this is exactly why B1 suspends the ks: a resumed/running ks reverts a hand-set `manual` within one interval, ≤5 min, or immediately on resume). In the hermes move the old RS is pruned at B5 anyway.

**Plan/runbook defects found while running S1** (all fail closed, none harmful):
1. `kubectl get pvc -A --field-selector=status.phase=Pending` (plan B6/S8 pre-check; **runbook Preconditions and B6**) is rejected by the API server (`"status.phase" is not a known field selector`). Use `kubectl get pvc -A -o json | jq '.items[]|select(.status.phase=="Pending")…'`.
2. S4 `managedFields` queries need `--show-managed-fields`.
3. The `pvc-new` watcher on a not-yet-existing name exits immediately.
4. `kn … get events --field-selector involvedObject.name=$APP | grep -c VolSyncPopulator` counts stale events from previous incarnations of the same name; filter by timestamp/UID.
5. The B6 Pending-claims listing: before the re-point the only Pending claim in the whole cluster was `rehearsal-new/moveprobe` (good sign for the hermes move: nothing competes for the PV).

Hermes recheck after S1: `develop/hermes` 1/1 Running (`hermes-6f54b89c46-4jzdl`); PV `pvc-12f54114-…` `Delete`/`Bound`/`hermes`; `hermes-local` `2026-09-23T22:24:32Z` Successful; 163 ks, notReady 0.

## Scenario 8 — claimRef re-point binding a Released PV, with a competing claim (Known untested #3; [R-5])

**Result: PASS. R-5 hazard CONFIRMED live; the re-point is the correct fix.** Block-mode bait/thief/wanted via the `s8_*` helpers (uid-0 `volumeDevices`/`dd` Jobs); no `Filesystem` claim could match the bait. Pre-check: nothing `Pending` cluster-wide and 0 Block claims existed.

- **Block-mode provisioning on `longhorn-1-replica-local` works** (N10 / open item 4 resolved): bait PV `pvc-f2c6c824-…` (`volumeMode: Block`, SC Delete → set `Retain`), writer Job printed `bait-marker-1234`; PSA `baseline` admitted the uid-0 Jobs (only a "would violate restricted" warning).
- **Step 2 (removal-only, the R-5 hazard):** `Released` bait → `pv_patch … remove /spec/claimRef` (23:19:33) and, in the same command, `thief` PVC in `rehearsal-new` + reader Job. **`thief` bound the bait** (`thief bound to: pvc-f2c6c824-… (== BAIT ⇒ R-5 hazard confirmed)`) and its reader printed `bait-marker-1234`; PV `Bound` to `rehearsal-new/thief`. **Any matching claim takes a claimRef-less PV, with the previous owner's data.**
- **Step 3 (reset):** deleted the thief Job/PVC; PV `Released`; `pv_repoint "$BAIT" rehearsal-new wanted` → PV `Available`, `claimRef: rehearsal-new/wanted` (reserved).
- **Step 4 (re-point test):** both `wanted` and `thief` claims created together with reader Jobs: **`wanted → pvc-f2c6c824-…` (the bait), marker read back; `thief → pvc-d08f67fc-…` (its own freshly provisioned volume, blank reader output).** PV `Bound` to `rehearsal-new/wanted`. So a reserved `claimRef` (`uid/resourceVersion: null`) blocks a competing claim and binds the intended one when both compete at once (**Known untested #3 fully CLOSED** across S2/S3/S1/S8).
- **Cleanup:** Jobs and both PVCs deleted; `pv_delete` on the bait (guard accepted the Released/`Retain` PV; deleted the PV then the Longhorn volume); the thief's PV/volume (`Delete` SC) went away with its PVC (verified gone). `kubectl get pv -l rehearsal=move` shows **no claimRef-less PV**. `others_ready` unaffected.
- Plan notes: the guards helper `record_pv` labels only the bait; the thief's PV is never in `rehearsal-pvs.txt` (it is `Delete`-class and is gone; teardown's `adopt_pv` would catch any that stayed by claimRef).

Hermes recheck after S8: see final baseline table.

## Teardown (plan §8) and verification

**Result: PASS — everything removed, hermes untouched.** Blocks T1–T5 each ran < 10 min.

- **T1** `watch_stop_all`; `adopt_pv` picked up the volsync helper PVs (claimRef `rehearsal-*`); `flux resume ks/hr --all` in both namespaces; every recorded PV set to `Delete` (`patched (no change)`; the deleted stale/bait entries answered `NotFound`, tolerated).
- **T2** `kubectl delete ks rehearsal-apps --wait=false` → parent gone in 11 s (23:22:37); both child ks gone; the NEW PVC (held by `pvc-protection` until the pod exited) finalised at 23:23:00.
  **Scenario 9 effect proof: PASS.** With the app PV patched `Retain → Delete` on the *bound* PV (B10), deleting the PVC removed **both the PV and the Longhorn volume `pvc-b9b2a1d3-…` within ~19 s** (`S9 EFFECT: PV and Longhorn volume both gone at 23:23:19`). Confirms trap 2 / [S-ret] under Flux prune (a `Delete` PV + prune = instant loss) and that B10's patch is what re-arms it. Then `kubectl delete gitrepository rehearsal`.
- **T3** `kubectl delete ns rehearsal-old rehearsal-new` → both gone by 23:23:47 (helper Jobs, `cluster-settings`/`cluster-secrets` copies went with them).
- **T4** guarded `pv_delete` over the recorded list (all already gone); `am_unsilence`: three silences expired.
- **T5** `git push origin --delete rehearsal-move` (explicit ref, the plan's only other remote write), worktree removed, local branch `rehearsal-move` deleted (was `66d0fcef`; the 10 fixture commits are unreachable after gc).
- **Verification block (all as required):** `ns: none`; `flux objects: none`; no PV with a `rehearsal-*` claimRef or `rehearsal=move` label; all 7 recorded PVs and their Longhorn volumes NotFound; no Longhorn volume / VolumeSnapshotContent / VolumeSnapshot for a `rehearsal-*` namespace; `others_ready` → all other ks Ready; `git ls-remote --heads origin rehearsal-move` empty; worktree/branch none; `silences.txt` 0 bytes; no watcher pid files.
- **Hermes final:** `develop/hermes` pod `hermes-6f54b89c46-4jzdl` 1/1 Running (age 6h15m, never restarted); PV `pvc-12f54114-9e99-442b-bae4-53a9cb239d69` `Delete`/`Bound`/claim `hermes`; PVC `develop/hermes` `Bound`; `hermes-local` last sync `2026-09-23T23:24:28Z` Successful (hourly `:23` run); **161 Kustomizations, all Ready** (the two scratch ks are gone). No hermes/`develop`/`ai` object changed at any point; `others_ready` and `inventory_ok` never failed.

**Residue teardown cannot remove:** kopia series `moveprobe@rehearsal-old` and `moveprobe@rehearsal-new` in the shared local (Garage) **and** R2 repositories (a handful of tiny snapshots each: seed-1, S10a-window syncs, B3 `pre-move`, B9). Needs a kopia client. **A re-run must use `APP=moveprobe2`.** The guards file and `rehearsal-state/` (`baseline.txt`, `drill.txt`, `s10a-poll.log`, watcher logs, `rehearsal-pvs.txt`) stay outside every repo; delete by hand when fully closed.
Cluster state left behind: none beyond the residue above. Bot-authored commits on `rehearsal-move` used the guards' hard-coded `Claude-Session` trailer (`session_011n8fwmnSb2pwCXEpoykL42`).

## Runbook corrections

Legend: **CONFIRMED** = observed here; **CONTRADICTED** = the runbook is wrong/incomplete; **OPEN** = not closed by this rehearsal.

### Known untested (runbook "Known untested" 1–13)

| # | Runbook item | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | SSA ownership of `volumeName` under real Flux | **CONFIRMED** (and trap 12 CONFIRMED) | S2/S1: initial add accepted on a pre-bound claim whose `dataSourceRef` the component owns; `kustomize-controller (Apply)` owns `f:volumeName`+`f:dataSourceRef`; kept across 2 forced reconciles and a spec change (2Gi, online, UIDs unchanged); **4c**: removing the patch → ks `Ready=False`, `spec is immutable after creation…`, PVC untouched |
| 2 | B6 ordering (PVC created before PV freed) | **CONFIRMED (both orders bind)** | S2: NEW claim `Pending` while OLD still Bound, bound after delete + re-point. S1: the NEW claim was created ~6 s *after* the PV went `Released` (`FailedBinding`, claimRef still the OLD claim), `Pending` 3m16s, `Bound` 12 s after re-point |
| 3 | claimRef re-point (`uid/resourceVersion: null`) binding a Released PV | **CONFIRMED** | S2, S3, S1, S8 (PV goes `Released → Available (reserved) → Bound`); S8 with a competing claim: only the reserved claim binds |
| 4 | Every rollback path (§5) | **PARTIALLY CONFIRMED / OPEN** | S3: the **B8–B9 row** (quiesce, forward commit with `volumeName` only, re-point) works and preserves post-move writes. S2 exercised the "B5 merged, before B6" state (orphan case). **OPEN:** `git revert` (R-6) not run (3b skipped, would consume the S9 PV); "B6–B7", "after B10" rows and approach A not run |
| 5 | Longhorn `kubernetesStatus` and `dataLocality: best-effort` | **CONFIRMED** | `kubernetesStatus` → `rehearsal-new/moveprobe` after rebind; replica followed the pod twice (brokkr02→03→02) within seconds and the surplus replica was trimmed (1 MiB volume; large-volume timing untested) |
| 6 | resumed ks not stripping the HR's `spec.suspend` (B4b) | **CONFIRMED** | S3A and S1 B4b: after `flux resume ks`, HR `suspend=true`, Deployment `replicas=0`, ks `suspend=[]` |
| 7 | schedule→manual on a live RS; RS reverting to schedule after B4b | **CONFIRMED** | Merge patch leaves **both** keys; `flux resume ks` reverted to `{"schedule":…}` immediately; Flux also reverts a hand-set `manual` on its own within one ks interval (≤5 min). Real-size volume not tested |
| 8 | `replicas: 0` honoured by app-template with `Recreate` | **CONFIRMED** | S2, S1: Deployment `replicas=0`, no pod, then started cleanly (`starts` +1) |
| 9 | Restore of the real 570 MB `hermes@develop` series | **OPEN** | Mechanics proven on 1 MiB: drill listing byte-identical to baseline; size/time at 570 MB (and ~44Gi budget) not tested |
| 10 | Envoy blip / Gatus flap on route hand-over | **OPEN (not covered by design)** | no route in the fixture |
| 11 | `Delete` on a bound PV; deleting the RD's dest PVC | **CONFIRMED** | B10 accepted on a Bound PV, PV stayed Bound; teardown: PVC delete removed PV + Longhorn volume in ~19 s. Dest PVC delete: recreated by VolSync on the next trigger (≤31 s), restore `Successful` |
| 12 | deployed `perfectra1n` fork's manual/tag semantics | **CONFIRMED** | in-flight scheduled sync stamped my `manual` tag (S10a); creation-time sync stamped the B9 tag (B9); `WaitingForManual` while `manual` set (manual precedence) |
| 13 | in-cluster kustomize-controller vs local build (kind-targeted patches) | **CONFIRMED** | `requestedIdentity: moveprobe@rehearsal-old`, `.spec.volumeName == $PV` on the live objects; gate fails name-targeted patches locally (S7) |

### Statements to change in `docs/runbooks/volsync-app-namespace-move.md`

1. **CONTRADICTED — Preconditions and B6:** `kubectl get pvc -A --field-selector=status.phase=Pending` is rejected by the API server (`"status.phase" is not a known field selector`). Replace with `kubectl get pvc -A -o json | jq -r '.items[]|select(.status.phase=="Pending")|"\(.metadata.namespace)/\(.metadata.name) sc=\(.spec.storageClassName)"'`.
2. **CONTRADICTED / add — trap 14 and §3A step 5 (populator stall):** reproduced on the *very first* deploy (see B-1). Add: (a) a `VolumeSnapshot` with `readyToUse: true` is not proof — check the Longhorn snapshot behind the content handle exists (`kubectl -n longhorn-system get snapshots.longhorn.io snapshot-<uid>`); (b) a hand-patched `spec.trigger.manual` on a Flux-managed RD is **reverted by Flux (≤5 min) and re-runs the restore**, so retriggering (`restore-2`) is only stable after `spec.manual == status.lastManualSync` again — suspend the ks first; (c) after the retrigger the populator does **not** re-prime by itself: delete the `vs-prime-*` PVC; (d) the app volume can then fail its *own* clone (`cloneStatus.state: failed`, never retried, `FailedAttachVolume … has not finished copying data`) — the only cure was deleting the claim (PV `Delete`) and letting Flux/the populator re-create it. This affects **approach A and the `ai` RD's `restore-once`** (B5b drill) but **not** approach B's app claim (pre-bound `volumeName`, no populator).
3. **CONFIRMED and sharpen — B3 / B4b:** the RS trigger after a merge patch is `{"manual":…,"schedule":…}` (both). A resumed **or merely running** ks removes `manual` within one interval (immediately on `flux resume`). That is why B1's ks suspension is mandatory; add "the schedule fires again after B4b, but the old RS is pruned at B5 anyway".
4. **CONFIRMED — trap 8 / B3 in-flight gate:** show the failure: a scheduled sync in flight when `manual` is patched stamps the tag and **no second sync starts**; `lastSyncTime > T0` alone still passes on a sync that started *before* T0. **Add the same warning to B9**: a **newly created RS starts a first sync at creation**, and if the claim is `Pending` it stays in flight for minutes (`lastSyncStartTime` set) — a `manual` tag patched then is satisfied by that older sync. Before trusting B9, require `lastSyncStartTime` empty (or accept the log check, which was `moveprobe@rehearsal-new` here).
5. **CONFIRMED — trap 6 / B4b / trap 7 / B11:** the suspended-ks orphan case reproduces exactly (13 objects, `del=null`). B11's orphan list is correct; observed helm release Secrets `v1`–`v2` (and `v5`–`v9` in the wrongly-run case). Fixture has no Service; hermes' chart may.
6. **CONFIRMED — §6.3 / trap 11:** the NEW ks/HR are a fresh Helm `v1`; the NEW RD restores at creation (45 s for 1 MiB) and `requestedIdentity` shows the patched identity.
7. **CONFIRMED with new detail — trap 15 / [S-priv]:** restored files in an **unannotated** namespace are `0:0` **mode 664** (originals `10000:10000` mode 644). B5b's checksum drill needs `runAsUser: 0` if the source files are not world-readable (here 664 would still be readable by uid 10000 — the plan's assumption of unreadability was not tested).
8. **CONFIRMED — B5b optional step:** "deleting the dest PVC is optional (UNVERIFIED …)" → verified: VolSync recreates it on the next trigger.
9. **CONFIRMED — B10:** `Delete` patch on a Bound PV accepted; **and** its effect is immediate: a later PVC delete removes PV and Longhorn volume in ~19 s.
10. **ADD — S-b class for B6 order:** the actual move order is *OLD prune → PV Released → NEW ks creates the claim ~6 s later*; the claim then waits `Pending` (`FailedBinding … already bound to a different claim`) until the re-point. Expected, not a fault.
11. **ADD — Longhorn v1.12.1 datum:** online PVC expansion (1Gi→2Gi, pod running) completed in ~28 s with no restart; a kustomize-managed request bump is safe with a pre-bound claim.
12. **OPEN — literal hermes-form B5 gate:** the rehearsal ran the equivalent `move_gate` (same three assertions, rehearsal paths). The runbook's own `cluster-apps` parent-build command was not executed literally; run it once on the real branch before merge.
13. **ADD — guards/procedure hygiene for the hermes move:** any helper that caches the app PV (`app_pv`) must be re-read after a re-provisioned claim (B-2); `kubectl get -w` on a not-yet-existing object exits immediately (use a namespace-wide watch); `--show-managed-fields` is needed to read `managedFields`; `kubectl get events --field-selector involvedObject.name=` includes stale same-name events (filter by timestamp).

### Mapping of results to scenarios

Baseline PASS (after recovery, SURPRISE B-1, B-2) · S7 PASS · S2 PASS · S3 PASS · S1 PASS (S4 PASS + 4c observed, S5 SURPRISE (order), S6 PASS, S9 PASS, S10a PASS/R-4 confirmed, S10b PASS) · S8 PASS · Teardown PASS.
