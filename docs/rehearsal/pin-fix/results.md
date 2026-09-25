# Pin-fix rehearsal results — `ssa: IfNotPresent` vs the permanent `volumeName` pin

Run 2026-09-25 (~19:20–20:15 UTC) under `plan.md`, on the throwaway app `moveprobe2` in `rehearsal-old`/`rehearsal-new`, kustomize-controller v1.9.1. Everything reached the cluster through the scratch `rehearsal-apps`/`rehearsal` Flux objects; the only hand mutations were `kn`-scoped (scratch namespaces), the `pv_*` guards, and `bootstrap_apply`. hermes (`ai/hermes`, PV `pvc-12f54114-…`) was checked after every scenario: uid/volumeName/phase unchanged, and its managedFields identical to the P0 reference at teardown.

## Verdict per hypothesis

| # | Scenario | Result |
| --- | --- | --- |
| Baseline | unpinned deploy + first backup | PASS, **no populator wedge**. Provisioned claim: `kube-controller-manager` (Update) owns `f:volumeName` (+ `kube-scheduler` annotations) → `s1_equiv` **DIFFERS** from `ai/hermes`, as designed. |
| S1 real-shape | PV Retain → delete claim (ks suspended) → commit pin → Flux creates pre-bound claim → `pv_repoint` | PASS. Claim Pending with `volumeName` until re-point, Bound in ~8 s, 0 populator events. **`s1_equiv` = EQUAL to live `ai/hermes`** (Flux Apply owns `volumeName`; KCM owns only annotations). Data intact; RD did **not** re-run. |
| S2c control | drop pin + RD patch, **no** annotation | PASS (stall reproduced): ks `Ready=False`, `spec is immutable after creation except resources.requests and volumeAttributesClassName for bound claims`, diff `-"VolumeName": "pvc-…"` / `+""`. Claim uid unchanged; the whole ks applied nothing (RD still named `rehearsal-old`). Recovered by re-committing the pin. |
| **S2 fix** | one commit: `ssa: IfNotPresent` + drop `volumeName` + drop RD `sourceNamespace` | **PASS.** rc=0, Ready=True, 0 "immutable" mentions, claim uid + volumeName unchanged, live claim state **identical** before/after (ownership included), RD `sourceNamespace` gone (rest of the ks *was* applied) and RD did not re-run, stable over forced reconciles. **The `ssa` annotation is NOT on the live claim** (skipped apply writes nothing) — as predicted from source. |
| S3a | git `VOLSYNC_CAPACITY` 1Gi→2Gi | Ready; **claim NOT expanded** (req=1Gi, actual=1Gi) while RS/RD capacity **were** applied (2Gi). Silent. |
| S3d | manual `kubectl patch pvc` 2Gi | Expanded online, no pod restart (~30 s); Flux does not revert it. Side effect: **`kubectl-patch` took over `f:resources` from Flux's Apply entry.** |
| S3b | git label + annotation + `storageClassName` probe | Ready; **none reached the claim** (label/annotation null, sc unchanged); no event. Silent. |
| S6 | desired `volumeName` ≠ bound | **Silent**: ks Ready=True, no warning event, claim untouched. The only traces: kustomize-controller log `"PersistentVolumeClaim/…":"skipped"` (14×) and `flux diff` printing `PersistentVolumeClaim/… skipped`. |
| S5a | `prune: disabled` via git on the *existing* claim | Did **not** land (`prune:null`); a manual `kubectl annotate` landed and **survived** forced reconciles. |
| **S4 rebuild** | PV→Delete, delete claim **and** RD, resume ks | **PASS.** Flux recreated the claim **unpinned** (new uid, `volumeName` set only by binding), with **both annotations on the live object** (created from git). RD recreated: `sourceIdentity` = `{sourceName}` only, `requestedIdentity moveprobe2@rehearsal-new`, Longhorn snapshot behind `latestImage` exists (`readyToUse=true`). New PV; `sha256sum` OK; **starts.log lines 1–4 restored in order, +1 boot (=5)** → the newest series (`pin-pre-rebuild`, NPRE=4) came back, incl. post-'move' writes. No trap-14 wedge. |
| S5 prune protection | delete the child ks (parent suspended) | **PASS.** Claim survived: same uid, no deletionTimestamp, PV `Bound/Retain`; every other inventory object pruned. Resuming the parent recreated the child, which **adopted the same claim** (same uid, back in the inventory); HR fresh install, app Running, data intact. |
| Teardown | T1–T5 | `verify_clean` rc=0 (namespaces, Flux CRs, PVs + Longhorn volumes, VolumeSnapshotContents, silences, remote branch); remote `rehearsal-pin` deleted; silences expired. As predicted (m5), the `prune: disabled` claim survived parent deletion and went with its namespace. |

## What it means for hermes

1. **The fix works exactly as proposed** (Appendix A of the plan): one commit adding the strategic-merge `ssa: IfNotPresent` patch and removing the two pin patches leaves the claim untouched, ks Ready, and — with the S2c control — is precisely what removes the stall.
2. **The DR path is proven** (S4): a recreated claim is created unpinned and populated from the newest series; the `hermes` cleanup can therefore ship on S2 **and** S4, not S2 alone.
3. **Costs to write into the runbook:** (a) the annotation must never be removed while the claim exists (frozen ownership; S2c is one commit away); (b) capacity/label/annotation/class edits in git silently no longer reach the claim — expansion is a manual `kubectl patch` (which moves `f:resources` ownership to `kubectl-patch`); (c) drift is silent (S6) — consider a PR-time `flux build` assertion; (d) `prune: disabled` on the *existing* `ai/hermes` claim needs a one-off `kubectl annotate` (git does not land it), then it works (S5).
4. Before merging the hermes cleanup PR: re-run `hermes_owners | diff - pinfix-state/hermes-owners-before.json` (m10).

## Deviations / defects found while running (all handled, none touched anything outside `rehearsal-*`)

- **`backup_now` waited on `lastManualSync`, which Flux strips mid-run [Rh-7]** — the first `backup_now` timed out although both syncs had succeeded (verified by `check_backup`). The helper now waits for "no sync in flight AND `lastSyncTime > T0`" (`wait_synced`); the 851-test suite still passes. All later backups used it and passed the R-3 rule.
- One block (S6) exited early under `set -e` (`flux diff` piped to `head`) before its revert step; S6's evidence was captured afterwards and the revert re-run. A second block (S5) exited under `set -e` at a `NotFound` `get`; state was verified by hand before continuing.
- `others_ready` reported `media/kometa`, `plex-auto-languages`, `plex-image-cleanup` `Ready=False` after S2: `DependencyNotReady` on `media/plex`, which was mid-Helm-upgrade from an **unrelated merge to `main`**. Not caused by the rehearsal.
- Local worktree/branch `rehearsal-pin` was **kept** (remote deleted); commit chain in `pinfix-state/commit-chain.txt`.
- Residue: kopia series `moveprobe2@rehearsal-new` in the shared local (Garage) and R2 repositories (small; needs a kopia client to remove). A re-run needs a new app name.
