# Workflow — moving `<APP>` from `<OLD>` to `<NEW>` (PV `<PV>`)

Class B only (see `classify.md`). Procedure and evidence: `docs/runbooks/volsync-app-namespace-move.md` (**the runbook**; `B0–B11`, traps 1–15). The executed instance, with real output: `docs/rehearsal/hermes-move/execution-plan.md`
(on `main`, with `results.md` and the two reviews). This file is the **generic order of operations**; it does not repeat the runbook's evidence — read the cited section when a step surprises you.

**Status labels:** **TESTED** = exercised in the rehearsal (1 MiB fixture) or the real hermes move; **UNTESTED** = reasoning/source reading only; **UNVERIFIED** = an assumption nobody checked.
**Guards:** every command shown as `hm '…'` is `MOVE_CONF=<conf> hm '…'` (`README.md` in this directory); tool calls keep no shell state, so state lives in `$STATE_DIR` (written by `hm`) and is re-read.
**Bounded waits:** every loop is bounded under the 600 s tool limit; a timeout means STOP, not "wait longer".

---

## P0 — Classify  → checkpoint `CLASSIFIED`
Run `classify.md`. Covered only if class B. Record: PV, StorageClass, capacity, both RS schedules, consumers, NEW-namespace state. **Abort:** any other class.

## P1 — Investigate (read-only)
1. **Baseline layout — look, don't assume.** Read the live volume with a read-only, uid-0 listing (guard `data_check` does this, but it needs the window; before it, `kubectl -n OLD exec deploy/<APP> -- ls -la <mount>` for the top level + `find <dir> -type f | wc -l` per dir is fine — *read-only exec, one command each*).
   Hermes' `memories/` was **empty** and its state lived in `state.db`; an assumed "non-zero `memories/`" gate would have failed a healthy volume, an assumed "sessions/ is big" would have passed a wrong one.
   Decide `EXPECT_FILES` (must exist, non-empty), `EXPECT_DIRS` (must hold files), `REPORT_DIRS` (reported only), `LIVE_FILES` (a live DB whose file may not be byte-stable across a pod start). **The app may rewrite files at start (hermes rewrites `.env`)** — compare content *before* the pod starts (W-12), never after.
