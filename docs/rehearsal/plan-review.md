# Pre-flight review: `docs/rehearsal/plan.md` (moveprobe namespace-move rehearsal)

Read-only review, 2026-09-23. Nothing was applied, committed or pushed.

**Inputs**

- The plan.
- The fixtures in `~/.herdr/worktrees/flux-talos/rehearsal-move/kubernetes/{rehearsal,rehearsal-bootstrap}/` (uncommitted).
- The live cluster (`kubectl get` only).
- Flux controller source at the deployed tags (kustomize-controller v1.9.1, helm-controller v1.6.1).
- Local shell tests of zsh behaviour on this host (`$SHELL=/bin/zsh`).

"Line N" means `docs/rehearsal/plan.md` line N.

**Verified** means observed live, in controller source, or in a local shell test. **Inferred** means reasoning I did not test.

## Verdict up front

**No path from this plan to hermes, `develop`, `ai`, `cluster-apps` or `main` was found.** The scratch parent is genuinely isolated: its patches only apply to its own build output, and none of its selectors can reach live objects. The failure modes are:

- (a) the plan does not execute as written in this environment (zsh; the agent's shell state does not persist between tool calls);
- (b) one guard fails **open** and two teardown paths can strand a PV;
- (c) one deliberate test briefly exposes a PV to the whole cluster;
- (d) several scenarios cannot tell apart the outcomes they claim to close.

**NO-GO as written; GO after the BLOCKER and MAJOR fixes below.** See the end of the file.

## Summary

| # | Sev | Line(s) | Finding |
| --- | --- | --- | --- |
| 1 | **BLOCKER** | 96-152, 101-102, 158-160, 197 | The "paste once per shell" guard model doesn't hold here. Tool calls don't keep functions or variables, and under **zsh** `$GIT add …` / `$PUSH` fail with `command not found` (verified). Most guarded steps then fail closed, but the run becomes unpredictable, and the obvious "fix" is a bare `git push` |
| 2 | MAJOR | 129-151, 172, 248 | `data_check` mounts the RWO Longhorn PVC from a second pod with no node pinning. While the app pod is running (baseline 172, S2 248), a different node gets **Multi-Attach**, the Job hangs 240s, and baseline **ABORTs** on a false failure. On failure the logs are never shown |
| 3 | MAJOR | 355-362 (S8 step 2) | Removal-only makes the bait PV `Available` to **any** cluster PVC on `longhorn-1-replica-local` requesting ≤1Gi. That is the one step with blast radius outside `rehearsal-*` |
| 4 | MAJOR | 393, 420, 422 | `jq … select(.spec.claimRef.namespace\|test(…))` **aborts** (rc 5, verified) on the first PV with no claimRef. Teardown step 0 then silently records nothing after that point, and the verification query errors instead of reporting leftovers |
| 5 | MAJOR | 113-120, 405-408 | `rehearsal_pv_ok` refuses a PV whose claimRef was cleared (S8 bait), so teardown **sticks** and leaves an `Available` PV in the cluster (feeding #3). Separately, the Longhorn `volumes.longhorn.io` delete at 407 runs **without** the guard, even when the guard just refused the PV |
| 6 | MAJOR | 257-260 (S3) | S3 moves the app back while the NEW HelmRelease is **suspended**, so GC orphans the NEW Deployment and `sh.helm.release.v1.moveprobe.*` Secrets (helm-controller v1.6.1 skips uninstall when suspended, verified). S1 then lands in a NEW namespace that already holds release history, so it is not the "clean" run the plan relies on |
| 7 | MAJOR | 38, 54, 444 | Both rehearsal namespaces carry `privileged-movers: "true"`. The real pairing is `develop` annotated → `ai` **unannotated**, so the post-move backup (B9) is rehearsed in the wrong namespace shape |
| 8 | MAJOR | 205 (S7b) | 7b's expected observation cannot appear. After S1 the PVC already exists, so dropping `volumeName` hits the immutable-field SSA error (that's 4c), not a fresh populator PVC. The RD won't re-run (its trigger tag is unchanged), so `requestedIdentity` stays stale |
| 9 | MINOR | 167-168 | The inventory check's `grep -v 'rehearsal-(old\|new)'` also filters out the Namespace entries, so the expected output is empty, not "only Namespace entries". It also fails **open** if the inventory is null (a jq error reads as clean) |
| 10 | MINOR | 229 | The S2 "orphan" pass criterion says "PVC still Bound". A PVC that is being deleted but held by pvc-protection is **also** Bound. Check `.metadata.deletionTimestamp` to tell an orphan from a slow prune |
| 11 | MINOR | 302 | `(.fieldsV1\|keys)` only shows `f:metadata`/`f:spec`. It cannot show who owns `f:volumeName` |
| 12 | MINOR | 316-325 (S6) | Locality pass criterion is "stays on **or** follows", which passes either way. The pod may not even change node (no cordon allowed). Pis have **0** Longhorn disks, so a Pi placement always means a remote replica |
| 13 | MINOR | 384 (#12) | The in-flight `lastManualSync` race needs the patch to land during a live sync. A 1 MiB volume's sync is short, so it is not closed unless it is made deterministic |
| 14 | MINOR | 442, guardrail 8 | A push to **any** branch fires the Receiver, which reconciles `home-kubernetes` **and `cluster-apps`** (live). Harmless (it re-applies `main`), but the plan says only `home-kubernetes` |
| 15 | MINOR | 437 | Alert noise. `flux-system/alertmanager` (`Kustomization/*`, `GitRepository/*`) will page on `rehearsal-apps`/`rehearsal` errors, and `VolSyncVolumeOutOfSync` is cluster-wide, so orphaned/manual moveprobe RSes can fire it. Silence first |
| 16 | MINOR | 92 | "The `refreshInterval: 5m` patch comes from the component": it comes from `components/common`, which the rehearsal deliberately does **not** include. It doesn't change any outcome |
| 17 | MINOR | 5, 177, 430 | kopia residue persists, so a **re-run** after teardown restores `moveprobe@rehearsal-old` from run 1 at first deploy, and the baseline `starts=1` check fails |
| 18 | MINOR | 403, 411-412 | Teardown uses variables where literals would be safer (`kubectl delete ns $OLD $NEW`). Harmless with empty vars under zsh (verified: empty unquoted params vanish), but spell the names out |

---

## 1. Blast radius (question 1)

All verified unless marked otherwise.

**Scratch parent vs `cluster-apps`.**

- The live `cluster-apps` spec is `path ./kubernetes/apps`, `prune: true`, `decryption.provider: sops` with **no** `secretRef`, `retryInterval 2m`, `timeout 5m`, `wait: false`.
- `diff` of `cluster-apps.spec.patches` (live, JSON) against `rehearsal-apps.yaml` `spec.patches` gives **identical** patches.
- Kustomization `spec.patches` are applied only to that Kustomization's own build output, so the label/kind selectors (`kind: Kustomization`, `labelSelector: substitution.flux.home.arpa/disabled!=true`, `kind: HelmRelease`) can only match the child `moveprobe` Kustomization and the HelmRelease inside it. **They cannot reach live objects.** OK.

**SOPS / `cluster-secrets`.**

- kustomize-controller runs with `--sops-age-secret=sops-age` (live args). That is the fallback key for any Kustomization without a `secretRef`, so `rehearsal-apps` decrypts exactly as `cluster-apps` does.
- `components/common/cluster-config` contains only ConfigMap `cluster-settings` and Secret `cluster-secrets`, **with no `metadata.namespace`**. The parent kustomization's `namespace:` places them in `rehearsal-old`/`rehearsal-new`. No collision with, or write to, `flux-system` or any other namespace.
- The pushed fixture adds no SOPS file and no new secret material. The encrypted file is already public on `main`.

**Names.** None of these exist live: namespaces `rehearsal-*`, Kustomization `moveprobe`, `rehearsal-apps`, GitRepository `rehearsal` (only `home-kubernetes` and `flux-talos-ssh` exist). No collisions.

**Cluster-scoped objects.**

- Only the two Namespaces. `kustomize.toolkit.fluxcd.io/prune: disabled` **is** honoured on parent deletion, not just on prune: `deleteObjects()` in the finalizer passes `Exclusions: {kustomize.toolkit.fluxcd.io/prune: disabled}` (`kustomization_controller.go:1410`). Teardown step 5 deletes them by hand. OK.
- PVs are the only other cluster-scoped objects (#3, #4, #5).

**Hermes.** No command in the plan selects PVs or Kustomizations cluster-wide for mutation.

- `flux resume ks --all` is always `-n rehearsal-*`, and the loop at 395 iterates only over non-empty values.
- `rehearsal_pv_ok` refuses the hermes PV twice: by name, and because its claimRef is `develop`.
- Teardown step 0 records only PVs whose claimRef namespace is `rehearsal-*`, and hermes' is `develop`.
- With functions missing (#1), the `rehearsal_pv_ok … && kubectl patch pv` pairs fail closed (`command not found`).

The only unguarded destructive commands on PV-like objects are the Longhorn deletes at 407 (#5), and they are limited to names in `$REH_PVS`.

## 2. Push side effects (question 2)

All verified.

- **Workflows** (`.github/workflows/*`, identical to `main`):
  - `flux-local`, `image-pull`, `labeler` run on `pull_request` → `main`;
  - `claude-code-review` runs on `pull_request`;
  - `claude.yml` runs on comments, issues and reviews;
  - `label-sync` and `schemas` run on `push` to **`main`** with path filters;
  - `tag` and `tailnet-cleanup` run on schedule or dispatch.

  **No workflow triggers on a push to `rehearsal-move`.** Guardrail 2 ("never open a PR") is the right line.
- **Receiver `github-webhook`** listens for `push` on **any** branch and reconciles `GitRepository/home-kubernetes` **and** `Kustomization/cluster-apps`. Harmless: it is a no-op re-apply of `main` (#14).
- **Renovate**: `.renovaterc.json5` has no `baseBranches`, so it only works on the default branch. It does nothing.
- **Image automation** (`flux-talos-ssh`) tracks `main` only.
- **No `.drone.yml`** in the repo.
- **`github-status` Alerts** only report on `cluster-apps`.
- **Upstream**: the branch has **no upstream** (`fatal: no upstream configured`), so a bare `git push` errors rather than targeting `main`. Good. Remote is SSH (`git@github.com:`). If SSH push fails, use the HTTPS fallback from memory, still with an explicit refspec.
- **Hooks**: a lefthook pre-commit **will** run on `$GIT commit`: gitleaks, plus yamlfmt on the staged YAML. yamlfmt may rewrite the flow-style maps/arrays in `helmrelease.yaml` (`{drop: ["ALL"]}`). That is semantics-preserving, but it means the pushed files are not byte-identical to what `flux build` checked. **Re-run the gate after the commit, not before.** Nothing in the fixture looks like a secret.

## 3. Guard logic (question 3)

### BLOCKER 1 — the guards don't exist where the commands run; `$GIT`/`$PUSH` break under zsh

- The plan says "paste once per shell" (line 96). In this agent environment every Bash tool call is a **fresh** shell: functions and exports don't persist.
- zsh does not word-split unquoted parameters. Verified:

  ```
  $ zsh -c 'G="echo -n hi there"; $G add'
  zsh:1: command not found: echo -n hi there     (rc 127)
  ```

  So line 158 (`$GIT add`), 159 (`$GIT commit`), 160 and 197 (`$PUSH`) all fail. Fail-closed, but the first bootstrap step can't succeed, and the tempting workaround is a bare `git commit`/`git push`. Guardrail 2 forbids exactly that.
- Line 99: `return 1` at the top level of `zsh -c` exits the whole command string (verified: `rc=1`, later lines not run). That is fine non-interactively. Pasted into an interactive shell it would not stop the paste.
- Line 105: `S=` is hard-coded to **another session's** scratchpad (`33a0c13e-…`). `REH_PVS` lives there. If that directory is gone, `touch` fails, `rehearsal_pv_ok` refuses everything (closed), and `record_pv` still echoes the name but records nothing. Teardown then leans entirely on step 0, which is also broken (#4).

**Fix.**

- Put the variables and functions in a file, e.g. `$R/../rehearsal-guards.sh` (keep it outside the repo), with `#!/bin/bash` and `set -euo pipefail`.
- Start **every** command with `source <file>`, and run them under `bash`.
- Replace the string commands with functions:

  ```bash
  GIT() { git -C "$R" -c 'user.name=fizz-bot-bvn[bot]' -c 'user.email=324971095+fizz-bot-bvn[bot]@users.noreply.github.com' "$@"; }
  PUSH() { git -C "$R" push origin rehearsal-move:refs/heads/rehearsal-move; }
  ```

- Put `REH_PVS` in a stable path (for example next to the guards file). Make the context check `|| exit 1`.

### MAJOR 2 — `data_check` Multi-Attach

The app PVC is RWO on Longhorn. A second pod can mount it only on the **same node**, and there are 7 schedulable workers.

- Line 172 (baseline, pod Running) and line 248 (S2, pod Running) will usually schedule the Job elsewhere. The pod then sits `ContainerCreating` with `Multi-Attach error`, `wait` times out at 240s, and line 178 says ABORT.
- `wait --for=condition=complete … && logs` never prints logs when the Job **fails**, which is exactly the case you need to read.

**Fix.**

- If the app pod exists, pin the Job with `nodeName: $(kn $ns get pod -l app.kubernetes.io/name=$APP -o jsonpath='{.items[0].spec.nodeName}')`, or only run `data_check` with the app at 0.
- Wait for `condition=complete` **or** `condition=failed`: run two `wait`s in the background, or poll `.status.succeeded/.status.failed`. Always print logs.

### MAJOR 4 — teardown/verification `jq` aborts on claimRef-less PVs

Verified: `echo null | jq 'test("x")'` gives `null (null) cannot be matched` with rc 5. Any `Available` PV (the S8 bait after step 2, or any cluster PV with no claimRef) stops step 0 (393) at that point, and the verification queries (420, 422) error out instead of reporting.

**Fix.** Use `select((.spec.claimRef.namespace // "") | test("^rehearsal-"))`. The same applies to 420 and 422, where `kubernetesStatus.namespace` can be null.

### MAJOR 5 — teardown can strand a PV; the Longhorn delete bypasses the guard

- Line 117: a PV with `claimRef` removed returns an empty namespace, which is refused. For the S8 bait (or any PV left after a removal-only step), steps 2 and 6 refuse forever. The PV stays `Available` (Retain or Delete), in the cluster, bindable by others (#3).
- A PV whose claimRef was re-pointed to `rehearsal-*` passes, which is correct.
- Line 407 runs `kubectl -n longhorn-system delete volumes.longhorn.io "$pv"` whenever the Longhorn volume exists, **regardless** of whether `rehearsal_pv_ok` just refused the PV. The result is a PV pointing at a deleted volume (rehearsal-only names, but the ordering violates guardrail 5).

**Fix.**

- Extend `rehearsal_pv_ok`: accept an **empty** claimRef **only** if the PV is in `$REH_PVS` **and** carries a rehearsal marker. Label the PV when it is recorded: `kubectl label pv $pv rehearsal=move`. Then check `rehearsal=move`, `claimRef.ns ∈ rehearsal-*` or empty, and membership of the list.
- Nest the Longhorn delete under the same guard:
  `rehearsal_pv_ok "$pv" && { kubectl delete pv "$pv" --ignore-not-found; kubectl -n longhorn-system delete volumes.longhorn.io "$pv" --ignore-not-found; }`
- Delete the bait **before** leaving S8. Never end a step with a claimRef-less PV.

### Other guard notes (no action needed)

- `kn`: when the namespace is empty, zsh drops the unquoted `$OLD`, so `$1` becomes the verb and the call is refused (verified: `argc=1 1=[delete]`). Fail-closed.
- `record_pv` / `check_backup`: `<<<` and `grep -c` work in both shells.
- `check_backup` does **not** assert its "want" values. It prints counts and a human decides. Acceptable, but consider `return 1` when a count fails.
- The `while read` loops use `kubectl` calls that don't read stdin, so the loops are safe.

## 4. Scientific validity (question 4)

### MAJOR 3 — S8's "thief" step exposes the bait PV cluster-wide

Between step 2 (claimRef removed → `Available`) and step 3, **any** Pending PVC in **any** namespace with SC `longhorn-1-replica-local`, RWO, requesting ≤1Gi can bind the bait. The SC is WaitForFirstConsumer, and the scheduler's volume binder prefers existing Available PVs (inferred, standard behaviour).

Live claims on that SC include `ai/hindsight-hf-cache` (**1Gi**). If it were recreated during the window, or any new ≤1Gi claim appeared, a production workload would get the bait volume with a junk file. The teardown guard would then correctly refuse it (claimRef not rehearsal), leaving a cross-namespace mess.

**Fix, in order of preference:**

- (a) Create the bait PV and thief/wanted PVCs with **`volumeMode: Block`**. Every production claim is Filesystem and cannot match a Block PV. The consumer Job then uses `volumeDevices` and `dd` for the marker.
- (b) Keep Filesystem. Immediately before step 2, assert `kubectl get pvc -A --field-selector=status.phase=Pending` is empty, then create the thief and its consumer in the **same command** to keep the window to seconds. The bait size doesn't help here: a PV matches every claim that requests less than or equal to its capacity.

Result interpretation is fine: re-point with `uid: null` reserves the PV for `wanted`, and WFFC needs the consumer Jobs, which the plan includes.

### MAJOR 6 — S3 leaves orphans in NEW that contaminate S1

S3 suspends the NEW HelmRelease (257), resumes only the Kustomization (259), and commits the move back. GC deletes the suspended HR **without uninstall**: helm-controller v1.6.1 `reconcileDelete` runs the uninstall only `if !obj.Spec.Suspend` (`helmrelease_controller.go:455`). What remains in NEW:

- Deployment `moveprobe` (Helm-annotated, replicas 0);
- `sh.helm.release.v1.moveprobe.v1…` Secrets;
- the RS/RD-owned leftovers are GC'd.

S1 then recreates HelmRelease `moveprobe` in NEW. helm-controller finds the existing release storage and **upgrades** it, instead of doing a fresh v1 install, and adopts the orphaned Deployment. S1's B11 / R-12 observation ("orphans from the suspended HR") and runbook §6.3 ("release restarts at v1") are no longer tested cleanly.

**Fix.** After S3, repeat S2's orphan cleanup in `$NEW`: `deploy,svc,sa -l app.kubernetes.io/instance=$APP`, plus the `sh.helm.release.v1.$APP.*` Secrets. Then assert `kn $NEW get all,secret | grep moveprobe` is empty before starting S1. Record what was orphaned: it is S3's evidence for R-12.

### MAJOR 7 — namespace annotation does not mirror develop → ai

`develop` has `volsync.backube/privileged-movers: "true"` (PSA privileged). `ai` has **neither** (PSA baseline). Both rehearsal namespaces are annotated.

S1's B9 (first backup in NEW), the B5b restore drill in NEW, and the post-move RS all run with mover caps that `ai` will not have. The plan treats this as an optional second pass (444).

**Fix.** Remove the annotation from `rehearsal-new/namespace.yaml` **by default**, so NEW mirrors `ai`. Record the restored ownership in the B5b drill: `root:root` expected per [S-priv].

### MAJOR 8 — S7b tests the wrong thing

After S1 the NEW PVC exists and is bound. Pushing name-targeted patches does not create a PVC. It asks SSA to **remove** `volumeName` from a bound claim, which is 4c's immutable-field failure. The RD's `trigger.manual` is unchanged, so VolSync does not re-run it, and `status.kopia.requestedIdentity` keeps the old value.

**Fix.** Either drop 7b (the offline gate in S7 already proves the patch mechanics, and B5b checks it live), or run it as a real move step: name-targeted variant **plus** a new PVC, e.g. during S1's B5 on purpose, with Retain set. Expect the B5b check to fire, then fix forward.

### Smaller validity notes

- **S2 (#10).** The pass criterion must include `kn $OLD get pvc $APP -o jsonpath='{.metadata.deletionTimestamp}'` = empty, and the same for the HR and RS. Only then does "Kustomization gone + objects present with no deletionTimestamp" prove orphaning.

  Source reading (kustomize-controller v1.9.1 `finalizerShouldDeleteResources`: `if obj.Spec.Suspend { return false }`) predicts orphaning, and the finalizer issues deletes **before** removing itself. So a "slow prune" would show deletionTimestamps, not intact objects.

- **S4 (#11).** Use `jq '.metadata.managedFields[]|{manager,operation,spec:((.fieldsV1["f:spec"]//{})|keys)}'`.

  Also, `VOLSYNC_CAPACITY` 1Gi→2Gi changes the PVC request **and** the RS/RD `capacity`. The RD dest PVC and the RS clone sizes change too, so record whether VolSync recreates the dest PVC.

  With the app pod at 1 replica this is an **online** expansion. Record the Longhorn version and whether it completes without a restart.

  4c's prediction is sound. `volumeName` is set only by kustomize-controller here (pre-bound; the binder doesn't change it), so SSA will try to remove it and the apiserver rejects it (inferred).

- **S6 (#12).** Pass/fail must be stated before the run.

  `kubernetesStatus` → `rehearsal-new/moveprobe` is discriminating. Locality is not: with `dataLocality: best-effort` and 1 replica, "follows the pod" requires the pod to land on a **brokkr** node other than the replica's. Pis (`jormungandr*`, 0 Longhorn disks) can never hold the replica.

  Since cordoning is forbidden, deleting the pod will usually reschedule it to the same node or to a Pi. Mark #5-locality "not closed unless the pod moved to another brokkr", and record the node before and after.

  Note the fixture lacks hermes' control-plane anti-affinity. That is harmless, since `freyja01` is presumably tainted, but add it for parity.

- **S10 / #12 (#13).** To actually rehearse R-4:

  1. poll until `.status.lastSyncStartTime` is **non-empty** at the `:47` slot;
  2. patch `manual: $TAG` immediately;
  3. record whether `lastManualSync==$TAG` after **that** sync, and whether a second sync starts.

  Snapshot + clone + mover start on Longhorn takes ~1-2 min even for 1 MiB (inferred from the smoke timings), so the window is catchable. It needs to be written down as the procedure.

- **The populator path is exercised.**
  - First deploy: RD with no series → empty image → populated PVC. That is [S-b] as a feature, and correct.
  - S3b is the restore-into-new-volume case.
  - S1/S2 pre-bound claims check that the populator is **not** exercised.

  Busybox/app-template: the chart from `oci://ghcr.io/bjw-s-labs/helm/app-template` 5.2.1 is the same source hermes uses and is reachable. `docker.io/library/busybox:1.37` is multi-arch (Pis fine).

  Longhorn snapshots on this SC: `longhorn-snapclass` is `type: snap`, `deletionPolicy: Delete`, and the smoke test used exactly this SC and class. 1Gi volume with 2Gi caches is ample.

- **Known-untested items that will NOT be closed despite the §7 table:**
  - **#5 locality**: not closed unless the pod actually changes brokkr node (see S6 above).
  - **#9**: tiny data. The plan admits it.
  - **#10 route**: the plan admits it.
  - **#12**: not closed unless S10 follows the procedure above.
  - **#11 dest-PVC delete**: only if the B5b drill's dest PVC is actually deleted and the RD is observed afterwards. Does VolSync recreate it on the next trigger?

## 5. What the real hermes move needs but this doesn't rehearse (question 5)

- **Unannotated destination**: see #7. Make it the default.
- **HTTPRoute hand-over** (runbook trap / R-11). Deliberately not rehearsed, and **correctly so**. An HTTPRoute on the shared `internal` gateway is outside the blast radius, and external-dns/gatus/homepage react to route annotations (inferred: external-dns watches routes and would publish a DNS record). Keep it open, and verify by hand during the real move (`kubectl get httproute -A | grep hermes` → exactly one, in `ai`).
- **The live-sync race at hermes' size (570 MB)** and the ~44Gi B5b drill. The size-dependent timing is not rehearsed.
- **`develop`'s PSA `privileged` vs `ai` baseline for the app pod itself.** Hermes' s6 entrypoint needs root/caps. `ai`'s baseline was chosen for it, but busybox as uid 10000 doesn't exercise that.
- **Reloader + a real `ExternalSecret` (`hermes-secret`)**, and HelmRelease remediation settings. These are not in the fixture. Low risk, but the hermes HR has `install.remediation.retries: 3`, which matters if the first install in `ai` fails.
- **kopiur**: correctly out of scope (hermes is not on kopiur).
- **Alert handling during the real move**: #15 applies to hermes too. `VolSyncVolumeOutOfSync` on the old RS while it is in manual mode or orphaned.

## MINOR details

- **9.** Replace 167-168 with a positive assertion:
  `kubectl -n flux-system get ks rehearsal-apps -o json | jq -e '[.status.inventory.entries[].id] | length > 0 and all(test("^(rehearsal-(old|new)_|_rehearsal-(old|new)__Namespace$)"))'`
  This fails closed on a null inventory.
- **14.** Correct guardrail 8 and open item 1: the Receiver reconciles `cluster-apps` on every branch push.
- **15.** Before bootstrap, add Alertmanager silences for `namespace=~"rehearsal-.*"` and for Flux alerts naming `rehearsal-apps`/`rehearsal`. Do not edit the `Alert` CRs.
- **16.** Delete the `refreshInterval` sentence at 92, or say the rehearsal ExternalSecrets use the ESO default.
- **17.** Record the residue in `results.md`. For any re-run, change `APP` (e.g. `moveprobe2`), since the series can't be deleted without a kopia client.
- **18.** Use literal `rehearsal-old rehearsal-new` in teardown steps 1 and 5.
- The commit trailers at 159/197 name "Claude Sonnet 5". Use the executing model's trailer as given by the session.

## GO / NO-GO

**NO-GO as written.** The deciding reason is BLOCKER 1: under zsh and per-call shells, the plan's own commit/push and guard setup fail. That fails closed, but the obvious improvisations are exactly the forbidden ones.

**GO after these fixes:**

- **BLOCKER 1**: guards file sourced per command, under bash; `GIT`/`PUSH` as functions; stable `REH_PVS`.
- **MAJOR 2**: `data_check` node pinning, plus logs on failure.
- **MAJOR 3**: S8 bait as `volumeMode: Block`, or a Pending-claims pre-check in the same command.
- **MAJOR 4 and MAJOR 5**: null-safe jq; claimRef-less guard path via PV label; guarded Longhorn delete.
- **MAJOR 6**: NEW orphan cleanup after S3.
- **MAJOR 7**: `rehearsal-new` unannotated.
- **MAJOR 8**: drop or redesign 7b.

With those in place I found no mechanism by which the rehearsal can affect objects outside `rehearsal-old`/`rehearsal-new` (plus its two `flux-system` CRs, its own PVs/Longhorn volumes, and tiny `moveprobe@*` kopia series in the shared repos), and none that can touch hermes.
