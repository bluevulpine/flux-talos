# pin-fix rehearsal (2026-09-25) — `ssa: IfNotPresent` vs the permanent `volumeName` pin

| File | What it is |
| --- | --- |
| `plan.md` | The plan that was executed (after the adversarial reviews and four rounds of `kn-guard.sh` review). |
| `plan-review.md` | The pre-flight adversarial review of that plan. |
| `results.md` | What happened, scenario by scenario, and what it means for hermes. |
| `tools/` | Reference copies of the rehearsal-specific guard tooling (see below). |

Outcome: every scenario passed; the fix is one commit (see `docs/runbooks/volsync-app-namespace-move.md`, "Retiring the permanent pin").

## About `tools/`

Reference copies, **not** runnable in place: they were written to live in `~/.herdr/worktrees/flux-talos/` next to a `rehearsal-pin` worktree and a `pinfix-state/` directory,
and hard-code the rehearsal names, the cluster's kube-system UID and the throwaway app `moveprobe2`. Their value is the pattern:

- `kn-guard.sh` (the reusable, namespace-pinned kubectl wrapper: verb + kind + flag allow-list; JSON-only, strictly validated `apply -f -`), its 460-test suite and its 66-mutant mutation
  check are **not duplicated here**: byte-identical copies (same sha256) were vendored by the `/move-workload` skill at `.claude/move-workload/guards/` — that is the canonical in-tree copy.
  `pinfix-guards.sh` sources a `kn-guard.sh` from its own directory, so to run it copy that file next to it.
- `pinfix-guards.sh` + `pinfix-states.sh` — the rehearsal's guards (PV guards, gated push, silence/window interlocks, `PIN_FAKE` harness interlock) and the state writer.
- `pinfix-guards-test/` — the fake-kubectl harness (`run.sh` needs the scratch `rehearsal-pin` worktree beside it, so it is reference only).

The fixtures (`kubernetes/rehearsal-pin*`) lived on the scratch branch `rehearsal-pin`, which was deleted after teardown, and are deliberately not in-tree; `pinfix-states.sh` regenerates every state.
Residue: kopia series `moveprobe2@rehearsal-new` in the shared repositories; a re-run needs a new app name.
