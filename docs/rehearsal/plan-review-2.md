# Delta pre-flight review: `docs/rehearsal/plan.md` rev 2 + `rehearsal-guards.sh`

Read-only, 2026-09-23. Nothing was applied, committed or pushed.

**What I looked at**

- **Cluster.** `kubectl get`, plus read-only `get --raw` GETs through the Prometheus service proxy.
- **Controller source** at the deployed tags: kustomize-controller v1.9.1, notification-controller v1.9.1.
- **Builds.** `flux build … --dry-run` (flux 2.9.5) on a **scratch copy** of the fixtures.
- **Guard tests.** Run under `/bin/bash` 3.2.57, against a scratch copy of the guards file with `GUARDS_DIR` redirected so the real `rehearsal-state/` wasn't touched. Only read-only functions were exercised.

**How to read the refs**

- `P:N` is `docs/rehearsal/plan.md` line N.
- `G:N` is `~/.herdr/worktrees/flux-talos/rehearsal-guards.sh` line N.
- **Verified** means observed or executed. **Inferred** means reasoning I did not test.

## Headline

The revision fixes every finding from review 1 in substance. The orchestrator's **kube-system UID check is sound** and strictly better than a context-name check.

I found **no path to hermes, `develop`, `ai`, `cluster-apps`, `main`, the Receiver or the `Alert` CRs**. The three Alertmanager silences are provably scoped to `rehearsal-*`, checked against the real label sets.

The revision does introduce problems:

- **One gate hole**: `move_gate` passes a commit with a stale `targetNamespace`/`path`, or an unedited parent kustomization.
- **One acceptance check that runs without its wait**: the baseline `check_backup`.
- **A broken S3→S1 hand-off**: the app is left at `replicas: 0`.
- **A guard that returns "ok" on any `kubectl get` error.**
- Several blocks that fail closed under `set -u` or `set -e`, or hang, when run as written.

**Verdict: NO-GO as written, GO after the 4 MAJOR fixes** (all small; details at the end).

---

## 1. Status of the 19 review-1 items (checked in the text, not the change table)

