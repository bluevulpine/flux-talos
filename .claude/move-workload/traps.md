# Traps — one line each

`R§2 n` = runbook `docs/runbooks/volsync-app-namespace-move.md` §2 trap *n* (evidence and commands there). Tags `[Rh-n]` = rehearsal result. Each of these produces a **plausible wrong answer**, not an error.

## Runbook traps 1–15

1. **Missing `sourceNamespace` = silent EMPTY restore** — RD reports `Successful`, PVC binds, volume holds only `lost+found`; verify by content, never RD/PVC status. (R§2 1, [S-b])
2. **PV `Delete` + `prune: true` = instant total loss** — pruning the PVC deletes PV then Longhorn volume in ~19 s; keep `Retain` until B10. (R§2 2, [Rh-11])
3. **Completed Job pods block PVC deletion** — pvc-protection stays; delete every helper Job (baseline, checksum, drill) first. (R§2 3)
4. **Empty-source backup is green with no snapshot** — `Directory is empty skipping backup` + `OPERATION_RESULT: FAILURE` + `result: Successful`; gate on the log lines. (R§2 4)
5. **Name-targeted kustomize patches are silently dropped** — names are `${APP}` at build time; target by kind; gate on the build; unsafe with >1 PVC/RD. (R§2 5, [Rh-13])
6. **A suspended Kustomization that is deleted orphans its whole inventory** — resume the OLD ks (HR stays suspended) before the merge. (R§2 6, [Rh-O])
7. **A suspended HelmRelease that is deleted is not uninstalled** — Deployment/SA/`sh.helm.release.v1.*` orphaned in OLD; clean before the app ever returns (B11). (R§2 7)
8. **`lastManualSync` is stamped by whichever sync finishes next** — a scheduled/creation-time sync satisfies your tag; require no sync in flight AND `lastSyncTime > T0`. (R§2 8, [Rh-12])
9. **Mover status log is a truncated tail** — `Creating snapshot for …` is absent on real-size volumes; accept on `Created snapshot with root` + policy line + SUCCESS. (R§2 9)
10. **Removing `claimRef` makes the PV claimable by any matching PVC** — the RD's own dest PVC is the likeliest thief; re-point, never clear. (R§2 10, [Rh-3])
11. **The NEW RD is not inert** — `restore-once` runs a full restore at creation (~44 Gi budget); patched it is a free drill, unpatched it is the empty-restore generator. (R§2 11)
12. **A pre-bound PVC's `volumeName` must stay in the manifest** — removing the patch later makes SSA unset an immutable field and stalls the ks; never `force: true`. (R§2 12, [Rh-1])
13. **Two routes for one host: the OLDEST wins** — brief blip if OLD's route is pruned, permanent 503 if orphaned (trap 6); verify exactly one route. (R§2 13)
14. **Longhorn populator/clone path can wedge** — `VolumeSnapshot readyToUse` is not proof; Flux reverts a hand-patched RD trigger; delete `vs-prime-*`; only the RD drill and approach A are exposed, not the pre-bound claim. (R§2 14, [Rh-B1])
15. **Restored ownership depends on the namespace annotation** — unannotated restore gives `0:0` mode 664; NEW needs `privileged-movers` live before the move; run drills as uid 0. (R§2 15, [Rh-P])

## Real-move traps (hermes, 2026-09-24)

- **`gh pr diff` / the PR record goes STALE after a stacked-PR merge** — after PR 1 merges, PR 2's files/mergeability may still show the old two-commit state. Verify with `git merge-tree --write-tree origin/main <head-sha>` and diff *its tree* against `origin/main`, not with `gh pr diff` alone.
- **`mergeable: UNKNOWN` on the first poll is normal** — GitHub recomputes asynchronously (PR 2 right after PR 1 merged); poll (`pr_mergeable` retries), don't abort. `CONFLICTING` is the real signal.
- **Drafts still run CI and the Claude review** — Flux Local / Image Pull run on drafts (no draft filter); the review action's `opened` trigger fires too. A draft is the merge lock, not a CI skip.
- **The bot review reviews the BRANCH, not `main`** — a stale-base branch yields false positives about "removed" files that `main` already changed; check findings against current `main` before acting, and prefer a fresh base.
- **Main churn treadmill** — every unrelated bump on a path the commit touches forces a rebase → new SHAs → re-run every gate/test/CI. Keep the commit minimal (app dir + two lists), defer comment edits, watch `DRIFT_PATHS`, hold the app's Renovate PRs, no sweep from push to W-17.
- **The app rewrites files at start** (hermes rewrites `.env`) — compare content **before** the pod starts (W-12); a post-start compare fails on a healthy app. Live DB files (`LIVE_FILES`) are only comparable while nothing runs.
- **Test harness under zsh hits the REAL cluster** — non-interactive `zsh -c` re-reads `~/.zshenv` and puts the real `kubectl` first; a "read-only" reviewer created live Jobs. Use `/bin/bash`, `HM_FAKE=1` interlock, and verify reviewer runs yourself.
- **The baseline must match the REAL layout** — hermes' `memories/` was empty and state lived in `state.db`; an assumed gate on `memories/` is wrong either way. Look at the volume (P1) before writing `EXPECT_FILES/DIRS`.
- **`SINCE` gates `Delete`** — once `SINCE.txt` exists the guard refuses `Delete` without `B10_OK=yes`; don't work around it, that is the point.
- **A recreated OLD PVC while `Retain` holds** (days between T-1 and the window) silently diverges (stock claim, populator restore into a NEW volume); check `app_pv` at every phase start.
- **Kubernetes `get -w` on an absent object exits at once; `--field-selector=status.phase=Pending` is rejected; `-o json` hides `managedFields` without `--show-managed-fields`; stale same-name events live ~1 h** — [Rh-F]; use the guards' helpers.
