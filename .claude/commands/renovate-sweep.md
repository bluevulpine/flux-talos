---
description: Triage, merge, and monitor open Renovate PRs for this Flux/Talos cluster
argument-hint: "[PR# | 'careful' | empty for all]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, EnterWorktree, ExitWorktree
---

# Renovate PR sweep

Process open Renovate dependency PRs for this Flux-managed Talos cluster: evaluate
each for safety, merge the safe ones (Flux auto-reconciles on merge via webhook),
monitor the rollout to steady state, and report. Make trivial fixes inline; skip
anything that needs real effort and flag it for follow-up.

**Scope** — `$ARGUMENTS`:
- empty → all open Renovate PRs
- a PR number → just that PR
- `careful` → operators / storage / secrets only, one at a time

## Reference material — read on demand, do NOT preload

These live in `.claude/renovate-sweep/` (repo root). Read each one at the step where
you need it (keeps this command lean and your context focused):

- `.claude/renovate-sweep/triage-and-safety.md` — how to classify each PR; breaking-change heuristics;
  bootstrap-vs-Flux; apiVersion/CRD checks; what to always skip.
- `.claude/renovate-sweep/repo-runbook.md` — cluster-specific commands and gotchas; the worktree→PR→CI→merge
  flow for derived fixes; validation tooling; known traps.
- `.claude/renovate-sweep/rollout-and-health.md` — pre-merge health checks; rollout monitoring; stateful /
  secret / storage special cases; how to tell healthy-in-progress from real failure.

**Serena (optional):** if the Serena MCP server is present, activate the project and
skim `mem:core` (plus linked memories) for the current source map and topology. Treat
it as a helpful accelerator only — this command must work fully without it.

## Procedure

1. **Inventory.** List open Renovate PRs (`gh pr list` — author `app/renovate[bot]`
   or the `renovate`/`dependencies` labels). Bucket by risk and kind: patch / minor /
   major / digest, and app / operator / storage / secrets / CI / bootstrap. See the
   triage doc.

2. **Classify each PR.** Read the diff; for minor/major bumps read the upstream
   changelog/release notes. Decide **safe** / **trivial-fix-then-merge** / **skip**
   using `triage-and-safety.md`. State the call and the reason.

3. **Pre-merge health.** Confirm the target workload is currently healthy *before*
   touching it — mandatory for stateful / secret / storage workloads. See
   `rollout-and-health.md`.

4. **Act:**
   - *Safe* → `gh pr merge <#> --merge --delete-branch`, then reconcile + monitor.
   - *Trivial fix* → make it via worktree → PR → CI green → merge (`repo-runbook.md`),
     then monitor.
   - *Skip* → record the reason; move on.

5. **Monitor.** After merge, fetch the Flux git source and reconcile, then watch the
   rollout to steady state. Distinguish healthy in-progress states and pre-existing
   baselines from genuine regressions (`rollout-and-health.md`). Process operator /
   storage / secrets PRs one at a time, verifying each before the next.

6. **Summarize.** End with four buckets: **merged & verified**, **fixed**,
   **skipped (with reasons)**, and **pre-existing/unrelated issues noticed**.

## Hard guardrails

- Never edit `talos/clusterconfig/` (generated) or write decrypted `*.sops.yaml` to disk.
- Merge only when the PR's own CI is green AND the workload is healthy.
- Do NOT auto-merge in the sweep: major (`!`) version bumps, talos/kubernetes node or
  control-plane upgrades, or no-downgrade storage bumps (e.g. Longhorn minors). Flag
  these for a deliberate maintenance window.
- Commit/merge derived fixes only as needed to unblock a PR you are actively processing;
  keep each fix minimal and documented (explain the WHY).