| # | Item | Status | Evidence |
| --- | --- | --- | --- |
| B1 | Guards don't persist; zsh breaks `$GIT`/`$PUSH` | **Fixed**, with residue | Guards file with `#!/bin/bash` + `set -euo pipefail` (G:1,10). `GIT`/`PUSH`/`COMMIT` are functions (G:31-43). `PUSH` takes no args and checks the branch (G:33-37). Stable state dir (G:24-27). Every block uses `bash <<'EOF'; source …` (P:122-127). `bash -n` OK and sources cleanly under 3.2 (verified). **Residue:** the §5.1/§1 text still describes a *context* check (P:48, P:124), while G:16 is a UID check; the recipe's `PV=<recorded PV name>` placeholder is a bash **syntax error** (N6); `$PV` is **unbound** under `set -u` in stand-alone blocks (N7) |
| 2 | `data_check` Multi-Attach; no logs on failure | **Fixed** | G:133-134 pins `nodeName` to the app pod's node. G:154-157 waits on succeeded **or** failed. G:159-161 always prints logs and deletes the Job |
| 3 | S8 bait exposed cluster-wide | **Fixed (design)** | P:449-477: bait/thief/wanted are `volumeMode: Block`. The PV controller never binds a Filesystem claim to a Block PV (volume-mode mismatch is a hard filter), so no production claim can take the bait. Block on Longhorn is still UNVERIFIED (P:450, see N10). The steps are comments, not commands (P:484-491) |
| 4 | `jq` aborts on claimRef-less PVs | **Fixed** | `// ""` everywhere in G:58,60,70,84,86. Teardown P:528, P:558, P:560, P:561; P:492 is null-safe |
| 5 | Teardown strands claimRef-less PV; unguarded Longhorn delete | **Partly fixed** | Label + list + empty-claimRef acceptance (G:79-89). Longhorn delete nested in `pv_delete` (G:92-97). **New hole:** G:83 returns **0 ("gone")** on *any* `kubectl get pv` failure, not just NotFound (N4) |
| 6 | S3 orphans contaminate S1 | **Fixed** | P:302-315: evidence, cleanup, assert-empty. But the same orphan class recurs in **S1 B11**, where it is contradictory (N9) |
| 7 | Namespace annotations | **Fixed** | Verified: `kustomize build` shows `privileged-movers` **1× in `rehearsal-old`, 0× in `rehearsal-new`** |
| 8 | S7b invalid | **Fixed** | Dropped (P:221-222); rationale correct |
| 9 | Inventory check filters Namespaces / fails open | **Fixed** | G:103-109. Regex tested against the real id format (`_develop__Namespace`, `develop_cluster-settings__ConfigMap`, `develop_hermes_kustomize.toolkit.fluxcd.io_Kustomization` from live `cluster-apps`): accepts `_rehearsal-old__Namespace` and `rehearsal-old_…`; rejects `develop_…`, `_rehearsal-oldx__Namespace`, and any cluster-scoped `_x_…` id. Fails closed on a missing ks (verified: rc 1) |
| 10 | S2 "Bound" ≠ orphaned | **Fixed** | P:246-253: `del=` printed for every object; the pass criterion requires `null` |
| 11 | S4 managedFields depth; recreation not recorded | **Fixed** | P:354 (`f:spec` keys per manager), P:356-367 (UID before/after diff) |
| 12 | S6 locality passes either way | **Fixed** | P:381-397 states the criteria up front; "NOT CLOSED" unless the pod moves to another brokkr node; the 6b `nodeSelector` commit is scratch-only |
| 13 | S10 race not deterministic | **Fixed**, operationally fragile | P:414-429. But the block can wait up to 59 min, and the tool call limit is 10 min. It also leaves `manual` set, which pollutes 10b (N11) |
| 14 | Receiver reconciles `cluster-apps` | **Fixed** (text, P:56, P:583) | But `others_ready` right after `PUSH` can now trip on that very reconcile (N8) |
| 15 | Alert noise | **Fixed; matchers verified safe** | G:169-185; see §3 |
| 16 | Wrong `refreshInterval` sentence | **Fixed** | §4 (P:102-114) no longer mentions it |
| 17 | kopia residue breaks a re-run | **Fixed** | P:112, P:570; `APP` from the environment (G:21). **But** the env inheritance is unvalidated (N5) |
| 18 | Teardown variables | **Fixed** | P:531, P:539 use the literal names |

---

## 2. The orchestrator's UID edit (G:12-16)

- **Correct and fail-closed.** Verified live: both `admin@home-kubernetes` (server `10.0.10.30:6443`, user `admin@home-kubernetes`) and `tso-talos.flyingfox-decibel.ts.net` (user **`tailscale-auth`**) return kube-system uid `793124f9-2b2e-4c9e-9fd0-41d27bd2d5a0` and hermes-PV uid `3acc15ba-…`.
- An API error yields `""`, which never equals the UID, so the check `exit 1`s. `exit` inside a `source`d file under `bash <<'EOF'` terminates the block (verified).
- The UID is set at cluster creation and cannot collide. It is a better identity than a context name.
- **What it doesn't prove: that the tailnet identity has the permissions the plan needs.** `tso-talos…` goes through the Tailscale API-server proxy as `tailscale-auth` (impersonation). Two things are **UNVERIFIED** for that identity:
  - its RBAC for `patch/delete persistentvolumes`, `delete volumes.longhorn.io`, `create pods/portforward` in `observability`, and `create` of PVCs/Jobs;
  - whether `kubectl port-forward` (used by `am_open`) works through that proxy at all.

  A mid-rehearsal `Forbidden` would stop a scenario halfway. **Fix (MINOR):** add a pre-flight line to §5.2:
  `kubectl auth can-i patch pv; kubectl auth can-i delete volumes.longhorn.io -n longhorn-system; kubectl auth can-i create pods/portforward -n observability; kubectl auth can-i create persistentvolumeclaims -n rehearsal-old`.
  These are SelfSubjectAccessReviews, which are non-mutating. Also update P:48 and P:124 to say "kube-system UID" instead of the context name.
