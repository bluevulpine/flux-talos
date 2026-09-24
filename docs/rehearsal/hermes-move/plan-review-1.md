# Adversarial pre-flight review: the real hermes move

Scope: `docs/rehearsal/hermes-move/execution-plan.md` (the plan), `hermes-move-guards.sh` and its tests, local commits `e9797a01` and `4af24c89`, checked against the runbook and `docs/rehearsal/results.md`. Reviewed 2026-09-24.

Nothing was edited, committed or pushed. How each part was checked:

- **Cluster:** `kubectl get` only, plus read-only GETs through the Prometheus and Gatus service proxies.
- **Git:** only in a scratch clone (`git clone --no-local` of the `hermes-move` worktree). `origin/main` and three open PR heads were fetched into that clone only.
- **Guards:** tests ran on a scratch copy with the fake `kubectl`.
- **Controller behaviour:** source read at the deployed tags (kustomize-controller v1.9.1; upstream VolSync).

`P:N` = plan line N. `G:N` = guards line N. **Verified** = observed or executed. **Inferred** = reasoning only.

## Verdict

| | Verdict |
| --- | --- |
| **T-1 (push branches, open PRs)** | **NO-GO as written.** Opening two merge-ready PRs against an unprotected `main` while the PV is still `Delete` means one accidental click is trap 2 (B1). **GO** once both PRs are opened as **drafts** *and* (recommended) the PV is set to `Retain` before they exist. |
| **The window (W-0 … W-17)** | **NO-GO as written.** Fix M1–M5 first. None of them needs a new rehearsal; after the fixes: **GO**. |

The core mechanics hold up:

- Two-PR recompute (reproduced).
- Kind-targeted patches reaching the objects.
- Re-point instead of claimRef removal.
- Suspended-HR orphaning.
- The ai RD not being able to steal the PV.

What would lose data or leave hermes down is around the mechanics, not in them:

- an early merge;
- one guard that allows `Delete` on a `Released` PV;
- a content gate that skips the file most likely to hold the sessions;
- a state/`hm` model that doesn't survive tool calls;
- an unresolved in-window decision that the rehearsal already answered.

## Summary table

