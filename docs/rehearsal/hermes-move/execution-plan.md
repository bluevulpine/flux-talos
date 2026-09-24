> **EXECUTED 2026-09-24 — see [`results.md`](results.md).** This is the plan **as executed** (the real `develop/hermes` → `ai/hermes` move succeeded; ~17.5 min downtime, no data loss). Commands, SHAs, PR numbers (#1915/#1916) and paths are the values that were used and are kept as a record, not as a template: `~/.herdr/worktrees/…` paths refer to the operator's machine, and the guards (`hermes-move-guards.sh`, `hm`, `guards-test/`) are **reference copies that hard-code hermes, its PV name and paths — do not re-run them against another app.** The generic procedure lives in `docs/runbooks/volsync-app-namespace-move.md`.

# Execution plan: moving `develop/hermes` → `ai/hermes`

Prepared 2026-09-24, revised the same day after the adversarial pre-flight review (`docs/rehearsal/hermes-move/plan-review-1.md`; every finding is mapped in **Changes since the pre-flight review** at the end).
**Nothing in this file has been executed.** It is the copy-pasteable sequence for the real move; the procedure and its evidence are in `docs/runbooks/volsync-app-namespace-move.md` (**the runbook**; step names B0–B11, traps 1–15 and tags `[Rh-n]` are theirs)
and were rehearsed on a throwaway app (`docs/rehearsal/results.md`). This document adds the order of operations, the two-PR mechanics, the clock, the abort/rollback rules and the alerting.

**Convention:** **UNVERIFIED** = an assumption nobody has tested. **TESTED** = exercised by the rehearsal (1 MiB fixture, throwaway app). **UNTESTED** = source reading or reasoning only.

## 0. What is prepared

### The literals — the ONE place that is filled in, at T-1.5

Every command below uses literal values. The two SHAs are already literal in this file **and pinned inside the guards** (`PR1_SHA`, `PR2_SHA`, `BASE_SHA` in `hermes-move-guards.sh`; `pr_merge` refuses anything else). The two PR numbers do not exist yet: at T-1.5 run, **once**,
`sed -i '' 's/1915/<the real number>/g; s/1916/<the real number>/g' ~/.herdr/worktrees/flux-talos/hermes-to-ai/docs/runbooks/hermes-ns-move-execution.md` and confirm `grep -c '<PR[12]>' <file>` prints `0`. After that no command may contain a variable, a `$(cat …)`, or an empty argument where a PR number goes.

| Literal | Value |
| --- | --- |
| PR 1 | `1915` (branch `hermes-move-pr1`) |
| PR 2 | `1916` (branch `hermes-move-pr2`) |
| SHA 1 (commit 1, the move, pod held at 0) | `b7667471e658da525f1dd3aaa0ca1524a96d1717` |
| SHA 2 (commit 2, start the pod) | `b91dd0c9b94b959432ce4b0d2ec1b788d02a5dbf` |
| BASE (main the commits were built on) | `9d73a56dc1b5f90c0789690df1a29e43c7db48bc` |
| PV | `pvc-12f54114-9e99-442b-bae4-53a9cb239d69` |

If a commit is ever rebuilt (rebase, review finding) the SHAs change: update this table, every command, and the three constants in the guards, re-run every gate and the guard tests, and redo T-1.4–T-1.6.

| Item | Where | State |
| --- | --- | --- |
| Commit 1 — the move, `controllers.hermes.replicas: 0`, HelmRelease `spec.timeout: 15m` | branch `hermes-move` `b7667471…` (worktree `~/.herdr/worktrees/flux-talos/hermes-move`) | local only, **not pushed**, bot-authored |
| Commit 2 — start the pod (drops `replicas: 0`; leaves the timeout) | same branch `b91dd0c9…` (child of commit 1) | local only, **not pushed** |
| Guards | `~/.herdr/worktrees/flux-talos/hermes-move-guards.sh` | `bash -n` + `shellcheck` clean; **108** fake-`kubectl`/fake-`gh` tests pass under `/bin/bash` (§ 12) |
| `hm` | `~/.herdr/worktrees/flux-talos/hm`, symlinked as `~/.local/bin/hm` | an executable **script** (`source` guards, `eval "$*"`); state paths come from the guards, never the caller's environment |
| Guard tests | `~/.herdr/worktrees/flux-talos/hermes-move-guards-test/` (`run.sh`, `gate-test.sh`, fake `bin/kubectl`, `bin/gh`) | rerun after any edit to the guards |
| This plan | `hermes-to-ai` docs branch | **not committed** |

**Real values** (re-verified read-only 2026-09-24): PV as above (`Bound`, reclaim `Delete` **until T-1.3b**), PVC `develop/hermes` 20Gi `longhorn-1-replica-local`, `ai` annotation `volsync.backube/privileged-movers: "true"` (live), no kopiur `SnapshotPolicy` for hermes,
`hermes-local` `23 * * * *` (last run 1 m 32 s), `hermes-r2` `29 6 * * *` (~66 s), Gatus endpoint `develop_hermes` up. Live volume layout (read-only exec by the reviewer, 2026-09-24): `/opt/data` top level holds `.env`(600) `auth.json`(600) `config.yaml` `SOUL.md`
`state.db`(600, 864 KB)+`-wal`+`-shm`, `kanban.db`, `projects.db`, `shared-state.db`, `response_store.db`, `runs_idempotency.db`, `cron/executions.db`; dirs `home`(25159 files) `skills`(346) `cache`(555) `lazy-packages`(3018) `logs`(34) `backups`(9) `cron`(7) `scripts`(13) `sessions`(2) `memories`(**0**) …; files are `hermes:hermes` (uid 10000), dirs setgid.
**The real state is in `state.db`**, not in `sessions/` or `memories/` — which is why the content gate covers it (M2, m1).

### Gate results, literally, on the committed files (real output)

```
# SHA 1  b7667471…                           # SHA 2  b91dd0c9…
0. committed                                 0. committed
1. 224:  volumeName: pvc-12f54114-…          1. 223:  volumeName: pvc-12f54114-…
   385:      sourceNamespace: develop           384:      sourceNamespace: develop
2. ai                                        2. ai
2b. replicas: 0                              2b. replicas: null   (absent)
3. ai hermes ./kubernetes/apps/ai/hermes/app ai      (exactly one line, both commits)
   children: 159                             children: 159        (main also has 159: moved, not added)
```

That is the literal runbook gate including assertion 3 (the `cluster-apps` parent build): **Known-untested #5 is closed.** `yamlfmt -lint` is clean on every changed YAML file; `lefthook pre-commit` (yamlfmt + gitleaks) passed on both commits.
`flux-local test --path kubernetes/flux/cluster` (Kustomization tests): 14 passed. With `--enable-helm` 113 of 277 fail **for an environmental reason** (`docker-credential-osxkeychain: executable file not found` while pulling `ghcr.io` charts; every HelmRelease, including unrelated ones) — the `ai/hermes` HelmRelease render is **not** exercised locally; CI's `Flux Local` job is (T-1.6).
`move_gate` (the guard) was also run against scratch commits: name-targeted patches (0 lines → FAIL), stale `targetNamespace` (FAIL), unlisted `ks.yaml` (158 children → FAIL), uncommitted tree (FAIL), wrong replicas expectation (FAIL); PASS for both commits.

### What changed in commit 1 (v2: the minimal list)

Commit 1 was stripped to the minimum so churn elsewhere on `main` cannot touch it. **It changes only:** the rename `kubernetes/apps/develop/hermes/*` → `kubernetes/apps/ai/hermes/*` (README, `app/{externalsecret,helmrelease,httproute,kustomization,ocirepository}.yaml`, `ks.yaml`), `kubernetes/apps/develop/kustomization.yaml` (−`./hermes/ks.yaml`) and `kubernetes/apps/ai/kustomization.yaml` (+`./hermes/ks.yaml`).
Inside the moved files: `ks.yaml` (`path`, `targetNamespace: ai`, `NS: ai`, `interval: 30m` / `retryInterval: 1m` / `timeout: 5m`, `dependsOn` unchanged); `app/kustomization.yaml` kind-targeted patches (PVC `volumeName`, RD `sourceNamespace: develop`; the comment says "the VolSync namespace-move runbook" without a file path, because the runbook is not on `main`);
`app/helmrelease.yaml`: `controllers.hermes.replicas: 0` **and `spec.timeout: 15m`** (m2: the default 5 m plus `upgrade.remediation.strategy: rollback` would put a slow-starting pod back at replicas 0; the 922 MiB image is cached on brokkr03 only); `app/httproute.yaml` gatus `group: ai`, homepage `"AI"`; `README.md` `-n ai`.
**Deferred to the post-move cleanup PR** (comment-only, § Phase S): `ai/namespace.yaml`, `ai/hindsight/.../helmrelease.yaml`, `components/kopiur/{local,r2}.yaml`, `home/ev-charge-tracker/ks.yaml`, `docs/runbooks/kopiur-migration.md` W6. `volsync-mover-stuck.md` history is left alone.
Verified: `git diff --name-status -M BASE C1` lists exactly the ten paths above (seven renames/adds/deletes under `apps/{develop,ai}/hermes` plus the two kustomization lists).

## 1. How the move reaches the cluster (two DRAFT PRs, merged late)

The repo has **no branch protection and no rulesets** (`branches/main/protection` → 404, `rulesets` → `[]`), auto-merge is off, and merge commit / squash / rebase are **all enabled**. So nothing but this plan stops a click. Two defences, both mandatory:

1. **Both PRs are opened as drafts** (`gh pr create -R bluevulpine/flux-talos --draft`). GitHub refuses to merge a draft through the UI or the API. `pr_merge` runs `gh pr ready -R bluevulpine/flux-talos <N>` only at the step that merges.
2. **The PV is set to `Retain` at T-1.3b, before any branch is pushed.** It is harmless to a running Bound app (tested in the other direction, [Rh-11]) and turns any accidental early merge from "PV + Longhorn volume deleted, ≤ 1 h of data only in kopia" into "PV `Released`, recover by re-point".

CI + the Claude review take **3–4 min** (`Claude Code Review` 06:01:24 → 06:04:27, `Flux Local` 2 m 12 s, `Image Pull` 1 m 8 s). `Flux Local` and `Image Pull` run on drafts (default `pull_request` types). `ready_for_review` re-triggers the Claude review; that does not block the merge and is not waited for. **Verified in the workflows (delta review, N7):** `flux-local.yaml` and `image-pull.yaml` trigger on `pull_request: branches: [main]` with default types and **no draft filter**, so they run on drafts; `claude-code-review.yml` triggers on `opened, synchronize, ready_for_review, reopened` with only a renovate-author filter; `gh pr ready` fires `ready_for_review`, which re-runs **only** the Claude review — with no required checks it does not gate the merge, its comment lands after the merge, no wait is needed and no race affects the cluster; `--match-head-commit` is a merge-API precondition that works with `--merge`. **Still UNVERIFIED:** that the review *action* itself does not skip a *draft* (its `opened` trigger has no draft condition, so it should); T-1.6 checks, with a fallback.

| PR | Branch | Contains | Merged at | Command (the only merge path) |
| --- | --- | --- | --- | --- |
| **PR 1** `1915` | `hermes-move-pr1` = SHA 1 | the move, pod held at 0 | W-9 (B5) | `hm 'pr_merge 1915 b7667471e658da525f1dd3aaa0ca1524a96d1717'` |
| **PR 2** `1916` | `hermes-move-pr2` = SHA 2, base `main` | (until PR 1 merges: both commits) → then only commit 2 | W-13 (B8) | `hm 'pr_merge 1916 b91dd0c9b94b959432ce4b0d2ec1b788d02a5dbf'` |

`pr_merge` = `gh pr ready -R bluevulpine/flux-talos <N>` (if draft) then `gh pr merge <N> -R bluevulpine/flux-talos --merge --match-head-commit <FULL_SHA>`. It refuses: a non-numeric or missing number, a short or wrong SHA, a base other than `main`, a head branch that is not `hermes-move-pr1/2`, a head that moved, a closed PR, and **PR 2 before PR 1 is merged**.
**Every `gh` call — in the guards and in this plan — passes `-R bluevulpine/flux-talos` (`gh` otherwise resolves the repo from the caller's cwd, and `gh pr list --head hermes-move-pr1 --state merged` would count another repo's PRs).** **Checklist line, in case the guard is bypassed: never type a bare `gh pr merge` — with no number it merges the PR of the current branch; never merge with `--squash`/`--rebase` (a squash gives PR 2 a merge-base of BASE and it shows all 16 files; W-13's `--name-only` check catches that), and never pass `--delete-branch`.**

Why the shape works (**reproduced by the reviewer in a scratch clone**): PR 2's head already contains commit 1, so once PR 1 is merged with a merge commit GitHub recomputes PR 2's diff as commit 2 alone, **without changing PR 2's head SHA** — its CI and review stay valid. GitHub recomputes `mergeable` asynchronously, so PR 2 may read `UNKNOWN` right after PR 1 merged: **poll, do not abort** (`pr_mergeable` retries up to 60 s).
A hermes image bump on the `develop` path landing on `main` between T-1.4 and the window makes **both PRs CONFLICT** (reproduced) — hence W-0b, **before** quiescing. Put `HOLD — merged only by docs/rehearsal/hermes-move/execution-plan.md step W-9 / W-13` as the first line of each PR body. **Renovate PR #1917 (a hermes image bump that touches `develop/hermes`) is on HOLD: it must not be merged — including by `renovate-sweep` — until after the move; it would conflict with commit 1. After the move Renovate re-targets the `ai` path (and re-opens/updates the PR).** **No Renovate sweep from T-1.4 to W-17** (a hermes bump merged by a sweep is exactly that conflict).

## 2. The maintenance window

**Schedule grid (UTC — VolSync `nextSyncTime …06:29:00Z` shows UTC; CronJobs have no `timeZone` so they use the controller-manager's, UTC on Talos [UNVERIFIED for the CronJobs]):**

- `hermes-local` **`:23` every hour**, now **~1 m 32 s** → busy `:23:00–:24:45`. B3 needs no sync in flight (trap 8): **no B3 between :20 and :26.**
- `hermes-r2` **06:29Z** (~66 s) → avoid **06:15–06:45Z**.
- `kopia-maint-kopia-maintenance-r2` `0 3 * * *` → avoid ~02:45–03:45Z. **`kopia-maint-kopia-maintenance-local` `0 */4 * * *`** (00/04/08/12/16/20Z, against the shared local repo the movers write to) → **keep W-5 and the drill away from :00 of those hours.**
- After the move the new `ai` RS's first hourly (`:23`) runs against the retained volume and writes `hermes@ai` (B9). Harmless.

**Recommended:** start B1 at **:27–:32** of an hour that is not 00/04/08/12/16/20Z and not within 02:45–03:45Z or 06:15–06:45Z, so B3's syncs (~2–3 min) finish long before the next `:23` and the whole window (≈ 25–45 min) ends before the following `:00`-of-a-maintenance-hour if at all possible. Budget **90 minutes**.
Pick a time the human does not need the agent (Hermes is an interactive gateway). Not during a Renovate sweep.

## 3. Expected hermes downtime

Downtime = B1 (`scale 0`, W-3) → pod `Ready` (W-13). Derived from rehearsal timings (1 MiB) and observed sync durations; **everything scaled to real size is UNVERIFIED.** **The restore drill is no longer inside the downtime** (M4): it runs after the pod is back.

| Phase | Estimate | Basis |
| --- | --- | --- |
| W-3 B1 quiesce | 0.5–1 min | live: `terminationGracePeriodSeconds: 30`, `strategy: Recreate` |
| W-4 B2 baseline listing (29 229 files hashed as uid 0) | **0.5–1 min** | **VERIFIED live** (delta review, accidental run): the uid-0 + `DAC_OVERRIDE` reader read **all 29 229 files with no error in ~12 s**, scheduling on the pinned node with the image cached; allow for a cold pull |
| W-5 B3 two forced backups (in parallel) | 2–3 min | `lastSyncDuration` 1 m 32 s (local), ~66 s (r2) + trigger latency |
| W-6/7 B4 read-back, B4b resume | ~1 min | scripted |
| W-9 merge PR 1 → old PVC gone → PV `Released` → new claim | 10–30 s | rehearsal: `Released` in the same second the old PVC went `Terminating`; new claim +6 s |
| W-10 patch checks | ~0.5 min | |
| W-11 B6 re-point → `Bound` | 15–30 s | rehearsal 12 s |
| W-12 B7 checksum Job + compare | **0.5–1 min** | as B2 (same reader, same volume) |
| W-13 merge PR 2 → HR upgrade → pod scheduled → image → Ready | 2–8 min | image cached on **brokkr03 only** (922 MiB): a cold pull elsewhere is the swing; HR timeout is now 15 m |

**Best ≈ 8 min, expected ≈ 15–25 min.** 45-minute decision point (§ 6).

## 4. Who else notices the outage (and the proposed silence)

| Signal | Mechanism | Fires? |
| --- | --- | --- |
| **Gatus** `develop_hermes` | auto-generated by `gatus-sidecar` from the route annotation (`group: develop`); live: HTTP 200 | Red during the down time; key becomes `ai_hermes`, history splits. **Whether generated endpoints carry a Pushover alert is UNVERIFIED** — the sidecar runs `--auto-httproute` and the annotation only sets `group:`; `alerting.pushover.default-alert` applies only to endpoints that list `alerts:`, so **inferred: no push**. |
| **Homepage** tile | route annotations | Shows down; moves from "Development" to "AI". |
| **`VolSyncVolumeOutOfSync`** (critical, `for: 15m`, `obj_namespace`/`obj_name`) — `apps/volsync-system/volsync/app/prometheusrule.yaml` | new `ai` RS creation-time first sync stays in flight while the claim is `Pending` | Only if Pending > 15 min (rehearsal 3 m 16 s). |
| **`VolSyncMoverStuck`** (warning, `for: 20m`) — `kube-prometheus-stack/app/prometheusrule.yaml:93` | mover pod in `ContainerCreating` | Only on a populator/clone wedge (trap 14). |
| kube-prometheus defaults live: `KubePodNotReady` (15 m), `KubeContainerWaiting` (60 m), `KubePodCrashLooping`, `KubeJobFailed` (15 m), `KubeDeploymentReplicasMismatch` (spec 0 ⇒ no), `KubePersistentVolumeErrors` (Failed/Pending only; `Released` no) | pods/Jobs in `develop`/`ai` | Only on a stall. `KubeJobFailed` would name a failed `hchk-*` helper Job. |
| **Flux → Alertmanager** (`components/common/alerts/alertmanager/alert.yaml`, `eventSeverity: error`; an `Alert` already exists in `ai`) | provider labels `alertname, severity, reason, kind, name, namespace, reportingcontroller` | An error event on `Kustomization/hermes` / `HelmRelease/hermes`. |
| Route to humans | `AlertmanagerConfig`: default receiver **pushover**, `groupWait 1m`, `repeatInterval 4h` | Anything above notifies after ~1 min. |

**Proposed silence (only with the human's go-ahead; expires by itself in 3 h; refused by the guard without `SILENCE_OK=yes`):** `obj_namespace=~develop|ai & obj_name=~hermes-.*`; `namespace=~develop|ai & name=~hermes.*`; `namespace=~develop|ai & pod=~(volsync-(src|dst)-)?hermes.*` (`am_silence`, `AM_HOURS=3`).
It does **not** silence Gatus (own Pushover config) or `KubeJobFailed` for `hchk-*`. **The silence is removed right after W-14 passes** (`am_unsilence`, m10) — its `pod=~hermes.*` matcher would otherwise mute a crashloop of the freshly started pod for up to 3 h. Reviewer verified the matchers cannot mute anything outside `develop|ai` × `hermes*`.

## 5. Rollback rows (runbook § 5) — TESTED vs UNTESTED

`git revert` is **not** a rollback [R-6] (**UNTESTED** as a claim): it restores a stock claim without `volumeName`. The way back is a **forward** commit + re-point + content check.
**Recovery by restore (approach A, or any DR restore) replays `auth.json` (m12).** Per `kubernetes/apps/ai/hindsight/app/helmrelease.yaml:160-168`, a replayed *rotated* Nous refresh token fails permanently (`refresh_token_reused`): after any restore-based path expect to **re-authenticate** hermes, and **never run a restored copy alongside the live agent**. Approach B (this plan's path) and the drill (nothing reads its dest PVC as an agent) are unaffected.

| Point | Rollback | Status |
| --- | --- | --- |
| T-1 (PV `Retain` set, nothing else) | **If the `develop` PVC is ever recreated before the window: STOP** (Flux then recreates a stock claim with no `volumeName`, the populator restores ≤ 1 h-old `hermes@develop` into a NEW volume, hermes comes back "healthy" on old data and the newest data sits on the retained PV — silent). Recovery = suspend the ks, scale 0, delete the new claim, re-point the retained PV to `develop/hermes` (`pv_repoint`), content check. Undo of `Retain`: `hm 'pv_reclaim $HERMES_PV Delete'` — the guard allows it only while the PV is `Bound` **and** the `develop/hermes` claim is `Bound` to it | PV `Delete` patch on a Bound PV **TESTED [Rh-11]**; the guard rule is unit-tested (§ 12) |
| W-3 … W-5 (B1–B3) | `flux resume helmrelease/kustomization`; scale up | **UNTESTED** (trivial) |
| W-6 … W-8 (B4–B4b) | resume the HR; scale up. **Do not flip the PV back to `Delete`** unless the app is running and Bound — the guard refuses on a `Released` PV | **UNTESTED** |
| PR 1 merged, before the re-point (W-9 … W-10) | forward-commit the app back into `develop` **with** the kind-targeted `volumeName` patch; `pv_repoint … develop`; content check. **Never `pv_reclaim … Delete` here** (the PV is `Released`; the guard refuses; a `Released` PV set to `Delete` is reclaimed at once) | **UNTESTED as a rollback** (the state was produced in the rehearsal) |
| Re-pointed, pod at 0 (W-11 … W-12) | same forward commit; `pv_repoint … develop`; or approach A into `develop` | **UNTESTED** |
| Pod running in `ai` (W-13 …) | suspend HR, scale 0, no pod references the PVC, resume ks; forward commit back with the `volumeName` patch (gate `want=1`); wait `Released`; re-point to `develop`; content check; clean the orphans left by the suspended HR in `ai` (trap 7) | **TESTED [Rh-4]** (1 MiB fixture; post-move writes preserved) |
| After B10 (`Delete`) | restore from either series into a fresh PVC (approach A; see the `auth.json` caveat); or set `Retain` again first | **UNTESTED** |

A forward-commit rollback is a **new PR under time pressure**: prepare it at T-1.7 (local branch `hermes-move-rollback`, gated `move_gate develop 1 zero`, **not pushed** unless needed). **UNTESTED at hermes size.**

## 6. Abort rules (everywhere)

- **A step whose pass criterion fails: stop, do not improvise, do not proceed.** Post the output; § 11 lists what to ask.
- **Before W-9 everything is reversible** by `flux resume` + scale up. After W-9 every state has a rollback row above; only one is tested.
- **45 minutes since B1** with no convergence: stop and ask.
- **Never**: `kubectl apply` a repo app, `flux reconcile` after a merge (webhook), remove the PV `claimRef` (re-point only), patch any PV but the hermes PV, set the PV `Delete` early, delete the PV or the Longhorn volume, `--force`, edit the RD `spec.trigger.manual` while the ks runs (trap 14b), touch the app PV to "fix" the drill, a bare `gh pr merge`, `kubectl exec` into the hermes pod for anything not listed.

---

# The sequence

**Interlocks (N1, N4).** `data_check` is the only helper that **creates** an object (a Job). It refuses unless `HM_WINDOW=yes` is in the environment — **the plan sets it only inline on the three window steps that need it (W-4, W-12, W-15), never exported and never earlier** — and unless the target PVC exists and is `Bound` (otherwise nothing is applied); its wait is ≤ 80 × 5 s and a trap deletes the Job on exit/INT/TERM, so a killed or timed-out call cannot orphan a pod (an orphaned pod holds pvc-protection, trap 3). **Loop audit — every wait in the guards and in this plan is bounded under the 10-minute tool limit:** `wait_manual` ≤ 40 × 10 s (refused above 50), `wait_pv_phase` ≤ 100 × 3 s, `wait_running` ≤ 110 × 5 s (this plan uses 100), `data_check` ≤ 80 × 5 s + 60 s, `w0b` 2 × 60 s, `others_ready` 3 × 20 s.

**Tooling.** `hm` is a script on `PATH` (`which hm` → `~/.local/bin/hm`). `hm '<guard call>'` runs in a fresh bash that sources the guards (which checks the cluster UID, pins `APP=hermes`, and derives the state dir `~/.herdr/worktrees/flux-talos/hermes-move-state` itself). **Do not `export` anything for it and do not define shell functions** — tool calls keep neither.
Values that must survive between calls (`T0`, `TAG`, `SINCE`, `T-quiesced`) are written by `hm` calls into the state dir and read back by later `hm` calls; the PV name is re-read from the live PVC (`hm app_pv`) and must equal the constant. Inside `hm '…'` single quotes, `$MOVE_DIR`, `$HERMES_PV`, `$R` etc. are expanded by the child bash.

## Phase T-1 — pre-flight (before the window; **one deliberate cluster mutation: T-1.3b**)

**T-1.1 Is the tree still what was gated?**
```zsh
cd ~/.herdr/worktrees/flux-talos/hermes-move
git log --oneline -2 hermes-move                          # b91dd0c9 hermes: start the pod in ai …  /  b7667471 hermes: move from develop to ai …
hm 'drift_check'                                          # fetches origin/main; want: "no drift on origin/main in the paths the move touches"
```
**Pass:** no drift. **If drift:** rebase `hermes-move` onto `origin/main` (bot identity via `-c`), then **update the SHAs and the guards' constants, re-run every gate (T-1.2), the guard tests, and redo T-1.4–T-1.6.** Never rebase during the window.

**T-1.2 Re-run the gates on both commits, literally.**
```zsh
cd ~/.herdr/worktrees/flux-talos/hermes-move
git checkout -q --detach b7667471e658da525f1dd3aaa0ca1524a96d1717 && hm 'move_gate ai 2 zero'     # GATE PASS; 2 lines; ns ai; "ai hermes ./kubernetes/apps/ai/hermes/app ai"; children: 159
git checkout -q --detach b91dd0c9b94b959432ce4b0d2ec1b788d02a5dbf && hm 'move_gate ai 2 absent'   # GATE PASS
git checkout -q hermes-move
```
**Pass:** two `GATE PASS`. **Abort:** any `GATE FAIL`.

**T-1.3 Cluster preconditions (read-only).**
```zsh
kubectl -n develop get pvc hermes -o jsonpath='{.spec.volumeName} {.status.phase} {.spec.storageClassName}{"\n"}'   # pvc-12f54114-… Bound longhorn-1-replica-local
kubectl get pv pvc-12f54114-9e99-442b-bae4-53a9cb239d69 -o jsonpath='{.spec.persistentVolumeReclaimPolicy} {.status.phase}{"\n"}'   # Delete Bound  (Retain Bound if T-1.3b already ran)
kubectl get ns ai -o jsonpath='{.metadata.annotations.volsync\.backube/privileged-movers}{"\n"}'   # true
kubectl get snapshotpolicy -A 2>&1 | grep -i hermes || echo "no kopiur policy for hermes"          # no kopiur policy … (else STOP: runbook §6.4)
kubectl -n develop get pods -o wide | grep hermes ; kubectl -n develop get replicationsource.volsync.backube,replicationdestination.volsync.backube | grep hermes
kubectl get pvc -A -o json | jq -r '.items[]|select(.status.phase=="Pending")|"\(.metadata.namespace)/\(.metadata.name) sc=\(.spec.storageClassName)"'   # expect nothing
hm 'others_ready'
kubectl -n longhorn-system get volumes.longhorn.io pvc-12f54114-9e99-442b-bae4-53a9cb239d69 -o json | jq -c '{state:.status.state,robust:.status.robustness}'   # attached / healthy
for RS in hermes-local hermes-r2; do kubectl -n develop get replicationsource.volsync.backube $RS -o jsonpath='{.metadata.name} {.status.lastSyncTime} {.status.latestMoverStatus.result}{"\n"}'; done   # both Successful, recent
gh pr list -R bluevulpine/flux-talos --state open --json number,title,files --jq '.[]|select(.files[]?.path|test("apps/ai/hermes|apps/ai/kustomization|apps/develop/(hermes|kustomization)|components/volsync"))|"#\(.number) \(.title)"'   # expect nothing
kubectl -n ai get all,pvc 2>&1 | head                     # nothing named hermes in ai
kubectl -n longhorn-system get nodes.longhorn.io -o json | jq -r '.items[]|"\(.metadata.name) \((.status.diskStatus // {})|to_entries|map("\((.value.storageAvailable/1073741824)|floor)Gi free")|join(","))"'
```
**Pass:** as commented. The PR filter is narrowed to the paths the move touches (m6): **#1911 (`ai/litellm`, `gatus/config.yaml`) and #1912 (draft, `ai/hindsight`) touch `ai/` but the reviewer verified with `git merge-tree` that both merge cleanly against both commits** — they may be open. The Longhorn `jq` is null-safe (the Pis report `diskStatus: null`); the reviewer measured every brokkr data disk ≥ 694 Gi available. Transient need ≈ 44 Gi (RD dest+cache) + the creation-time syncs of both new RSes ≈ 116 Gi total [inferred] — ample.

**T-1.3b PV `Retain` — the ONE deliberate cluster mutation before the window (B1).** *Ask first (§ 11).* Harmless to a Bound app; tested in reverse [Rh-11]; it is what makes an accidental early merge recoverable. `record_pv` first labels the PV `hermes-move=1` (the second and only other mutation).
```zsh
hm 'record_pv'                                            # prints the PV; labels it hermes-move=1
hm 'app_pv'                                               # prints pvc-12f54114-9e99-442b-bae4-53a9cb239d69
hm 'pv_reclaim $HERMES_PV Retain'                         # prints Retain
kubectl get pv pvc-12f54114-9e99-442b-bae4-53a9cb239d69 -o jsonpath='{.spec.persistentVolumeReclaimPolicy} {.status.phase} {.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}'   # independent read-back: Retain Bound develop/hermes
```
**Pass:** both `Retain`, still `Bound`. **Do not push any branch until this prints `Retain`.** Consequence to remember: while `Retain` holds, deleting the PVC (or a PR merge) leaves the PV `Released`, never destroyed; **B10 at the end is the only step that flips it back to `Delete`.**

**T-1.4 Create the branches and push them** *(the only push; go-ahead, § 11)*:
```zsh
cd ~/.herdr/worktrees/flux-talos/hermes-move
git branch hermes-move-pr1 b7667471e658da525f1dd3aaa0ca1524a96d1717 && git branch hermes-move-pr2 b91dd0c9b94b959432ce4b0d2ec1b788d02a5dbf
git push origin hermes-move-pr1 hermes-move-pr2           # if SSH push fails despite working auth: HTTPS via gh; `gh pr create -R bluevulpine/flux-talos` then needs an explicit --head
```

**T-1.5 Open both PRs as DRAFTS, then fill the literals once.**
```zsh
gh pr create -R bluevulpine/flux-talos --draft --base main --head hermes-move-pr1 --title 'hermes: move from develop to ai, pod held at 0 replicas' --body-file <(printf 'HOLD — merged only by docs/rehearsal/hermes-move/execution-plan.md step W-9.\n\n<summary + link to the runbook>\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n\nhttps://claude.ai/code/session_01AA9xxfsX3xSg8xher3SAKa\n')
gh pr create -R bluevulpine/flux-talos --draft --base main --head hermes-move-pr2 --title 'hermes: start the pod in ai (drop the temporary replicas: 0)' --body-file <(printf 'HOLD — merged only by step W-13, and ONLY after PR 1. Until PR 1 merges this PR shows both commits.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n\nhttps://claude.ai/code/session_01AA9xxfsX3xSg8xher3SAKa\n')
gh pr view -R bluevulpine/flux-talos hermes-move-pr1 --json number,isDraft --jq '"\(.number) draft=\(.isDraft)"' ; gh pr view -R bluevulpine/flux-talos hermes-move-pr2 --json number,isDraft --jq '"\(.number) draft=\(.isDraft)"'    # both draft=true
sed -i '' 's/1915/<the real PR 1 number>/g; s/1916/<the real PR 2 number>/g' ~/.herdr/worktrees/flux-talos/hermes-to-ai/docs/runbooks/hermes-ns-move-execution.md
grep -c '<PR[12]>' ~/.herdr/worktrees/flux-talos/hermes-to-ai/docs/runbooks/hermes-ns-move-execution.md     # 0
```
**Pass:** both drafts; `0` placeholders left. **From here on every command carries the literal numbers.**

**T-1.6 Wait for CI + review on BOTH; read the review.**
```zsh
gh pr checks -R bluevulpine/flux-talos 1915 ; gh pr checks -R bluevulpine/flux-talos 1916                   # Flux Local, Image Pull, Claude Code Review: pass
gh pr view -R bluevulpine/flux-talos 1915 --comments | tail -60
```
**Pass:** all green; no unresolved finding. "Bot-approved" means the `Claude Code Review` run **succeeded and its comments are read and answered** — **UNVERIFIED** that it posts a formal approval; nothing enforces one. `Flux Local` is the first render of the `ai/hermes` HelmRelease (local `--enable-helm` cannot run, § 0).
**Fallback if `Claude Code Review` did not run on the draft (UNVERIFIED trigger):** `gh pr ready -R bluevulpine/flux-talos 1915 && gh pr ready -R bluevulpine/flux-talos 1915 --undo` (a moment of "ready" is harmless now: the PV is `Retain`), wait ~4 min, read it, repeat for `1916`.
**A finding that needs a code change** changes the SHAs: update the literals and guards, redo T-1.2–T-1.6 (force-push needs a go-ahead, § 11).

**T-1.7 Prepare the rollback branch (local, not pushed).** Mirror image of commit 1 (app back in `develop`, **`volumeName` kept**, **no** `sourceNamespace`, `replicas: 0`):
```zsh
cd ~/.herdr/worktrees/flux-talos/hermes-move && git checkout -q -b hermes-move-rollback hermes-move
# git mv apps/ai/hermes apps/develop/hermes; ks.yaml path/targetNamespace/NS -> develop; remove the RD patch; kustomization lists reversed; replicas: 0; httproute group: develop / "Development".
CLAUDE_SESSION_URL=https://claude.ai/code/session_01AA9xxfsX3xSg8xher3SAKa hm 'COMMIT "hermes: move back to develop (rollback)"' && hm 'move_gate develop 1 zero'
git checkout -q hermes-move
```
**Pass:** `GATE PASS`. [UNTESTED at hermes size; the equivalent rollback was TESTED on the fixture.]

**T-1.8 Human decisions** (§ 11): window time; T-1.3b/T-1.4 go-ahead; silence go-ahead; who does the dashboard login at W-14.

**T-1.9 Cluster-mutation rule until the window.** The **only** mutations allowed are: the PV label `hermes-move=1` and PV `Retain` (T-1.3b — deliberate, harmless to a Bound app, [Rh-11] in reverse). **Nothing else**: no suspend, no scale, no annotation. Confirm: `kubectl -n develop get pods | grep hermes` still `1/1 Running`; `flux get ks -n develop hermes` Ready and not suspended. The window must not start with any PR already merged.

---

## Phase W — the window

Runbook step tags → this plan: **W-2 B0 · W-3 B1 · W-4 B2 · W-5 B3 · W-6 B4 (read-back; the patch was T-1.3b) · W-7 B4b · W-9 B5 · W-10 B5b (patch proof) · W-11 B6 · W-12 B7 · W-13/W-14 B8 · W-15 B5b (restore drill, moved after the start) · W-16 B9 · W-17 end.**

Have a second terminal running `watch -n5 'kubectl get pv pvc-12f54114-9e99-442b-bae4-53a9cb239d69 -o jsonpath="{.status.phase} {.spec.claimRef.namespace}/{.spec.claimRef.name}{\"\n\"}"'`.

**W-0 Clock and slot.**
```zsh
date -u +%FT%TZ ; date -u +%M                             # minute NOT :20–:26; hour not 00/04/08/12/16/20Z at :00; not 06:15–06:45Z; not 02:45–03:45Z
```

**W-0b Pre-quiesce check — BEFORE hermes goes down (M5).**
```zsh
hm 'w0b 1915 1916'                                      # no drift on origin/main AND both PRs OPEN + MERGEABLE with the pinned heads (UNKNOWN retried up to 60 s each)
gh pr list -R bluevulpine/flux-talos --state open --json number,title --jq '.[]|select(.title|test("hermes";"i"))|"#\(.number) \(.title)"'   # only the two move PRs
```
**Pass:** `w0b` prints `no drift…`, `PR #1915 OPEN MERGEABLE b7667471…`, `PR #1916 OPEN MERGEABLE b91dd0c9…`. **Abort (nothing is down yet):** drift or `CONFLICTING` or a moved head → go back to T-1.1. No Renovate sweep has run since T-1.4 (state it).

**W-1 Silence (only if the human said yes) and confirm the PV.**
```zsh
SILENCE_OK=yes AM_HOURS=3 hm 'am_silence'                 # three ids, recorded in the state dir
hm 'app_pv'                                               # pvc-12f54114-9e99-442b-bae4-53a9cb239d69
```
**Abort:** any other PV name (claim re-provisioned) → stop and ask.

**W-2 B0 baseline record (read-only).**
```zsh
hm 'kubectl get pv $HERMES_PV -o json | jq -c "{reclaim:.spec.persistentVolumeReclaimPolicy,phase:.status.phase,claim:.spec.claimRef|{namespace,name},cap:.spec.capacity.storage,sc:.spec.storageClassName}"'
hm 'kubectl -n longhorn-system get volumes.longhorn.io $HERMES_PV -o json | jq -c "{state:.status.state,robust:.status.robustness,ns:.status.kubernetesStatus.namespace,pvc:.status.kubernetesStatus.pvcName}"'
hm 'no_sync_in_flight develop'                            # both idle
```
**Pass:** `Retain`, `Bound`, `develop/hermes`, `20Gi`, `longhorn-1-replica-local`; both RS idle. (Reclaim is `Retain` already, from T-1.3b.)

**W-3 B1 quiesce.** *Downtime starts.*
```zsh
flux suspend kustomization hermes -n develop && flux suspend helmrelease hermes -n develop
kubectl -n develop scale deploy/hermes --replicas=0
kubectl -n develop wait --for=delete pod -l app.kubernetes.io/name=hermes --timeout=180s
kubectl -n develop get pods -o json | jq -r '.items[]|select(.spec.volumes[]?.persistentVolumeClaim.claimName=="hermes")|.metadata.name'   # expect: empty (no Completed pod either — trap 3)
hm 'date -u +%FT%TZ > $MOVE_DIR/T-quiesced.txt; cat $MOVE_DIR/T-quiesced.txt'
```
**Pass:** `wait` returns; the listing is empty. **Rollback:** resume both, scale up. **Abort:** pod not gone in 180 s → ask.

**W-4 B2 content baseline — mandatory.**
```zsh
HM_WINDOW=yes hm 'data_check develop $MOVE_DIR/baseline.txt'            # uid-0 read-only Job; deletes itself (--cascade=foreground) and requires its pod gone; saves a header + names/hashes/counts
hm 'data_baseline_ok $MOVE_DIR/baseline.txt'              # .env auth.json config.yaml SOUL.md state.db present & non-empty; home>0 skills>0; counts reported
kubectl -n develop get pods -l job-name 2>&1 | grep hchk || echo "no helper pod left"
```
**Pass:** `saved …`; `data_baseline_ok` returns 0 (the real layout: `memories` is **0** and is not required); no `hchk` pod (m8/trap 3). **Abort:** any of the five files absent or empty *now* → understand why before continuing. The Job adds `DAC_OVERRIDE` beside `runAsUser: 0` (admitted by PSA baseline and privileged); **verified live: it read all 29 229 files with no error in ~12 s.**

**W-5 B3 forced final backup under the OLD identity, in two `hm` calls (m13).** The manual triggers for **both** RS are set in call A so they run in parallel; each call waits at most 40 × 10 s (< the 600 s tool limit) and reports its own RS.
```zsh
# call A — pre-check, T0/TAG, patch BOTH, wait + check LOCAL
hm 'no_sync_in_flight develop && date -u +%FT%TZ > $MOVE_DIR/T0.txt && echo pre-move-$(date +%s) > $MOVE_DIR/TAG.txt &&
 for RS in hermes-local hermes-r2; do kubectl -n develop patch replicationsource.volsync.backube $RS --type merge -p "{\"spec\":{\"trigger\":{\"manual\":\"$(cat $MOVE_DIR/TAG.txt)\"}}}"; done &&
 wait_manual develop hermes-local "$(cat $MOVE_DIR/TAG.txt)" 40 && check_backup develop hermes-local hermes@develop "$(cat $MOVE_DIR/T0.txt)"'
# call B — wait + check R2
hm 'wait_manual develop hermes-r2 "$(cat $MOVE_DIR/TAG.txt)" 40 && check_backup develop hermes-r2 hermes@develop "$(cat $MOVE_DIR/T0.txt)"'
```
**Pass:** for **both** RS: `lastManualSync=<TAG>` and `check_backup` shows `Created snapshot ≥1`, `Setting policy hermes@develop ≥1`, `RESULT SUCCESS ≥1`, `Directory is empty 0`, **no** `STALE` (lastSyncTime > T0). `T0` was taken after the pod was gone. `no_sync_in_flight` refuses if `:23` is running — wait for it to finish and restart from call A.
**Abort:** any FAIL/STALE → do not cut over; trigger again once; a second failure → ask (`volsync-mover-stuck.md` if a mover wedged). If call A fails on RS local, call B may still be run to see r2 — nothing is lost. **CONFIRMED [Rh-7/Rh-12].**

**W-6 B4 read-back (the `Retain` was set at T-1.3b).**
```zsh
kubectl get pv pvc-12f54114-9e99-442b-bae4-53a9cb239d69 -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'   # Retain
```
**Pass:** `Retain`. **Do not proceed otherwise.**

**W-7 B4b resume the OLD Kustomization; HR stays suspended, Deployment at 0 (trap 6).**
```zsh
flux resume kustomization hermes -n develop
kubectl -n develop get helmrelease hermes -o jsonpath='{.spec.suspend}{"\n"}'                       # true
kubectl -n develop get deploy hermes -o jsonpath='{.spec.replicas}{"\n"}'                           # 0
kubectl -n develop get kustomization.kustomize.toolkit.fluxcd.io hermes -o jsonpath='{.spec.suspend}{"\n"}'   # empty or false
kubectl -n develop get pods | grep hermes || echo "no hermes pod"
hm 'inventory_ok develop'
```
**Pass:** `true` / `0` / not suspended / no pod / `inventory ok`. **Abort:** any mismatch. **CONFIRMED [Rh-6].**

**W-8 Final go/no-go.**
```zsh
hm 'app_pv' ; kubectl get pv pvc-12f54114-9e99-442b-bae4-53a9cb239d69 -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'   # …  Retain
hm 'pending_claims'                                        # nothing
date -u +%M                                                # not :20–:26
hm 'pr_mergeable 1915 b7667471e658da525f1dd3aaa0ca1524a96d1717 12 && pr_mergeable 1916 b91dd0c9b94b959432ce4b0d2ec1b788d02a5dbf 12'
```
**Pass:** every line as commented. **Abort:** `CONFLICTING`/head moved (main moved after W-0b: resume + scale up, ask).

**W-9 B5 merge PR 1.** *Soft point of no return.* Record `SINCE`, then merge — **no `flux reconcile`** (webhook).
```zsh
hm 'date -u +%FT%TZ > $MOVE_DIR/SINCE.txt'
hm 'pr_merge 1915 b7667471e658da525f1dd3aaa0ca1524a96d1717'      # gh pr ready 1915 -R bluevulpine/flux-talos ; gh pr merge 1915 -R bluevulpine/flux-talos --merge --match-head-commit b7667471…
hm 'wait_pv_phase $HERMES_PV Released 100'               # bounded 300 s; rehearsal: Released within ~8 s of the merge
kubectl -n develop get pvc hermes 2>&1 | tail -1           # NotFound (Terminating ⇒ trap 3: a Completed pod/Job still references it — delete it)
hm 'pending_claims'                                        # expect ai/hermes (Pending, FailedBinding …already bound to a different claim — EXPECTED) and the RD's dest/cache claims
```
**Pass:** PV `Released`; old PVC gone; only `ai/hermes` (+ RD claims) Pending. **Abort:** PV stays `Bound` > 5 min → old ks still suspended (trap 6) — `flux get ks -n develop hermes`, ask. **Do not remove `claimRef`; do not `pv_reclaim … Delete` (the guard refuses on a `Released` PV).** **Rollback:** § 5 row 4 (UNTESTED).

**W-10 B5b the patches reached the objects.**
```zsh
kubectl -n ai get replicationdestination.volsync.backube hermes-dst-local -o jsonpath='{.status.kopia.requestedIdentity}{"\n"}'   # hermes@develop   (hermes@ai = patch dropped: STOP)
kubectl -n ai get pvc hermes -o jsonpath='{.spec.volumeName}{"\n"}'                                                              # pvc-12f54114-9e99-442b-bae4-53a9cb239d69
hm 'inventory_ok ai' ; kubectl -n ai get deploy hermes -o jsonpath='{.spec.replicas}{"\n"}'                                     # inventory ok ; 0
```
**Pass:** `hermes@develop`, the PV name, `inventory ok`, replicas `0`. **Abort:** `hermes@ai` or empty `volumeName` → stop (trap 1/5). **CONFIRMED in-cluster [Rh-13].**
**Why the next step does not wait for the RD's restore (M4).** At W-9 the ai RD creates `volsync-hermes-dst-local-dest` (20 Gi, `longhorn-1-replica-local`, WFFC) while the PV is `Released` with a claimRef that still names the OLD claim **with a uid** — not bindable. The re-point then reserves the PV for `ai/hermes` (`uid: null`). The rehearsal tested exactly the concurrent case: **S8 step 4 created `wanted` and `thief` together against a re-pointed PV and only the reserved claim bound it; `thief` provisioned its own volume** (`results.md`, S8 "Step 4 (re-point test)"; "Known untested #3 fully CLOSED"). The runbook's "don't run B6 while the dest PVC provisions" dates from claimRef **removal** (R-5), which this plan never does. The drill is backup evidence, not an app-volume precondition, and runs after the pod is up (W-15).

**W-11 B6 re-point the PV; never remove the claimRef.**
```zsh
hm 'pending_claims'                                        # ai/hermes (+ RD claims) only
hm 'pv_repoint $HERMES_PV ai'                              # patched (uid/resourceVersion null)
hm 'wait_pv_phase $HERMES_PV Bound 40'                     # bounded 120 s; rehearsal 12 s
kubectl -n ai get pvc hermes -o wide
kubectl -n ai get events --field-selector involvedObject.name=hermes -o json | jq --arg since "$(cat ~/.herdr/worktrees/flux-talos/hermes-move-state/SINCE.txt)" '[.items[]|select(.reason|startswith("VolSyncPopulator"))|select((.lastTimestamp // .eventTime // "") >= $since)]|length'   # 0
```
**Pass:** `Bound`, PVC `ai/hermes` on the PV, **0** populator events. **From here to B10 the PV stays `Retain`: `pv_reclaim … Delete` is refused unless `B10_OK=yes` is set (N2) — nobody sets it in the window.** If `ai/hermes` stays Pending: `kubectl -n ai describe pvc hermes`; deleting it is safe only because W-10 proved the patch — **ask first**. **Abort:** the claim bound a *different* PV or a new volume was provisioned → STOP.

**W-12 B7 verify by content, pod still at 0.**
```zsh
HM_WINDOW=yes hm 'data_check ai $MOVE_DIR/after.txt'
hm 'data_compare $MOVE_DIR/baseline.txt $MOVE_DIR/after.txt'      # EVERYTHING identical, state.db* INCLUDED; baseline header develop/hermes and newer than T-quiesced
kubectl -n ai get pods -l job-name 2>&1 | grep hchk || echo "no helper pod left"
hm 'app_pv'
```
**Pass:** `content identical (state.db* included)`. `--ignore-sqlite` exists and **this plan never uses it**: between W-4 and W-12 nothing writes to the volume (pod at 0; the B3 movers read a snapshot clone), so the SQLite files are static and are the file most likely to hold the sessions. **Abort / rollback:** any difference → wrong volume or empty restore [S-b]: **do NOT merge PR 2**; roll back per § 5.

**W-13 B8 start — merge PR 2.** *Only after W-12 passed.*
```zsh
hm 'pr_mergeable 1916 b91dd0c9b94b959432ce4b0d2ec1b788d02a5dbf 12'    # UNKNOWN right after PR 1 merged is expected: it polls up to 60 s instead of aborting
gh pr diff -R bluevulpine/flux-talos 1916 --name-only                                # only kubernetes/apps/ai/hermes/app/helmrelease.yaml (else PR 1 was not merged with --merge: stop)
hm 'pr_merge 1916 b91dd0c9b94b959432ce4b0d2ec1b788d02a5dbf'
hm 'wait_running ai 100'                                    # bounded: 100 x 5 s = 500 s (< the 600 s tool limit; the guard refuses > 110)
```
**Pass:** the diff is `helmrelease.yaml` only; pod `Running` + Ready. *Downtime ends.* If `wait_running` times out while the pod is still pulling / Init and the HR is still `Reconciling` within its 15 m timeout, re-run **once**; a second timeout → ask. **Rollback:** § 5 row 6 (**TESTED [Rh-4]**).

**W-14 B8 verification — application level — then remove the silence (m10).**
```zsh
kubectl -n ai exec deploy/hermes -- ls -la /opt/data        # (allowed here: the only exec) .env auth.json config.yaml SOUL.md state.db … home skills …
hm 'one_route ai'                                           # exactly ONE hermes route, in ai
kubectl -n ai get httproute hermes -o jsonpath='{.metadata.annotations.gatus\.home-operations\.com/endpoint}{"\n"}'   # group: ai
kubectl get --raw /api/v1/namespaces/observability/services/gatus:80/proxy/api/v1/endpoints/ai_hermes/statuses | jq -c '{key,last:(.results[-1]|{status,success})}'      # the per-key response is an OBJECT {key,name,results[]}, not an array; may take minutes to appear
kubectl get --raw /api/v1/namespaces/observability/services/gatus:80/proxy/api/v1/endpoints/develop_hermes/statuses | jq -c '{key,last:(.results[-1]|{status,success})}'      # stale/failing after the move; ages out
kubectl -n ai get helmrelease hermes ; helm -n ai history hermes | tail -3      # 2 revisions: 1 = install (replicas 0, W-9), 2 = upgrade (PR 2, W-13). Any develop history (v5…v9) is the trap-7 orphan set
hm 'am_unsilence'                                           # RIGHT NOW, not at the end of the window: the pod=~hermes.* matcher would mute a crashloop
```
The Gatus per-key endpoint is used because `/api/v1/endpoints/statuses` is paginated (20 per page; `develop_hermes` is not on page 1).
**Human:** open `https://hermes.<domain>`; log in through Authentik; confirm the sessions and that the agent answers. **Pass:** all of it; helm history shows revision 2. A fresh empty agent also comes up "healthy" — W-12's identical listing is the real gate.

**W-15 B5b restore drill — post-start backup evidence (M4).** The RD restored at creation (W-9); by now it has almost certainly finished. **A failure here means only that the `hermes@develop` series may not be restorable** (matters for rollback-by-restore and for aging out the old series) — **the live volume was verified at W-12 and nothing here touches it.**
```zsh
kubectl -n ai get replicationdestination.volsync.backube hermes-dst-local -o jsonpath='{.status.latestMoverStatus.result} {.status.lastManualSync}{"\n"}'   # Successful restore-once
hm 'drill_snapshot_ok'                                      # latestImage=… handle=snap://… ; "longhorn snapshot snapshot-<uid> readyToUse=true"; NotFound = void (trap 14a)
HM_WINDOW=yes hm 'data_check ai $MOVE_DIR/drill.txt volsync-hermes-dst-local-dest'
hm 'data_compare $MOVE_DIR/baseline.txt $MOVE_DIR/drill.txt'      # expect identical. If it differs: read the diff — kopia skips CACHEDIR.TAG directories by default [UNVERIFIED], and the volume holds 1317 MiB actual vs kopia's 570 MB estimate; a difference confined to cache/ is expected, anything else is a finding
```
Keep off :00 of 00/04/08/12/16/20Z (kopia-maintenance-local). A stalled RD/`vs-prime` (trap 14) does **not** affect the running app (approach B's claim is pre-bound); recovery of the drill is § 3A step 5 with the ks suspended first — **ask**, and never touch the app PV. Ownership is `10000:root` expected in the annotated `ai`, not `0:0`.

**W-16 B9 the new series.** The RS fires on its schedule; wait for `:23` (`hermes-local`); R2 is nightly (06:29Z).
```zsh
for RS in hermes-local hermes-r2; do kubectl -n ai get replicationsource.volsync.backube $RS -o jsonpath='{.metadata.name} start=[{.status.lastSyncStartTime}] last={.status.lastSyncTime} {.status.latestMoverStatus.result}{"\n"}'; done
hm 'check_backup ai hermes-local hermes@ai'                # Setting policy for hermes@ai:/data — NOT hermes@develop
hm 'check_backup ai hermes-r2 hermes@ai'                   # after the 06:29Z run
```
**Caveat (trap 8/[Rh-12], TESTED):** both new RS start a creation-time first sync that was in flight while the claim was Pending and may already have written `hermes@ai`; patch a `manual` tag only if `lastSyncStartTime` is empty; the log check is the proof. **Pass:** `hermes@ai` for both RS. Until R2 passes the move is functionally done but **not closed** (Phase S).

**W-17 End of window.**
```zsh
hm 'watch_stop_all' ; hm 'others_ready' ; kubectl get ks -A | grep -v True | head
kubectl -n develop get all,pvc,secret,sa,hr,ks,externalsecret,replicationsource.volsync.backube,replicationdestination.volsync.backube,httproute -o name 2>&1 | grep hermes   # expect the trap-7 ORPHANS only: deploy/svc/sa/sh.helm.release.v1.hermes.* (B11 is Phase S)
```
**Do not** patch the PV to `Delete` and do not clean `develop` in the window.

---

## What to check at the end

- [ ] `hm app_pv` prints the same PV; PV `Retain`, `Bound`, claim `ai/hermes`; Longhorn `kubernetesStatus` → `ai/hermes`, attached, healthy.
- [ ] W-12 `content identical (state.db* included)`; the dashboard shows the old sessions.
- [ ] Exactly **one** `hermes` route, in `ai`; Gatus `ai_hermes` green; homepage tile in "AI"; no red `develop_hermes` left.
- [ ] `helm -n ai history hermes` = 2 revisions.
- [ ] `hermes@ai` written by both `hermes-local` **and** `hermes-r2`.
- [ ] No Pending PVC, no `hchk-*` Job **or pod** in either namespace, no unexpected alert; silences removed (W-14).
- [ ] `kubectl get ks -A` all Ready; `hermes` only in `ai`.
- [ ] Runbook updated with what was observed (real-size drill time, downtime, actual B6 order) — Known-untested #1, #2, #8 narrow or close.

## Phase S — post-move soak (days; the PV stays `Retain`)

| When | Do | Pass |
| --- | --- | --- |
| +1 h | W-16 local check; `kubectl -n ai get pods,pvc`; Gatus history | `hermes@ai` written; restarts 0 |
| ≥ 1 nightly R2 run (suggest ≥ 3 days) | `hm 'check_backup ai hermes-r2 hermes@ai'` | `hermes@ai` in R2 |
| **B10 criteria, all true:** W-12 passed; the soak; both `hermes@ai` series exist; the W-15 drill passed | `B10_OK=yes hm 'pv_reclaim $HERMES_PV Delete'` (**needs the human's `B10_OK=yes`** — once `SINCE.txt` exists the guard refuses `Delete` without it; **re-arms trap 2** — deliberate, last; the guard requires the PV `Bound` and `ai/hermes` `Bound` to it) | prints `Delete`; PV still `Bound` [Rh-11] |
| after B10 | **B11**: confirm `kubectl get pv <pv> -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}'` = `ai/hermes` **first**; delete the `develop` orphans (`deploy/svc/sa`, `sh.helm.release.v1.hermes.*`); assert empty with the bounded loop | `OLD clean` |
| after B11 | `kubectl label pv <pv> hermes-move-`; delete the state dir (listings: names + hashes) | — |

### The post-move cleanup PR (small — and the long-term shape is a HUMAN DECISION)

**Deferred comment-only updates** (dropped from commit 1 in v2 so `main` churn cannot conflict; do them here, once):
- `kubernetes/apps/ai/namespace.yaml`: the two comment blocks that say Hermes "moves in" / "is expected to move here" → past tense (`Set BEFORE Hermes moved in`; `Hermes moved here from develop`; "either/or … would have meant"; "If Hermes ever moves out");
- `kubernetes/apps/ai/hindsight/app/helmrelease.yaml` (~line 167): "separate pod in `develop`" → `ai`;
- `kubernetes/components/kopiur/local.yaml` and `r2.yaml` (~line 60): "`develop/hermes` is the one exception" → `ai/hermes`;
- `kubernetes/apps/home/ev-charge-tracker/ks.yaml` (~line 60): `develop/hermes-r2` → `ai/hermes-r2`;
- `docs/runbooks/kopiur-migration.md`: W6 row and "Only `develop/hermes` is affected" → `ai/hermes`;
- **re-add a runbook path reference** in `kubernetes/apps/ai/hermes/app/kustomization.yaml` (`docs/runbooks/volsync-app-namespace-move.md`) once the runbook is on `main`.

1. **Remove the HelmRelease `spec.timeout: 15m`** added to commit 1 for the move (the image is warm; the default 5 m is the repo norm). (m2)
2. **Long-term shape of the pinned claim — UNTESTED, REQUIRES A SCRATCH REHEARSAL AND A HUMAN DECISION before it is used.** The permanent `volumeName` patch (trap 12) means a **rebuilt** cluster (PVC applied with a `volumeName` naming a PV that no longer exists) leaves `ai/hermes` `Pending` forever: the PV controller keeps such a claim Pending and the populator ignores pre-bound claims. It fails **loud** (pod Pending), not as an empty hermes, but it is an outage that needs a git edit — and the same happens after B10 if `ai/hermes` is ever deleted by a prune. Likewise the RD `sourceNamespace: develop` patch would make a DR restore read the **frozen** `hermes@develop` series.
   The reviewer's recommended shape, **all one commit**:
   - annotate the claim `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent` via the same kind-targeted patch (Flux v1.9.1 supports it: `api/v1` `IfNotPresentValue`, `kustomization_controller.go:864` — kustomize-controller then applies the object only when it is **absent**);
   - **drop the `volumeName` patch and the RD `sourceNamespace` patch** in the same commit;
   - optionally add `kustomize.toolkit.fluxcd.io/prune: disabled` to the claim so a future ks rename/move cannot delete the volume at all (trap 2 permanently off for hermes; cost: manual PVC cleanup if the app is ever retired).
   Result if it works: the live PVC is never re-applied (no immutable-field stall, trap 12 neutralised); on a rebuilt cluster the claim is created unpinned and populated from `hermes@ai`; a DR restore reads the newer series. **UNTESTED:** that `IfNotPresent` skips SSA validation entirely for an existing object whose desired spec differs in an immutable field; that removing the RD patch does not start a restore (upstream VolSync re-syncs a manual trigger only when `spec.trigger.manual != status.lastManualSync`; the deployed fork is inferred to match). **Rehearse on a scratch app (`moveprobe2`) first, then stop and ask (§ 11).** Do it only after `hermes@ai` exists in the **local** repo (the RD reads local).
3. Update the PVC-patch comment and add a paragraph to `kubernetes/apps/ai/hermes/README.md` about whichever shape is chosen, including the `auth.json` replay caveat for any restore.

### Residue list (nothing here is deleted by this plan)

| Residue | Where | Why kept / when to age out |
| --- | --- | --- |
| kopia series **`hermes@develop:/data`** (local Garage + R2) | shared kopia repos | never written again ⇒ never expired (inferred, UNVERIFIED); rollback + proof of the pre-move state. **Review at ≥ 30 days** (e.g. 2026-11-01) and only after a `hermes@ai` restore has been drilled. Needs a kopia client. **Never during the soak.** |
| earlier test series: `smoketest*`, `moveprobe@rehearsal-old/new` | same repos | small; delete together with `hermes@develop` |
| `ai` RD leftovers: dest PVC `volsync-hermes-dst-local-dest` (20 Gi) + cache (24 Gi) + a VolumeSnapshot | `ai` | VolSync-owned; ~44 Gi for the life of the app |
| orphaned `develop` objects from the suspended HR (`deploy` at 0, `svc`, `sa`, `sh.helm.release.v1.hermes.v1…v9`) | `develop` | B11 |
| Gatus history for `develop_hermes` | Gatus Postgres | ages out with Gatus retention [UNVERIFIED] |
| PV label `hermes-move=1`; state dir; branches `hermes-move`, `hermes-move-pr1/2`, `hermes-move-rollback`; the `hm` symlink | PV, laptop, GitHub | remove after B11; ask before deleting remote branches |

## 11. Stop and ask the human — do not decide these yourself

**Before the window**
1. **T-1.3b** (the one deliberate cluster mutation: PV label + `Retain`; harmless to a Bound app, tested in reverse [Rh-11]) — get the go-ahead; and **T-1.4/T-1.5** (the only push, opening two draft PRs); a force-push after a review finding.
2. The window: date/time/duration (§ 2), and whether the agent may be down.
3. The Alertmanager silence (per window).
4. T-1.1 drift, T-1.3 an open PR in the narrowed filter / Pending PVC / low disk, W-0b `CONFLICTING`.
5. Any review finding that changes a file.

**During the window (any of these = stop)**
6. A step's pass criterion is not met (W-3, W-4 baseline lacks a file, W-5 STALE/FAIL twice, W-7, W-9 PV stays `Bound`, W-10 `hermes@ai`, W-11 wrong PV, W-12 content differs).
7. `app_pv` ever prints a name other than the constant — every PV guard refuses; do not edit the guard.
8. Anything requiring: removing a `claimRef`, deleting a PV/PVC/Longhorn volume, `--force`, `kubectl apply` of a repo app, suspending/resuming anything not listed, flipping the PV to `Delete` before B10, editing the RD trigger, a `git revert`, a bare `gh pr merge`.
9. 45 minutes since B1 with no convergence; any alert not in § 4.
10. Whether to roll back (needs a new PR; UNTESTED at hermes size).
11. *(The old in-window question "may B6 proceed while the drill is unresolved?" is removed: answered by rehearsal S8, § W-10.)*

**After**
12. B10 (`Delete`; the guard needs `B10_OK=yes`, which only the human gives) and the soak length.
13. **The long-term claim shape (cleanup PR item 2) — after a scratch rehearsal.**
14. When to age out `hermes@develop`.

## 12. Guard file: what was tested

`~/.herdr/worktrees/flux-talos/hermes-move-guards.sh` (bash 3.2, `set -euo pipefail`; `bash -n` and `shellcheck -x` clean, also for `hm`), run against a **scratch copy** in a scratch dir (the guards derive `GUARDS_DIR`/`R`/`MOVE_DIR` from their own location) with a **fake `kubectl` and a fake `gh`** first on `PATH`, under `/bin/bash` (macOS 3.2): **108 checks, 0 failures**, plus the `move_gate` scenarios against a scratch `git worktree` on the real commits (removed afterwards). No real cluster or GitHub call.

- context/pinning: wrong kube-system UID exits; `APP=other`, `MOVE_DIR=…`, `GUARDS_DIR=…` in the caller's environment are ignored; no `PUSH`, no `pv_delete`; `kn` refuses `kube-system`/`media`, allows `develop`/`ai`;
- PV mutators refuse another PV name, empty name, an unlabelled PV, claimRef `media`, **an EMPTY claimRef (m9)**, an API error (fail closed, 0 mutations), an absent PV; `pv_repoint` only `develop|ai` with `uid:null,resourceVersion:null`;
- **`pv_reclaim … Delete` (M1):** Bound + claim Bound to the PV → allow; **Released → refuse; Available → refuse; Bound but claim missing → refuse; claim Pending → refuse; claim bound to another PV → refuse**; `Retain` allowed in any phase; bogus policy refused;
- `record_pv` / `app_pv` (re-read every call; refuses a re-provisioned PV, develop/ai disagreement, no claim even with a stale cache file);
- `check_backup` (identity, empty-source, T0 staleness, foreign ns), `no_sync_in_flight`, `one_route`, `am_silence` refuses without `SILENCE_OK=yes`;
- **`data_baseline_ok` (m1):** the real layout (memories = 0) accepted; missing `SOUL.md`, an **empty** `state.db`, `skills = 0` refused; **`data_compare` (M2, m11):** identical accepted; a changed `state.db` **detected**; `--ignore-sqlite` ignores it; missing file detected; baseline older than `T-quiesced`, from another namespace, without a header, after-older-than-baseline, and no `T-quiesced.txt` all refused;
- `data_check` (N1, N4): **refuses without `HM_WINDOW=yes`**; refuses a non-hermes PVC / `media` / `tries` > 80; **claim missing → refuse and no `apply` reaches kubectl; claim Pending → refuse, no apply**; happy path (incl. the RD dest PVC) writes the header; the Job is deleted with `--cascade=foreground`; a lingering helper pod is an error (m8); **a timeout (1 try) → failure, Job delete issued, nothing saved; SIGTERM to a running `data_check` → the trap deletes the Job (`--cascade=foreground --wait=false`)**;
- **`pv_reclaim … Delete` after the move started (N2):** with `SINCE.txt` present and no `B10_OK` → refused; `B10_OK=no` → refused; `B10_OK=yes` → allowed; `Retain` still allowed; before the move (no `SINCE.txt`) the T-1 undo still works;
- **interlocks (N4):** with `HM_FAKE=1` and the real `kubectl` first on `PATH` the guards `exit 1` before any command (`HM_FAKE=1 but kubectl is [/opt/homebrew/bin/kubectl], not the harness fake — refusing`); the harness refuses to run under zsh or if `kubectl` does not resolve to its fake; **wait bounds:** `wait_running 111`, `wait_manual … 51`, `wait_pv_phase … 151` refused; **every `gh` call carries `-R bluevulpine/flux-talos` (N3)**;
- **PRs (M3, M5):** `pr_merge` refuses an empty/non-numeric number, a short or wrong SHA, a foreign branch, base ≠ main, a merged PR, **PR 2 before PR 1**; PR 1 draft → `ready` then `merge --merge --match-head-commit <sha>`; `pr_mergeable` retries `UNKNOWN`, refuses `CONFLICTING` and a moved head; `drift_check`/`w0b` pass with no drift and **detect a hermes bump on main, a change to `kubernetes/flux/cluster/ks.yaml`, and a change under `kubernetes/components/common` (N6)**;
- `move_gate` on the real commits: SHA 1 → PASS (`ai 2 zero`), FAIL for `ai 2 absent`; SHA 2 → PASS (`ai 2 absent`), FAIL for `ai 2 zero`; scratch commits with name-targeted patches, stale `targetNamespace`, an unlisted `ks.yaml`, and an uncommitted tree FAIL.

**Not tested (UNVERIFIED):** real `kubectl`/Longhorn/VolSync/`gh` behaviour behind the fakes (the rehearsal covers the cluster side at 1 MiB); `am_silence`/`am_unsilence` against a real Alertmanager; `wait_running`/`wait_pv_phase`/`others_ready`/`inventory_ok`/`drill_snapshot_ok` (read-only pipelines).

### Incident note (2026-09-24, found by the delta review)

The opus reviewer exercised `hm` through **nested `zsh -c`**. A non-interactive zsh re-reads `~/.zshenv`, which prepends `/opt/homebrew/bin` and `~/.local/bin` to `PATH`, so the **real** `kubectl` won over the harness fake and three `data_check` calls hit the **live** cluster: `develop/hchk-1790233756` (a read-only uid-0 listing of `develop/hermes`, completed in ~12 s and was deleted), and `ai/hchk-1790233772` / `ai/hchk-1790233922` (Jobs on claims that do not exist in `ai`, so **Pending**; the reviewer killed the stuck `hm`, which also killed the guard's cleanup, and deleted both Jobs by hand at ~07:13 UTC).
Verified afterwards: no `hchk` Job or pod anywhere, hermes PV `Delete`/`Bound`/unlabelled, the hermes pod `Running` (0 restarts), 161 Kustomizations Ready, no alerts. **Any `hchk-*` Job events in `develop`/`ai` around 07:09–07:13 UTC are not rehearsal artefacts — they are this incident.**
It exposed the real defect (N1) and the missing interlocks (N4): fixed as described in "Interlocks" above. **From now on every test runs under `/bin/bash` directly with `PATH` pinned; never `zsh -c`.**

## 13. Assumptions summary (every one UNVERIFIED)

1. Downtime scaling to real size for everything except the B2/B7 listings (now measured): the W-13 image pull if not on brokkr03; the RD restore/drill.
2. CronJob schedules run in UTC; nothing else contends the chosen hour.
3. `Claude Code Review` runs on draft PRs and produces a review, not a formal approval; nothing enforces one.
4. Stacked-PR behaviour with `--merge` — reasoned and reproduced by the reviewer in a scratch clone, not exercised on GitHub.
5. Gatus auto-generated endpoints carry no Pushover alert (inferred).
6. ~~`DAC_OVERRIDE` is what lets the uid-0 reader read the mode-600 files.~~ **VERIFIED live 2026-09-24** (delta review): the uid-0 + `DAC_OVERRIDE` reader read all 29 229 files, no error, ~12 s. (That root *without* `DAC_OVERRIDE` could not is still inferred, and moot.)
7. `IfNotPresent` and RD-patch-removal behaviour (cleanup PR, § Phase S).
8. A `hermes@develop` snapshot is never expired by anything (inferred).
9. A difference confined to `cache/` in the W-15 drill is a kopia exclusion (CACHEDIR.TAG).
10. Every rollback row except "pod running in `ai`" (§ 5) and the `Delete`-undo of T-1.3b's `Retain` (tested in the other direction).

## Changes since the pre-flight review

| Review finding | Fixed in |
| --- | --- |
| **B1** merge-ready PRs, PV `Delete` | § 1 (two defences); **T-1.3b** (PV `Retain` before any push, independent read-back); T-1.4/T-1.5 (`gh pr create -R bluevulpine/flux-talos --draft`, both drafts asserted); `pr_merge` runs `gh pr ready -R bluevulpine/flux-talos` at W-9/W-13; W-2/W-6 (Retain read-back only); T-1.9 rewritten; § 5 rows; § 11 items 1, 8 |
| **M1** `Delete` on a `Released` PV | guards `pv_reclaim` (phase Bound + claim Bound to the PV); 6 new tests (§ 12); § 5 rows forbid it after W-9; Phase S B10 |
| **M2** content gate skipped `state.db*` | guards `data_compare` compares everything, explicit `--ignore-sqlite` never used; W-12 explains why; § 12 |
| **M3** `hm`/state/PR numbers across tool calls | `hm` is an executable script on `PATH`; state dir derived inside the guards, no caller export; § 0 literals table filled once at T-1.5 (`sed`, `grep -c`), full SHAs literal and pinned in the guards; `pr_merge` (literal number + `--match-head-commit`, refuses a missing number); "never a bare `gh pr merge`" checklist line (§ 1, § 6, § 11) |
| **M4** in-window drill decision | drill moved to **W-15** after the start; W-10 cites rehearsal S8 step 4; § 11 old item removed; § 3 downtime no longer includes the drill |
| **M5** drift/mergeability after quiesce | new **W-0b** (`w0b`), `drift_check`, `pr_mergeable` UNKNOWN polling (W-8, W-13); no Renovate sweep T-1.4 → W-17 (§ 1) |
| **m1** real layout | guards `data_baseline_ok` (5 files present & non-empty; `home`, `skills` > 0; counts; no `memories` requirement); § 0 live layout; W-4 |
| **m2** HR timeout | commit 1 amended (`spec.timeout: 15m`), commit 2 rebuilt (SHAs changed everywhere); cleanup-PR item 1; W-13 note |
| **m3** helm revision | W-14, "What to check at the end" (2 revisions) |
| **m4** Gatus per-key | W-14 (`/api/v1/endpoints/ai_hermes/statuses`, `develop_hermes`) |
| **m5** null-safe `jq` | T-1.3 Longhorn free-space line |
| **m6** open-PR filter | T-1.3 narrowed regex + #1911/#1912 note |
| **m7** schedules | § 2 (`kopia-maintenance-local 0 */4 * * *`, `hermes-local` 1 m 32 s) |
| **m8** Job cascade / pod gone | guards `data_check` (`--cascade=foreground`, pod-gone assertion); W-4, W-12 `get pods -l job-name` |
| **m9** empty claimRef | guards `pv_ok` refuses it; test flipped |
| **m10** unsilence | W-14 runs `am_unsilence` (§ 4 states why) |
| **m11** baseline freshness | guards `data_check` header line; `data_compare` checks namespace/pvc/age vs `T-quiesced.txt`; W-3 writes it; tests |
| **m12** `auth.json` replay | § 5 preamble; cleanup-PR item 3 |
| **m13** W-5 | two `hm` calls (local, r2), each `wait_manual ≤ 40` |
| **DR** shape | Phase S cleanup-PR item 2: `ssa: IfNotPresent` + drop both patches (+ optional `prune: disabled`), marked **UNTESTED, requires a scratch rehearsal and a human decision**; § 11 item 13 |

## Changes since the delta review (`plan-review-2.md`)

The two commits **do not change** (`b7667471…`, `b91dd0c9…`). Only the guards, their tests and this plan.

| Finding | Fixed in |
| --- | --- |
| **Incident** (nested `zsh -c` hit the live cluster) | § 12 incident note; "Interlocks" paragraph; harness refuses under zsh / a non-fake `kubectl`; guards' `HM_FAKE` interlock (N4) |
| **N1** (blocks the window) `data_check` orphaned Job, no claim precheck, 600 s loop | guards `data_check`: refuses unless the PVC is `Bound` (no apply otherwise), ≤ 80 × 5 s, trap deletes the Job on EXIT/INT/TERM (`--cascade=foreground --wait=false`), pod-gone check after the normal delete; `wait_running` ≤ 110 (plan uses 100), `wait_manual`/`wait_pv_phase` bounds; loop audit in "Interlocks" and in the guards; 12 new tests incl. claim missing/Pending, timeout, SIGTERM |
| **N2** `Delete` accepted W-11 → B10 | guards `pv_reclaim`: once `SINCE.txt` exists `Delete` needs `B10_OK=yes`; W-11 and Phase S B10 say so; § 11 item 12; 4 tests |
| **N3** `gh` repo from cwd | guards (`GH_REPO`, `-R` on every call) and every `gh` command in the plan; a test asserts `-R` on every call |
| **N4** interlocks | harness exports `HM_FAKE=1`; guards exit when `kubectl`/`gh` are not the harness fakes (proved with the real `kubectl` first on `PATH`); `data_check` needs `HM_WINDOW=yes`, set only inline at W-4, W-12, W-15; tests for both |
| **N5** verified reader / timings | § 3 table (W-4/W-12 0.5–1 min, best ≈ 8 / expected ≈ 15–25 min), W-4 note, § 13 assumption 6 VERIFIED, assumption 1 narrowed |
| **N6** drift paths | guards `drift_check` adds `kubernetes/flux/cluster/ks.yaml` and `kubernetes/components/common`; 2 tests |
| **N7** workflow facts | § 1 (drafts run flux-local/image-pull; claude review on `ready_for_review`, no gating, no race; `--match-head-commit` works with `--merge`) |
| **N8** recreated `develop` PVC before the window | § 5 row T-1 |
| **m4 / N9** Gatus per-key `jq` | W-14: `jq -c '{key,last:(.results[-1]|{status,success})}'` (object, not array) for `ai_hermes` and `develop_hermes` |


## T-1.7 executed

Local rollback branch **`hermes-move-rollback`** = **`296b2d5fbcfcb4e3af473df5740f513de5c6a9ac`** (child of commit 2 `b91dd0c9b94b959432ce4b0d2ec1b788d02a5dbf`; bot-authored; **not pushed**; `git ls-remote --heads origin hermes-move-rollback` → nothing). The worktree is back on `hermes-move`, clean.

Mirror image of commit 1: `apps/ai/hermes` → `apps/develop/hermes`; `ks.yaml` path/`targetNamespace`/`NS` → `develop` and back to its original shape (`interval: 1h`, **no** `retryInterval`/`timeout` — checked against `e2f4b531:kubernetes/apps/develop/hermes/ks.yaml`); PVC `volumeName` patch **kept**, RD `sourceNamespace` patch **removed**; `develop/kustomization.yaml` lists `./hermes/ks.yaml` again (after `gitea`), `ai/kustomization.yaml` no longer does; HelmRelease `controllers.hermes.replicas: 0` restored and the `spec.timeout: 15m` block dropped (the original had none); route `group: develop` / `"Development"`; README `-n develop`.
**Rebuilt on the v2 commits** (2026-09-24, after the minimal rebuild; the earlier rollback SHA `45be7836…` is obsolete). **Not reverted / not present:** the comment-only edits elsewhere (kopiur components, `ai/hindsight` helmrelease comment, `ev-charge-tracker` ks comment, `kopiur-migration.md` W6 rows, `ai/namespace.yaml` comments) — harmless prose; a real rollback should not spend a PR on them.

Gate, literal, on the rollback commit (`hm 'move_gate develop 1 zero'`):

```
223:  volumeName: pvc-12f54114-9e99-442b-bae4-53a9cb239d69      (1 line: volumeName only, no sourceNamespace)
replicas: 0
parent children: 159
develop hermes ./kubernetes/apps/develop/hermes/app develop
GATE PASS
```
`yamlfmt -lint` clean on the changed YAML; `lefthook pre-commit` (yamlfmt + gitleaks) passed on the commit. **UNTESTED at hermes size** (the equivalent rollback was TESTED on the fixture, [Rh-4]). If used: it is a forward commit, so the § 5 sequence (suspend, scale 0, re-point to `develop`, content check) still applies, and a start commit dropping `replicas: 0` follows.

## Changes in v2 rebuild

| Change | Detail |
| --- | --- |
| Commit 1 stripped to the minimum | rebuilt on the new `origin/main` (BASE `9d73a56dc1b5f90c0789690df1a29e43c7db48bc`): only the `apps/develop/hermes` → `apps/ai/hermes` rename and the two kustomization lists; comment-only edits (`ai/namespace.yaml`, hindsight, kopiur, ev-charge-tracker, `kopiur-migration.md`) restored to `main`'s version and deferred to the cleanup PR; the kustomization comment no longer cites a runbook file path |
| New SHAs | C1 `b7667471e658da525f1dd3aaa0ca1524a96d1717`, C2 `b91dd0c9b94b959432ce4b0d2ec1b788d02a5dbf` (PR numbers #1915/#1916 unchanged); pinned in the guards (`PR1_SHA`, `PR2_SHA`, `BASE_SHA`), both test scripts and every literal in this plan; the orchestrator force-pushes the two draft PR branches |
| `drift_check` narrowed | now watches only `apps/develop/hermes`, `apps/develop/kustomization.yaml`, `apps/ai/hermes`, `apps/ai/kustomization.yaml`, `components/{volsync-claim,volsync-backup,kopiur,common}`, `flux/cluster/ks.yaml`, `apps/volsync-system`; hindsight / ev-charge-tracker / `kopiur-migration.md` / `ai/namespace.yaml` removed; test: an unrelated hindsight change **passes**, a hermes bump on the `develop` path is still **detected** (suite now 108) |
| Renovate #1917 | on hold until after the move (§ 1) |
| Rollback branch rebuilt | `hermes-move-rollback` = `296b2d5fbcfcb4e3af473df5740f513de5c6a9ac`, gated `move_gate develop 1 zero` → PASS (§ T-1.7 executed) |

