# Adversarial pre-flight review: pin-fix rehearsal (`ssa: IfNotPresent` vs the permanent `volumeName` pin)

**Scope.** Reviewed on 2026-09-24:

- the plan, `docs/rehearsal/pin-fix/plan.md` (831 lines);
- `pinfix-guards.sh` (562) and `pinfix-states.sh` (136);
- the suite `pinfix-guards-test/`;
- the fixtures, commit `3775138e` on `rehearsal-pin`.

`P:N` = plan line, `G:N` = guards line.

**Reviewer conduct: nothing I ran reached the cluster with a mutating verb.** Everything I did falls into one of these:

- **Live cluster:** `kubectl get` (with `--show-managed-fields`), plus `git ls-remote` against the public repo (the `rehearsal-pin` head does not exist).
- **Source code:** `gh api` reads of `fluxcd/kustomize-controller@v1.9.1` and `fluxcd/pkg@ssa/v0.76.1` (the version in that tag's `go.mod`).
- **Fixtures:** a scratch clone of `rehearsal-pin` in my scratchpad.
- **Test suite (287/287 PASS):** run in place with `T=<my scratchpad>/gt-pin` under `/bin/bash` directly. Its own interlock verified that `kubectl`/`flux`/`curl`/`date` resolve to the harness fakes, and `PIN_FAKE=1` plus a dead `KUBECONFIG` were in force.
- **My adversarial tests:** a separate `/bin/bash` script that first asserts `command -v kubectl` is the fake, and runs with `PIN_FAKE=1`.
- **Never used:** `zsh -c`, the guards' state dir, and `pin_gate` against the real worktree (it writes `gated-head.txt`, which authorises `PUSH`).

## Verdict

**GO**, after two MAJOR fixes (M1, M2). Both are small, and neither needs new cluster work.

- I found **no path from the plan's commands to hermes, `ai`, `develop`, `cluster-apps`, `main`, the Receiver, the `Alert` CRs, or any kopia identity other than `moveprobe2@rehearsal-new`** (plus a read-only `moveprobe2@rehearsal-old` request that is never expected to run).
- The source claims in §1 check out against the exact deployed versions.
- The scenario design discriminates its hypotheses.

The weak points:

- `kn` is not the namespace boundary the guardrails say it is (M1).
- The decision table lets hermes' cleanup ship on S2 alone, although the reason for the change is the DR path that only S4 tests (M2).

## Summary

| # | Sev | Where | Finding |
| --- | --- | --- | --- |
| M1 | MAJOR | G:91-97; P:105-106 guardrails 1-2 | `kn` pins `-n` but passes **everything else** through. Verified with the fake: `kn rehearsal-new delete pv <hermes PV>`, `kn rehearsal-new patch pv <hermes PV>`, `kn rehearsal-new --namespace ai delete pvc hermes` (kubectl: the last `-n` wins) and `kn rehearsal-new -n longhorn-system delete volumes.longhorn.io <hermes PV>` all reach `kubectl` unrefused. The plan's own commands never do this, but the guardrails promise that `kn` "refuses every namespace but `rehearsal-*`" and that "no bare `kubectl patch/delete pv`" can happen |
| M2 | MAJOR | P:785-795 (§11), App. A | Row 1 ships Appendix A on S1+S2c+S2 alone. The cleanup's **purpose** is DR: an unpinned recreate plus a newest-series restore. That is only tested in S4, which has the highest wedge risk (trap 14, P:709/716). The table has no rows for "S4 inconclusive after 2 recoveries" or "S1 `s1_equiv` DIFFERS → S1-alt" |
| m1 | MINOR | G:158-165 | `pv_reclaim … Delete` has **no phase check**. Verified: a listed, labelled, **`Released`** PV is patched to `Delete` (rc 0), which reclaims it at once. Scratch-only, but the brief asks for "Delete only when Bound" and it is not implemented |
| m2 | MINOR | G:451-487; P:163, P:349-366 | `ro_run` waits 60 × 5 s and cleans up only at the end: no `trap`, no `--cascade=foreground`. S1-D (two `data_check` + `wait_running 60`) and S4-C can exceed the 600 s tool limit. A killed block leaves a Job whose pod holds pvc-protection, and then S4-B's `delete pvc --wait=true --timeout=120s` aborts. (This is the same defect class that was reproduced live in the hermes review.) |
| m3 | MINOR | P:301, P:599 | The "no pod references the claim" check only **prints**. It should fail the block before the claim is deleted in S1-B/S4-B |
| m4 | MINOR | P:537 | S6's `flux diff` uses a **relative** `--path` from the tool's cwd (not `$R`), so the probe errors and `\|\| true` hides it. It also calls `flux` directly, not through `fx`. It is read-only (a server-side dry-run), but add `cd "$R" &&` |
| m5 | MINOR | P:739-744 (T2) | The comment says deleting the parent "prunes the child + its inventory + the claim". After S4 the live claim carries `prune: disabled`, so it **survives** T2 and goes only with the namespace in T3. Correct outcome (T1 set its PV to `Delete`), wrong expectation; an operator could read "claim still there" as a failure |
| m6 | MINOR | P:465-510 | Between S3a (RS/RD `capacity: 2Gi`) and S3d (claim expanded to 2Gi), a scheduled `:47` sync would clone a 2 Gi volume from a 1 Gi snapshot. That is an untested Longhorn path and could wedge a mover (silenced). Run S3a → S3b → revert → S3d back-to-back outside `:40-:50`, or do S3d first |
| m7 | MINOR | §4, P:121 | `hermes_same` compares hermes' PV `phase\|reclaim` for ~5–7 h. Hermes' own Phase S (B10 `pv_reclaim … Delete`, P:418 of the hermes plan) or its B11 cleanup landing mid-rehearsal would trip a false ABORT + teardown. Freeze hermes changes for the window, or compare only uid/volumeName/phase |
| m8 | MINOR | G:151-156 | `rehearsal_pv_ok` accepts an **empty** claimRef for listed+labelled PVs (the hermes guards now refuse it). No step in this plan needs it (re-point only), and an empty claimRef is the R-5 thief state. Refuse it |
| m9 | MINOR | G:444, G:481, G:393 | Poll intervals are env-overridable (`PIN_POLL_*`). They are test hooks and fail closed (a 0 s poll times out and deletes the Job), but document them or drop them outside `PIN_FAKE=1` |
| m10 | MINOR | P:783-797 | Precondition for hermes is missing from Appendix A: `s1_equiv` compares against **today's** `ai/hermes` ownership. If anything re-applies or patches hermes' claim before the cleanup PR (a manual `kubectl annotate prune=disabled`, a `kubectl patch` for size), the ownership changes. Re-run `s1_equiv`'s hermes half right before merging Appendix A |

---

## 1. Blast radius (question 1)

All verified:

- **Parent Kustomization vs live `cluster-apps`.** `spec.patches` are **identical** (`diff` of sorted JSON). `decryption`/`force: false`/`prune`/`retryInterval`/`timeout`/`wait` are identical. `path`, `sourceRef` and `interval` differ as intended. Patches in `spec.patches` apply only to this Kustomization's own build, so no selector can reach live objects.
- **GitRepository** `rehearsal` → `refs/heads/rehearsal-pin`, same public HTTPS URL, no `secretRef`. `bootstrap_apply` (G:494-507) checks the name, ref, path, sourceRef and the absence of `${`.
- **Namespaces** `rehearsal-old`/`rehearsal-new`: `prune: disabled` (honoured on parent deletion; kustomize-controller `deleteObjects` exclusions), PSA baseline, `privileged-movers` annotated. None exist live, nor any `rehearsal*` Flux CR, and the remote branch does not exist.
- **Silences** (G:521-535): `namespace=~rehearsal-.*`, `obj_namespace=~rehearsal-.*`, `name=~rehearsal-apps|rehearsal`. Alertmanager anchors regexes, and the label sets were verified previously (Flux provider `name`/`namespace`; VolSync `obj_namespace`), so none can mute anything in `ai`/`develop`/hermes.
- **PV guards.** `record_pv`/`adopt_pv`/`rehearsal_pv_ok` refuse hermes' PV by name, require the `pins.txt` list, the `rehearsal=pin` label and claimRef `rehearsal-*`, and fail closed on an API error. Gaps: M1 (bypass via `kn`), m1 (`Delete` phase), m8 (empty claimRef).
- **Push guard.** `PUSH` takes no arguments, requires `PIN_WINDOW` and a live silence, checks the branch, and pushes only a HEAD that equals the `pin_gate`-recorded SHA, with the single refspec `rehearsal-pin:refs/heads/rehearsal-pin`. Tested in the suite against a scratch bare origin. Workflows re-checked: only `label-sync`/`schemas` trigger on `push`, both `main`-scoped. Every push fires the Receiver (a `cluster-apps` no-op reconcile), ~20 times. `others_ready` tolerates the transient `Unknown`.
- **Kopia.** Writes only `moveprobe2@rehearsal-new` (distinct identity). The S1-state RD requests `moveprobe2@rehearsal-old`, which is empty and read-only if it ever ran.
- **Caller environment.** `APP`, `BRANCH`, `HERMES_PV`, `R`, `PIN_PVS`, `PIN_GATED`, `GUARDS_DIR` and `PIN_HERMES_PV` are all pinned. Verified: env overrides are ignored.
- **Teardown order.** T1 resumes every suspended object (no orphaning, trap 6), adopts and flips PVs. T2 → parent. T3 → namespaces. T4 → `pv_delete` (Longhorn only after the PV is confirmed gone). T5 → branch + `verify_clean` (fails closed on an unreadable remote). T6 → worktree. Nothing can strand a PV: a claim protected by `prune: disabled` goes with its namespace (m5), with its PV already `Delete`.

**M1 fix.**

- `kn` refuses any argument equal to or starting with `-n`, `--namespace`, `-A` or `--all-namespaces`.
- It refuses cluster-scoped or foreign kinds: `pv`, `persistentvolume*`, `ns`, `namespace*`, `node*`, `crd*`, `clusterrole*`, `volumes.longhorn.io`, `*.longhorn.io`, `storageclass*`, `volumesnapshotcontent*`. An allow-list of verb+kind is better still.
- Add the four bypass cases above as `refuse` tests.
- Update guardrail 1's wording until then.

## 2. Source claims in §1 (question 2)

Verified at kustomize-controller **v1.9.1**, `fluxcd/pkg/ssa` **v0.76.1**.

| Plan claim (P:37-46) | Verdict | Evidence |
| --- | --- | --- |
| `IfNotPresentSelector = {ssa: IfNotPresent}` | ✓ | `kustomization_controller.go:864-866`. Also `ExclusionSelector` = `reconcile: disabled` / `ssa: Ignore` (:860-863); `ForceSelector` = `force: enabled` (:867-869); `applyOpts.Force = obj.Spec.Force` (:859) |
| Skip needs the existing UID **and** the annotation on the **desired** object | ✓ | `manager_apply.go:543-560` `shouldSkipApply`: `existingObject.GetUID() != "" && AnyInMetadata(desiredObject, IfNotPresentSelector)`. (Note: `ExclusionSelector` is checked on desired **or** existing.) |
| The skip runs **before** `dryRunApply` | ✓ | `Apply` :128 vs :142; `ApplyAll` :238 vs :253. A skipped object never reaches the dry-run, so no immutable error is possible, and `shouldForceApply` (which needs an immutable dry-run error) cannot fire either, with or without `ks.spec.force` |
| The skipped entry is recorded from the **existing** object → stays in the inventory | ✓ | `shouldSkipApply` builds the entry from `existingObject` when UID ≠ "". `inventory.AddChangeSet` (`internal/inventory/inventory.go:39-51`) appends **every** entry, `Skipped` included. Skipped entries are excluded from health checks (`kustomization_controller.go:1009-1015`) |
| Prune exclusion is read from the **live** object | ✓ | `manager_delete.go:83` owner-label selector **and** `:87` `AnyInMetadata(existingObject, opts.Exclusions)`, both on the live object. Also true: a live object without the Flux owner labels is never pruned (not relevant here; the claim was created by Flux) |
| A skipped apply writes nothing (annotation, labels, capacity, class never reach an existing claim; managedFields frozen) | ✓ by construction (no dry-run, no apply call follows `return true`) | — |
| Removing the annotation later re-arms the stall | ✓ derived. Flux keeps sole `Apply` ownership of `f:volumeName`; the next apply without it unsets an immutable field. S2c demonstrates exactly that mechanism | — |
| `force` false on `cluster-apps` and unset on the child | ✓ live and fixture (`ks.yaml` has no `force`) | — |

**What happens when the object later leaves git** (question 2, last part): it is in the old inventory and not the new one, so it is stale and goes to `deleteObjects`.

- With `prune: disabled` **on the live object**: `SkippedAction`, treated as *settled* by `pruneSurvivors` (:1129-1142) and dropped from the inventory, so it is orphaned (untracked) from then on.
- Without it: deleted.

`IfNotPresent` itself gives **no** prune protection.

**Could not verify:**

- that kustomize-controller's embedded kustomize renders the strategic-merge annotation patch exactly like the CLI (the plan's S4-C live read closes this);
- behaviour when the `Get` of the existing object fails with something other than NotFound: UID is empty → no skip → dry-run → the old immutable stall. That only happens on an API error and is transient, but it means a transient read error on hermes' claim would surface trap 12's message once.