2. **Schedules → the clock rules** (UTC; VolSync `nextSyncTime` shows UTC): `local` RS busy window = its cron minute + last `lastSyncDuration` + margin; the `r2` RS same. Kopia-maintenance CronJobs (`kubectl get cronjob -A | grep kopia`) too. No B3 inside those windows (trap 8).
3. **Consumers** (`classify.md` #6), gatus/homepage annotations in `httproute.yaml`, README/`kubectl -n OLD` snippets — inside the app dir they move with it; **outside** it they are deferred (P2).
4. **Open PRs / Renovate** touching the app: hold them (a bump on the `OLD` path conflicts with the move commit). Note the PR numbers; no Renovate sweep from P4 push to W-17.
5. **NEW namespace:** exists; `volsync.backube/privileged-movers: "true"` **live** if OLD has it (runbook §6.5) — merged to `main` as its **own** commit *before* the move. PSA compatible with a root mover. No conflicting object named `<APP>`.
6. **Capacity:** free Longhorn space ≥ ~116 Gi for a 20 Gi app (RD dest + cache ≈ 44 Gi + creation-time syncs) **[inferred, from the hermes review; not measured]**.
7. Copy `guards/move.conf.example` to a path **outside every repo**, fill the layout/name keys (PR/SHA keys wait for P4).

## P2 — Prepare the MINIMAL move commit (local only, no push)
Worktree on a branch off current `origin/main`. **The commit changes only:** the app directory move + the two namespace `kustomization.yaml` lists.
**Defer every comment-only or docs edit elsewhere to a cleanup PR (P7)** — `main` churn collided with the hermes commit four times, and each collision meant new SHAs and a re-run of every gate.

1. `git mv kubernetes/apps/<OLD>/<APP> kubernetes/apps/<NEW>/<APP>`; remove `./<APP>/ks.yaml` from `apps/<OLD>/kustomization.yaml`; add it (alphabetical) to `apps/<NEW>/kustomization.yaml`.
2. `ks.yaml`: `path`, `targetNamespace: <NEW>`, `postBuild.substitute.NS: <NEW>`; optionally match the destination's neighbours' shape (interval/retryInterval/timeout). Keep every `VOLSYNC_*` unchanged (`VOLSYNC_STORAGECLASS` must equal the retained PV's class).
3. `app/kustomization.yaml` — patches **by kind, never by name** (trap 5; safe only with exactly one PVC and one RD — classify B guarantees it):
   ```yaml
   patches:
     - target: {kind: PersistentVolumeClaim}
       patch: |-
         - op: add
           path: /spec/volumeName
           value: <PV>                       # keep for the life of the claim (trap 12)
     - target: {kind: ReplicationDestination}
       patch: |-
         - op: add
           path: /spec/kopia/sourceIdentity/sourceNamespace
           value: <OLD>                      # NOT inert: the NEW RD restores at creation (trap 11)
   ```
4. `app/helmrelease.yaml`: temporary `controllers.<CONTROLLER>.replicas: 0` (nothing writes before W-12; TESTED [Rh-8]) and, if the image is slow to start/cached on one node, `spec.timeout: 15m` (else `upgrade.remediation.strategy: rollback` can put a slow start back at 0). Both are removed in P7.
5. Inside the moved dir only: gatus `group`, homepage `gethomepage.dev/group`, README `kubectl -n` snippets. Nothing outside it.
6. **Commit 2** (child of commit 1): drop `replicas: 0`, nothing else.
7. `MOVE_COAUTHOR='<model Co-Authored-By>' hm 'COMMIT "<scope>: move from <OLD> to <NEW>, pod held at 0 replicas"'` (bot identity; lefthook may rewrite YAML — re-gate after).

**MANDATORY LITERAL GATE** (on the COMMITTED tree, both commits; `hm 'move_gate <NEW> 2 zero'` for commit 1, `hm 'move_gate <NEW> 2 absent'` for commit 2). It asserts, and you must **read the output**:
- tree committed; the app build (`flux build ks <APP> -n <NEW> --path ./kubernetes/apps/<NEW>/<APP>/app --kustomization-file …/ks.yaml --dry-run`) has **exactly two** `volumeName|sourceNamespace` lines;
- **all objects in the app build are in `<NEW>`** (`yq … .metadata.namespace | sort -u` = one line);
- the **parent** `cluster-apps` build (`flux build ks cluster-apps -n flux-system --path ./kubernetes/apps --kustomization-file ./kubernetes/flux/cluster/ks.yaml --dry-run`) has **exactly one** child named `<APP>` and it equals `<NEW> <APP> ./kubernetes/apps/<NEW>/<APP>/app <NEW>`; and `replicas` zero/absent.
Also run `yamlfmt -lint` on changed YAML and `lefthook run pre-commit` **staged-only** (never `--all-files`). Local `flux-local --enable-helm` may fail on ghcr keychain; CI's Flux Local is the first real HelmRelease render (P4).
**Pass:** `GATE PASS` ×2. **Abort:** any `GATE FAIL`. Rollback: n/a (local).
Then `guards/test/run.sh <conf>` and `guards/test/gate-test.sh <conf>` (P3 prerequisite). Fill `templates/execution-plan.md.tmpl` (literal values in one place).

## P3 — Adversarial review (before anything leaves the laptop)
A **second model** reviews the plan + guards (sonnet/opus per `agent-delegation.md`; ask before `fable`). Brief it to **verify by executing**: run the harness, feed the gate bad commits, try to make a guard mutate the wrong PV, hit the zsh/PATH trap (with `HM_FAKE`), reason about ordering. Reading is not verification — the hermes reviews found 1 blocker + 5 major + a live-cluster incident *by running things*.
Reviewer rules: read-only cluster, `/bin/bash` only, no zsh, report every mutation it makes. Fix findings → new SHAs → re-run gates and tests. **Pass:** a written review with every finding mapped to a fix or an explicit accept.

## P4 — T-1 (pre-window)

**T-1.1 drift/gates** — `hm 'drift_check'` (no drift), re-run `move_gate` on both SHAs.
**T-1.2 cluster preconditions** — re-run `classify.md` #2/#7/#8/#9/#10 and `hm 'others_ready'`. **Pass:** as classify; no Pending claim but none; no open PR in the touched paths.
**T-1.3 `RETAIN` checkpoint — the one deliberate pre-window mutation:**
```bash
hm 'record_pv'                                    # labels the PV <APP>-move=1 (only if a live claim names exactly PV)
hm 'app_pv'                                       # prints PV
hm 'pv_reclaim $PV Retain'                        # prints Retain
kubectl get pv <PV> -o jsonpath='{.spec.persistentVolumeReclaimPolicy} {.status.phase} {.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}'   # INDEPENDENT read-back: Retain Bound <OLD>/<APP>
```
**Pass:** both `Retain`, still `Bound`. **Do not push until this prints `Retain`** — it turns an accidental early merge from "PV + Longhorn volume deleted" into "PV `Released`, recover by re-point". Rollback: `hm 'pv_reclaim $PV Delete'` (guard allows only while Bound + claim Bound; Delete patch on a Bound PV TESTED [Rh-11]).
**Mutation rule from here to the window:** only the label and `Retain`. No suspend, no scale, no annotation. If `<OLD>/<APP>` PVC is ever recreated before the window: **STOP** (Flux recreates a stock claim, silent divergence; recovery: suspend ks, scale 0, delete the new claim, `pv_repoint … <OLD>`, content check).
**T-1.4 `PUSH` checkpoint:** create branches `<APP>-move-pr1` = commit 1, `<APP>-move-pr2` = commit 2 and push them (SSH fails despite auth → HTTPS via `gh`, then `gh pr create` needs explicit `--head`); open **both as drafts** (`gh pr create -R <repo> --draft …`; templates `pr-move-body`, `pr-start-body`); first line of each body `HOLD — merged only by …`. Fill `PR1`, `PR2`, `PR1_SHA`, `PR2_SHA`, `BASE_SHA` in the conf **once**; from here no command carries a variable where a PR number goes. Renovate PRs for the app: on HOLD.
**T-1.5 CI + bot review on BOTH drafts** (Flux Local + Image Pull + Claude review run on drafts; the review reviews the *branch*, so stale-base findings are possible — trap in `traps.md`). Read the review; a finding that changes a file **changes the SHAs** → update conf, redo T-1.1–T-1.5 (force-push needs a go-ahead). PR 2 shows both commits until PR 1 merges (expected).
**T-1.6 rollback branch, local only** — `templates/rollback-branch-recipe.md`; gate `move_gate <OLD> 1 zero` → PASS. UNTESTED at real size.
**T-1.7** decide window time (P5 clock rules), `SILENCE` yes/no, who does the application-level login check at W-14.

---

## P5 — The window

Map: **W-2 B0 · W-3 B1 · W-4 B2 · W-5 B3 · W-6 B4 · W-7 B4b · W-9 B5 · W-10 B5b patch proof · W-11 B6 · W-12 B7 · W-13/14 B8 · W-15 B5b drill · W-16 B9 · W-17 end.** Second terminal: `watch -n5` the PV phase + claimRef.

| Step | Do (commands) | Pass / abort | Rollback |
| --- | --- | --- | --- |
| **W-0 clock** | `date -u +%FT%TZ`. From the RS cron: not within the `local` RS busy window (≈ cron minute −3 … +6), not the `r2` window, not kopia-maintenance (`0 */4` local / `0 3` r2 in UTC on this cluster), and prefer the app idle. | **Abort:** inside a busy window — wait. | n/a |
| **W-0b pre-quiesce** (app still up) | `hm 'w0b'` → no drift; both PRs OPEN+MERGEABLE at the pinned heads (UNKNOWN is retried ≤60 s each — normal first poll). `gh pr list -R <repo> --state open --json number,title` filtered to titles naming <APP> → only the two PRs. | **Abort (nothing down yet):** drift / `CONFLICTING` / moved head → T-1.1. | n/a |
| **W-1 silence** (`SILENCE` ok) | `SILENCE_OK=yes AM_HOURS=3 hm 'am_silence'`; `hm 'app_pv'` = PV. Gatus and `KubeJobFailed` for `hchk-*` are **not** silenced. | Any other PV name → stop. | `hm 'am_unsilence'` |
| **W-2 B0** | PV reclaim/phase/claim/cap/sc; Longhorn volume state; `hm 'no_sync_in_flight <OLD>'` idle. | `Retain`, `Bound`, `<OLD>/<APP>`, both RS idle. | n/a |
| **W-3 B1 quiesce** (`QUIESCE` ok) — *downtime starts* | `flux suspend kustomization <APP> -n <OLD>`; `flux suspend helmrelease <APP> -n <OLD>`; `kubectl -n <OLD> scale deploy/<APP> --replicas=0`; `kubectl -n <OLD> wait --for=delete pod -l app.kubernetes.io/name=<APP> --timeout=180s`; pods still mounting the PVC (incl. Completed → trap 3) = empty; `hm 'date -u +%FT%TZ > $MOVE_DIR/T-quiesced.txt'`. ks suspension is **mandatory** (Flux strips a hand-patched `manual`, [Rh-7]). | Pod gone ≤180 s, list empty. **Abort:** not gone → ask. | resume both, scale up — UNTESTED (trivial) |
| **W-4 B2 baseline** | `HM_WINDOW=yes hm 'data_check <OLD> $MOVE_DIR/baseline.txt'` (uid-0 read-only Job, self-deleting, pod-gone asserted) then `hm 'data_baseline_ok $MOVE_DIR/baseline.txt'`. | Every `EXPECT_FILES` present + non-empty, `EXPECT_DIRS` > 0, no `hchk` pod. **Abort:** a named file absent *now* → understand why first. | n/a (read-only) |
| **W-5 B3 forced final backup** | Call A: `hm 'no_sync_in_flight <OLD> && date -u +%FT%TZ > $MOVE_DIR/T0.txt && echo pre-move-$(date +%s) > $MOVE_DIR/TAG.txt && for RS in <APP>-local <APP>-r2; do rs_trigger <OLD> $RS "$(cat $MOVE_DIR/TAG.txt)"; done && wait_manual <OLD> <APP>-local "$(cat $MOVE_DIR/TAG.txt)" 40 && check_backup <OLD> <APP>-local <APP>@<OLD> "$(cat $MOVE_DIR/T0.txt)"'`; Call B: same wait + `check_backup` for `<APP>-r2`. | **Both** RS: `lastManualSync==TAG`, `lastSyncTime > T0`, Created ≥1, `Setting policy <APP>@<OLD>` ≥1, SUCCESS ≥1, `Directory is empty` 0. `lastManualSync==TAG` alone proves nothing (trap 8). **Abort:** fail/STALE twice → ask (`docs/runbooks/volsync-mover-stuck.md` if wedged). | none needed (additive). TESTED [Rh-7, Rh-12] |
| **W-6 B4 read-back** | `kubectl get pv <PV> -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'` | `Retain`. | n/a |
| **W-7 B4b** | `flux resume kustomization <APP> -n <OLD>` (HR stays suspended, Deployment at 0 — else the merge prunes nothing, trap 6); HR `.spec.suspend`=`true`, deploy replicas `0`, ks `.spec.suspend` empty/false; no pod; `hm 'inventory_ok <OLD>'`. | All as stated. **Abort:** any mismatch. TESTED [Rh-6]. | resume HR; scale up; UNTESTED |
| **W-8 go/no-go** | `hm 'app_pv'`; PV `Retain`; `hm 'pending_claims'` empty; minute still outside busy windows; `hm 'pr_mergeable <PR1> <SHA1> 12 && pr_mergeable <PR2> <SHA2> 12'`. | All. **Abort:** `CONFLICTING`/moved (main moved after W-0b) → resume + scale up, ask. | as W-7 |
| **W-9 B5 merge PR 1** (`MERGE-1` ok) — *soft point of no return* | `hm 'pr_merge <PR1> <SHA1>'` — **re-checks the W-8 state itself** (PV `Retain`+`Bound` to `<OLD>/<APP>`, HR suspended, ks NOT suspended, replicas 0, no pod on the claim, `T-quiesced`/`T0` on record, both forced backups accepted after T0) and **writes `SINCE.txt` before merging** (from then `Delete` needs `B10_OK=yes`); **no `flux reconcile`**; `hm 'wait_pv_phase $PV Released 100'`; `kubectl -n <OLD> get pvc <APP>` NotFound; `hm 'pending_claims'` = `<NEW>/<APP>` (+ RD claims). `FailedBinding … already bound to a different claim` is **expected**. | PV `Released`, old PVC gone. **Abort:** PV stays `Bound` >5 min → OLD ks still suspended (trap 6). Never remove claimRef; never `Delete`. | forward-commit back into OLD **with** the `volumeName` patch + `pv_repoint … <OLD>` + content check — **UNTESTED as a rollback** |
| **W-10 B5b patch proof** | `kubectl -n <NEW> get replicationdestination.volsync.backube <APP>-dst-local -o jsonpath='{.status.kopia.requestedIdentity}'` = `<APP>@<OLD>` (`@<NEW>` = patch dropped: **STOP**, trap 1/5); `kubectl -n <NEW> get pvc <APP> -o jsonpath='{.spec.volumeName}'` = PV; `hm 'inventory_ok <NEW>'`; deploy replicas `0`. | as stated. TESTED in-cluster [Rh-13]. | as W-9 |
| **W-11 B6 re-point** | `hm 'pending_claims'`; `hm 'pv_repoint $PV <NEW>'`; `hm 'wait_pv_phase $PV Bound 40'`; `kubectl -n <NEW> get pvc <APP> -o wide`; populator events for this claim since `SINCE` = **0** (jq in runbook §3 B6). Do **not** wait for the RD restore (concurrent competing claim TESTED, S8). | Bound to PV, 0 events. **Abort:** bound a *different* PV / new volume → STOP. Stays Pending → `describe pvc` first; ask before deleting it. | forward commit + `pv_repoint … <OLD>`; UNTESTED |
| **W-12 B7 content compare — BEFORE the pod starts** | `HM_WINDOW=yes hm 'data_check <NEW> $MOVE_DIR/after.txt'`; `hm 'data_compare $MOVE_DIR/baseline.txt $MOVE_DIR/after.txt'` — **everything** identical, `LIVE_FILES` included (`--ignore-live` exists for cross-start comparisons; **this workflow never uses it**); no `hchk` pod; `hm 'app_pv'`. | `content identical`. **Abort:** any difference → wrong volume/empty restore [S-b]; **do NOT merge PR 2**. | roll back per runbook §5 |
| **W-13 B8 start** (`MERGE-2` ok, only after W-12) | `hm 'pr_mergeable <PR2> <SHA2> 12'` (UNKNOWN right after PR 1 merged: poll, don't abort; the guard needs `W12-PASS` from W-12 — `pr_merge` refuses without it, and unless PR 1 is `MERGED` at its pinned head and the PV is `Retain`+`Bound` to `<NEW>/<APP>`); `gh pr diff -R <repo> <PR2> --name-only` → only the HelmRelease (but see traps: the record can be **stale** — `git merge-tree`); `hm 'pr_merge <PR2> <SHA2>'`; `hm 'wait_running <NEW> 100'`. | Diff = HelmRelease only; pod Ready. *Downtime ends.* Timeout with HR still `Reconciling` inside its timeout → re-run once, then ask. | **TESTED [Rh-4]** (1 MiB): suspend HR, scale 0, no pod on the PVC, resume ks, forward commit back + `volumeName`, wait `Released`, re-point to `<OLD>`, content check, clean trap-7 orphans |
| **W-14 B8 verify → unsilence** | `kubectl -n <NEW> exec deploy/<APP> -- ls -la <mount>` (the only allowed exec); `hm 'one_route <NEW>'`; gatus `<NEW>_<APP>` (per-key API returns an **object**, may take minutes) and stale `<OLD>_<APP>`; `helm -n <NEW> history <APP>` = 2 revisions; **`hm 'am_unsilence'` NOW** (its pod matcher (`APP-<hash>-<id>`) would mute a crashloop). Human: log in, check the state is there. A fresh empty app also comes up "healthy" — W-12 is the real gate. | All + human OK. | as W-13 |
| **W-15 drill (post-start evidence)** | RD `latestMoverStatus.result` + `lastManualSync`; `hm 'drill_snapshot_ok'` (the Longhorn snapshot behind `latestImage` must exist — trap 14a); `HM_WINDOW=yes hm 'data_check <NEW> $MOVE_DIR/drill.txt volsync-<APP>-dst-local-dest'`; `hm 'data_compare $MOVE_DIR/baseline.txt $MOVE_DIR/drill.txt'`. Keep off `:00` of kopia-maintenance-local hours. | A failure means only that `<APP>@<OLD>` may not be restorable — the live volume was verified at W-12. A diff confined to `cache/` may be a kopia CACHEDIR.TAG exclusion [UNVERIFIED]. Stalled `vs-prime` → ask; **never touch the app PV**. | n/a |
| **W-16 B9 new series** | `for RS in <APP>-local <APP>-r2`: `lastSyncStartTime`/`lastSyncTime`/result; `hm 'check_backup <NEW> <APP>-local <APP>@<NEW>'`; `-r2` after its nightly run. Patch a `manual` tag only if `lastSyncStartTime` is empty (creation-time first sync stamps it, trap 8). | `Setting policy for <APP>@<NEW>:/data`, not `@<OLD>`. Move is functionally done but **not closed** until R2 passes. | n/a |
| **W-17 end** | `hm 'watch_stop_all'`; `hm 'others_ready'`; `kubectl get ks -A | grep -v True`; `<OLD>` shows only the trap-7 orphans (deploy/svc/sa/`sh.helm.release.v1.<APP>.*`). | Do **not** patch the PV to `Delete`; do not clean `<OLD>` in the window. | n/a |

45 minutes after W-3 with no convergence: stop and ask. Checklist to close the window: same PV, `Retain`/`Bound`/`<NEW>/<APP>`, Longhorn `kubernetesStatus` → `<NEW>/<APP>`; W-12 identical; one route in `<NEW>`; gatus green; helm history 2; both `<APP>@<NEW>` series; no Pending PVC / `hchk-*` Job or pod; silences removed; all ks Ready.

## P6 — Soak (days; PV stays `Retain`)
+1 h: `check_backup <NEW> <APP>-local <APP>@<NEW>`, pods/PVC, restarts 0. ≥1 nightly R2 run (suggest ≥3 days): `check_backup <NEW> <APP>-r2 <APP>@<NEW>`. **A restore-based recovery replays app secrets** (hermes' `auth.json` refresh token dies on replay): after any restore path expect to re-authenticate and never run a restored copy beside the live app.

## P7 — Cleanup (each needs its checkpoint)
1. **B10** (`B10` ok; criteria: W-12 passed, soak done, both `<NEW>` series exist, drill passed): `B10_OK=yes hm 'pv_reclaim $PV Delete'` → prints `Delete`, PV still `Bound`. **Re-arms trap 2** — last, deliberately.
2. **B11** (`CLEANUP`): confirm `kubectl get pv <PV> -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}'` = `<NEW>/<APP>` **first**; delete the `<OLD>` orphans (deploy/svc/sa, `sh.helm.release.v1.<APP>.*`); bounded assert-empty loop (runbook B11).
3. **Cleanup PR** (small): deferred comment/docs edits (`<NEW>`/`<OLD>` namespace.yaml comments, kopiur component comments, cross-refs, runbook rows), re-add a runbook path in the app's kustomization, **remove the temporary `spec.timeout`**.
4. **Long-term shape — human decision, UNTESTED, rehearse on a scratch app first:** the permanent `volumeName` pin breaks a rebuilt cluster (claim Pending forever) and the RD `sourceNamespace` patch makes a DR restore read the frozen old series. Candidate: `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent` on the claim + drop both patches in one commit (+ optional `prune: disabled`). See the hermes execution plan, Phase S item 2.
5. **Orphans/residue:** PV label `kubectl label pv <PV> <APP>-move-`, state dir, local branches (ask before deleting remote branches). **Age out the old `<APP>@<OLD>` series** only ≥30 days and after a `<NEW>`-series restore was drilled; needs a kopia client; never during the soak.
6. Fill `templates/results.md.tmpl`; update the runbook's Known-untested list with what this move closed or opened.
