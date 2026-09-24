# Delta review: the hermes move plan after `plan-review-1.md`

**What was reviewed:**

- the plan, `docs/rehearsal/hermes-move/execution-plan.md` (538 lines);
- `hermes-move-guards.sh` (466 lines);
- the `hm` script;
- `hermes-move-guards-test/` (re-run in a scratch copy: **86/86 pass**);
- commits `42e23c7e` and `68cdf071`, checked in a scratch clone: authored by the bot, `68cdf071`'s parent is `42e23c7e`, `42e23c7e`'s parent is `e2f4b531`, and commit 1's only change against `e9797a01` is the 5-line `spec.timeout: 15m` block.

Dated 2026-09-24. `P:N` = plan line, `G:N` = guards line.

---

## ⚠ Incident during this review: I mutated the live cluster by mistake

I needed to exercise `hm` against the fake `kubectl`, and I did it through nested `zsh -c "…hm …"` calls. **A non-interactive `zsh` re-reads `~/.zshenv`, which prepends `/opt/homebrew/bin` and `~/.local/bin` to `PATH`.** That put the real `kubectl` ahead of the harness's fake, so those `hm` calls ran against the real cluster. That was my error; the plan and the harness did not cause it.

What happened, in order (UTC):

| Time | Object | What it did | End state |
| --- | --- | --- | --- |
| 07:09:32 | `develop/hchk-1790233756` | A real `data_check develop`: a read-only, uid-0 listing Job on the **live** `develop/hermes` PVC. It was pinned to brokkr03 (the hermes pod was running there) and completed in ~12 s. The guard deleted it (`--cascade=foreground`, pod gone). | The listing (29,229 names + hashes, no contents) was written to my scratchpad. I used it for the evidence below, then **deleted it**. |
| 07:09:32 | `ai/hchk-1790233772` | A Job on claim `hermes` in `ai`. That claim doesn't exist, so it stayed **Pending**. | I killed the stuck `hm` process, and with it the guard's cleanup. **I deleted this Job (`--cascade=foreground`) at ~07:13.** |
| 07:12:03 | `ai/hchk-1790233922` | A Job on claim `volsync-hermes-dst-local-dest` in `ai` (also nonexistent), **Pending**. | **Deleted by me at ~07:13.** |

Checked afterwards (live):

- PV `pvc-12f54114…` is still `Delete Bound develop/hermes` with **no labels**. Nothing touched it: every PV-touching call in that run used `/bin/bash` directly, and therefore the fake.
- The hermes pod is `1/1 Running` (14 h, 0 restarts).
- `kubectl get jobs,pods -A | grep hchk` finds nothing.

Nothing was patched, nothing was labelled, no PR or git remote was touched, and the Pending pods existed for less than 4 minutes, under the 15 m `KubePodNotReady` threshold. **Please tell the author, so they don't mistake the Job events in `develop`/`ai` for a rehearsal artefact.**

This also exposed a real defect in `data_check` (N1 below).

---

## 1. Status of the previous review's 17 items (checked in the code)

