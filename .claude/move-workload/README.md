# move-workload — repeatable "move a workload between namespaces"

Entry point: **`/move-workload <app> <old-namespace> <new-namespace>`** (`.claude/commands/move-workload.md`). This directory is what the command reads on demand.
Covers **one** workload class: **VolSync + Longhorn PVC** (procedure: `docs/runbooks/volsync-app-namespace-move.md`). Everything else is classified and refused/escalated.

| File | Role |
| --- | --- |
| `classify.md` | P0 decision tree + read-only discovery commands (stateless / VolSync+Longhorn / kopiur / NFS / DB / StatefulSet / several PVCs) |
| `workflow.md` | P0–P7, the window `W-0…W-17` ↔ runbook `B0–B11`, commands, pass/abort, TESTED/UNTESTED rollback |
| `traps.md` | one line per trap (runbook 1–15 + real-move traps) |
| `guards/move-guards.sh` | the guard library: reads **`$MOVE_CONF`** only; pins namespaces, the one PV, PR numbers/SHAs; fails closed; no push function |
| `guards/kn-guard.sh` (+ `.sha256`, `.test.sh`, `.mutation.sh`, `kn-guard-mutants/`) | the vendored shared namespace-pinned kubectl allow-list guard (see below) |
| `guards/hm` | `MOVE_CONF=… hm '<guard call>'` — sources the guards in a fresh bash and `eval`s the argument (tool calls keep no shell state). A convenience, **not** a sandbox |
| `guards/move.conf.example` | every key, documented |
| `guards/examples/hermes.conf` | the real values of the 2026-09-24 move; `probe.conf` is a fake second app the harness uses to prove nothing is hard-coded |
| `guards/test/` | `run.sh <conf>` (fake `kubectl`/`gh`, no real call), `gate-test.sh <conf>` (`move_gate` vs the real commits, in a scratch shared clone), `gate-synth.sh <conf>` (`move_gate` vs a synthetic tree: `CONTROLLER`≠`APP`, wrong values, two PVCs), `bin/` fakes |
| `templates/` | `execution-plan.md.tmpl`, `pr-move-body`, `pr-start-body`, `results.md.tmpl`, `rollback-branch-recipe.md` |

## Start a move
1. `/move-workload <app> <old> <new>` → P0 classify; stop unless class B.
2. `cp .claude/move-workload/guards/move.conf.example <path OUTSIDE every repo>/<app>-move.conf`; fill it (APP OLD NEW PV, `CLUSTER_UID` = `kubectl get ns kube-system -o jsonpath='{.metadata.uid}'`, `STATE_DIR`, `WORKTREE`, and the layout keys from P1). Leave `PR1 PR2 PR*_SHA BASE_SHA` for P4.
3. Prove the guards for **this** conf: `/bin/bash .claude/move-workload/guards/test/run.sh <conf>` (all must pass; **never zsh**). After P2 also `test/gate-test.sh <conf>` (needs the real commits) and `test/gate-synth.sh <conf>`.
4. `ln -s "$PWD/.claude/move-workload/guards/hm" ~/.local/bin/hm` (optional); every guard call is `MOVE_CONF=<conf> hm '<call>'`.
5. Follow `workflow.md`; fill `templates/execution-plan.md.tmpl` at P2; stop at every named checkpoint.

