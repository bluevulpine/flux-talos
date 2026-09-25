---
description: Move a VolSync+Longhorn workload between namespaces with no data loss (classify, prepare, guarded window, soak, cleanup)
argument-hint: "<app> <old-namespace> <new-namespace>"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

# Move a workload between namespaces

Drive the repeatable version of the 2026-09-24 `develop/hermes` → `ai/hermes` move: **zero data loss** by keeping the Longhorn volume (Retained PV, re-pointed
claimRef) and forking the kopia identity `user@NAMESPACE`. The procedure, its evidence and every trap live in `docs/runbooks/volsync-app-namespace-move.md`
(**the runbook**; steps `B0–B11`, traps 1–15, tags `[Rh-n]`). This command is the operator layer: classification, checkpoints, and guards that make the
dangerous steps refuse instead of trusting you.

**Arguments** — `$ARGUMENTS` = `<app> <old-namespace> <new-namespace>`. Fewer than three → ask; do not guess a namespace.

## Reference material — read on demand, do NOT preload

All under `.claude/move-workload/` (see its `README.md` for the layout):

- `classify.md` — **read first.** Decision tree + read-only discovery commands. Refuses/escalates what this workflow does not cover.
- `workflow.md` — phases P0–P7, the window `W-0…W-17` mapped to runbook `B0–B11`, commands, pass/abort criteria, TESTED/UNTESTED rollback per step.
- `traps.md` — one line per trap (runbook traps 1–15 + the real-move traps). Skim before P2 and before the window.
- `guards/` — `move-guards.sh` + `hm` (reads `$MOVE_CONF`), `move.conf.example`, `examples/hermes.conf`, `test/`. **The guard functions are the safety layer; `hm` is only a convenience** that runs them (it `eval`s its argument, so it is not a sandbox). Steps with no guard (flux suspend/resume, scale, label removal, B11 deletes) are raw commands — they are checkpointed, not enforced.
- `templates/` — execution plan, PR bodies, results, rollback-branch recipe.
- Runbook `§3` (procedure), `§5` (rollback), `§6.4` (kopiur differences). Real-move plan, reviews and results: `docs/rehearsal/hermes-move/`.

## HARD RULES (a violation is a stop, not a judgement call)

1. **Never `kubectl apply` a repo app** (kustomize build | apply skips Flux `postBuild` envsubst; a literal `${SECRET_DOMAIN}` took 9 hosts down once). Flux applies; the only objects you create are guard-made helper Jobs.
2. **Never remove a PV `claimRef`.** Re-point it (`hm 'pv_repoint …'`). A claimRef-less PV is taken by any matching claim (trap 10).
3. **Never set a PV to `Delete` before the human says B10** (`B10_OK=yes` is theirs to give). `Delete` re-arms trap 2: PV + Longhorn volume gone in ~19 s.
4. **Never merge a move PR before its step.** PR 1 only at W-9, PR 2 only at W-13 after the content compare passed. Only via `hm 'pr_merge <n> <sha>'` — which itself refuses PR 1 unless the W-8 state holds (PV `Retain`+`Bound`, HR suspended, ks running, replicas 0, no pod, backups accepted) and PR 2 unless PR 1 is `MERGED` at its pinned head and `W12-PASS` is on record; never a bare `gh pr merge`, never `--squash/--rebase`, never `--delete-branch`.
5. **Never fix a stalled restore drill by touching the app PV** (trap 14). The drill is evidence, not a precondition.
6. **No push, no PR, no silence, no quiesce, no merge of a move PR, no B10 without the human's explicit go-ahead at the named checkpoint** below. An earlier "yes" does not carry over.
7. Fail closed: a guard refusal, an API error, an unexpected PV name, or a failed pass criterion **stops the run**. Do not edit a guard to get past it.
8. No `flux reconcile` after a push to `main` (webhook auto-reconciles). No `git revert` as a rollback (trap 6 in §5: forward commit + re-point).
9. Run harnesses and guards under `/bin/bash`, never `zsh -c` (re-reads `~/.zshenv`, puts the real `kubectl` ahead of a fake; this hit the live cluster once).
10. Commits are bot-authored per repo `CLAUDE.md` (`MOVE_COAUTHOR='<Co-Authored-By value>' hm 'COMMIT "<scope>: …"'`; the model is never defaulted). Scoped Commits, no type prefixes. Never commit unless asked; the operator commits P2 work unless told otherwise.

## Procedure — phases and human checkpoints

| Phase | What | Checkpoint (human go-ahead, by name) |
| --- | --- | --- |
| **P0 classify** | `classify.md`: refuse/escalate anything but VolSync+Longhorn | **`CLASSIFIED`** — show the class + discovery output; proceed only on "covered" |
| **P1 investigate** | read-only: real volume layout, schedules, consumers, open PRs, free space | — |
| **P2 prepare** | minimal move commit + kind-targeted patches + literal gate (local only) | — (nothing leaves the laptop) |
| **P3 adversarial review** | a second model reviews plan + guards; verify by executing | — |
| **P4 T-1** | PV label + `Retain` → push → draft PRs → CI + bot review → local rollback branch | **`RETAIN`** (the one pre-window cluster mutation), then **`PUSH`** (push + open drafts) |
| **P5 window** | W-0…W-17 (clock, drift, quiesce, baseline, forced backup, merge PR 1, re-point, content compare, merge PR 2, verify) | **`SILENCE`** · **`QUIESCE`** (downtime starts) · **`MERGE-1`** (W-9) · **`MERGE-2`** (W-13, only after W-12 passed) |
| **P6 soak** | days; PV stays `Retain`; both new series written | — |
| **P7 cleanup** | B10, cleanup PR, orphans, age-out, drop-RD-patch and volume-pin decisions | **`B10`**, **`CLEANUP`** (each deletion/PR), then the age-out and long-term-shape decisions |

At each checkpoint: state what you are about to do, the evidence, the rollback, then **stop and wait**.

## STOP AND ASK (any of these, mid-run)

- A pass criterion is not met, or a step's output differs from what the workflow says (do not improvise a fix).
- `hm 'app_pv'` prints a name other than the configured `PV` (the claim was re-provisioned).
- Drift on `origin/main` in `DRIFT_PATHS`, a `CONFLICTING` PR, a moved PR head, an open Renovate PR touching the app, a Pending PVC that is not the moving claim, low Longhorn space.
- Anything needing: removing a claimRef, deleting a PV/PVC/Longhorn volume, `--force`, editing the RD `spec.trigger.manual` while the ks runs, suspending/resuming anything not listed, a rollback (needs a new PR; mostly UNTESTED).
- 45 minutes since quiesce with no convergence, or an alert not accounted for in the plan.
- The app has more than one PVC or ReplicationDestination (kind-targeted patches hit them all) — stop at P0.

## Output

After each phase, one short status: what was verified (with the command), what is UNVERIFIED, next checkpoint. At the end fill `templates/results.md.tmpl`
and list what to update in the runbook (Known untested). Keep the per-move config, baseline listings and state dir **outside** every repo.