| Item | Status | Where |
| --- | --- | --- |
| **B1** merge-ready PRs, PV `Delete` | **FIXED** | Drafts (P:68, P:214-216 with `isDraft` asserted). `pr_merge` runs `gh pr ready` only at W-9/W-13 (G:350). PV `Retain` before any push, T-1.3b (P:196-203), with an independent read-back. T-1.9 allows only the label + `Retain` (P:242). |
| **M1** `Delete` on a `Released` PV | **FIXED** | G:99-109: phase must be `Bound`, the claimRef's PVC must exist, be `Bound`, and name this PV. Residue: N2 |
| **M2** `state.db*` excluded | **FIXED** | G:266-289: compares everything; `--ignore-sqlite` is opt-in and never used (P:371) |
| **M3** `hm`/state/PR numbers | **FIXED** | `hm` is a bash script on `PATH` (symlink verified). `GUARDS_DIR`/`MOVE_DIR`/`APP`/`HERMES_PV`/SHAs are derived or pinned. Verified: `APP=other MOVE_DIR=/tmp/evil HERMES_PV=pvc-evil GUARDS_DIR=/tmp/evil hm 'echo …'` prints the pinned values. Literal PR numbers are filled once (P:14, P:217-218). `pr_merge` requires a literal number, the full SHA, the branch, base `main`, and PR 1 merged before PR 2 (G:336-352). Residue: N3 |
| **M4** in-window drill decision | **FIXED** | W-10 cites S8 step 4 (P:352). The drill moved to W-15 (P:395-402). §11 item removed (P:479) |
| **M5** drift/mergeability after quiesce | **FIXED** | `drift_check`/`pr_mergeable`/`w0b` (G:306-333); W-0b runs before W-3 (P:257-262); W-8 re-checks (P:331); UNKNOWN is polled up to 60 s. Residue: N6 (two paths missing) |
| **m1** real layout | **FIXED, verified live** | G:199-215. **The accidental real listing passed `data_baseline_ok`** (all five files present and non-empty; home 25159, skills 346, cache 555, sessions 2, memories 0, cron 7) |
| **m2** HR timeout | **FIXED** | Commit `42e23c7e` adds `spec.timeout: 15m` at spec level (verified diff). No node affinity; acceptable (§3) |
| **m3** helm revision | **FIXED** | P:389 and P:426 expect 2 revisions |
| **m4** Gatus per-key endpoint | **PARTLY** | The endpoint exists (verified: `develop_hermes` returns an **object**, `{key,name,results[32]}`). But P:387's `jq '.[0].key … .[0].results'` indexes it as an array and errors; only the `|| head -c 300` fallback prints anything. Use `jq -c '{key,last:(.results[-1]\|{status,success})}'` |
| **m5** null-safe Longhorn `jq` | **FIXED** | P:192 |
| **m6** open-PR filter | **FIXED** | P:190 |
| **m7** schedules | **FIXED** | P:86-93 |
| **m8** Job cascade / pod gone | **PARTLY** | G:254-258 handles the normal path. The kill path is not handled: N1 |
| **m9** empty claimRef refused | **FIXED** | G:73 |
| **m10** unsilence right after start | **FIXED** | P:390 |
| **m11** baseline freshness | **FIXED, verified** | G:271-280. Verified with the fakes: the **legitimate B7 compare (baseline header `develop hermes`, after header `ai hermes`) and the drill compare (`ai volsync-hermes-dst-local-dest`) both pass**. Only the baseline's namespace and PVC are checked, and "after" is checked only for age, so the cross-namespace design is not refused. A baseline older than a re-written `T-quiesced` is refused |
| **m12** `auth.json` replay | **FIXED** | P:132, P:451 |
| **m13** W-5 split into two calls | **FIXED** | P:297-304 (`wait_manual … 40` = 400 s per call) |
| **DR** long-term claim shape | **FIXED as a decision item** | P:444-451: marked UNTESTED, requires a scratch rehearsal and a human decision; the timeout removal is listed |

## 2. NEW findings

### MAJOR

**N1. `data_check` can orphan its Job, and it creates a Job on a claim that isn't `Bound`** (G:221-261; used at P:291, P:366, P:399). **Reproduced live**, see the incident.

1. **The loop can't finish inside a tool call.** The status loop is 120 × 5 s = **600 s, equal to the tool-call limit**, and cleanup (G:254-258) only runs after it. On any slow Job (cold image pull, scheduling, a `Pending` claim), the tool call is killed first and cleanup never runs. There is no `trap`.
2. **There is no claim precheck.** `data_check` never checks that `<pvc>` exists and is `Bound`, so a mis-ordered call creates a `Pending` pod that sits waiting for the claim.

**Consequences in this plan:**

- An orphaned `hchk` pod in `develop` after W-4 holds pvc-protection. At W-9 the old PVC then stays `Terminating` and the PV never goes `Released`. P:340 catches this, but hermes is down while it happens.
- A `Pending` `hchk` pod in `ai` created before W-11 becomes a second consumer of `ai/hermes` the moment it binds. At W-13 the hermes pod then competes with it. Both are on the same node only if pinned; RWO Multi-Attach is possible.

**Fix:**