## 3. Scientific validity (question 3)

**S1 real-shape — safe, and it reproduces the shape.**

- The live `ai/hermes` ownership is exactly as P:50 says (`kustomize-controller Apply` owns `accessModes, dataSourceRef, resources, storageClassName, volumeName`; `kube-controller-manager Update` owns only `annotations`; plus the status subresource).
- The sequence reaches that ownership by the same mechanism as the move: Flux **creates** a pre-bound claim; the PV controller then binds without writing `volumeName` and adds only `bind-completed`. Hermes has run VolSync syncs since the move (last 19:24:27Z Successful) and has no VolSync manager entry, so the RS will not perturb the rehearsal claim's owners either.
- Safety:
  - `Retain` is set in S1-A and re-asserted before the delete (P:315).
  - The claimRef keeps the uid until `pv_repoint`, so there is no thief window.
  - The populator ignores the pre-bound claim [S-e].
  - The child stays suspended across parent reconciles (observed in the first rehearsal's S2).
  - m3 applies to the unasserted pod check.

**S2c control — discriminates.** With Flux the sole owner of `f:volumeName`, applying without it fails the dry-run with the immutable error (first rehearsal 4c on the same shape). `ApplyAll` returns at the dry-run phase, so **nothing** in the ks is applied, and the RD `sourceNamespace` check (P:396) proves it.

- Recovery (re-commit `s1`) re-applies an identical value, so ownership is unchanged. S2 therefore starts from the same state; this is not a hidden dependency.
- If `s1_equiv` DIFFERED, S2c might not stall. The plan stops correctly (P:401). §11 lacks that row (M2).

**S2 fix — discriminates, and cannot pass for the wrong reason.**

- If the annotation patch failed to render in-cluster, S2 would behave exactly like S2c (stall), which is a FAIL, not a false PASS.
- `wait_ks_outcome` requires `lastAttemptedRevision` = the pushed SHA, so a stale Ready cannot be mistaken for a pass.
- The RD `sourceNamespace` removal proves the rest of the ks applied.

**S3 — discriminates.** Each probe has its own live field. m6 applies.

**S6 — discriminates** (rc 0 vs 2). m4 applies.

**S5a/S5 — discriminate.**

- Live `prune` null after the git commit vs present after the manual annotate.
- S5 checks uid + `deletionTimestamp`, and deletes the **child** (not suspended) while the **parent** is suspended, which is correct: a suspended child would orphan everything and prove nothing.
- After the parent is resumed, the recreated child's inventory re-lists the claim through the `IfNotPresent` skip. That is how "adoption" happens, and it is consistent with the source.
- The recreated RD runs its `restore-once` again into its own dest PVC. Harmless, but expect it (not stated).

**S4 — the RD restore does re-run.**

- The recreated RD is a new object: `lastManualSync` is empty and `restore-once` ≠ "", so it syncs.
- The populator waits for the **new** RD's `latestImage`, so it cannot use a stale image.
- The `starts == NPRE+1` plus ordered-lines check discriminates the newest series (NPRE ≥ 4) from any older one (`pin-pre-s1` = 1) and from empty.
- Trap 14 can **stall** S4 but cannot fake a PASS. The ABORT criteria cover a wrong or empty series.
- The only wrong-reason bind would be a pre-existing `Available` PV of the same class ≥ 2 Gi (none exist live now), and the "NEW volume + NPRE lines" check would catch it anyway.

**Pass criteria are mutually exclusive** in every scenario (PASS / SURPRISE / FAIL / ABORT are disjoint predicates on rc, uid and live fields).

**Hidden dependencies.** The only real one is **S3d before S4** (2 Gi everywhere), which the plan makes mandatory. m6 is its window. S2c → S2 is handled by the recovery commit. S5a → S4 → S5 relies on S4 creating the claim with both annotations, and S5 asserts that first (P:661).

## 4. Guards (question 4)

- **Suite: 287/287 PASS** in my scratch copy, under `/bin/bash` 3.2.57, with the harness interlock active. Its `PIN_FAKE=1` check (G:24-29) makes the guards refuse to load unless `kubectl`/`flux`/`curl` are the harness fakes and `KUBECONFIG` is the dead one. That is the right fix for the earlier incident.
- **My added tests** (fake-verified):

| Test | Expected | Result |
| --- | --- | --- |
| `pv_reclaim Delete` on a Released PV | refuse | **accepted** → m1 |
| `kn` + `--namespace ai` / `-n longhorn-system` | refuse | **accepted** → M1 |
| `kn` `delete pv` / `patch pv` on hermes' PV | refuse | **accepted** → M1 |
| env overrides of `APP`/`BRANCH`/`HERMES_PV`/`R`/`PIN_*` paths | ignored | ignored ✓ |
| `fx` whitelist | exact-string | ✓. `fx get`/`build` pass through read-only; `flux build` without `--dry-run` only *reads* the cluster (verified: it tried the dead API) |

- **`set -e` vs `&&`/`||`.** Every guard does explicit checks (G:143 notes it), and `backup_now`/`ro_run`/`pin_gate` accumulate `rc`/`ok`. Sourcing the guards twice in one shell fails on `readonly CHILD_PATH`, which is harmless (blocks source once), but note it for anyone composing blocks.
- **Quoting.** There is no `hm` wrapper in this plan; blocks are `/bin/bash <<'EOF'`. `ro_run` JSON-quotes the command (G:460), so there is no YAML injection.

## 5. Cost, time, meaning for hermes (question 5)

- **Time/cost.** ~4.5–6.5 h, ~20 pushes, ~15 Gi Longhorn peak, and kopia residue `moveprobe2@rehearsal-new` (needs a kopia client to remove). This is honest. The 10 h silence covers it. A re-run needs `moveprobe3` (stated).
- **Decision table (M2).** Rewrite row 1 as "S1 EQUAL + S2c stall + S2 pass + **S4 pass** → Appendix A". Add:
  - "S2 pass, S4 inconclusive (2 wedges) → the stall fix is proven but the DR path is not: either keep the pin, or ship with the DR claim marked UNVERIFIED and schedule a DR drill";
  - "S1 DIFFERS (S1-alt) → S2c/S2 inconclusive for hermes; do not ship on this evidence".
- **Appendix A** matches what S2+S4 would justify:
  - one strategic-merge annotation patch replacing both pin patches;
  - `prune: disabled` by hand;
  - the precondition `hermes@ai` exists in the **local** repo. Live: `ai/hermes-local` last sync 19:24:27Z Successful; confirm the identity with `check_backup ai hermes-local hermes@ai`.
  - m10: re-check hermes' ownership right before merging.
- **Ways it could pass for the wrong reason.** None found for S2/S4 (see §3). S5 passes only if `prune: disabled` is on the **live** claim, and P:661 asserts that before deleting anything.

## GO / NO-GO

**GO** once **M1** (`kn` flag and kind allow-list, plus 4 tests) and **M2** (§11 rows) are fixed. Neither changes the fixtures or needs a cluster action. Fix m1–m3 at the same time: small guard edits, and the suite re-run must stay green. m4–m10 can be fixed during execution.
