# Namespace-move rehearsal (2026-09-23)

Evidence for `docs/runbooks/volsync-app-namespace-move.md`. A throwaway app, `moveprobe`, was moved between two scratch namespaces
under real Flux on the live cluster, following the runbook, to test the procedure before it is used on hermes.

| File | What it is |
| --- | --- |
| `plan.md` | The plan that was executed (rev 3, after two adversarial reviews): scenarios, pass/abort criteria, guardrails, teardown. |
| `plan-review.md`, `plan-review-2.md` | The two pre-flight reviews of that plan. Rev 1 and rev 2 were both NO-GO as written; the findings are what became the guards. |
| `results.md` | What actually happened, scenario by scenario, with observed output, plus the runbook corrections it produced. |
| `rehearsal-guards.sh` | Reference copy of the guard functions used during the run. |

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
