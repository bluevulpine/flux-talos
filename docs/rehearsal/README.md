# Namespace-move rehearsal (2026-09-23) and the real hermes move (2026-09-24)

Evidence for `docs/runbooks/volsync-app-namespace-move.md`. A throwaway app, `moveprobe`, was moved between two scratch namespaces
under real Flux on the live cluster, following the runbook, to test the procedure before it is used on hermes.

| File | What it is |
| --- | --- |
| `plan.md` | The plan that was executed (rev 3, after two adversarial reviews): scenarios, pass/abort criteria, guardrails, teardown. |
| `plan-review.md`, `plan-review-2.md` | The two pre-flight reviews of that plan. Rev 1 and rev 2 were both NO-GO as written; the findings are what became the guards. |
| `pin-fix/` | The 2026-09-25 rehearsal of `ssa: IfNotPresent` as the way to retire the permanent `volumeName` pin (plan, review, results, guard tooling). |
| `results.md` | What actually happened, scenario by scenario, with observed output, plus the runbook corrections it produced. |
| `rehearsal-guards.sh` | Reference copy of the guard functions used during the run. |

## `hermes-move/` — the real move (2026-09-24)

The rehearsed procedure was then executed for real: `develop/hermes` → `ai/hermes`, approach B (volume retained and re-claimed), **succeeded** (~17.5 min downtime, no data loss, content identical). The directory holds the plan as executed, its two pre-flight reviews, the outcome, and reference copies of the guards.

| File | What it is |
| --- | --- |
| `hermes-move/results.md` | **The execution record** — timeline, per-step PASS/deviation, numbers, evidence, new traps, what stayed open and the pending follow-ups (B10, cleanup PR, B11, Renovate #1917). Source of the runbook's `[Hm-n]` tags. |
| `hermes-move/execution-plan.md` | The plan **as executed** (banner at the top: EXECUTED 2026-09-24). T-1 pre-flight, the W-0…W-17 window with pass/abort/rollback for every step, alerting, residue. Values, SHAs, PR numbers (#1915/#1916) and operator paths are kept as a record, not a template. |
| `hermes-move/plan-review-1.md`, `plan-review-2.md` | The two adversarial pre-flight reviews of that plan (blocker B1: merge-ready PRs; the `pv_reclaim` guard; the content gate; the delta review and its live-cluster incident). Their findings became guard changes and plan steps. |
| `hermes-move/hermes-move-guards.sh`, `hermes-move/hm` | Reference copies of the guards (`hm` is the wrapper that sources them). |
| `hermes-move/guards-test/` | The fake-`kubectl`/fake-`gh` test harness (`run.sh`, `gate-test.sh`, `bin/`). Run under `/bin/bash` only — never `zsh -c` (see the runbook, trap 20). (The `HM_FAKE` interlock matches the original directory name `hermes-move-guards-test/`; this copy is for reading, not re-running.) |

**The hermes guards are reference copies, not tools.** They hard-code the app (`APP=hermes`), the PV name `pvc-12f54114-9e99-442b-bae4-53a9cb239d69`, the namespaces `develop`/`ai`, the two pinned commit SHAs and PR-branch names, the cluster's `kube-system` UID and their own state directory. **Do not re-run them against another app** — adapt the pattern (namespace-pinned `kubectl`, a single-PV mutation guard that fails closed, `HM_FAKE`/`HM_WINDOW`/`B10_OK` interlocks, a `move_gate` that builds the app **and** its parent Kustomization) into a new guards file for the next move.

## About `rehearsal-guards.sh`

It is a **byte-identical copy** of the file that ran from `~/.herdr/worktrees/flux-talos/rehearsal-guards.sh` (outside every repo, next to a
`rehearsal-state/` directory of logs). Commands in `plan.md` and `results.md` reference that original path because that is what ran.

Do **not** run it against hermes. It hard-codes:

- the rehearsal namespaces `rehearsal-old` / `rehearsal-new` (`kn` refuses any other namespace), and an `APP` allowlist of `moveprobe`, `moveprobeN`;
- the cluster's `kube-system` UID (it identifies the cluster by UID, not by kubeconfig context name, because the same cluster is reachable under two contexts);
- its own state directory for the recorded-PV list (`rehearsal_pv_ok` refuses any PV not recorded there and labelled `rehearsal=move`).

Its value is the pattern: namespace-pinned `kubectl`, a PV mutation guard that fails closed on API errors, a `PUSH` that can only push one refspec, and a
`move_gate` that builds the app **and** its parent Kustomization and asserts namespace, path, `targetNamespace` and the two patch lines before a move is pushed.

## Residue the teardown could not remove

The kopia series `moveprobe@rehearsal-old` and `moveprobe@rehearsal-new` remain in the shared local (Garage) and R2 repositories: a handful of tiny snapshots each.
Deleting them needs a kopia client. Any re-run must use a new `APP` (for example `moveprobe2`), otherwise the first deploy restores from the old series.
