# Adversarial review: `docs/runbooks/volsync-app-namespace-move.md` (hermes `develop` → `ai`)

Read-only review, 2026-09-23. Inputs: the runbook, `hermes-ns-move.md`, `hermes-ns-move-smoke.md`, the repo at
`hermes-to-ai`, and the live cluster (`kubectl get` only). Nothing was edited or committed. Line numbers are runbook lines.

The two build tests below ran against a **scratchpad copy** of `kubernetes/`, not the worktree, using `kustomize` v5.8.1 and
`flux build ks --dry-run` from flux CLI 2.9.5. Cluster controllers: kustomize-controller v1.9.1, helm-controller v1.6.1.

**Verified** means observed in a build, the controller source at the deployed tag, or a live object. **Inferred** means reasoning I did not test.

## Summary

| # | Sev | Where | One line |
| --- | --- | --- | --- |
| 1 | **BLOCKER** | 141-151 | Both B5 patches target names that don't exist at build time, so they are **silently dropped**. `ai/hermes` gets populated from `hermes@ai`, which has no snapshots, and comes up as a **fresh, empty hermes** |
| 2 | **BLOCKER** | 93, 157, 58, 333 | A **suspended** Kustomization that gets deleted **orphans its whole inventory** (verified in the source). With the develop `hermes` suspended at merge, nothing in `develop` is pruned. The old PVC never goes away, B6 never reaches `Released`, and the old HTTPRoute stays |
| 3 | MAJOR | 111-118, 223 | B3's acceptance string `Creating snapshot for hermes@develop:/data` is **not in** `latestMoverStatus.logs` (the log is truncated at the top). A good backup fails the check, which pushes the operator to loosen the gate |
| 4 | MAJOR | 111-113 | `lastManualSync` gets stamped by **whatever sync finishes next**, including a scheduled `:23` sync that started **before** the scale-down. The "consistent final backup" can be a live-app snapshot |
| 5 | MAJOR | 166, 171-172 | Removing `claimRef` makes the PV `Available` to **any** matching claim. The `ai` RD's own 20Gi `longhorn-1-replica-local` dest PVC is the likeliest thief. Pre-bind the claimRef to `ai/hermes` instead |
| 6 | MAJOR | 159, 175, 251-253 | "Rollback = `git revert`" does **not** re-bind the PV. A revert recreates the stock claim (no `volumeName`), so the populator restores the **last kopia snapshot into a new volume**, and the retained PV (with everything written since B8) is left behind |
| 7 | MAJOR | 151, 279 | The RD patch is called "inert". It is not: `trigger.manual: restore-once` runs a **full restore** in `ai` as soon as the RD is created (~44Gi of Longhorn). That is harmless when patched correctly; unpatched (#1), it is the empty-restore generator. Use it as a free restore drill |
| 8 | MINOR | 201-203 | B11's "leftovers" (dest PVC, 3 cache PVCs, VolumeSnapshot) are **ownerRef'd** to the RS/RD, so Kubernetes GC deletes them when Flux prunes the RS/RD. They won't be there to clean up (unless #2 orphaned everything), and they are **not** a rollback copy |
| 9 | MINOR | 113, 223-230 | Command defects: the `<that string>` placeholder loops forever, `$NS` is undefined, and B9 greps for the same truncated line as #3 |
| 10 | MINOR | 103-106, 177 | B2 is "optional", but B7 is the **only** content gate before B8 and diffs against B2 |
| 11 | MINOR | 64, 344 | HTTPRoute overlap: Gateway API gives the tie to the **oldest** route, which is `develop`'s. Brief if pruned. **Permanent 503** if #2 orphans it |
| 12 | MINOR | 94, 334 | With B1's HelmRelease suspend still in place at GC, helm-controller **skips the uninstall** (verified). The develop Deployment, Service and release Secrets are orphaned |
| 13 | MINOR | 335 | Open question 4 is answerable: upstream VolSync gives `manual` precedence over `schedule` (the fork was not checked) |
| 14 | MINOR | various | UNVERIFIED claims stated as fact, and "tested" claims that don't match what will actually run |

---

## BLOCKER 1: the B5 kustomize patches never apply, and hermes restores empty

**Runbook:** 141-151 (B5 step 3), 210 (§3A step 2), 279, 339.

**Mechanism (verified).** `patches[].target.name` is matched during `kustomize build`, and Flux's `postBuild.substitute` only runs after that.
At build time the component's resources are literally named `${APP}` (`components/volsync-claim/claim.yaml:5`) and `${APP:=temp}-dst-local`
(`components/volsync-backup/local.yaml:75`). `name: hermes` and `name: hermes-dst-local` match nothing. kustomize does not error when a
target matches zero resources.

Reproduced with the exact runbook patch appended to a copy of `develop/hermes/app/kustomization.yaml`:

```
$ flux build ks hermes -n develop --path ./kubernetes/apps/develop/hermes/app \
    --kustomization-file ./kubernetes/apps/develop/hermes/ks.yaml --dry-run | grep -c -E "volumeName|sourceNamespace"
0
```

**Failure scenario.** B5 merges. `ai/hermes` gets the stock claim with `dataSourceRef → RD hermes-dst-local` and **no** `volumeName`.
The `ai` RD has **no** `sourceNamespace`, so it requests `hermes@ai`. There are no snapshots under that identity, so it
produces an empty image while reporting `Successful` [S-b]. The PVC is WaitForFirstConsumer and stays Pending while replicas are 0.
B6 clears the claimRef, but nothing names `$PV`, so the `ai` PVC does not bind to it (the PV sits `Available`, see #5).
Two ways this ends in a fresh hermes:

- If the operator takes B6's fallback ("delete the ai PVC and let Flux recreate it", 172), Flux recreates the same unpatched claim.
- If B6/B7 are skimmed and B8 sets replicas back to 1, the pod becomes the consumer, the populator fills the PVC from the empty image,
  and hermes boots as a fresh install with no error anywhere. That is exactly trap 1.

The real data is safe only because B4 set `Retain`. It is stranded on an `Available` PV that nothing references, and B10 later tells the operator
to flip "the PV" back to `Delete`.

The §3A fallback is worse: it relies on the RD patch alone (210), and that patch is dropped the same way. So approach A restores empty **by construction**.

**Fix.** Target by kind (or `labelSelector`), not by the post-substitution name. The build contains exactly one PVC and one RD
(`r2.yaml` has only ExternalSecret + RS), so a kind-only target is unambiguous. Verified to apply:

```yaml
patches:
  - target: {kind: PersistentVolumeClaim}
    patch: |-
      - op: add
        path: /spec/volumeName
        value: pvc-12f54114-9e99-442b-bae4-53a9cb239d69
  - target: {kind: ReplicationDestination}
    patch: |-
      - op: add
        path: /spec/kopia/sourceIdentity/sourceNamespace
        value: develop
```

```
$ flux build ks … --dry-run | grep -n -E "volumeName|sourceNamespace"
222:  volumeName: pvc-12f54114-9e99-442b-bae4-53a9cb239d69
383:      sourceNamespace: develop
```

Add a **mandatory pre-merge gate** to B5: run the `flux build ks … --dry-run` above against the *moved* path with `ks.yaml` and require both lines.
The kind-only target is a trap if someone later adds a second PVC to the app (for example a media NFS claim), so add a comment saying so.
Note that the kind-only build was verified with local kustomize 5.8.1 / flux 2.9.5. kustomize-controller 1.9.1's embedded kustomize is inferred to behave the same.

---

## BLOCKER 2: suspending the develop Kustomization means nothing in `develop` is ever pruned

**Runbook:** 93 (B1 `flux suspend kustomization`), 58-59 (trap 6 "UNVERIFIED… Do both"), 157 ("Flux will delete the old Kustomization's inventory"), 164-165, 333.

**Mechanism (verified in source).** kustomize-controller v1.9.1, `internal/controller/kustomization_controller.go`:

```go
// A suspended Kustomization or one without an inventory will not delete resources.
func finalizerShouldDeleteResources(obj *kustomizev1.Kustomization) bool {
	if obj.Spec.Suspend {
		return false
	}
```

Removing `./hermes/ks.yaml` makes `cluster-apps` (`prune=true`, live) delete the `develop/hermes` Kustomization object. Its finalizer sees
`spec.suspend: true` and deletes **none** of the 10 inventory entries. The live inventory contains the PVC, three ExternalSecrets, the HTTPRoute,
the HelmRelease, the OCIRepository, the RD and both RSes.

**Failure scenario (as written, B1 → B5 with no resume in between):**

- `develop/hermes` PVC stays Bound. The PV never becomes `Released`, B6's first line waits forever, and the `ai` PVC stays Pending. Trap 3's
  "look for a Completed pod" (173) sends the operator hunting for a problem that doesn't exist.
- `develop` HTTPRoute `hermes` (older) stays and wins the hostname against the new one (see #11). After B8, `hermes.${SECRET_DOMAIN}`
  routes to a Service with no endpoints.
- `develop` `hermes-r2` keeps its schedule and keeps writing `hermes@develop` from the idle old PVC. That is harmless, but it muddies which series
  is "last". `hermes-local` remains in the manual mode B3 left it in.
- The operator's natural improvisation is `kubectl -n develop delete pvc hermes`, which is safe **only** because of B4. If the operator
  gets there by first undoing B4 ("rollback" row 250), they lose everything.

**Fix.** Pick one approach and state it:

- (a) **Preferred:** resume the develop Kustomization immediately before merging B5: `flux resume ks hermes -n develop`. Keep the HelmRelease
  suspended so the Deployment stays at 0. Then verify: `kubectl -n develop get hr hermes -o jsonpath='{.spec.suspend}'` → `true`,
  and `kubectl -n develop get deploy hermes -o jsonpath='{.spec.replicas}'` → `0`.
  **Inferred, not verified:** kustomize-controller's SSA doesn't strip `spec.suspend` set by the flux CLI (different field manager).
  Check those two outputs before merging. Then expect #12's orphans.
- (b) Keep it suspended, and add an explicit manual-cleanup list to B5 that runs *after* PV `Retain` is confirmed: delete PVC `hermes`, HTTPRoute `hermes`,
  RS `hermes-local`/`hermes-r2`, RD `hermes-dst-local`, ExternalSecrets ×3, OCIRepository `hermes`, HelmRelease `hermes` and Deployment/Service `hermes` in `develop`.

Either way, rewrite trap 6 and open question 2 as **answered**: suspended means orphan. Retain is still the guard against *un*-suspended deletion.

---

## MAJOR 3: B3's acceptance string is not in the status log

**Runbook:** 114-118, 223, 236; also B9 187-188.

**Evidence (live, `develop/hermes-local`, last sync 17:24Z).** `status.latestMoverStatus.logs` starts mid-upload. It contains
`Created snapshot with root kaf0fe0a… and ID 2273de6b…`, `Setting policy for hermes@develop:/data` and `OPERATION_RESULT: SUCCESS`,
but **no** `Creating snapshot for …` line. The smoke `[S-a]` output showed that line only because smoke volumes were tiny, so the log tail
reached back to it. Hermes is ~570 MB and ~4k files.

**Failure scenario.** B3 as written ("Accept only if … `Creating snapshot for hermes@develop:/data` **and** `Created snapshot…`") rejects a good
backup. The operator either stalls or loosens the check by eye. That is the moment the empty-source trap (4) gets waved through.

**Fix.** Accept when all of these hold on the fresh run: `grep -c 'Created snapshot with root'` ≥ 1, `grep 'Setting policy for hermes@develop:/data'`,
`grep 'OPERATION_RESULT: SUCCESS'`, and `grep -c 'Directory is empty'` = 0. The empty-source case logs `OPERATION_RESULT: FAILURE` [S-a run-1],
so the SUCCESS line alone discriminates it. For B9, use `Setting policy for hermes@ai:/data`.

## MAJOR 4: the forced sync can be a pre-quiesce snapshot

**Runbook:** 108-113.

**Mechanism (upstream VolSync source, `internal/controller/statemachine/machine.go`).** Trigger type is `manual` if `ManualTag()` is non-empty (line 85). Crucially,
**at the end of every sync** it runs `r.SetLastManualTag(r.ManualTag())` (line 214), whichever trigger started that sync.
The deployed image is the `perfectra1n` fork; I infer it keeps this logic but did not check.

**Failure scenario.** B1 happens at ~:22–:24, and the scheduled `:23` sync has already taken its VolumeSnapshot (copyMethod `Snapshot`) of the **live** agent.
B3's patch lands while that sync is still uploading. The sync finishes, `lastManualSync` gets the new tag, the until-loop exits, and the logs show
`Created snapshot` + `SUCCESS`. The "consistent final backup" is actually a crash-consistent image of a running SQLite `state.db`, and no second sync
runs. This is not data loss under approach B (the PV is the data), but it is the snapshot the runbook's rollback and approach A lean on.

**Fix.** Before patching, require `kubectl -n develop get replicationsource.volsync.backube hermes-local -o jsonpath='{.status.lastSyncStartTime}'` to be **empty**
(no sync in flight). Record `T0=$(date -u +%FT%TZ)` after the pod is gone. Accept only if `.status.lastSyncTime` > `T0`. If a sync is in flight, wait for it to
finish, then trigger. Same for `hermes-r2`.

## MAJOR 5: an `Available` PV can be claimed by the wrong PVC

**Runbook:** 166, 171-172.

**Mechanism.** Removing `claimRef` makes the PV matchable by **any** unbound claim with SC `longhorn-1-replica-local`, RWO, and a request ≤ 20Gi.
For WaitForFirstConsumer claims, the scheduler's volume binder prefers existing Available PVs before provisioning (inferred, standard behaviour).
The prime candidate is created by B5 itself: the `ai` RD's dest PVC `volsync-hermes-dst-local-dest`, which is exactly 20Gi RWO `longhorn-1-replica-local`
(`VOLSYNC_STORAGECLASS` feeds the RD `storageClassName`, `local.yaml:90`). It normally binds before B6. It does **not** bind before B6 if the RD
mover stalls and retries (trap 7 was seen in the smoke test), or if the operator follows the "delete and recreate" fallback. The smoke test had no competing claim.

**Failure scenario.** The RD's restore mover binds hermes' real PV and writes a kopia restore into it. `ai/hermes` stays Pending. The PV is now owned
through an RD-ownerRef'd PVC, and a later RD delete garbage-collects that claim.

**Fix.** Don't remove `claimRef`; **re-point** it. This is the standard reserve-a-PV pattern:

```bash
kubectl patch pv "$PV" --type merge -p '{"spec":{"claimRef":{"namespace":"'"$NEW"'","name":"'"$APP"'","uid":null,"resourceVersion":null}}}'
```

With the name and namespace set and no uid, only `ai/hermes` can bind. Also check `kubectl get pvc -A --field-selector=status.phase=Pending` before B6.
Today none are Pending, and the only non-Bound PVs are two `Released` `tns-csi-nfs` ones.

## MAJOR 6: rollback via `git revert` restores from kopia instead of re-binding

**Runbook:** 159, 175, 251-253 (§5 rows "B5 merged", "B6–B7", "B8–B9").

**Failure scenario.** A revert restores `develop/hermes/app/kustomization.yaml` **without** a `volumeName` patch. The develop claim comes back as a stock
populator PVC, and the develop RD (trigger `restore-once`, recreated, so it runs again) restores the **last `hermes@develop` snapshot** into a **new** volume.
Meanwhile the revert prunes `ai/hermes` (the PV goes `Released` under Retain). The retained PV holds everything written since B8, and hermes in
`develop` now runs without it. Nothing errors. After B8, that is silent loss of the post-move work.

The row "clear `claimRef`; re-create the PVC with `volumeName: $PV` in `$OLD`" can't be done with a revert. It needs a **forward** commit that adds the
kind-targeted `volumeName` patch (#1) to the develop app, plus the claimRef re-point (#5) to `develop/hermes`.

**Fix.** Rewrite §5 rows 251-253 as: "forward-commit develop back with the `volumeName` patch; re-point claimRef to `develop/hermes`; verify by content".
Mark it **untested**: no rollback path was exercised in the smoke test, and the table presents them as known-good.

## MAJOR 7: the `ai` RD is not inert; it runs a full restore at B5

**Runbook:** 151 ("inert under [S-e]"), 279.

**Mechanism.** The RD's `trigger.manual: restore-once` fires on creation. Live evidence: the develop RD shows `lastManualSync: restore-once`, and the smoke RDs ran on creation.
In `ai` that restore creates `volsync-hermes-dst-local-dest` (20Gi `longhorn-1-replica-local`) and a 24Gi cache (`cacheCapacity` default 24Gi, `local.yaml:89`),
then a VolumeSnapshot. It is independent of whether the PVC is pre-bound.

**Consequences.**

- It is the thief in #5.
- Unpatched (#1), it produces the empty `latestImage` that feeds the empty populate.
- Patched, it is a **free end-to-end restore drill** of `hermes@develop` in `ai`, the exact "heavier, UNVERIFIED" proof the runbook suggests at 119-120.

**Fix.** Say so. After B5, check the `ai` RD: `status.kopia.requestedIdentity` must be `hermes@develop` (**this is the direct test that #1's patch applied**),
and `latestMoverStatus` must be SUCCESS. Optionally mount its dest PVC read-only and diff against B2. Budget the ~44Gi, and delete that dest PVC when done.

## MINOR 8: B11 describes objects that GC will already have deleted

**Runbook:** 201-203; question (5) of the brief.

**Evidence (live).**

- `volsync-hermes-dst-local-dest` and `volsync-dst-hermes-dst-local-cache` have ownerRef → `ReplicationDestination/hermes-dst-local`.
- `volsync-src-hermes-local-cache` has ownerRef → `ReplicationSource/hermes-local`. The `-r2-cache` is presumably the same.
- VolumeSnapshot `volsync-hermes-dst-local-dest-20260905051844` has ownerRef → the RD, with no `do-not-delete` label.

When Flux prunes the RD/RS (only if #2 is fixed), Kubernetes GC cascades and their SC is `Delete`, so they are destroyed. None of this is a rollback copy:
the dest volume is the 2026-09-05 restore (18 days stale). The real rollback assets are the Retained `$PV` and the `hermes@develop` kopia series, and nothing in the
procedure deletes either. **Fix:** replace B11 with "expect these to be gone. If they aren't (orphan path, #2), delete them. Confirm `$PV`'s claimRef is `ai/hermes` first".

## MINOR 9: command defects

- 112-113: `"pre-move-$(date +%s)"` is not captured, and the until-loop compares against the literal `<that string>`, so it spins forever.
  Use `TAG=pre-move-$(date +%s)`, then `-p '{"spec":{"trigger":{"manual":"'"$TAG"'"}}}'` and `= "$TAG"`.
- 223-225: `$NS` is never set (the variables block defines `OLD`/`NEW` only).
- 114-115: `grep -E "^20|^Successful|…"` only works because `jq -r` prints each field on its own line. That is fine, but it doesn't test the `Directory is empty` count, so use the #3 set.
- 96: `app.kubernetes.io/name=hermes` matches the app pod (verified label); OK.
- 98: OK. It could print duplicates if a pod mounts the claim twice, which is cosmetic.
- 166 → replace with #5's claimRef re-point.
- 128/132/198: the `kubectl patch pv` syntax is fine (strategic merge on a core type).

## MINOR 10: B2 must be mandatory

**Runbook:** 103-106, 177, 239. B7 "diff against B2" is the only content check before the pod writes (B8). If B2 was skipped (it is labelled "optional"), B7 has nothing to diff,
and `-o wide` showing `$PV` proves which volume it is, not its contents. **Fix:** make B2 mandatory. At minimum, B7 must assert that `auth.json`, `.env`, `SOUL.md` and a `sessions/` count exist and match.

## MINOR 11: the HTTPRoute overlap goes to the old route

**Runbook:** 64, 344. Gateway API conflict resolution gives precedence to the route with the **oldest `creationTimestamp`**. The develop route (18d) beats the new one
(inferred from the spec; Envoy Gateway implements it). In the GC path the overlap is brief and hermes is down anyway. In the #2 orphan path, the develop route
never goes away and the new route never serves. **Fix:** in B8's verification, add `kubectl get httproute -A | grep hermes` → exactly one, in `ai`.

## MINOR 12: the suspended develop HelmRelease isn't uninstalled when pruned

**Runbook:** 94, 334. helm-controller v1.6.1 `reconcileDelete` runs the uninstall only `if !obj.Spec.Suspend` (verified, `helmrelease_controller.go:455`).
Fixing #2 via option (a) means GC deletes a suspended HelmRelease, which orphans Deployment `hermes` (replicas 0, `existingClaim: hermes`),
Service `hermes`, and the `sh.helm.release.v1.hermes.v*` Secrets in `develop`. They are harmless: the Deployment at 0 has no pod, so there is no pvc-protection hold.
**Fix:** list them in the post-cutover cleanup. There are no Helm ownership conflicts with `ai`: the PVC is kustomize-owned, not Helm-owned (`existingClaim`), and the chart has no hooks.

## MINOR 13: open question 4 is answerable

**Runbook:** 112, 335. Upstream: `manual` wins over `schedule` when both are set (`machine.go:85`). A `--type merge` patch leaves `schedule` in place, and the RS
runs in manual mode until `manual` is removed. The runbook never removes it, which only matters on the orphan path. The fork is unverified.

## MINOR 14: UNVERIFIED claims stated as fact, and gaps between what was tested and what will run

| Line | Claim | Reality |
| --- | --- | --- |
| 157 | "Flux will delete the old Kustomization's inventory" | False under B1's suspend (#2, verified) |
| 151, 279 | RD patch "inert" | Runs a restore on creation (#7) |
| 17, 339; smoke "(e)" | "The unmodified `volsync-claim` component's PVC can be used with a `volumeName` patch" | Smoke used **hand-written** PVC/RD manifests (`docs/investigations/smoke/08-approachB-rebind.yaml`). The component + patch path was never built; as written it doesn't apply (#1) |
| 118 / [S-a] | log line shape | Only true for tiny volumes (#3) |
| 159, 175, 251-253 | rollback rows | None were exercised, and the revert path is wrong (#6) |
| 171-172 | new PVC binds after a claimRef clear, in either order | Standard pv-controller behaviour (a pre-bound claim retries on resync), but untested in this order. With #5's re-point, the order doesn't matter |
| 244-245 | old series restorable "always" | True for kopia, but no restore of hermes' **real** (570 MB) `hermes@develop` has been done since 2026-09-05. #7's drill closes this |
| 181 | "ownership self-heals regardless" | Irrelevant under B (same filesystem); relevant only to A |
| 35 | old series never expired | Correctly flagged as inferred |

Smoke vs. real run, the gaps not covered above:

- The smoke used `retain: {latest: 2}`, 1Gi volumes, manual triggers from creation, and no Flux at all. That means no inventory, no suspend, no SSA ownership of
  `volumeName` (trap 5 remains untested), and no `cluster-apps` prune.
- It had no competing claims (#5) and no in-flight scheduled sync (#4).

## Answers to the brief's specific questions

1. **Ordering.** The develop PVC can only be pruned after B4 (Retain) as written, so that ordering is safe. But with B1's suspend it is **never** pruned (#2). The ai PVC can't bind
   before the claimRef is cleared: a pre-bound claim waits for a PV that is bound elsewhere. The race worth worrying about is the *wrong* claim binding after the clear (#5). Flux in `ai`
   neither adopts nor deletes the rebound PV. Its inventory holds `ai_hermes__PersistentVolumeClaim` (a new object, new labels
   `kustomize.toolkit.fluxcd.io/namespace: ai`), and the PV isn't in any inventory. Keeping `volumeName` in the manifest is right (trap 5).
2. **Rebind with the stock component.** The mechanics work (the populator ignores a pre-bound PVC [S-e]; `dataSource`/`dataSourceRef` are echoed back), but the patch as written doesn't reach the manifest (#1).
3. **Final backup.** It can false-pass (#4) and false-fail (#3). The snapshot is under `hermes@develop` (RS in `develop`, hostname unset → namespace).
4. **Helm in `ai`.** A fresh v1 install. No hooks, and the PVC isn't Helm-owned. The one caveat is the orphaned develop release under a suspended HR (#12).
5. **Other VolSync objects in develop.** None hold or block the app PV. They are GC'd with their owners (#8), and none is a useful rollback.
6. **Rollback validity.** Untested throughout; revert-based rows are wrong (#6).
7. See #14.
