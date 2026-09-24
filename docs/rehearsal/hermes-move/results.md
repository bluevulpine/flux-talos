# Real move results: `develop/hermes` → `ai/hermes` (2026-09-24)

The execution record of `docs/runbooks/volsync-app-namespace-move.md` on the real app, following `execution-plan.md` (this directory). **Outcome: succeeded** — approach B (the Longhorn volume was retained, released and re-claimed, not restored);
~17.5 min of hermes downtime; no data loss; the volume's content was byte-identical before and after; the human verified the dashboard login through Authentik and that the old sessions are present.
All times UTC, 2026-09-24. Everything below was **verified live** by the operator; nothing here is file content (names, hashes, counts and statuses only) and no secret was printed or written.
Tags **[Hm-n]** are the ones the runbook cites.

## Numbers at a glance

| | |
| --- | --- |
| Downtime (quiesce 16:29:26 → pod Ready ~16:47) | **~17.5 min** (plan estimate: best 8 / expected 15–25 min, decision point 45). ~5 min of it was operator/tool latency *between* steps; mechanical time is far smaller (PV `Released` ≤ 9 s, re-point → `Bound` seconds, `data_check` seconds) |
| Volume | 20 Gi `longhorn-1-replica-local`, PV `pvc-12f54114-9e99-442b-bae4-53a9cb239d69`, 29 238 entries (29 229 files listed by the reader) |
| Final backups under `hermes@develop` | ~2 min each (r2 16:36:54, local 16:37:12) |
| PV `Released` after the PR 1 merge | ≤ 9 s |
| Re-point → `Bound` | seconds; 0 `VolSyncPopulator` events |
| HelmRelease | 2 revisions (install at replicas 0 → upgrade on PR 2); `spec.timeout: 15m` never needed |
| Restore drill (RD `restore-once` at creation) | completed within ~2 min; Longhorn snapshot behind the image existed |
| Alerts that fired | none for hermes; Gatus `ai_hermes` 200 immediately |

## Preparation (T-1)

| Step | Result |
| --- | --- |
| T-1.3b — PV set `Retain` + label `hermes-move=1` | ~15:10, with an independent read-back, **before any branch was pushed** (so an accidental early merge would have left a `Released` PV, never a destroyed one) — PASS |
| Draft PRs | #1915 (the move, minimal 10-path commit `b7667471`) and #1916 (start the pod, `b91dd0c9`, a 4-line `replicas: 0` removal) opened as **drafts** — PASS |
| CI on drafts | green, **including the Claude review**: drafts do run Flux Local, Image Pull and the Claude review **[Hm-8]** |
| Bot review of #1915 | flagged a "dangling doc reference": a **stale-base false positive** — the bot reviews the PR-branch checkout, whose base predated the merge of the docs PR that added the runbook. Not a defect |
| Renovate #1917 | opened mid-prep: a hermes image bump touching `develop/hermes`; it would have **conflicted both PRs**. Held (never merged, including by `renovate-sweep`) — PASS; Renovate re-targets the `ai` path afterwards |

### The drift treadmill (deviation)