## Safety model — what is and is not enforced
**Enforced by the guard functions** (`guards/move-guards.sh`, each with a refuse-test in `guards/test/run.sh`):
- Config is **data**: only `KEY="value"` lines are accepted (nothing is executed), every safety-critical value comes from `$MOVE_CONF` (inherited env is `unset`, values validated then `readonly`), and exported shell functions are dropped at load.
- The cluster is identified by the kube-system UID (re-checked before every write). `kn` is the **vendored shared guard `guards/kn-guard.sh`** (unchanged; see below): a verb + kind + FLAG allow-list pinned to OLD/NEW. It refuses combined/attached short flags (`-RA`, `-Rnkube-system`, `-shttps://…`, `-A=true`), any `-n`/`-A`/`--context`/`--server`/`--as`/credential flag, `--`, unlisted long flags, secrets, cluster-scoped and unlisted kinds, `KUBERNETES_MASTER`, `exec`/`cp`/`port-forward`/…, and `apply` unless `apply -f -` of a Job manifest with no namespace. `apply -f -` accepts **JSON only** (validated as STRICT JSON by **python3**, then parsed with **jq**; every document must be an object whose `apiVersion/Kind` is in `KN_APPLY_KINDS` — default `batch/v1/Job` — with no `items` key and no `namespace` key anywhere, and kubectl is sent the canonical `jq -c` form that was checked), so `data_check` builds its Job with `jq`. kubectl always runs with `KUBERC=off`; short-flag arity is per verb (`logs -p` is boolean, `patch -p` takes a value); Flux and ESO kinds can be read/deleted but never patched. The deny/allow lists and hard-deny verbs are **not** overridable through `KN_*` variables; only namespaces, kinds, verbs (and apply kinds / extra flags) are opt-ins. This skill configures it with `KN_VERBS="get describe logs wait apply delete patch"` (so `kn` **can** delete/patch/apply allow-listed kinds in OLD/NEW — the helper Job and the RS trigger — it is no longer read-only) and adds the full Flux Kustomization kind name to its kind list.
- There is **no generic PV patcher**. A PV is written in exactly three functions, with payloads built in code (nothing caller-supplied): `record_pv` (label), `pv_reclaim` (`Retain`; `Delete` needs a Bound PV + Bound claim and `B10_OK=yes` when the claim is in NEW or `SINCE.txt` exists) and `pv_repoint` (PV Released/Available, `Retain`, target claim absent or Pending). Each re-runs `pv_ok` (the one configured PV, labelled, claimRef `OLD|NEW/APP`, never empty) and re-verifies the cluster UID. The claimRef is never removed. (`hm` is `eval`: raw `kubectl patch pv …` typed inside it still works — the guards do not sandbox it.)
- `pr_merge` re-checks the world itself: PR 1 needs the W-8 state (PV `Retain`+`Bound`, HR suspended, ks running, replicas 0, no pod on the claim, quiesce/T0 recorded, both forced backups accepted) and **writes `SINCE.txt`**; PR 2 needs PR 1 `MERGED` at its pinned head, a **`W12-PASS`** (written only by `data_compare` of a baseline taken in OLD against the app claim in NEW; the marker must hold exactly one baseline and one after line, the after-listing must be newer than `SINCE`, and `pr_merge` **re-runs the comparison** rather than trusting the file) and PV `Retain`+`Bound` to NEW. A user with shell access can still write files in the state dir — this stops mistakes and casual forgery, not a determined operator. Numbers/SHAs/branches are pinned. `move_gate` checks the patch **values**, not just their count. Waits are deadline-bound.
**NOT enforced — be honest about it:**
- `hm` is `eval "$*"`: anything typed inside it runs. Only the guard *functions* are the safety layer. `flux suspend/resume`, `kubectl scale`, the PV-label removal and the B11 deletes are raw commands with no guard.
- `HM_WINDOW`, `SILENCE_OK`, `B10_OK` are environment flags the agent sets itself: they are **speed bumps**, not authorisation. The human's go-ahead at each named checkpoint (see the command) is the only real approval.
- `gh` calls have no timeout flag (kubectl calls carry `--request-timeout=20s`); only the tool's own limit bounds a hung `gh`.
- `PATH` is trusted (a hostile `kubectl` earlier on `PATH` defeats everything; `HM_FAKE` only protects the *tests*). The frontmatter `allowed-tools: Bash` pre-approves every shell call while the command runs (**deferred, m10**: scoped `Bash(...)` entries would restore the permission prompt for mutating `kubectl`/`flux`/`gh`; consistent with `renovate-sweep.md`, but consider running this command in a mode that still prompts).
- Alertmanager silences (`am_open`/`am_post`/`am_unsilence`) and `wait_running`, `wait_pv_phase`, `others_ready`, `inventory_ok`, `drill_snapshot_ok` have no unit tests. The guards have **not** been run against a live cluster.

## Vendored guard: `guards/kn-guard.sh`
Copied **unchanged** from the shared source; sha256 `ff0dc99808775d404af8a49efedb398f07ab899a0dffbaefc76e28f2ad3587a2` (recorded in `guards/kn-guard.sha256`; `test/run.sh` re-checks it, so an edit or a stale copy fails the suite). Its own suite (`kn-guard.test.sh`, 460 tests) and mutation harness (`kn-guard.mutation.sh`, 66 mutants, all killed) sit beside it and run inside `test/run.sh`. To re-vendor: copy the new file, recompute the hash, update `kn-guard.sha256` and this line, re-run everything.

## Dependencies
`jq`, `yq` (mikefarah v4, used by `move_gate`), `git` and `python3` must be on `PATH`; `move-guards.sh` refuses cleanly at load if any is missing (tested). `kn-guard.sh` itself needs **both `jq` and `python3`** for `apply -f -` and refuses that verb cleanly if either is missing. `KN_CONTROLLER_KINDS` can only add controller kinds, never remove the built-in ones. Also `kubectl`, `flux`, `gh` for the workflow itself.

## Preconditions the guards assume (class B constants; not hermes-specific, but not universal)
Alertmanager at `observability/svc/kube-prometheus-stack-alertmanager:9093`; Longhorn in `longhorn-system`; kopia mount/policy path `/data`; VolSync object names `<APP>-local`, `<APP>-r2`, `<APP>-dst-local` and RD dest PVC `volsync-<APP>-dst-local-dest` (from `components/volsync-*`); app pods labelled `app.kubernetes.io/name=<APP>` and the app-template controller key = `CONTROLLER` (default `<APP>`); helper Job image `busybox:1.37` (a tag, **not** digest-pinned); commit identity `fizz-bot-bvn[bot]`; GitHub base branch `main`; BSD `sed -i ''` in `gate-test.sh`.

## Not covered / UNVERIFIED
kopiur, NFS/tns-csi, CNPG, StatefulSets, multi-PVC apps (all escalate/refuse in `classify.md`; multi-PVC/RD also fails the gate's exactly-one checks). Real `kubectl`/Longhorn/VolSync/`gh`/Alertmanager behaviour behind the fakes is exercised only by the rehearsal and the real hermes move.