- Before `apply`, require `kn "$ns" get pvc "$pvc" -o jsonpath='{.status.phase}'` = `Bound` (refuse otherwise).
- Bound the wait to 80 × 5 s.
- Add `trap 'kn "$ns" delete job "$j" --cascade=foreground --wait=false >/dev/null 2>&1 || true' EXIT INT TERM` right after the `apply`.
- Add tests for "claim missing → refuse, no apply" and "timeout → Job deleted".
- Apply the same bound to `wait_running ai 120` (P:378; 120 × 5 s = 600 s): use ≤ 110.

### MINOR

**N2. `pv_reclaim … Delete` is still accepted between W-11 and B10** (G:99-109). Once the PV is `Bound` to `ai/hermes`, every check passes.

- P:136-142 says "never before B10", but only in prose.
- If `Delete` is set in that window and a §5 rollback-from-`ai` then prunes `ai/hermes`, the volume is destroyed.

**Fix:** once `$MOVE_DIR/SINCE.txt` exists (the move has started), refuse `Delete` unless `B10_OK=yes` is set in the environment (the human's go-ahead, like `SILENCE_OK`). Before the move starts, the T-1 undo of `Retain` still needs `develop/hermes` `Bound`, as now. Add a test.

**N3. `gh` resolves the repository from the caller's cwd** (G:311, G:340, G:347, P:224-225, P:376).

- `pr_merge` validates the head branch, base and SHA, so a wrong repo is refused (fail-closed).
- `gh pr list --head hermes-move-pr1 --state merged` counts merged PRs of **whatever repo the cwd is in**.
- From a cwd outside any git repo, every `gh` call fails.

**Fix:** pass `-R bluevulpine/flux-talos` everywhere, in the guards and in the plan's bare `gh pr checks/view/diff`.

**N4. The guards have no test-mode interlock.** The harness is only safe if the fake `kubectl` wins on `PATH`. The UID check passes against the real cluster, and `data_check` is a mutating helper. The incident shows how easily this goes wrong: `zsh` re-reads `.zshenv`, and the real `~/.local/bin/hm` sources the real guards.

**Fix, both:**

- The harness exports `HM_FAKE=1`. The guards `exit 1` when `HM_FAKE=1` and `command -v kubectl` is not under the harness `bin/`.
- `data_check` requires `HM_WINDOW=yes` in the environment, so a helper Job can't be created outside the window by accident.

**N5. Evidence from the accidental run, for the plan:**

- The uid-0 + `DAC_OVERRIDE` reader read **all 29,229 files with no error line** (the listing had no non-hash, non-count lines). §13 assumption 6 is **verified**.
- The Job ran on the live volume in **~12 s**, including scheduling on the pinned node with the image cached. P:103/P:109 (2–4 min) are generous; downtime planning can use ~0.5–1 min each for W-4 and W-12.

**N6. `drift_check` misses two paths that change how commit 1 renders without a git conflict** (G:325-328):

- `kubernetes/flux/cluster/ks.yaml` (the `cluster-apps` patches: `crds`/`strategy`/`substituteFrom`);
- `kubernetes/components/common` (included by `apps/ai/kustomization.yaml`).

Add both. `pr_mergeable` still covers textual conflicts.

**N7. Draft PRs and CI (question 3), verified in the workflows:**

- `flux-local.yaml` and `image-pull.yaml` use `pull_request: branches: [main]` with default types (`opened, synchronize, reopened`) and **no draft filter**, so they run on drafts. P:71 is correct.
- `claude-code-review.yml` triggers on `opened, synchronize, ready_for_review, reopened` with only a renovate-author filter. Whether the action itself skips drafts is still UNVERIFIED; P:228 has the fallback.
- `gh pr ready` fires `ready_for_review`, which re-runs **only** the Claude review. With no required checks it does not gate the merge, and the review's comment lands after the merge. No wait is needed, and there is no race that affects the cluster.
- `--match-head-commit` works with `--merge`: it is a merge-API precondition independent of the method.

**N8. A PVC deleted while `Retain` holds for days** (T-1.3b onward). If anything deletes `develop/hermes` while the `develop` Kustomization is live:

1. The PV goes `Released` and is kept. That part is good.
2. **But Flux recreates the stock claim** (no `volumeName`, `dataSourceRef` → RD). The populator restores `hermes@develop` (≤ 1 h old) into a **new** volume.
3. Hermes comes back "healthy" on slightly old data, while the newest data sits on the retained PV.

That is still strictly better than `Delete`, but it is silent. Add one line to §5, row T-1: "if the develop PVC is ever recreated before the window: STOP; recovery = suspend ks, scale 0, delete the new claim, re-point the retained PV to `develop/hermes`, content check".

Nothing else about `Retain` affects a running `Bound` app:

- Longhorn has no notion of it.
- VolSync Snapshot-method clones and caches are separate PVs from `Delete`-class StorageClasses.
- Flux prune simply deletes the PVC, which leaves the PV `Released`.

**N9. P:387 Gatus `jq`:** see m4 above.

## 3. Other checks (no finding)

- **`pv_reclaim` after W-9:**
  - With the develop PVC gone and the PV `Released` → refused (phase).
  - After W-11, with the PV `Bound` to `ai/hermes`, it looks up `ai/hermes` via the claimRef namespace. That lookup is correct; the only issue is the timing policy in N2.
  - `Retain` stays allowed in any phase, which is correct.
- **`hm`:**
  - It runs under `#!/bin/bash`, so it never reads `.zshenv`.
  - `eval "$*"` handles embedded double quotes, `$(…)`, and single quotes passed in from `zsh`. Verified: `a  b hermes pvc-12f5… lit $x`.
  - It cannot run under `zsh`: `source hm` is not in the plan, and invoking it via `PATH` always uses bash.
- **`pr_mergeable` / `w0b`:** read-only; retries `UNKNOWN`; refuses a moved head, `CLOSED` and `CONFLICTING`. W-13's poll before `pr_merge` (P:375) handles GitHub's async recompute after PR 1.
- **W-11 re-point before the start / RD dest PVC created at W-9:**
  - No thief path. At W-9 the PV is `Released` with a uid'd claimRef, so it is not bindable.
  - After the re-point it is reserved for `ai/hermes` (S8 step 4).
  - The RS clone PVCs are on `longhorn-1-replica`, so they can't match.
- **The drill after the start** mounts a **different** PVC (`volsync-hermes-dst-local-dest`). Its node pin finds no pod using that claim, so it runs anywhere, read-only. No interaction with the app.
- **`spec.timeout: 15m`:**
  - It applies to helm install/upgrade/rollback waits.
  - The install at W-9 (replicas 0) is instant.
  - The W-13 upgrade now tolerates a cold 922 MiB pull.
  - Remediation (`install.retries: 3`, `upgrade.rollback`) triggers only after 15 m.
  - No effect on Flux Local (helm template ignores it).
  - Removing it later changes only the HR spec, not the values or chart, so no upgrade is expected (inferred).
  - A brokkr03 node **preference** would additionally keep the Longhorn replica local and avoid a best-effort rebuild. It is optional; I don't require it.
- **State assumptions across tool calls:** none left in the window.
  - Every value is in `$MOVE_DIR` (read inside `hm`) or a literal path (P:360).
  - Unreplaced `<PR1>` placeholders fail closed: bash treats them as a redirect, a syntax error.
  - T-1.2's `git checkout --detach` leaves the worktree detached if interrupted; T-1.7 checks out branches explicitly, so that is harmless.
- **Remaining in-window human decisions**, all abort paths, none blocking the normal flow:
  - W-11 claim stuck `Pending` → ask before deleting it;
  - W-13 second `wait_running` timeout → ask;
  - W-14 needs a human for the dashboard login (schedule them).

## 4. Verdict

| | |
| --- | --- |
| **T-1 (T-1.3b `Retain`, push, open draft PRs)** | **GO.** B1 is fixed on both defences. The one extra line from N8 ("a recreated develop PVC before the window = STOP") is documentation and can be added at the same time. Tell the author about this review's incident first. |
| **The window** | **NO-GO until N1 is fixed** (claim precheck, a wait bounded below 600 s, and a `trap` cleanup in `data_check`; same bound on `wait_running`). It was just demonstrated live that a killed `data_check` leaves a Job behind. At W-4 that becomes trap 3 while hermes is down. **Then GO.** Strongly recommended with it: N2 (`B10_OK` interlock), N3 (`-R`), N4 (`HM_FAKE`/`HM_WINDOW` interlocks), N6 (two drift paths), m4/N9 (Gatus `jq`). |