- The `2>/dev/null` hides *why* the check failed, so a transient API timeout reads as "WRONG CLUSTER". Cosmetic.

## 3. Alertmanager silences: scope proof

**Flux labels.** notification-controller v1.9.1 `internal/notifier/alertmanager.go:109-116` sets exactly these labels: `alertname`, `severity`, `reason`, `kind`, `name`, `namespace` (the involved object's), and `reportingcontroller`. P:156 and P:585 call these "INFERRED"; they are now **verified**. `rehearsal-apps` and GitRepository `rehearsal` emit `namespace=flux-system`, `name=rehearsal-apps|rehearsal`. The rehearsal namespaces have no `Alert` CRs (`components/common/alerts` is excluded), so child objects emit nothing.

**VolSync labels.** Verified via the Prometheus series API:

```
volsync_volume_out_of_sync{namespace="volsync-system", obj_namespace="media", obj_name="audiobookshelf-local", role, method, …}
```

`namespace` is the **exporter's** namespace. The per-object namespace is `obj_namespace`.

**Anchoring.** Alertmanager fully anchors regex matchers (`^(?:…)$`). So:

- `namespace=~rehearsal-.*` matches only `rehearsal-*`. It cannot match `volsync-system`, `flux-system`, `develop` or `ai`.
- `obj_namespace=~rehearsal-.*` matches only VolSync series for `rehearsal-*` objects.
- `name=~rehearsal-apps|rehearsal` becomes `^(?:rehearsal-apps|rehearsal)$`. The only objects with those names are the two scratch CRs. It has no namespace constraint, but no other object of any kind is named that. **Safe.**

**Result: no silence can mute an alert outside the rehearsal.**

Minor notes:

- **Expiry.** The 8h expiry vs the timeline (≈5-6h plus waits for `:47` slots, optional S4c/6b) is tight. Re-run `am_silence` if the rehearsal spills over, or make it 12h.
- **Leaked port-forward.** `am_silence` is called bare. A `curl` failure (for example, port-forward not ready after `sleep 3`) aborts the block under `set -e` *before* `am_close`, leaving a `kubectl port-forward` running and 0-2 silences created. Add `trap am_close EXIT` inside `am_open`, or retry the curl.

---

## 4. NEW findings

### MAJOR

**N1. `move_gate` doesn't catch a stale `targetNamespace`/`path`, or an unedited parent kustomization** (G:190-197; P:199-214, P:216)

- The gate greps only for `volumeName|sourceNamespace`. Suppose the operator `git mv`s the directory and adds the patches but forgets `targetNamespace:` in `ks.yaml`. `flux build` renders every object into **`rehearsal-old`**, the grep still finds 2 lines, and the gate **passes**.
- Once pushed, the new Kustomization in `rehearsal-new` applies the app into `rehearsal-old`, at the same moment the old Kustomization (resumed at B4b) prunes it there. You get two Kustomizations fighting over one PVC/RS/RD set. Retain prevents data loss, but the scenario's evidence is garbage.
- Likewise, the porcelain check (G:192) covers only `kubernetes/rehearsal/$ns/$APP`. An **uncommitted** edit to `rehearsal-old/kustomization.yaml` or `rehearsal-new/kustomization.yaml` passes the gate and is simply not pushed. For example, forgetting to add `./moveprobe/ks.yaml` to `$TO` means the old Kustomization is GC'd and no new one appears.
- Aside: the recipe (P:199-214) interleaves "edit by hand" comments inside a non-interactive heredoc, so as written it commits the bare `git mv`. The gate then fails correctly, but an unpushed broken commit is left behind.

**Fix.**

- Check porcelain on the whole tree: `GIT status --porcelain -- kubernetes/rehearsal` must be empty.
- In the app build, assert every `metadata.namespace` equals `$ns`:
  `… | yq -N '.metadata.namespace' | sort -u` must equal exactly `$ns`.
- Build the **parent** and assert the child Kustomization appears exactly once, in `$ns`, with `spec.path == ./kubernetes/rehearsal/$ns/$APP/app` and `targetNamespace == $ns`. Verified to work on the scratch copy:
  `flux build ks rehearsal-apps -n flux-system --path ./kubernetes/rehearsal --kustomization-file ./kubernetes/rehearsal-bootstrap/rehearsal-apps.yaml --dry-run | yq -N 'select(.kind=="Kustomization")|[.metadata.namespace,.spec.path,.spec.targetNamespace]|join(" ")'`
  The old layout printed `rehearsal-old ./kubernetes/rehearsal/rehearsal-old/moveprobe/app rehearsal-old`.
- Split the recipe into "edit" (by hand, outside the heredoc) and "commit + gate + push" blocks.
- The same `targetNamespace` hole exists in the **runbook's** B5 gate. Carry this fix there.

**N2. Baseline `check_backup` runs without its wait** (P:180-182)

- "wait for lastManualSync=seed-1 on both" is a **comment**. Under `bash <<'EOF'`, `check_backup` runs immediately after the patch, against the **previous** mover run's logs.
- If no previous run exists (empty logs), it fails and `set -e` aborts the block, so `inventory_ok`/`others_ready` never run.
- If a scheduled or initial run already happened, it can pass **on a snapshot that is not seed-1**. That is exactly the R-3/R-4 false-green class the rehearsal exists to test.

**Fix.**

```bash
for RS in "$APP-local" "$APP-r2"; do
  for i in $(seq 1 60); do
    [ "$(kn "$OLD" get replicationsource.volsync.backube "$RS" -o jsonpath='{.status.lastManualSync}')" = seed-1 ] && break
    sleep 10
  done
done
```

Then call `check_backup` with `|| rc=1` per RS, so the second one is still reported. Apply the same pattern wherever S1's B3 is written out.

**N3. S3 leaves the app at `replicas: 0`; S1 and S10a need it running** (P:294, P:322, P:327, P:414)

- The S3 rollback commit re-adds `controllers.moveprobe.replicas: 0` (recipe P:206).
- S3 ends at `data_check "$OLD"` and the NEW cleanup. Nothing removes `replicas: 0`.
- S1 starts from "app healthy in `$OLD`", and S10a explicitly needs "app running". With the pod at 0 and the RS still firing at `:47`, the precondition is silently false. A B7 continuity check (`starts` +1 after B8) is then off by one versus the baseline.
- Also, the S3 main block (P:285-298) contains the forward commit as a **comment** followed by `until … Released; do sleep 3; done`, which has **no timeout**. Run literally, it loops until the 10-min tool limit kills it.

**Fix.**

- Split the S3 block at the commit.
- Give every `until` loop a bound (`for i in $(seq 1 100)`).
- Add an **S3 exit step**: a commit removing `replicas: 0` in `$OLD`, then wait for Running, then `data_check "$OLD"` (expect `starts` +1). State that this is S1's precondition.

**N4. `rehearsal_pv_ok` returns 0 ("gone") on *any* `kubectl get pv` failure** (G:83)

- Verified: a listed name that doesn't exist gives `gone: pvc-doesnotexist-1`, `rc=0`. The same branch fires on an API timeout, a tailnet-proxy hiccup, or `Forbidden` (see §2).
- `pv_delete` (G:92-97) then runs `kubectl -n longhorn-system delete volumes.longhorn.io "$pv"`. In teardown it is called as `… && pv_delete "$pv" || true` (P:541), and bash **disables `errexit` inside a function called in an `&&`/`||` list** (verified: `f(){ false; echo inside-continued; }; f && …` prints `inside-continued`). So the Longhorn delete proceeds even if the preceding `kubectl delete pv` failed.
- Net effect: a transient error can delete a rehearsal Longhorn volume while its PV (and possibly a bound PVC) still exist. The damage is bounded to names in `$REH_PVS`, which is rehearsal-only by construction, so it is not a hermes risk. But it is a guard that fails **open**, the exact class this review hunts for.

**Fix.** Distinguish NotFound explicitly:

```bash
out=$(kubectl get pv "$pv" --ignore-not-found -o name) || { echo "REFUSE: cannot read $pv" >&2; return 1; }
[ -n "$out" ] || { echo "gone: $pv"; return 0; }
```

In `pv_delete`, only delete the Longhorn volume if the PV is confirmed gone (or the `kubectl delete pv` succeeded): `kubectl delete pv … && kubectl -n longhorn-system delete volumes.longhorn.io …`.

### MINOR

**N5. `APP` is inherited from the caller's environment unvalidated** (G:21)

- Verified: `APP=hermes bash -c 'source guards; echo $APP'` prints `hermes`.
- `kn` still pins namespaces and the PV guard still refuses hermes' PV, so nothing mutates hermes. But:
  - `others_ready` (G:113) then **excludes every Kustomization named `hermes`**, including `develop/hermes`, from the readiness check;
  - `flux suspend ks "$APP" -n rehearsal-old` targets a nonexistent object;
  - `grep -E "$APP"` in the orphan listings goes wrong.
- The runbook's own variables block sets `APP=hermes`, so a shared shell profile or a pasted snippet makes this plausible.
- **Fix:** `case "$APP" in moveprobe|moveprobe[0-9]) ;; *) echo "APP=[$APP] not a rehearsal app" >&2; exit 1;; esac`

**N6. Recipe placeholder `PV=<recorded PV name>` is a bash syntax error** (P:202)

Verified: `syntax error near unexpected token 'newline'` (rc 2) after the `source` line ran. Fail-closed, but the recipe is unrunnable as written. **Fix:** `PV=$(record_pv "$FROM" "$APP")`, or for S2/S3 read it from the recorded file.

**N7. Stand-alone blocks use `$PV` without defining it; `set -u` aborts them**

- S9 (P:405) and the S1 table rows B4/B10 (P:330, P:341) are affected. Verified: `PV: unbound variable`, rc 1.
- **Fix:** start each such block with `PV=$(record_pv "$NEW" "$APP")`. Don't use `record_pv` where the PVC may not exist; use `tail -1 "$REH_PVS"` plus `rehearsal_pv_ok` there.

**N8. `others_ready` right after `PUSH` can false-abort**

- Every Kustomization reconcile starts with `MarkUnknown(Ready, "Reconciliation in progress")` (`kustomization_controller.go:325`).
- `PUSH` fires the Receiver, which reconciles `cluster-apps` (P:56), and 161 Kustomizations each reconcile on their own intervals. So "not `True`" at a single instant is possible even when nothing is wrong.
- Guardrail 6 turns that into ABORT + teardown. It is not harmful, but it would waste a run.
- **Fix:** treat `Unknown` as retry. Fail only on `Ready=False`, or on anything not `True` for three polls 20s apart.

**N9. S1 B11 is self-contradictory** (P:342)

- B1 suspends the OLD HelmRelease and B4b resumes only the Kustomization, so B5's GC orphans the OLD Deployment and `sh.helm.release.v1.moveprobe.*`. This is the same mechanism as S3's.
- B11 says "list orphans", then "verify `$OLD` holds only `cluster-settings`/`cluster-secrets`". It can't pass without a cleanup step.
- **Fix:** copy S3's evidence → clean → assert-empty block (P:304-312) into B11. That is also the real B11 the hermes runbook needs.

**N10. S8 Block mode details**

- Longhorn supports `volumeMode: Block` in general. It is not verified on this SC or version (v1.12.1), as P:450 says.
- The bait-writer runs `runAsUser: 0` with `drop: [ALL]`. Writing works only if the device node the runtime creates is **owned by uid 0**. Without `DAC_OVERRIDE`, root gets only the owner bits. That is likely, but inferred.
- The **reader** Jobs are "the same shape" but their securityContext is unspecified. Give them `runAsUser: 0` too. Non-root readers depend on whether the kubelet applies `fsGroup` to raw block devices, which is unverified.
- PSA `baseline` admits all of this (no privileged, no hostPath, no added caps).
- The Pending-claims pre-check (P:483) is cluster-wide and not filtered by SC. It is over-strict (any unrelated Pending claim aborts S8), which is harmless.
- The race-sensitive steps 1-5 are comments (P:484-491). Write them as commands. That matters only for the Filesystem fallback, since Block already removes the exposure.

**N11. S10a timing and side effects** (P:416-426)

- `until [ "$(date +%M)" = 46 ]` can block for up to 59 minutes. The tool call limit is 600s, so run it with `run_in_background`, or start the block at `:44`.
- The "poll every 10s for ~6 min" is a comment, not a loop.
- 10a leaves `spec.trigger.manual=race-…` on the OLD RS. 10b's "before" reading (P:436, expected `{"schedule":…}`) is then already polluted, and scheduled syncs stop (manual takes precedence) until B3.
- **Fix:** after 10a, apply the removal from P:445 and confirm the next `:47` fires; or fold 10a's observation into 10b.

**N12. Blocks that outlive a tool call or leak background processes**

- Teardown P:535 + P:539 are each `--timeout=600s` in one block, which exceeds the tool limit. Split them.
- S1 B5's `kubectl get -w … > file &` watchers (P:333) survive the `bash` block. Record their PIDs in `$REH_DIR` and kill them after B6.

**N13. S1 B5b drill ownership**

The plan expects `root:root` files in unannotated `rehearsal-new`. A drill Job running as uid 10000 (as in `data_check`) then cannot read the 600/660 root-owned files, so `sha256sum` fails for permission reasons, not data reasons. Run the drill Job as `runAsUser: 0` (baseline allows it), and record `ls -ln` separately.

**N14. Stale text**

- P:48 and P:124: context-name check. Now a UID check.
- P:156 and P:585: Flux label names "INFERRED". Now verified (§3).

## 5. Fixture renders (scratch copy, verified)

| Build | Result |
| --- | --- |
| Old layout `rehearsal-old/moveprobe` | rc 0; ExternalSecret ×2, HelmRelease, OCIRepository, PVC, RD, RS ×2; `volumeName\|sourceNamespace` = **0**; control-plane `nodeAffinity` renders |
| Parent `rehearsal-apps` | rc 0; both Namespaces, `cluster-settings` + `cluster-secrets` in each; child Kustomization in `rehearsal-old` with `substituteFrom` |
| Moved layout → `rehearsal-new` + kind-targeted patches | **2 lines**: `volumeName` and `sourceNamespace: rehearsal-old`; all objects `namespace: rehearsal-new` |
| Rollback layout → `rehearsal-old`, `volumeName` patch only | **1 line** (`volumeName`), matching `move_gate "$OLD" 1` |
| Namespace annotations | `privileged-movers`: `rehearsal-old` 1, `rehearsal-new` 0 |

## 6. Sequence walk 7 → 2 → 3 → 1 → 8 (preconditions)

- **Bootstrap → baseline:**
  - N2: the wait is missing.
  - N8: `others_ready` right after the push.
- **S7:** local only; OK.
- **S2:**
  - Setup (Retain, suspend ks+hr, scale 0) establishes the orphan preconditions correctly.
  - Observation block OK.
  - Recovery deletes every orphan and re-points, so `$OLD` is left with only `cluster-*`, the PV is Retain and claimRef'd to `$NEW`, and the NEW HelmRelease is **not** suspended.
  - The "remove `replicas: 0`" commit is ad hoc: write it as its own block (the gate still expects 2).
- **S3:**
  - Precondition (app running in `$NEW`) is met by S2.
  - The block must be split (N3).
  - Its NEW-orphan cleanup is correct. Re-run it if GC is still finishing: the `pvc` / `volsync-moveprobe-*` names match `grep "$APP"` while they terminate.
  - **Leaves the app at 0 (N3).**
- **S1:**
  - Starts from the wrong state until N3 is fixed.
  - 10a pollutes 10b (N11).
  - B4b → B5: correct; GC runs because the Kustomization was resumed.
  - B5b drill ownership (N13).
  - B6 re-point from a Released PV claimRef'd to `$OLD`: guard OK.
  - B10 sets Delete.
  - B11 needs a cleanup (N9).
- **S8:**
  - Runs after S1 in `$OLD` (annotated) with the app in `$NEW`; no conflicts.
  - A claimRef-less bait PV is accepted by the guard for cleanup (listed + labelled).
- **Teardown:**
  - Step 0 → `adopt_pv` only receives `rehearsal-*` claimRefs, so it can't refuse and abort the pipeline.
  - Step 2 → step 3 (resumed Kustomizations actually prune) → step 5 → step 6 (leftovers) is sound, apart from N4.
  - A Released PV keeps its claimRef, so it is adopted.
  - A claimRef-less PV is reachable only if it was recorded earlier. The S8 bait always is, and the verification query at P:558 would surface any other.

## 7. Blast radius re-confirmed

- **Namespaced mutations** all go through `kn` (refuses `develop`: verified). The exceptions are the literal-namespace `kubectl -n "$OLD|$NEW"` in the helm-Secret `xargs` (P:268, P:310) and the `flux` CLI calls with `-n "$OLD|$NEW"`; `OLD` and `NEW` are **hard-set** in G:22, not taken from the environment.
- **PV mutations** go only through `pv_*`. The hermes PV is refused by name (verified) and by claimRef.
- **Git:** `PUSH` accepts no args and checks the branch. The only other remote write is teardown's explicit `push origin --delete rehearsal-move`.
- **Outside `rehearsal-*`**, the only writes are the two `flux-system` CRs, the silences (§3), and reads of the shared OpenBao template keys (unchanged from rev 1).
- No command references the Receiver, the `Alert` CRs, `cluster-apps` (except `others_ready`, which reads it), `home-kubernetes` or `main`.
- The one weakening is N5 (`APP` from the environment), which is read-only in effect.

## GO / NO-GO

**NO-GO as written.** No blocker threatens anything outside the rehearsal, but as written:

- **N1**: the gate can pass a mis-edited move;
- **N2**: the baseline acceptance check can pass on the wrong snapshot;
- **N3**: S1 starts from a false precondition;
- **N4**: the PV guard fails open on API errors.

**GO once these four MAJOR fixes are in:**

- **N1**: whole-tree porcelain, a namespace assertion, and a parent-build assertion in `move_gate`;
- **N2**: an explicit `lastManualSync` wait before `check_backup`;
- **N3**: an S3 exit commit restoring `replicas`, S3 split at the commit, and bounded loops;
- **N4**: `--ignore-not-found` in `rehearsal_pv_ok`, and `pv_delete` deleting the Longhorn volume only after the PV is confirmed gone.

**Strongly recommended with them:**

- N5 (APP allowlist);
- N6 / N7 (placeholders and unbound `$PV`);
- the `auth can-i` pre-flight from §2 for the tailnet identity.

The remaining MINOR items can be fixed during execution.