| # | Sev | Where | Finding |
| --- | --- | --- | --- |
| B1 | **BLOCKER (T-1)** | P:50-66, P:189-199, P:222 | "HOLD" is text. With no protection, auto-merge off and squash/rebase **allowed**, nothing mechanical stops PR 1 or PR 2 being merged before W-3, e.g. a human clicking a green PR the day before. An early merge with the pod running and the PV `Delete` = HR uninstall → PVC delete → PV + Longhorn volume gone, with ≤1 h of data only in kopia |
| M1 | MAJOR | G:88-93 | `pv_reclaim <pv> Delete` is accepted on a **`Released`** PV (verified with the fake: rc 0, patch sent). A `Released` PV flipped to `Delete` is reclaimed at once. The plan's own rollback row "W-6 … W-7: `pv_reclaim … Delete`" is one mis-timed paste away from destroying hermes after W-9 |
| M2 | MAJOR | G:232-240, P:268, P:357 | `data_compare` excludes `state.db*`. Between B2 (W-4) and B7 (W-13) nothing runs against the volume, so the "live SQLite" reason doesn't apply. The comparison therefore ignores the file most likely to hold sessions/FTS (inferred from hermes' layout; not checked) |
| M3 | MAJOR | P:141-148, P:200, P:258, P:273, P:311, P:367 | `hm` is a zsh function and `HM_STATE` an export, "once per terminal". In agent tool calls neither survives (the plan itself says tool calls keep no state). `hm` is then "command not found". `$HM_STATE/…` becomes `/…`. `gh pr merge $(cat $HM_STATE/pr1.txt) --merge` becomes `gh pr merge --merge`, which merges **the current branch's PR**, whatever the cwd is |
| M4 | MAJOR | P:331-341, P:451 | W-11 leaves "may B6 proceed while the drill is unresolved?" as an in-window human decision, with hermes down. The rehearsal already answered it: S8 step 4 created `wanted` and `thief` together against a re-pointed PV and only the reserved claim bound (results.md:190). The drill is backup evidence, not an app-volume precondition. Move it after W-14 |
| M5 | MAJOR | P:152-161, P:298-306 | Main drift is only checked at T-1.1 and again at W-8, **after quiesce**. Verified in the scratch clone: a Renovate-style `hermes-agent` tag bump merged on the `develop` path makes **PR 1 CONFLICT** (and PR 2). W-8 then aborts with hermes already down |
| m1 | MINOR | G:195-231, P:265 | `data_baseline_ok` hard-requires `sessions/` and `memories/` with >0 files and ≥1 of 4 named files. Never checked against the live layout; a mismatch stops the window at W-4, after quiesce |
| m2 | MINOR | P:363-370 | HR has no `spec.timeout` (5 m default) and `upgrade.remediation.strategy: rollback`. The 922 MiB image is cached **only on brokkr03**. A slow pull on brokkr01/02 plus a 30 s readiness delay can trip the rollback, which puts it back to replicas 0 |
| m3 | MINOR | P:379 | W-15 expects "revision 1". PR 2 is an **upgrade**, so it will be revision 2 |
| m4 | MINOR | P:378 | The Gatus statuses API is paginated (20 per page, verified). The W-15 query can miss `ai_hermes`. Use the per-key endpoint |
| m5 | MINOR | P:187 | The Longhorn free-space `jq` aborts on nodes with `diskStatus: null` (the Pis; verified error) |
| m6 | MINOR | P:183 | The open-PR filter matches #1911/#1912 (`apps/ai/…`) today, so "expect nothing" fails. Both merge **clean** against both commits (verified) |
| m7 | MINOR | §2 | `kopia-maintenance-local` runs `0 */4 * * *` (UTC) against the shared local repo; the plan knows only `kopia-maint-r2`. `hermes-local` now takes **1 m 32 s**, not 59.7 s |
| m8 | MINOR | G:228 | `kubectl delete job --wait` doesn't wait for the pod. A lingering Completed `hchk` pod is trap 3 at W-9 |
| m9 | MINOR | G:61-70 | `pv_ok` accepts an **empty** claimRef. This plan never needs one (re-point only), and an empty claimRef is the R-5 thief state. Refuse it |
| m10 | MINOR | P:111-113, G:349-358 | Silences are 3 h from W-1 and include `pod=~hermes.*`, so a post-start crashloop in `ai` is muted. Unsilence right after W-15, not at W-17 |
| m11 | MINOR | G:234-240 | No freshness check on `baseline.txt`. A listing left over from an aborted earlier window compares against a changed volume (false DIFFERS), and can hide a skipped W-4 |
| m12 | MINOR | §5, DR | Any kopia-based recovery (approach A, DR) replays `auth.json`. Per `hindsight/helmrelease.yaml:160-168`, a replayed rotated Nous refresh token fails permanently (`refresh_token_reused`) |
| m13 | MINOR | P:271-276 | W-5 is fail-closed (verified: `set -e` aborts at the first failed `check_backup`), but then the other RS is never reported. Two sequential `wait_manual … 50` can exceed the 600 s tool limit |

---

## BLOCKER

### B1 — the two PRs are merge-ready and unprotected from T-1 to W-9 (P:50-66, P:189-199)

**Verified repo settings:**

- `branches/main/protection` → 404; rulesets → 0.
- `allow_auto_merge: false`.
- `allow_merge_commit / allow_squash_merge / allow_rebase_merge: true`.