`main` moved four times in ~2 h from unrelated work (hindsight, litellm, docs, Renovate; #1911, #1912, #1913). The first move commit carried **comment-only edits** in files others edit constantly (`ai/hindsight` helmrelease) and collided.
Fix: rebuild the move commit **minimal** (only the `develop/hermes` → `ai/hermes` rename and the two kustomization lists), **defer the comment-only updates to the cleanup PR**, and **narrow the drift guard to render inputs** (`apps/{develop,ai}/hermes`, the two kustomization lists, `components/{volsync-*,kopiur,common}`, `flux/cluster/ks.yaml`, `apps/volsync-system`).
After that, `drift_check` reported no drift despite three unrelated merges. Updating the draft PR heads used `git push --force-with-lease` pinned to the old SHAs (safe). Runbook trap 18.

### The baseline guard that would have aborted the window (deviation, caught early)

The original `data_baseline_ok` hard-required `memories/` > 0 and `sessions/` > 0. A **read-only look at the live volume before the window** showed `memories/` **empty** and `sessions/` with **2 files**: the state is SQLite (`state.db` + `-wal`/`-shm`, `kanban.db`, `projects.db`, …).
Run as written it would have aborted the window at W-4 with hermes already down. The guard now requires the named files present **and non-empty** (`.env auth.json config.yaml SOUL.md state.db`) plus `home/` and `skills/` > 0, and only reports the other counts. Runbook trap 16.

## The window

| Step | Time | Result |
| --- | --- | --- |
| W-0 clock/slot | 16:28:32 | the `:28` slot, 55 min before the next `:23` sync — PASS |
| W-0b pre-quiesce check (drift + both PRs mergeable at the pinned heads) | before 16:29 | PASS |
| W-1 silences | 16:29 | 3 Alertmanager silences scoped to hermes (`SILENCE_OK=yes` interlock) |
| W-3 B1 quiesce (suspend ks + HR, scale 0) | 16:29:26 | pod gone and no pod referencing the PVC by 16:30:10 — PASS. *Downtime starts.* |
| W-4 B2 baseline (uid-0 + `DAC_OVERRIDE`, read-only Job) | ~16:30 | 29 238 entries listed in seconds. `.env auth.json config.yaml SOUL.md state.db` (+`-wal`) present; `home` 25 159, `skills` 346, `cache` 555, `sessions` 2, `memories` 0, `cron` 7 — PASS **[Hm-2, Hm-7]** |
| W-5 B3 final backups (`T0` 16:35:01, tag `pre-move-1790267701`) | 16:36:54 (r2), 16:37:12 (local) | both: `Created snapshot 1`, `Setting policy hermes@develop`, `RESULT SUCCESS`, `Directory is empty 0`, `lastSyncTime > T0`; ~2 min each — PASS **[Hm-1]** |
| W-6 B4 read-back | | `Retain` — PASS |
| W-7 B4b resume the old ks | 16:37:40 | HR stayed suspended, replicas 0, inventory ok — PASS |
| W-8 go/no-go | | PASS |
| W-9 B5 merge PR 1 (`gh pr ready` + `gh pr merge --merge --match-head-commit`) | 16:38:56 | merge commit `627bba28`; PV `Released` within ≤ 9 s; old PVC `NotFound`; the only Pending claims `ai/hermes` and the RD dest claim; `ai` HelmRelease `InstallSucceeded` (revision 1, replicas 0) 16:39:39 — PASS |
| W-10 B5b patch proof | | RD `requestedIdentity hermes@develop`; `ai` PVC `volumeName` = the PV; `ai` Deployment replicas 0; exactly **one** hermes HTTPRoute (in `ai`); the old `develop` ks gone — PASS |
| W-11 B6 re-point (`uid`/`resourceVersion` null) | 16:40:10 | `Bound` within seconds; 0 `VolSyncPopulator` events; PV stayed `Retain` — PASS |
| W-12 B7 content check (pod still at 0) | | baseline (develop) vs after (ai): **"content identical (state.db* included)"**, 29 238 entries — PASS **[Hm-2]** |
| W-13 B8 merge PR 2 | 16:46:01 | merge commit `bc61a0e1`; HR upgrade complete 16:46:41 (revision 2); pod `Running` 1/1 by ~16:47 (image cached on brokkr03 where it landed). *Downtime ends.* — PASS |
| W-14 verification + silences removed | 16:48 | Gatus `ai_hermes` 200 immediately; no hermes alert fired; the human verified the Authentik login and the old sessions — PASS |

The literal hermes-form three-part gate (app build, namespace set, **`cluster-apps` parent build with exactly one `ai hermes ./kubernetes/apps/ai/hermes/app ai` child, 159 children**) ran on both commits and passed **[Hm-3]** — it closes the runbook's old "STILL OPEN".

### Post-start evidence

- **Restore drill** (the ai RD's `restore-once` ran at creation; `latestImage …164036`): the Longhorn snapshot behind it **existed** (`readyToUse=true`) — trap 14a did **not** bite (1 of 1). The drill volume lists 4 084 lines vs 29 238 live; the **only** files missing are the 25 154 under `home/.cache/uv` (a uv package cache; kopia skips cache directories — *inferred* CACHEDIR.TAG, **not verified**). All 4 077 remaining files are **identical by hash**, including `.env auth.json config.yaml SOUL.md state.db state.db-wal`.
  So `hermes@develop` is restorable and complete except that regenerable cache — a backup-coverage property that predates the move **[Hm-5]**.
- **New series:** both new `ai` RS ran a creation-time first sync (local 16:41:31, r2 16:42:29) that wrote `hermes@ai:/data` with SUCCESS while the pod was still at 0 (the data already verified); `check_backup` passes for both. The natural `:23` sync (17:23) was still to come **[Hm-6]**.

## Deviations and new traps (all folded into the runbook)

1. **GitHub's PR 2 record went STALE after PR 1 merged** (trap 17, [Hm-4]). `gh pr diff --name-only` still listed all 10 files of the move and `base.sha` still pointed at the old base, although git showed PR 1's merge commit had commit 1 as its second parent and `merge-base(main, C2) = C1`. The plan's "diff must be only `helmrelease.yaml`" check **failed on the stale cache**. Resolved with `git merge-tree --write-tree origin/main <C2>` and diffing that tree against `main`: only the 4 `replicas` lines, 0 conflicts. The check should use `git merge-tree`, not `gh pr diff`. `mergeable=UNKNOWN` on the first poll is normal (resolved on attempt 1/12).
2. **The Claude review of the large docs PR stalled** without posting findings (its checklist stopped at "finder agents running in background"). It was merged on **explicit human instruction** because it was docs-only with CI green.
3. **Incident: a read-only reviewer hit the LIVE cluster** (trap 20, [Hm-10]). While testing the guards through nested `zsh -c`, a non-interactive zsh re-read `~/.zshenv` and put the real `kubectl` ahead of the fake; three helper Jobs were created — one read-only listing on the real volume (completed, deleted) and two `Pending` on claims that do not exist (deleted by hand within ~4 min, under the 15 m `KubePodNotReady` threshold). **No lasting effect:** PV unlabelled and `Delete`/`Bound`, pod untouched (0 restarts), no `hchk` objects left, no alerts. Fixes: the `HM_FAKE` interlock (guards refuse if `kubectl`/`gh` are not the harness fakes), `HM_WINDOW=yes` required for `data_check` (which also requires the PVC `Bound`, is bounded and traps its own cleanup), and a `B10_OK=yes` interlock on PV `Delete`; harnesses run under `/bin/bash` only.
4. **uid-0 reader verified** [Hm-7]: it read all 29 229 files with no error in ~12 s on the live volume; `DAC_OVERRIDE` is needed for the mode-600 `.env`/`auth.json`/`state.db`.
5. **Hermes rewrites `.env` at start** (mtime changed, same size): compare content **before** the pod starts, never after (trap 19).
6. **HelmRelease shows 2 revisions** (install at replicas 0, upgrade on PR 2) — expected [Hm-9].
7. **A bot false positive from a stale base** (see Preparation) — not a finding; noted so the next operator does not chase it.

## Known-untested items settled by the real move

| Item | Verdict |
| --- | --- |
| Literal hermes-form parent-build gate | **CLOSED [Hm-3]** — ran on both commits, assertion 3 passed |
| Restore of the real `hermes@develop` series (mechanics + content) | **CLOSED [Hm-5]** — ~2 min, complete except the regenerable cache; Longhorn replica-rebuild time and an *app-claim* populator restore at real size remain unmeasured |
| HTTPRoute hand-over | **CLOSED [Hm-1]** — exactly one route in `ai` at W-10; no overlap observable because the app was down; the blip is not measurable |
| Stacked two-PR mechanics with `--merge` | **CLOSED [Hm-4]** — PR 2 merged clean, only 4 lines; but see deviation 1 (stale record) |
| Draft-PR CI behaviour | **CLOSED [Hm-8]** — drafts run Flux Local, Image Pull and the Claude review |
| Guards at real size | **CLOSED** — see above |
| Real-size timing of the B3/B9 syncs | **CLOSED** — ~2 min each; creation-time first syncs wrote `hermes@ai` at real size |

## Still open

- Every rollback row except "pod running in `ai`" (the rollback branch `hermes-move-rollback` — the mirror image of the move, `volumeName` kept, no RD patch — was prepared and gated locally and **never used**); the `git revert` rollback (R-6).
- Approach A end to end on a real series; the kopiur cut-over (forks the series again).
- The long-term claim shape (`ssa: IfNotPresent` on the claim, dropping the `volumeName` and RD `sourceNamespace` patches, optionally `prune: disabled`) — **UNTESTED, needs a scratch rehearsal and a human decision** (the pinned `volumeName` would leave `ai/hermes` `Pending` on a rebuilt cluster; the RD patch would make a DR restore read the frozen old series).
- B10 and the soak; aging out `hermes@develop` (~2026-11-01, and only after a `hermes@ai` restore drill).
- Trap 14a (a published snapshot missing on Longhorn): 2 of 5 rehearsal RD runs, **0 of 1** in the real move — root cause still unknown.

## Pending follow-ups

1. **B10:** PV `Retain` → `Delete` after ≥ 1 nightly R2 run (suggest 3 days); needs `B10_OK=yes`.
2. **Cleanup PR:** drop the RD `sourceNamespace` patch (once `hermes@ai` exists in the **local** repo); restore the deferred comment-only updates (`ai/namespace.yaml` comment blocks, `ai/hindsight` helmrelease ~line 167, `components/kopiur/{local,r2}.yaml`, `ev-charge-tracker` ks comment, `kopiur-migration.md` W6 rows, and a runbook path reference in the kustomization comment); drop `spec.timeout: 15m`; decide the volume pin.
3. **B11:** clean the orphaned `develop` objects (`deploy/svc/sa hermes`, `sh.helm.release.v1.hermes.*`) after B10.
4. **Renovate #1917:** re-target to the `ai` path (do not merge the old-path PR).

## Files in this directory

`execution-plan.md` (the plan as executed), `plan-review-1.md`, `plan-review-2.md` (the two pre-flight reviews), `hermes-move-guards.sh`, `hm`, `guards-test/` (reference copies — see `docs/rehearsal/README.md`).