Checked and cannot merge: Renovate automerge (rules in `.renovate/autoMerge.json5` match only Renovate's own packages), `claude-code-review.yml` (`contents: read`, so `gh pr merge` fails), `claude.yml` (`contents: read`), and the renovate-sweep procedure (filters on `app/renovate[bot]` or the `renovate`/`dependencies` labels; the labeler only adds `area/*`).

**What can merge them:** any human with a browser, or any agent session told to "merge the green PRs".

**Failure scenario.**

1. PR 1 (or PR 2, which carries both commits) is merged before W-3.
2. The `develop/hermes` Kustomization is **not** suspended, so GC deletes the HelmRelease, and helm-controller **uninstalls** (the HR isn't suspended), which deletes the Deployment and the pod.
3. pvc-protection is released and the PVC is deleted.
4. PV reclaim `Delete` removes the PV and the Longhorn volume. Only the last hourly `hermes@develop` snapshot remains.
5. `ai/hermes` then populates from `hermes@develop` (the RD patch works), so the agent comes back up to ~1 h stale. It is *not* empty, but recent work is lost silently, and nobody notices unless they look.

Merging PR 2 first also skips B7: the pod starts as soon as the PV binds.

**Fix (both, before T-1.4):**

1. **Open both PRs as drafts:** `gh pr create --draft …`. GitHub refuses to merge a draft through the UI or the API. At W-9 run `gh pr ready <PR1>` then merge; at W-14 run `gh pr ready <PR2>` then merge.
   - `ready_for_review` re-triggers the Claude review. That doesn't block the merge and doesn't need waiting for.
   - `Flux Local`/`Image Pull` run on draft PRs too (default `pull_request` types).
2. **Set the PV to `Retain` before the branches are pushed**, i.e. move W-6 to T-1: `pv_reclaim $HERMES_PV Retain`.
   - Harmless to a running, Bound app, and tested [Rh-11] in the other direction.
   - It turns any early merge from "data loss" into "PV `Released`, recover by re-point".
   - This contradicts T-1.9 "write nothing into the cluster". That rule should give way here. Keep W-6 as a read-back.

---

## MAJOR

### M1 — the guard allows `Delete` on a `Released` PV (G:88-93)

Verified in the scratch suite: a labelled hermes PV with `status.phase: Released` and claimRef `develop` passes `pv_ok`, and `pv_reclaim … Delete` sends the patch (rc 0).

Once the reclaim policy of a `Released` PV becomes `Delete`, the PV controller deletes it and the Longhorn volume. This is the one command in the toolbox that destroys hermes, and between W-9 and W-12 (PV `Released`) it is one wrong rollback row away. §5 row 2 *is* `pv_reclaim … Delete`.

**Fix.** In `pv_reclaim`, when the policy is `Delete`, also require all of:

- `status.phase == Bound`;
- the claimRef names an existing PVC that is `Bound` to this PV (`kubectl -n <ns> get pvc hermes -o jsonpath='{.spec.volumeName} {.status.phase}'` = `<pv> Bound`);
- when after W-9, that the namespace is `ai`.

Add three tests (Released → refuse; Available → refuse; Bound + claim Bound → allow).

### M2 — the content gate skips `state.db*` when nothing is running (G:237; P:268, P:357)

The exclusion is justified "across a start". But:

- B2 (W-4) and B7 (W-13) both run with replicas 0, and the volume has no writer between them. W-5's movers use `copyMethod: Snapshot`, so they read a clone.
- The W-11 drill image comes from the W-5 snapshot, taken after B2, also with no writer.
- Hermes' SQLite files, including `-wal`/`-shm`, are therefore static across all three listings.

Excluding them means a truncated or zeroed `state.db` passes W-13 as "content identical". Whether sessions live in `state.db` or `sessions/` is **not verified here**. Either way the gate should cover it.

**Fix.** `data_compare` compares **everything** by default. Add an explicit `--ignore-sqlite` flag used only for a comparison across a pod start (none in this plan). Keep `data_baseline_ok`'s structural checks.

### M3 — `hm`, `HM_STATE` and the PR numbers don't survive tool calls (P:141-148 and every `$HM_STATE` use)

Verified in zsh: with `hm` and `HM_STATE` defined in the **same** process, the W-5 quoting works (inner `\"`, `$TAG`, `$(date)` all expand correctly in bash). In a fresh call:

- `hm` → `command not found`;
- `date … > $HM_STATE/T-quiesced.txt` → writes to `/T-quiesced.txt` (permission denied);
- `hm 'data_check develop $HM_STATE/baseline.txt'` → `set -u` abort;
- **`gh pr merge $(cat $HM_STATE/pr1.txt) --merge` → `gh pr merge --merge`**, which targets the PR of the cwd's branch. With cwd = `hermes-move` there is none, so it errors. With a cwd on any branch that has an open PR, **that** PR is merged.

The pattern fails closed in most steps, but it makes the window non-executable part-way through (hermes down) and has one wrong-merge path.

**Fix.**

- Make `hm` a **script** on `PATH` (`~/.herdr/worktrees/flux-talos/hm`: `#!/bin/bash`, `source guards`, `eval "$*"`), not a function.
- Use the guards' own `$MOVE_DIR` inside `hm`, never a caller export.
- Write the PR numbers **literally** into the plan at T-1.5.
- Merge with the head pinned:
  `gh pr merge <N> --merge --match-head-commit e9797a01…` (full SHA), and the same with `4af24c89…` for PR 2. That refuses if the head moved and makes an empty-number merge impossible.

### M4 — W-11's in-window decision is already answered; move the drill out of the downtime (P:331-341, P:451)

**Why B6 is safe regardless of the drill:**

- At W-9 the ai RD creates `volsync-hermes-dst-local-dest` (20 Gi, `longhorn-1-replica-local`, WFFC) while the hermes PV is `Released`. It still has claimRef `develop/hermes` **with a uid**, so it is not bindable.
- At W-12 the re-point reserves the PV for `ai/hermes` (`uid: null`). The binder skips PVs whose claimRef names another claim.
- The rehearsal tested exactly the concurrent case: S8 step 4 created `wanted` and `thief` together, and only `wanted` bound (results.md:190, "Known untested #3 fully CLOSED").
- The runbook's "don't run B6 while the RD dest PVC is provisioning" dates from claimRef **removal** (R-5). It does not apply to a re-point.

**Why waiting is costly:**

- The drill is the largest unknown in the downtime budget (P:90, "2–10 min, UNKNOWN").
- It is exposed to trap 14, which wedged the rehearsal's first deploy for ~1 h (results.md:45-59).
- Its content compare can differ for legitimate reasons: kopia's default policy skips `CACHEDIR.TAG` directories (inferred). The Longhorn volume holds 1317 MiB actual vs kopia's 570 MB estimate, which fits exclusions but is also explained by unreclaimed blocks. Unverified either way.

**Fix.** Order the window W-10 → W-12 → W-13 → W-14 → W-15, then W-11 (drill + `drill_snapshot_ok` + compare) as **post-start backup evidence**, with no human decision while hermes is down.

A drill failure then means "the `hermes@develop` series may not be restorable". That matters for rollback-by-restore and for aging out the old series, not for the live volume, which B7 has verified.

### M5 — check main drift and PR mergeability before quiescing (P:152-161, P:298-306)

Reproduced in the scratch clone:

| Scenario | Result |
| --- | --- |
| **A.** Main unchanged, PR 1 merged with `--no-ff` | Merge-base(main, PR 2 head) = `e9797a01`; PR 2's diff = `ai/hermes/app/helmrelease.yaml` only. **The plan's two-PR claim holds.** |
| **B.** A `hermes-agent` tag bump on `develop/hermes/app/helmrelease.yaml` lands on main first | **PR 1 CONFLICTS.** The tag line sits next to commit 1's `args:` reflow (yamlfmt). **PR 2 CONFLICTS too.** |
| **C.** The same bump on the `ai` path *after* PR 1 | PR 2 merges clean |
| **D.** PR 1 **squashed** | PR 2's merge-base falls back to `e2f4b531` and it shows all 16 files. It merges clean (a no-op re-apply), but W-14's `--name-only` check correctly stops it |
| **E.** PR 2 merged first | `main` has no `replicas: 0`: the pod starts the moment the PV binds, skipping B7 |

Renovate itself cannot automerge a `hermes-agent` bump; only a human or sweep merge can. Hermes releases roughly every 10 days (`v2026.9.11` → `v2026.9.21`, both cached on brokkr03). The window may be a day after T-1.

As written, B is caught only at W-8, **after** W-3 quiesced hermes, and the only safe answer then is "resume, scale up, rebase, redo T-1.4–T-1.6".

**Fix.**

- Add a **W-0b** before quiesce:
  - `git fetch` + T-1.1's `git diff --stat e2f4b531 origin/main -- <paths>` must be empty;
  - `gh pr view <PR1> --json mergeable,headRefOid` must be `MERGEABLE e9797a01…`, retrying `UNKNOWN` for up to 60 s;
  - the same for PR 2.
- Don't run a Renovate sweep between T-1.4 and W-17.
- `UNKNOWN` after PR 1's merge (GitHub recomputes PR 2 asynchronously) is expected at W-14. Poll, don't abort.

---

## MINOR

- **m1 — verify the live layout at T-1.**
  - Run a read-only `kubectl -n develop exec deploy/hermes -- sh -c 'ls -la /opt/data; for d in sessions memories skills cron; do echo $d $(find /opt/data/$d -type f | wc -l); done'`.
  - Adjust `data_baseline_ok`'s expectations to what is actually there, so W-4 can't stop a quiesced window over a naming assumption.
  - The ks comment lists "config, .env, SOUL.md, sessions, memories, skills, cron", but nothing has confirmed that these are top-level directories.
- **m2 — HR timeout and node placement.**
  - For the window, add `spec.timeout: 15m` to the HR in commit 1 (it rides with PR 1 and is harmless at replicas 0). Alternatively, add a `preferredDuringScheduling` node affinity for `brokkr03`, where the image (922 MiB) and the replica already are. Both are verified live.
  - The Pis carry `node.kubernetes.io/low-power=raspberry-pi:NoSchedule`, so placement is brokkr01-03 only.
  - Without this, a cold pull plus the 30 s readiness delay can exceed 5 m. `upgrade.remediation.strategy: rollback` then returns to revision 1 (replicas 0) and W-14's `wait_running` times out with hermes down.
- **m3 — revision.** The install at W-9 is v1 (replicas 0) and PR 2's upgrade is v2. Expect `helm history` = 2 revisions, both in `ai`. Any `develop` history (`v5…v9`, verified) is the trap-7 orphan set.
- **m4 — Gatus query.**
  - `/api/v1/endpoints/statuses` pages at 20; verified that `develop_hermes` is not on page 1.
  - Use `/api/v1/endpoints/ai_hermes/statuses` (and `develop_hermes`).
  - Whether auto-generated endpoints alert: the gatus-sidecar runs `--auto-httproute` and the hermes annotation carries only `group:`. `alerting.pushover.default-alert` exists but applies only to endpoints that list `alerts:`. **Inferred: no Pushover for `develop_hermes`/`ai_hermes`.**
- **m5 — Longhorn free-space `jq`.** Use `(.status.diskStatus // {})`. Verified values for the record:
  - every brokkr data disk has ≥ 694 Gi available;
  - over-provisioning is 200 %, minimal-available 25 %.

  The transient need at W-9…W-12 is larger than the plan's 44 Gi: dest 20 Gi + cache 24 Gi, plus the **creation-time syncs of both new RSes** once the claim binds (2 × 20 Gi clone on `longhorn-1-replica` + 2 × 16 Gi caches), ≈ 116 Gi (inferred). That is still ample.
- **m6 — T-1.3 filter.** It currently lists #1911 (`ai/litellm`, `gatus/config.yaml`) and #1912 (draft; `ai/hindsight` — PR 1 also edits `ai/hindsight/app/helmrelease.yaml:167`). `git merge-tree` of each PR head against `e9797a01` and `4af24c89`: all **clean** (verified). Narrow the filter to `apps/ai/hermes|apps/ai/kustomization|apps/develop/(hermes|kustomization)|components/volsync`, or document that these two are expected.
- **m7 — schedules.**
  - Verified: `hermes-local` `23 * * * *`, `nextSyncTime …07:23:00Z`, `lastSyncDuration 1m31.8s`.
  - Verified: `hermes-r2` `29 6 * * *`, `nextSyncTime …06:29:00Z`, 66 s.
  - Verified: `kopia-maint-kopia-maintenance-r2` `0 3 * * *`.
  - **Missing from the plan:** `kopia-maint-kopia-maintenance-local` `0 */4 * * *`.
  - CronJobs have no `timeZone`, so they run at the kube-controller-manager's TZ: UTC on Talos (inferred).
  - Keep W-5 and the drill away from :00 of hours 00/04/08/12/16/20 UTC. The start at :27–:32 already does, unless the window crosses the hour.
- **m8 — Job cleanup.** In `data_check`, use `delete job … --cascade=foreground --wait=true`. Also, at W-4/W-13, check `kubectl -n <ns> get pods -l job-name` is empty, not just `get jobs`.
- **m9 — empty claimRef.** Drop `""` from `pv_ok`'s accepted set (G:68). Update the test "claim empty (cleared window) allowed" to expect a refusal.
- **m10 — silences.**
  - Scope verified against real label sets: `volsync_volume_out_of_sync{namespace="volsync-system", obj_namespace, obj_name}`; the Flux provider sets `name`/`namespace`/`kind` (notification-controller v1.9.1 `alertmanager.go:109-116`). Alertmanager anchors regexes.
  - The three matchers cannot mute anything outside `develop|ai` × `hermes*`. The VolSync mover pod names (`volsync-src-hermes-local-…`, `volsync-dst-hermes-dst-local-…`) match matcher 3.
  - Run `am_unsilence` right after W-15 passes, so a crashloop in the first hours is not muted until the 3 h expiry.
- **m11 — baseline freshness.** `data_check` should write a first line `# <job> <ns> <pvc> <utc>`. `data_compare` should refuse a baseline older than `T-quiesced.txt`, or from another namespace than expected.
- **m12 — `auth.json` replay.** Note in §5 and in the DR section:
  - any restore-based path (approach A rollback, a DR restore) brings back an `auth.json` whose Nous refresh token may already have been rotated. Expect to re-authenticate, and never run a restored copy alongside the live agent.
  - Approach B, and the drill (nothing reads its dest PVC), are unaffected.
- **m13 — W-5 reporting and time.** Run the two RSes as two separate `hm` calls (local, then r2), each with its own `wait_manual … 40`. You get both reports, and each call stays under the 600 s tool limit.

---

## (2) Guard review notes (everything else checked and fine)

**Test suite.** Re-ran it in a scratch copy: **52/52 pass**. Added adversarial checks:

- M1: `Delete` on a `Released` PV accepted (**fails the intent**).
- `data_compare` with a missing "after" file → DIFFERS rc 1 (good).
- Stale identical file → "identical" (m11).
- `check_backup` with empty `lastSyncTime` + T0 → STALE (good).
- W-5 loop with a failing first RS → the block aborts, rc 1, no false green (good; m13).

**`set -e` interaction.** Functions called in `&&`/`||` lists lose errexit. Every guard checks explicitly (G:60 says so and it holds). `record_pv`, `app_pv` and `no_sync_in_flight` fail closed on read errors.

**`record_pv` circularity.** Not exploitable. The name must equal `$HERMES_PV` before any label logic (G:63), and the rehearsal's label key (`rehearsal=move`) differs. A stale `hermes-move=1` on the hermes PV from an earlier run only re-authorises the same PV, whose claimRef is still checked.

**`data_check`.**

- uid 0 + `DAC_OVERRIDE` is admitted by PSA baseline (`ai`, verified live) and privileged (`develop`).
- The volume is mounted `readOnly` at both the `volumeMount` and the PVC source.
- Node pinning follows any pod mounting the claim.
- The listing is hashes and names only; a truncated or empty file changes its hash.
- An empty volume fails both `data_baseline_ok` (on the baseline) and `data_compare` (on "after").
- Permission and ownership changes are **not** detected. That is irrelevant for approach B (same filesystem).
- If `find` cannot descend a directory, the failure is silent in both listings (`sh` without pipefail). `DAC_OVERRIDE` makes that unlikely.

**Other helpers.** `inventory_ok`, `one_route`, `no_sync_in_flight`, `check_backup` (`[[ > ]]` on RFC3339-Z) and `drill_snapshot_ok` are correct as read.

## (3) Sequence notes (verified unless marked)

- **W-3.** `terminationGracePeriodSeconds: 30`, `strategy: Recreate` (live).
- **W-7.** Resuming the ks re-applies the HR with `spec.suspend` preserved [Rh-6] and reverts the RS trigger [Rh-7]. W-8's `:20–:26` check covers the restored schedule.
- **W-9, GC in `develop`.** GC deletes the develop RD. By ownerRef that removes `volsync-hermes-dst-local-dest` (`pvc-2f71e667…`), the source of the Longhorn clone that created the hermes volume on 2026-09-05. Safe: the hermes Longhorn volume shows `cloneStatus.state: completed` (live), so it no longer depends on the source.
- **W-9, secrets.** The develop `hermes-secret` ExternalSecret and Secret are deleted. The `ai` ExternalSecret of the same name makes its own Secret in `ai` (same OpenBao key `hermes`), well before W-14. There is no cross-namespace conflict. Reloader only reacts to changes of a referenced Secret on a live workload, so with replicas 0 nothing is woken.
- **W-9, orphans.** The orphaned `develop` Deployment (replicas 0, `reloader` annotation, `existingClaim: hermes`) is inert.
- **Consumers.** Nothing in the repo consumes hermes. A repo-wide grep outside `ai/hermes` finds only comments (`ev-charge-tracker`, `hindsight` README/HR). There is no NetworkPolicy in `ai`, no CronJob, and no `hermes.develop.svc` reference. Hermes is a client of hindsight/litellm; namespace-independent DNS is inferred.
- **W-12.** The re-point is safe while the RD dest PVC provisions (M4).
- **W-14.** The PR 2 merge is an HR upgrade: see m2 and m3.

## (4) DR and post-move shape

- **Removing the RD `sourceNamespace` patch after `hermes@ai` exists:** safe by source reading. In upstream VolSync (`statemachine/machine.go:85, 233`) a manual trigger re-syncs only when `spec.trigger.manual != status.lastManualSync`, and a spec change leaves `restore-once` unchanged. The deployed fork is inferred to behave the same. Do it only after `hermes@ai` exists in the **local** repo; the RD reads local. The plan's reason (a DR restore must read the newer series) is correct.
- **"The permanent `volumeName` pin leaves `ai/hermes` Pending on a rebuilt cluster":** correct.
  - The PV controller keeps a claim whose `volumeName` names a missing PV `Pending`.
  - The populator ignores pre-bound claims ([S-e]: no events).
  - It fails **loud** (pod Pending), not as a fresh empty hermes. That is the safer failure, but it is an outage that needs a git edit.
  - The same happens after B10 if the `ai/hermes` PVC is ever deleted by a prune: the PV is deleted with it, and the recreated pinned claim hangs.
- **Recommended long-term shape (for the cleanup PR; rehearse on a scratch app first):**
  1. Annotate the claim `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent` via the same kind-targeted patch. Flux v1.9.1 supports it (`api/v1` `IfNotPresentValue`, `kustomization_controller.go:864`): the controller applies the object only when it is absent.
  2. In the **same** commit, drop the `volumeName` patch **and** the RD `sourceNamespace` patch.
  3. Result:
     - the live PVC is never re-applied, so there is no immutable-field stall (trap 12 is neutralised);
     - on a rebuilt cluster the claim is created unpinned and populated from `hermes@ai`, as for every other app;
     - optionally add `kustomize.toolkit.fluxcd.io/prune: disabled` to the claim, so a future ks rename/move cannot delete the volume at all (trap 2 permanently off for hermes; the cost is manual PVC cleanup if the app is ever retired).
  4. **UNTESTED:** that `IfNotPresent` skips SSA validation entirely for an existing object whose desired spec differs in an immutable field. Rehearse it before relying on it.

## (5) Facts re-verified

| Plan claim | Live / repo |
| --- | --- |
| PV `pvc-12f54114…` `Bound`, `Delete`, claim `develop/hermes`, 20 Gi, `longhorn-1-replica-local` | ✓. No labels yet; Longhorn `attached/healthy` on brokkr03; the single replica is on brokkr03 |
| `ai` `privileged-movers: "true"` | ✓ live (added by #1910; `main` = `e2f4b531`, no drift since) |
| PSA | `ai` baseline, `develop` privileged ✓ |
| No kopiur `SnapshotPolicy` for hermes | ✓ |
| `hermes-local` `23 * * * *` / 59.7 s | schedule ✓ (UTC, `nextSyncTime …Z`); duration now **1 m 31.8 s** |
| `hermes-r2` `29 6 * * *` / 63.5 s | ✓ / 66.1 s |
| `kopia-maint-r2` hour 03 | ✓ `0 3 * * *`; **plus** `kopia-maintenance-local` `0 */4 * * *` (m7) |
| Gatus `develop_hermes` from the annotation `group: develop` | ✓ (key present; the API is paginated, m4) |
| Alert rules / labels | ✓ `VolSyncVolumeOutOfSync` critical 15 m; `VolSyncMoverStuck` warning 20 m at `kube-prometheus-stack/app/prometheusrule.yaml:93`; `KubePodNotReady` 15 m; `KubeJobFailed` 15 m; `KubeContainerWaiting` 60 m |
| Commit contents | ✓ Both are bot-authored. Commit 1 matches §0's list; the `helmrelease.yaml` diff also carries a yamlfmt flow→block reflow (`args`, `capabilities`) — the reason for M5-B's conflict. Commit 2 removes 4 lines only |
| Repo: no protection, no rulesets, auto-merge off, merge commits used | ✓ — and squash/rebase are **enabled** (B1) |
| terminationGracePeriod (UNVERIFIED in the plan) | 30 s, `Recreate` |
| Image pull time (UNVERIFIED in the plan) | 922 MiB, cached only on brokkr03 (m2) |

## What to change before each gate

**Before T-1.4:**

- B1: draft PRs + PV `Retain`.
- M3: `hm` script, literal PR numbers, `--match-head-commit`.

**Before the window:**

- M1: guard phase check.
- M2: include `state.db*`.
- M4: reorder the drill after W-14.
- M5: W-0b drift and mergeability check before quiesce.
- m1: live layout check.
- m2: HR timeout or brokkr03 preference, ideally in commit 1. That changes SHAs, so redo T-1.2–T-1.6 once, **before** opening the PRs.

After that: **GO**.
