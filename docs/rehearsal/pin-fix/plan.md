# Rehearsal plan: does `ssa: IfNotPresent` retire the permanent `volumeName` pin?

**Status: DESIGN + FIXTURES + GUARDS ONLY. Nothing has been pushed, applied, or run against the cluster.** Cluster access so far: `kubectl get/describe` (read-only) and `flux build` (offline).
Everything under "what happens" is a **hypothesis (UNVERIFIED)** until a scenario has run; the only VERIFIED things are marked as such (source reading, live reads made today, local builds, the guard test suite).

This plan is **not** committed to `rehearsal-pin` (the branch will be pushed as a scratch branch). It lives in the `hermes-to-ai` worktree, untracked.

## Changes since the adversarial review (`plan-review.md`, verdict GO after M1 + M2)

| # | Finding | State |
| --- | --- | --- |
| M1 | `kn` only pinned `-n` | **fixed**: reusable `kn-guard.sh` (verb + kind allow-list, refuses `-n/--namespace/-A/--all-namespaces` and every cluster-scoped/foreign kind); the four bypasses are refuse-tests; guardrails 1–2 reworded |
| M2 | §11 let Appendix A ship on S2 alone | **fixed**: row 1 now requires S4; new rows "S2 pass + S4 inconclusive" and "`s1_equiv` DIFFERS → S1-alt"; Appendix A names the precondition |
| R4-1, R4-2 (5th review), R4-3, R4-4 | jq's lenient parse rewrote `0400`/`+1`/`.5`/`nan`/`infinity` (kubectl reads `0400` as 256, kn sent 400); `KN_CONTROLLER_KINDS=""` lifted the controller-kind write ban; log flags via extra flags; apiVersion/kind compared as a joined string | **fixed**: `apply -f -` validates STRICT JSON with python3's json module (constants and float overflow rejected) before jq canonicalises it; `KN_CONTROLLER_KINDS` is additive (built-ins always included); `--log-file/--log-dir/--v/--vmodule/…` denied; apiVersion and kind compared as separate fields (entries must be `?*/?*`); apply now needs jq **and python3** |
| R3-1 (MAJOR), R3-3…R3-6, Y2/Y3/Y4/Y14 (4th review) | a `kind: Job` document with a top-level `items` list applied a Namespace/ClusterRoleBinding/hostPath PV; extra flags consulted before value flags, `_` spellings, missing global flags; blankable `KN_*` lists; YAML 1.1 vs 1.2; empty/`=` positionals; manifest echo; apiVersion unpinned | **fixed**: `items`/`namespace` keys (any case) refused in every document; `apply -f -` is JSON-only (yq dropped; `ro_run` builds its Job with jq); apiVersion pinned (`batch/v1/Job`); `_kn_L` function-local lists; extra flags last and `=`-only; `--proxy-url/--as-user-extra/--cache-dir/--kuberc` denied; plural + qualified controller kinds; 92 new refuse/allow tests and 30+ new mutants |
| F1–F7, D1 (3rd review) | per-verb short-flag arity (`logs -p` is boolean), `apply -f -` inspected with grep, `=`-positionals skipping the kind check, caller `IFS`/globbing, `KN_EXTRA_BOOL_FLAGS` re-enabling `--namespace`, match-everything selectors, kuberc, Flux/ESO kinds acting cross-namespace | **fixed**: see `kn-guard.sh` header — arity decided per verb; `apply -f -` is parsed with yq→jq, every document checked, kubectl gets the canonical JSON (refused if the parser is missing); `=` positionals refused except annotate/label pairs; `local IFS` + `set -f`; named-deny list checked first; write-verb selectors must be plain equality; `KUBERC=off KUBECTL_KUBERC=false`; `ks/hr/ocirepository/externalsecret` are read/delete only |
| N2 (2nd review) | `kn` accepted combined/attached short flags (`-RA`, `-Rnkube-system`, `-A=true`, `-shttps://…`), `--client-*`/CA flags, and `secrets` | **fixed**: exact flag allow-list, secrets and cluster kinds refused, hard-deny verbs, 184-test suite + 13-mutant mutation check |
| m1 | `pv_reclaim Delete` had no phase check | **fixed**: Delete only on a `Bound` PV |
| m2 | `ro_run` had no trap / cascade | **fixed**: EXIT/INT/TERM trap, `--cascade=foreground`, helper pod must be gone |
| m3 | "no pod references the claim" only printed | **fixed**: `no_consumers` fails the block (S1-A, S1-B, S4-B) |
| m4 | S6 `flux diff` used relative paths and bare `flux` | **fixed**: `(cd "$R" && fx diff …)`; `fx diff` allowed for `ks moveprobe2` only |
| m5 | T2 comment wrong about the claim | **fixed** |
| m6 | S3a→S3d window overlaps `:47` | **fixed**: order S3a → S3d → S3b; `slot_clear 25` look-ahead |
| m7 | `hermes_same` compared hermes' PV phase/reclaim | **fixed**: claim only; "freeze hermes' claim" noted |
| m8 | empty claimRef accepted | **fixed**: refused |
| m9 | env-overridable poll intervals | **documented** (test hooks; bounded; fail closed) |
| m10 | Appendix A lacked an ownership re-check | **fixed**: `hermes_owners` recorded at P0, re-diffed before merge |

## 0. Summary — read this first

**The question.** After the hermes move, `ai/hermes` is pinned by a kind-targeted `volumeName` patch that can never be removed while the claim exists (trap 12; observed: ks `Ready=False`, `spec is immutable`).
On a rebuilt cluster the pin names a PV that does not exist, so the claim is `Pending` forever. Proposed fix (UNTESTED): in **one commit**, annotate the claim `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent`, drop the `volumeName` patch and the RD `sourceNamespace` patch (optionally also `prune: disabled` on the claim).

**Three things this design changes relative to the brief, each because of something read today:**

1. **The brief's S1 shortcut is NOT equivalent to the real move, so S1 is rebuilt as "real-shape".** *(VERIFIED live, read-only.)* The real post-move claim `ai/hermes` has ONE `kustomize-controller (Apply)` entry owning `f:accessModes, f:dataSourceRef, f:resources, f:storageClassName, f:volumeName`, and `kube-controller-manager (Update)` owns **only** `f:annotations`.
   A dynamically provisioned claim (checked on `media/jellyseerr`) is the opposite: `kube-controller-manager (Update)` owns **`f:volumeName`**. If S1 merely *adds* the `volumeName` patch to a provisioned claim, both managers co-own the field. Dropping the patch later then only relinquishes Flux's share; the value stays owned by kube-controller-manager, **no immutable error is produced, and the control cannot reproduce trap 12** — so the experiment could not tell "the annotation fixed it" from "the pin was never a problem".
   Real-shape S1 therefore does what the move does: PV `Retain` → delete the claim (ks suspended) → commit the pin → Flux **creates** the claim pre-bound → re-point the PV. Its result is checked mechanically against the live `ai/hermes` ownership (`s1_equiv`). The shortcut survives only as a labelled fallback, **S1-alt** (§7.1).
2. **S4 deletes the ReplicationDestination as well as the claim.** The populator restores from the RD's `status.latestImage`, which is a snapshot taken when the RD last ran (for moveprobe2: the empty first-deploy series). Recreating only the PVC would restore *that*, not the newest series. A real rebuild recreates the RD too (its `restore-once` runs at creation and reads the newest snapshot); S4 reproduces that.
3. **`ssa: IfNotPresent` and `prune: disabled` interact — from source, not yet observed.** `IfNotPresent` is read from the **desired** object and skips *before* the dry-run; `prune: disabled` is read from the **live** object. On an existing claim the skipped apply never writes either annotation, so `prune: disabled` in git **never reaches hermes' existing claim** — it would need a one-off `kubectl annotate`. S5a/S5 test exactly this.

**Outcome the human needs:** after the run, a table (§11) says, for each hypothesis, PASS / FAIL / SURPRISE, and what to do to `ai/hermes`.

**Deliverables (all on disk):**

| Item | Where | State |
| --- | --- | --- |
| Fixtures (`kubernetes/rehearsal-pin/…`, `kubernetes/rehearsal-pin-bootstrap/…`) | worktree `~/.herdr/worktrees/flux-talos/rehearsal-pin`, branch `rehearsal-pin` (from `main` @ `bc61a0e1`) | committed **locally**, commit `3775138e` (bot identity, trailers); **not pushed** |
| State writer (pure, no cluster) | `~/.herdr/worktrees/flux-talos/pinfix-states.sh` | tested |
| Guards | `~/.herdr/worktrees/flux-talos/pinfix-guards.sh` | `bash -n` + `shellcheck -x` clean |
| Reusable `kn` (verb + kind allow-list) | `~/.herdr/worktrees/flux-talos/kn-guard.sh` | sourced by the guards; the sibling move-workload guards can source it with their own `KN_NAMESPACES` |
| Fake-kubectl test suite | `~/.herdr/worktrees/flux-talos/pinfix-guards-test/{run.sh,bin/}` | **851 tests, 851 pass** under `/bin/bash` 3.2.57 (391 in the guard suite + 460 from the shared `kn` suite it runs); `kn` lives in the self-contained, vendorable `~/.herdr/worktrees/flux-talos/kn-guard.sh` (own suite `kn-guard.test.sh`, mutation check `kn-guard.mutation.sh`: 66 mutants, all killed) |
| This plan | `hermes-to-ai/docs/rehearsal/pin-fix/plan.md` (untracked) | — |

## 1. What the source says (VERIFIED by reading; behaviour is still UNVERIFIED live)

kustomize-controller **v1.9.1** (live image tag confirmed), `fluxcd/pkg/ssa` **v0.76.1** (`go.mod` of that tag):

| Fact | Source | Consequence |
| --- | --- | --- |
| `IfNotPresentSelector = {kustomize.toolkit.fluxcd.io/ssa: IfNotPresent}` | `kustomization_controller.go:864-866` | the value is `IfNotPresent` (case-sensitive) |
| A skip needs `existingObject.GetUID() != ""` **and** the annotation on the **desired** object | `ssa/manager_apply.go` `shouldSkipApply` | on an existing claim the desired manifest alone triggers the skip; the live object need not carry the annotation |
| `shouldSkipApply` runs **before** `dryRunApply` | `manager_apply.go` `Apply`, first branch | **no SSA validation at all** for an existing skipped object: an immutable-field mismatch cannot error (S2 mechanism, S6 risk) |
| A skipped entry is still recorded in the ChangeSet (`SkippedAction`) from the *existing* object | `shouldSkipApply` | the PVC stays in the ks inventory (relevant to S5 "adoption") |
| Prune exclusion `{prune: disabled}` (and `reconcile: disabled`, `ssa: Ignore`) is matched against the **existing (live)** object | `manager_delete.go` `Delete`: `utils.AnyInMetadata(existingObject, opts.Exclusions)`; `deleteObjects` in `kustomization_controller.go:1410-1413` | `prune: disabled` must be **on the live claim** to protect it |
| Because a skipped apply writes nothing | derived | the `ssa` annotation, labels, capacity, `storageClassName`, `dataSourceRef` in git **never reach an existing claim**; `managedFields` ownership is frozen as it was (Flux keeps owning `f:volumeName` on the live object although the manifest no longer has it) |
| Corollary (derived, S2 control reasons) | — | if the annotation is ever **removed** later, the next apply has no `volumeName` while Flux still owns it → SSA tries to unset it → the immutable stall returns. The annotation must stay for the life of the claim |
| `force` is `false` on the live `cluster-apps` and unset (= false) on the fixture child; none of `cluster-apps`' three patches sets it on children | live `cluster-apps` spec, fixtures | an immutable mismatch can only stall, never delete/recreate the claim (`shouldForceApply` needs `force`) |

**Live reads made today (2026-09-24, read-only):**

- `ai/hermes` PVC `managedFields` (reference shape for S1): `kustomize-controller Apply` → spec `f:accessModes,f:dataSourceRef,f:resources,f:storageClassName,f:volumeName`, meta `f:labels`; `kube-controller-manager Update` → meta `f:annotations` only; `Update/status`. Annotations: `pv.kubernetes.io/bind-completed` only. Bound to `pvc-12f54114-…`, PV reclaim is still **`Retain`** (B10 has not happened).
- `media/jellyseerr` (provisioned): `kube-controller-manager Update` owns spec `f:volumeName`. Same object shape as the *baseline* claim in this rehearsal — `s1_equiv` is run at the baseline expecting **DIFFER**, which proves the check discriminates.
- `rehearsal-*` namespaces, Flux CRs, labelled PVs and the remote branch: **none**. `ai` carries `volsync.backube/privileged-movers: "true"` (so `rehearsal-new` is annotated too, mirroring `ai` as it is today).
- The parent Kustomization copy matches the live `cluster-apps` spec (decryption, `force`, all three patches, `prune`, `retryInterval`, `timeout`, `wait`) — diffed, identical.

## 2. Design

### 2.1 Fixture

```
kubernetes/rehearsal-pin/README.md
kubernetes/rehearsal-pin/rehearsal-old/{kustomization,namespace}.yaml     # EMPTY namespace (mirrors develop): only gives `sourceNamespace: rehearsal-old` a real namespace
kubernetes/rehearsal-pin/rehearsal-new/{kustomization,namespace}.yaml     # mirrors ai (privileged-movers annotated, PSA baseline); lists ./moveprobe2/ks.yaml
kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/ks.yaml                 # child Flux ks, sourceRef GitRepository/rehearsal
kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/app/{kustomization,ocirepository,helmrelease}.yaml
kubernetes/rehearsal-pin-bootstrap/{README,gitrepository,rehearsal-apps}.yaml    # the two hand-applied CRs
```

Names are distinct from the first rehearsal on purpose (dirs `rehearsal-pin*`, branch `rehearsal-pin`, app `moveprobe2`, PV label `rehearsal=pin`, state dir `pinfix-state/`, session URL). The namespaces and the two Flux CR names (`rehearsal`, `rehearsal-apps`) are the brief's; `preflight_clean` refuses to start if *any* `rehearsal-*` object of any earlier run exists.
The app is the first rehearsal's fixture unchanged in shape (busybox 1.37, app-template 5.2.1, `Recreate`, `existingClaim`, `volsync-claim` + `volsync-backup`, control-plane `nodeAffinity`): first start writes `marker.txt`, a 1 MiB `blob.bin` and `SHA256SUMS`; **every** start appends `start <pod> <utc>` to `starts.log`. `sha256sum -c` proves the original bytes; the `starts.log` line count proves *continuity* (an empty or older-snapshot volume lacks the later lines).
`VOLSYNC_LOCAL_SCHEDULE "47 * * * *"`, `VOLSYNC_R2_SCHEDULE "45 6 * * *"`, `VOLSYNC_CAPACITY 1Gi`, `VOLSYNC_CACHE_CAPACITY 2Gi`, `Snapshot` copy method, `longhorn-1-replica-local` / `longhorn-1-replica` / `longhorn-snapclass`.

### 2.2 The state machine (the only edits any scenario makes)

`pinfix-states.sh` writes `moveprobe2/app/kustomization.yaml` (+ the `VOLSYNC_CAPACITY` line of `ks.yaml`); the guards wrap it as `pin_state <state>` and check the **committed** result with `pin_gate <state>`.

| state | pin (`volumeName` + RD `sourceNamespace: rehearsal-old`) | `ssa: IfNotPresent` | `prune: disabled` | capacity | probe on the claim | used by |
| --- | --- | --- | --- | --- | --- | --- |
| `base` | – | – | – | 1Gi | – | fixture, baseline |
| `s1` | `<pv>` | – | – | 1Gi | – | S1 (= hermes today) |
| `control` | – | – | – | 1Gi | – | S2c ("the fix WITHOUT the annotation") |
| `fix` | – | **yes** | – | 1Gi | – | S2 (the fix) |
| `fix-cap2` | – | yes | – | 2Gi | – | S3a |
| `fix-meta` | – | yes | – | 2Gi | label + annotation + `storageClassName: longhorn` | S3b |
| `fix-vn` | – (RD) / `volumeName: pvc-00000000-…` (claim) | yes | – | 2Gi | fake `volumeName` | S6 |
| `fixprune` | – | yes | **yes** | 2Gi | – | S5a, S4, S5 |

The annotation patch is a **strategic-merge** patch (`metadata.name: not-used`, `target: {kind: PersistentVolumeClaim}`), not a JSON `add`: it works whether or not `metadata.annotations` exists on the rendered claim. Targets are by **kind** (trap 5), safe because the app has exactly one PVC and one RD.

### 2.3 Why the ordering is what it is

`baseline → S1 → S2c(control) → S2(fix) → S3 (a → d → b) → S6 → S5a → S4 → S5 → teardown`

- **Control first** (S2c) reproduces the stall in the *same* state the fix then starts from. Recovery = re-commit `s1`.
- **S3d (manual expansion to 2Gi) is mandatory, not optional**, and S4's desired capacity is 2Gi: a snapshot taken from a 2Gi volume cannot restore into a 1Gi claim, and restoring a 1Gi snapshot into a 2Gi request is an unverified Longhorn path. Keeping live, git and snapshots all at 2Gi isolates S4 from that question.
- **S5a before S4**, S5 **after** S4: S4 recreates the claim from git (so it carries both annotations *from creation* — the rebuild path); S5a shows the existing-claim path (annotation from git does not land; a manual `kubectl annotate` does and survives).
- **PV reclaim stays `Retain` from S1 until S4-B** (mirrors hermes today: B10 not done), is flipped to `Delete` right before S4 (the rebuild must actually lose the PV), then back to `Retain` for S5 as a safety net, and to `Delete` for teardown.

### 2.4 S1 real-shape: what it covers and what it does not

Covers: the SSA state of the claim (`s1_equiv` against the live `ai/hermes`), the pre-bound create, the RD patch, the same Flux/kustomize-controller v1.9.1, the same Longhorn class.
Does **not** cover: the old-namespace prune / `Released` race (mechanics CONFIRMED in the first rehearsal [Rh-2, Rh-3]; here the claim is deleted by hand while the ks is suspended), a `develop`→`ai` namespace change, HTTPRoute, hermes' 20Gi / 570 MB size and timings, hermes' HelmRelease, Reloader/ExternalSecret `hermes-secret`, kopiur, the real `hermes@ai` series (no `moveprobe2@rehearsal-old` series exists; `sourceNamespace: rehearsal-old` names an empty series, so the RD restore, if it ever re-ran, would return an empty volume — S1/S2 watch that it does not re-run).

## 3. HARD GUARDRAILS (a violation = stop and run teardown)

1. **Never touch** `ai`, `develop`, any hermes object (`hermes*`, PV `pvc-12f54114-9e99-442b-bae4-53a9cb239d69`), `cluster-apps`, `home-kubernetes`, `main`. The guards identify the cluster by **kube-system UID** (`793124f9-…`), `exit 1` on mismatch/API error, and `kn` is a **verb + kind allow-list pinned to `rehearsal-old|rehearsal-new`** (`kn-guard.sh`): **flags are an exact ALLOW-LIST** (pflag accepts combined short flags — `-RA`, `-Rnkube-system`, `-pnkube-system`, `-shttps://…`, `-A=true` — so a deny-list of exact tokens loses): every single-dash token longer than 2 characters is refused except `-ojson/-oyaml/-oname/-owide`, as is every unlisted short or long flag, `--`, a lone `-`, and — by name and in any `--flag=value` form — `-n/--namespace/-A/--all-namespaces/--context/--cluster/--user/--kubeconfig/-s/--server/--as*/--token/--raw/--insecure-skip-tls-verify/--tls-server-name/--certificate-authority/--client-*/--username/--password`; `KUBERNETES_MASTER` set is refused; `apply` only as `apply -f -`, with a **JSON-only** manifest (YAML is refused: its 1.1/1.2 scalar rules differ from kubectl's), parsed by jq, EVERY document checked (`batch/v1/Job` pinned with its apiVersion, no key spelled like `namespace` or `items` — kubectl applies each entry of any top-level `items` — no case-variant of kind/apiVersion) and kubectl sent the canonical `jq -c` form that was checked; no refusal message echoes the manifest; the deny/allow lists are function-local (a caller cannot blank them); extra flags only as `--flag=value`; `_`→`-` normalised; short-flag arity decided per verb; write-verb selectors must be plain equality; kubectl runs with the kuberc disabled; `ks/hr/ocirepository/externalsecret` are read/delete only (they act across namespaces); every verb outside `get describe logs wait scale patch delete apply annotate label`, and every kind outside the app's own (`pod deploy job pvc ks hr ocirepository externalsecret volumesnapshot event` and the two VolSync kinds) — so `pv`, `ns`, `node`, `crd`, `clusterrole`, `clusterissuers`, `*.longhorn.io`, `storageclass`, `volumesnapshotcontent` and **`secret(s)`** are all refused; `exec cp port-forward debug proxy attach auth run create edit replace config plugin` can never be enabled, also inside a comma list or a `kind/name` positional. The four bypasses the review found (`delete pv`, `patch pv`, `--namespace ai delete pvc hermes`, `-n longhorn-system delete volumes.longhorn.io`) are refuse-tests. `hermes_snapshot`/`hermes_owners`/`s1_equiv` read `ai/hermes` with `get` only (a test asserts no other verb is issued).
2. **No cluster mutation from this design phase.** During the run: every mutation is `kn` (allow-listed as above), `fx`, `pv_reclaim`/`pv_repoint`/`pv_delete`, `bootstrap_apply`, or one of the listed literal teardown commands. **No bare `kubectl patch/delete pv`, and `kn` cannot reach a PV or any cluster-scoped object** (PVs are changed only by the three `pv_*` functions, which check the recorded list, the label, the claimRef namespace and — for `Delete` — that the PV is `Bound`).
3. **The only push target is `origin rehearsal-pin:refs/heads/rehearsal-pin`, only via `PUSH`** (no arguments; refuses off-branch; **refuses any HEAD that `pin_gate` did not pass**; needs `PIN_WINDOW=yes` and a recorded, unexpired silence). **Never open a PR.** Nothing in `.github/workflows` triggers on a bare branch push (checked: `pull_request` / `main`-scoped / schedule only).
4. **No secret values**, printed or written. Only key **names** appear (§8).
5. **No `kustomize build | kubectl apply`, no `kubectl apply -k`, no apply of anything containing `${VAR}`.** The only hand-applied objects are the two CRs in `rehearsal-pin-bootstrap/` (`bootstrap_apply` refuses a file containing `${`, a GitRepository not tracking `refs/heads/rehearsal-pin`, or a parent whose path is not `./kubernetes/rehearsal-pin`). Exceptions (stated): `ro_run`/`data_check` helper Jobs via `kn` (no `${}`, uid 0, **read-only** mount and claim, deleted immediately — a Completed pod blocks PVC deletion, trap 3); Alertmanager silences via the API.
6. **`fx` whitelist**: `reconcile source git rehearsal`; `reconcile|suspend|resume` on `ks rehearsal-apps` (flux-system) and `ks|hr moveprobe2` (rehearsal-new). Nothing else (tests: `cluster-apps`, `home-kubernetes`, `ks hermes -n ai`, `--all` are refused).
7. **Commits only via `COMMIT`** (bot identity per command, scoped subject `rehearsal-pin: …`, trailers). Never `git config` in the worktree (it writes the shared `.git/config`); never touch `hermes-to-ai`'s branch.
8. **Do not `flux reconcile` `cluster-apps` or `home-kubernetes`.** The live `Receiver/github-webhook` reacts to a push on **any** branch by reconciling `home-kubernetes` and `cluster-apps` — a no-op re-apply of `main`; a transient `Ready=Unknown` elsewhere is expected (`others_ready` tolerates it for 3 polls).
9. **PV reclaim `Delete` re-arms total loss in ~19 s (trap 2).** `pv_reclaim … Delete` is used only where a scenario says so. The hermes PV is refused by every PV guard even if it were listed and labelled (tested).
10. **Scheduled slots:** nothing that removes/swaps the claim or forces a backup runs inside UTC `:45–:49` (local RS `:47`) or `06:43–06:47` (r2 `06:45`) — `slot_clear` enforces it. A scheduled sync in flight stamps a manual tag itself (trap 8); `backup_now` refuses if `lastSyncStartTime` is set.
11. **Every loop is bounded and every block < 10 min** (tool limit). Longhorn populator wedge (trap 14): time-box **30 min**, record, recover per §7.5-R or move on.
12. **Two-strikes rule:** a scenario whose *predicted* observation is missing is recorded as SURPRISE and the operator stops to think; only the ABORT criteria stop the run. Never "fix" a SURPRISE by touching hermes or `main`.
13. **Everything under `PIN_WINDOW=yes` is a scenario block.** The variable is set inside the block, never exported in a shell profile.

## 4. Blast-radius checks (run after bootstrap, after every push, before teardown)

`inventory_ok` (the parent's inventory is non-empty and only `rehearsal-*` objects + the two Namespaces; **fails closed** on null) · `others_ready` (no non-rehearsal Kustomization `Ready=False`; not-True must persist 3 polls, 20 s apart) · `hermes_same "$(cat "$PIN_DIR/hermes-before.txt")"` (uid|volumeName|phase of the `ai/hermes` **claim** unchanged; the PV's phase/reclaim are deliberately not compared, so hermes' own B10/B11 landing during the ~6 h window is not a false ABORT — **but freeze hermes changes to its claim** for the window) · `ks_report`.
A failing check ⇒ ABORT + teardown. Preflight `preflight_clean` proves nothing of any earlier rehearsal is left.

## 5. Schedule slot check, OpenBao keys, build proof (all VERIFIED today)

**Slots.** Expanded every live `ReplicationSource` schedule (93 sources): hourly minutes in use `0,2,4,5,6,8,10,12,14,15,16,18,20,22,23,24,25,30,32,34,35,36,38,40,42,44,45(×2),46,48,50,52,54,55,58`; **minute 47 hourly is free** (46 and 48 are used — same slot the first rehearsal used without incident); hour 06 fixed minutes `0,0,5,9,10,13,15,20,21,25,29,37,43,53` → **`45 6 * * *` is free**; hour 03 is empty. Kopiur `SnapshotSchedule`s (`H`-hashed): next runs at `:20, :53, :35, :52, :41, :25` (recyclarr-local 06:52) — none at `:47`/`06:45`. **Re-check on the day** (`P0`).

**OpenBao keys (names only; nothing created; no scratch key needed).** `components/volsync-backup/{local,r2}.yaml` render `ExternalSecret moveprobe2-volsync-local|-r2` (`ClusterSecretStore/openbao`, `dataFrom.extract`):

| ExternalSecret | key read | fields templated |
| --- | --- | --- |
| `moveprobe2-volsync-local` | `volsync-local-template` | `VolSync__Local__KopiaRepository`, `__KopiaPassword`, `__AwsAccessKeyId`, `__AwsSecretKey`, `__AwsS3Endpoint` |
| `moveprobe2-volsync-r2` | `volsync-r2-template` | `VolSync__R2__KopiaRepository`, `__KopiaPassword`, `__AwsAccessKeyId`, `__AwsSecretKey`, `__AwsS3Endpoint` |

`cluster-settings` / `cluster-secrets` (SOPS, decrypted by Flux, never printed) are copied into the two scratch namespaces by the fixture, exactly as the first rehearsal did. Consequence: `moveprobe2` writes to the **real** Garage and R2 kopia repositories as `moveprobe2@rehearsal-new` (tiny, distinct identity) and **that residue cannot be deleted without a kopia client** (§9).

**`flux build` proof (local, offline, `KUBECONFIG=/dev/null`; also exercised by the 29 assertions in the `pin_gate` section of the test suite, run against committed states in a scratch clone):**

| State | `volumeName` | `sourceNamespace` | `ssa: IfNotPresent` | `prune: disabled` | namespaces | note |
| --- | --- | --- | --- | --- | --- | --- |
| `base` | 0 | 0 | 0 | 0 | `rehearsal-new` only | ExternalSecret×2, HelmRelease, OCIRepository, PVC, RD, RS×2 |
| **`s1`** | **1** (`volumeName: pvc-…` at build line 117) | **1** (`sourceNamespace: rehearsal-old`, line 278) | **0** | 0 | `rehearsal-new` only | **has the pin, no annotation** |
| **`fix`** | **0** | **0** | **1** (`ssa: IfNotPresent`, line 101) | 0 | `rehearsal-new` only | **annotation, no `volumeName`, no `sourceNamespace`** |
| `fix-cap2` / `fix-meta` | 0 | 0 | 1 | 0 | `rehearsal-new` only | PVC `storage: 2Gi`; `fix-meta` adds label/annotation/`storageClassName: longhorn` |
| `fix-vn` | 1 (the fake name) | 0 | 1 | 0 | `rehearsal-new` only | S6 probe |
| `fixprune` | 0 | 0 | 1 | **1** | `rehearsal-new` only | |

**Parent build** (`flux build ks rehearsal-apps … --path ./kubernetes/rehearsal-pin`): Namespace `rehearsal-new`, `cluster-settings`/`cluster-secrets` in `rehearsal-new`, **child `Kustomization rehearsal-new moveprobe2 ./kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/app rehearsal-new`** (exactly one), Namespace `rehearsal-old` + its `cluster-settings`/`cluster-secrets`, **no child in `rehearsal-old`**.
`yamlfmt -lint` clean on all 12 committed fixture files and on all 8 rendered states; `gitleaks`: no leaks. **Not provable by a build:** SOPS decryption under the scratch parent (first check after bootstrap), and that kustomize-controller's embedded kustomize matches the CLI for the strategic-merge patch (the `Applied` result and a live read of the annotation on a *fresh* claim in S4 close it).

## 6. Session setup (how every command runs)

**Every block starts with `source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh` and runs under `/bin/bash` directly** — never `zsh -c` (a nested zsh re-reads `~/.zshenv` and puts the real `kubectl` ahead of a fake; that once created live Jobs). Pattern:

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh      # exits 1 unless the kube-system UID matches
export PIN_WINDOW=yes                                        # only in mutating scenario blocks
# ... steps ...
EOF
```

`set -euo pipefail` is on; a step that may legitimately fail is written `|| true` / `|| rc=$?`. **Timing:** blocks are sized to finish in well under 10 minutes when things go right; a few worst cases (a bounded wait stacked on a helper-Job timeout) can exceed the 10-minute tool limit. If a block is killed, do **not** re-run it blindly — read `pvc_state` / `ks_report` / `git -C "$R" log -1` first (commits and deletes are not idempotent), or run the block with `run_in_background`. State lives in `~/.herdr/worktrees/flux-talos/pinfix-state/` (PV list, silence ids + expiry epoch, gated HEAD, evidence files). **Human go-ahead is required for `SILENCE_OK=yes`** (the silence step).

| Function | Contract |
| --- | --- |
| `pin_state <state> [pv]` / `pin_gate <state> [pv]` | write / check a state (§2.2). `pin_gate` runs **after `COMMIT`, before `PUSH`**: on `rehearsal-pin`; whole `kubernetes/rehearsal-pin{,-bootstrap}` committed; committed file carries `# STATE: <state> `; build counts per §5; PVC storage == the state's capacity; `s1`: built `volumeName` == the live PV (or the Released PV you pass when the claim was deleted on purpose); all namespaces `rehearsal-new`; parent has **exactly one** child == `rehearsal-new moveprobe2 <path> rehearsal-new`. On PASS records HEAD; **`PUSH` refuses any other HEAD** |
| `GIT`, `COMMIT "rehearsal-pin: …"`, `PUSH`, `push_delete_branch` | bot identity per command; scoped subject required; trailers `Co-Authored-By: Claude Sonnet 5` + `Claude-Session: …session_01AA9xxfsX3xSg8xher3SAKa` |
| `push_and_reconcile` | `PUSH` → `fx reconcile source git rehearsal` → `fx reconcile ks moveprobe2` → `wait_ks_outcome <sha>`; returns **0** (Ready=True at the sha), **2** (Ready=False at the sha = STALL), 1 (timeout) |
| `kn <ns> <verb> <kind> …` | allow-listed verb + kind, namespace fixed to the first argument, which must be `rehearsal-old\|rehearsal-new`; no other namespace/context/file flag is accepted (guardrail 1) |
| `fx …` | whitelisted flux verbs (guardrail 6); read-only `get`, `build`, and `diff ks moveprobe2 -n rehearsal-new …` |
| `app_pv`, `live_pv`, `record_pv`, `adopt_pv`, `rehearsal_pv_ok` | `app_pv` **re-reads** the claim on every call (never a cached name [Rh-B2]); a PV is acted on only if listed in `pins.txt`, labelled `rehearsal=pin`, not hermes', claimRef namespace `rehearsal-*` (or empty); **a read error refuses** |
| `pv_reclaim <pv> Retain\|Delete`, `pv_repoint <pv>`, `pv_delete <pv>` | the only PV mutators. `pv_repoint` re-points a **Released/Available** PV to `rehearsal-new/moveprobe2` (uid/resourceVersion null; never a removal; extra arguments ignored). `pv_delete` deletes the Longhorn volume only after the PV is confirmed gone |
| `pvc_state`, `pvc_uid`, `s1_equiv`, `ks_report` | one-line evidence: uid, volumeName, requested/actual size, class, the `ssa`/`prune`/probe annotations+labels, **who owns which field**; `s1_equiv` compares that ownership with the live `ai/hermes` |
| `backup_now <pin-tag>` | forced backup of **both** RS under the current series: `slot_clear`, no sync in flight, bounded wait, `lastSyncTime > T0`, then the R-3 rule (`Created snapshot` ≥ 1, `Setting policy for moveprobe2@rehearsal-new:/data` ≥ 1, `OPERATION_RESULT: SUCCESS` ≥ 1, `Directory is empty` = 0) |
| `data_check`, `ro_run <pvc> "<cmd>"` | read-only uid-0 Job (+ `DAC_OVERRIDE`), node-pinned to any pod mounting the claim, refuses a claim that is not `Bound`, always prints logs, always deletes the Job — **a `trap` (EXIT/INT/TERM) deletes it with `--cascade=foreground` even if the block is killed**, and on the normal path it waits until the helper pod is really gone and fails if it is not (m2). `data_check` = `sha256sum -c SHA256SUMS`, `starts=<n>`, `cat starts.log` |
| `wait_ks_outcome`, `wait_pv_phase`, `wait_running`, `wait_manual` | **bounded** waits |
| `slot_clear [minutes]` | refuses if now **or the next `<minutes>`** overlap `:45–:49` (local RS `:47`) or, in hour 06, `06:43–06:47` (r2) |
| `inventory_ok`, `others_ready`, `hermes_snapshot`, `hermes_same`, `hermes_owners`, `preflight_clean`, `verify_clean` | §4 / teardown |
| `no_consumers` | **fails** if any pod (Completed/Job pods included) in `rehearsal-new` references the claim; run before deleting the claim (S1-B, S4-B) — a printed list is not a check |
| `am_silence` (`SILENCE_OK=yes`, `AM_HOURS` 1–12), `am_unsilence` | three silences scoped to `rehearsal-*`; ids + expiry epoch recorded; `PUSH`/`fx`/`ro_run`/`backup_now`/`bootstrap_apply` refuse without a live one |
| `APP` | pinned `moveprobe2` (**not** read from the environment; `APP=hermes` or `APP=moveprobe` in the caller's env is overridden — tested) |

**Guard test suite** (`/bin/bash ~/.herdr/worktrees/flux-talos/pinfix-guards-test/run.sh`): a scratch copy of the guards, a scratch **clone** of the worktree whose `origin` is a local bare repo (so `PUSH` is exercised for real without ever touching the real remote), fake `kubectl`/`flux`/`curl`/`date` first on `PATH`, `KUBECONFIG` pointing at a dead file, and `PIN_FAKE=1`, which makes the guards themselves **refuse to load** unless `kubectl`, `flux` and `curl` all resolve to the harness fakes and `KUBECONFIG` is the harness's dead one (tested against a real-looking decoy first on `PATH`, a real `KUBECONFIG` and an unset one). The fake `flux` passes only the offline `build` verb through to the real binary. **851 tests, 851 pass**; they cover the cluster-UID exit, pinning, `kn`, every PV-guard branch (including hermes' PV listed+labelled, API errors, gone), `pv_delete` ordering (Longhorn delete only after the PV is confirmed gone), state rendering (8 states, `yamlfmt` clean), `pin_gate` on real committed states plus stale `targetNamespace`/path/unlisted-ks/wrong-capacity/stripped-annotation/wrong-PV failures, `COMMIT` (bot author, both trailers, scope, off-branch), `PUSH` (argument, window, silence, expired silence, ungated HEAD, off-branch, exact remote ref, a *newer* ungated HEAD), `fx` whitelist, `inventory_ok`/`others_ready`/`hermes_*`/`preflight_clean`, `wait_ks_outcome`, `backup_now` (in-flight, slot, empty-source log, wrong identity, stuck tag), `ro_run`, `bootstrap_apply`, silences (scope, expiry epoch, pid cleanup), `verify_clean`, `s1_equiv` (incl. the dynamically-provisioned shape DIFFERS).
**Test hooks (m9, documented, not removed):** `PIN_POLL_*`, `PIN_POLL`, `PIN_AM_WAIT` and the fakes' `FAKE_*` only shorten sleeps; every wait stays bounded and fails closed (a 0 s poll times out and the helper Job is deleted). The plan never sets them.
**Not covered by the suite (UNVERIFIED):** any real cluster behaviour; the Alertmanager matcher semantics beyond the request body; `am_open`'s real port-forward.

## 7. Scenarios

Numbering follows the brief (S1 … S6). Execution order: **P0–P2 → Baseline → S1 → S2c → S2 → S3 → S6 → S5a → S4 → S5 → Teardown.**
For each scenario: *Hypothesis* (UNVERIFIED), *Commands*, *PASS*, *ABORT*, *Rollback*, *Means for hermes*. "Record" = append the raw output to `pinfix-state/results-<scenario>.txt` (redacted; no secret exists in any output).

### P0 — pre-flight (read-only)

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
preflight_clean
hermes_snapshot | tee "$PIN_DIR/hermes-before.txt"
hermes_owners   | tee "$PIN_DIR/hermes-owners-before.json"     # the reference ownership S1 must reproduce, and what Appendix A re-checks before it merges (m10)
kubectl -n flux-system get deploy kustomize-controller -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' | cut -c1-48     # …:v1.9.1 (the fix's semantics are read from this tag)
kubectl get ns ai -o jsonpath='{.metadata.annotations.volsync\.backube/privileged-movers}{"\n"}'                                    # true
for q in "patch pv" "delete volumes.longhorn.io -n longhorn-system" "create pods/portforward -n observability" "create persistentvolumeclaims -n rehearsal-old"; do
  printf '%-58s ' "can-i $q"; kubectl auth can-i $q; done                                                                           # all yes
kubectl get replicationsource.volsync.backube -A -o json | jq -r '.items[].spec.trigger.schedule' | grep -xE '47 \* \* \* \*|45 6 \* \* \*' || echo "slots :47 and 06:45 free"
kubectl get snapshotschedules.kopiur.home-operations.com -A -o json | jq -r '.items[]|"\(.metadata.name) \(.status.nextSchedule.at[11:16])"'    # none at 47 / 06:45
git -C "$R" log --oneline -1; test -z "$(git -C "$R" status --porcelain)" && echo "worktree clean"                                # 3775138e …
EOF
```

**PASS:** `preflight clean`; image `…v1.9.1`; all `can-i` yes; slots free; worktree clean at `3775138e`. **ABORT:** any leftover, a `no`, an image other than v1.9.1 (the source reading no longer applies — re-read `shouldSkipApply` for the new tag first).

### P1 — silence (needs the human's go-ahead)

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
SILENCE_OK=yes AM_HOURS=10 am_silence
EOF
```

Three anchored silences (`namespace=~rehearsal-.*`; `obj_namespace=~rehearsal-.*`; `name=~rehearsal-apps|rehearsal`), ids in `pinfix-state/silences.txt`, expiry epoch recorded (10 h; the run is ~6–7 h). Alertmanager fully anchors regexes, so none can match `ai`, `develop` or hermes' `hermes-*`. **Rollback:** `am_unsilence`.

### P2 — bootstrap (push the base commit, apply the two CRs)

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
pin_gate base                                   # GATE PASS (base); records HEAD
PUSH                                            # creates origin/rehearsal-pin (GitHub prints a "create a pull request" hint: DO NOT)
bootstrap_apply                                 # GitRepository/rehearsal + Kustomization/rehearsal-apps, nothing else
fx reconcile source git rehearsal -n flux-system
fx reconcile ks rehearsal-apps -n flux-system
sleep 60; inventory_ok; others_ready
fx get ks rehearsal-apps -n flux-system         # Ready ⇒ SOPS decrypted the scratch cluster-secrets
hermes_same "$(cat "$PIN_DIR/hermes-before.txt")"
EOF
```

**PASS:** parent `Ready`, `inventory ok`, `all other ks Ready`, hermes unchanged. **ABORT:** SOPS failure that touches `flux-system` sops config; `inventory_ok`/`others_ready` fail. **Rollback:** §10 teardown.

### Baseline — unpinned deploy in `rehearsal-new`, first backup (= hermes before the move: a populator-created claim)

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
kn rehearsal-new get ks,hr,pod,pvc,replicationsource.volsync.backube,replicationdestination.volsync.backube
wait_running rehearsal-new 100 || echo "NOT RUNNING YET — trap 14 clock started; see Baseline-R"
EOF
```

Then, once Running:

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
PV=$(app_pv); echo "PV=$PV"                                          # recorded + labelled rehearsal=pin
data_check                                                            # sha OK, starts=1
backup_now pin-seed1                                                  # both RS: identity moveprobe2@rehearsal-new  (avoid :45–:49 — slot_clear refuses)
pvc_state | tee "$PIN_DIR/s0-pvc.json"                                # baseline ownership: KCM (Update) owns f:volumeName
s1_equiv || echo "(expected: DIFFER — a provisioned claim is NOT the hermes shape; this proves s1_equiv discriminates)"
kn rehearsal-new get replicationdestination.volsync.backube moveprobe2-dst-local -o json \
  | jq -c '{trigger:.spec.trigger,src:.spec.kopia.sourceIdentity,lastManual:.status.lastManualSync,image:.status.latestImage.name,req:.status.kopia.requestedIdentity,result:.status.latestMoverStatus.result}' | tee "$PIN_DIR/s0-rd.json"
inventory_ok; others_ready
EOF
```

**PASS:** ks Ready; pod Running; `starts=1`; `backup_now` OK for both RS; RD `restore-once`, `requestedIdentity: moveprobe2@rehearsal-new`, no `sourceNamespace`; `s1_equiv` **DIFFERS** (KCM owns `f:volumeName`). **ABORT:** `inventory_ok`/`others_ready` fail; ExternalSecrets not `SecretSynced`; `starts` ≠ 1 (a series exists for `moveprobe2` — kopia residue from an earlier run; the guards pin `moveprobe2`, so a re-run needs a *new* app name).
**Baseline-R (trap 14 — the first rehearsal's first deploy wedged: `snapshot … is not ready to use` / `snapshot.longhorn.io … not found`, ~1 h):** no data exists yet, so the recovery is a full reset, bounded to **2 attempts / 30 min each**:

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
kn rehearsal-new get events --sort-by=.lastTimestamp | tail -15                                    # confirm the wedge signature first
fx suspend hr moveprobe2 -n rehearsal-new; kn rehearsal-new scale deploy/moveprobe2 --replicas=0 || true
kn rehearsal-new delete pvc moveprobe2 --wait=false
kn rehearsal-new delete replicationdestination.volsync.backube moveprobe2-dst-local --wait=false      # PV reclaim is Delete; nothing to lose
for i in $(seq 1 40); do kn rehearsal-new get pvc moveprobe2 >/dev/null 2>&1 || { echo "claim gone"; break; }; sleep 10; done
fx reconcile ks moveprobe2 -n rehearsal-new; fx resume hr moveprobe2 -n rehearsal-new
EOF
```

If the Longhorn snapshot behind `latestImage` is missing (`kubectl -n longhorn-system get snapshots.longhorn.io snapshot-<uid>`), the image is void (trap 14a). Two failed attempts ⇒ record and **abort the rehearsal** (the environment, not the fix, is the blocker).

### S1 — reach the post-move state, REAL-SHAPE (the brief's shortcut is S1-alt, §7.1)

*Hypothesis:* creating the claim pre-bound through Flux yields exactly the `ai/hermes` ownership (`s1_equiv` EQUAL); SSA accepts it; the RD `sourceNamespace` add does not re-trigger a restore.
*Why this and not the shortcut:* see §0.1. *What it does not cover:* §2.4.

**S1-A — quiesce, final backup, retain** (not inside a slot):

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
slot_clear
PV=$(app_pv); echo "$PV" | tee "$PIN_DIR/pv-s1.txt"                    # the PV to keep; later S1 blocks re-verify it with rehearsal_pv_ok and against the live claim
fx suspend ks moveprobe2 -n rehearsal-new                              # the ks must not recreate the claim while it is deleted on purpose
fx suspend hr moveprobe2 -n rehearsal-new
kn rehearsal-new scale deploy/moveprobe2 --replicas=0
kn rehearsal-new wait --for=delete pod -l app.kubernetes.io/name=moveprobe2 --timeout=180s
no_consumers                                                           # FAILS the block if any pod, Completed helper Jobs included, references the claim (trap 3)
backup_now pin-pre-s1                                                  # fresh backup, pod down
pv_reclaim "$PV" Retain                                                # prints Retain — do not continue otherwise
EOF
```

**S1-B — delete the claim, commit the pin, push (the ks stays suspended):**

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
slot_clear
PV=$(cat "$PIN_DIR/pv-s1.txt"); rehearsal_pv_ok "$PV"; [ "$(live_pv)" = "$PV" ] || { echo "live claim does not name the saved PV — ABORT"; exit 1; }
[ "$(kubectl get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')" = Retain ] || { echo "PV is not Retain — ABORT"; exit 1; }
no_consumers                                                           # a Completed helper pod would hold pvc-protection and stall the delete
kn rehearsal-new delete pvc moveprobe2 --wait=true --timeout=120s
wait_pv_phase "$PV" Released 100
pin_state s1 "$PV"
GIT add -A kubernetes/rehearsal-pin
COMMIT "rehearsal-pin: pin moveprobe2 to its retained PV (S1, hermes-shaped)"
pin_gate s1 "$PV"                                                      # volumeName 1, sourceNamespace 1, annotation 0, built volumeName == $PV
PUSH
fx reconcile source git rehearsal -n flux-system
EOF
```

**S1-C — resume the ks, watch the pre-bound create, re-point:**

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
PV=$(cat "$PIN_DIR/pv-s1.txt"); rehearsal_pv_ok "$PV"
SINCE=$(date -u +%FT%TZ)
fx resume ks moveprobe2 -n rehearsal-new
for i in $(seq 1 30); do kn rehearsal-new get pvc moveprobe2 >/dev/null 2>&1 && break; sleep 5; done
wait_ks_outcome "$(git -C "$R" rev-parse HEAD)" 40 || true; ks_report
kn rehearsal-new get pvc moveprobe2 -o wide                            # Pending, volumeName=$PV, event FailedBinding "volume … already bound to a different claim" (expected [Rh-2])
pvc_state | tee "$PIN_DIR/s1-pvc-pending.json"
kubectl get pvc -A -o json | jq -r '.items[]|select(.status.phase=="Pending")|"\(.metadata.namespace)/\(.metadata.name) sc=\(.spec.storageClassName)"'   # only rehearsal-new/moveprobe2
pv_repoint "$PV"
for i in $(seq 1 40); do [ "$(kn rehearsal-new get pvc moveprobe2 -o jsonpath='{.status.phase}')" = Bound ] && break; sleep 3; done
kn rehearsal-new get pvc moveprobe2 -o wide                            # Bound to $PV in ~10 s [Rh-3]
kn rehearsal-new get events --field-selector involvedObject.name=moveprobe2 -o json \
  | jq --arg since "$SINCE" '[.items[]|select(.reason|startswith("VolSyncPopulator"))|select((.lastTimestamp // .eventTime // "") >= $since)]|length'      # 0 — no populator on a pre-bound claim
EOF
```

**S1-D — verify by content, then start the pod:**

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
PV=$(app_pv); [ "$PV" = "$(cat "$PIN_DIR/pv-s1.txt")" ] || { echo "PV CHANGED — ABORT"; exit 1; }
data_check                                                             # pod at 0: sha OK, starts=1 (identical to before)
pvc_state | tee "$PIN_DIR/s1-pvc.json"
s1_equiv                                                               # THE equivalence check: owners EQUAL to live ai/hermes
kn rehearsal-new get replicationdestination.volsync.backube moveprobe2-dst-local -o json \
  | jq -c '{src:.spec.kopia.sourceIdentity,lastManual:.status.lastManualSync,image:.status.latestImage.name,req:.status.kopia.requestedIdentity}'    # spec has sourceNamespace rehearsal-old; lastManual/image UNCHANGED vs s0-rd.json (no restore re-ran)
fx resume hr moveprobe2 -n rehearsal-new
kn rehearsal-new scale deploy/moveprobe2 --replicas=1                  # a resumed HR does not re-scale by itself [Rh-6]
wait_running rehearsal-new 60
data_check                                                             # starts=2
hermes_same "$(cat "$PIN_DIR/hermes-before.txt")"; inventory_ok; others_ready
EOF
```

**PASS:** claim created pre-bound; `Bound` after `pv_repoint`; **`s1_equiv` = EQUAL**; `starts` 1 → 2 with `sha256sum` OK; RD `lastManualSync`/`latestImage` unchanged (no re-restore); ks Ready; `ai/hermes` unchanged. **ABORT:** the claim binds to a *different* PV or a new volume is provisioned (`live_pv` ≠ saved); the PV or its Longhorn volume vanishes; `s1_equiv` DIFFERS (record both shapes — the S2 conclusions then apply only as in S1-alt); a competing Pending claim appears.
**Rollback:** the PV is `Retain` throughout. If the claim did not bind: `pv_repoint "$PV"` again; if a wrong claim was created, delete it (its PV is *not* the saved one), then repeat S1-C. Worst case: teardown (the data is a fixture).
**Means for hermes:** proves the S1 state used by S2/S6 has the same SSA ownership as the live `ai/hermes`, so the S2 result transfers to it.

#### 7.1 S1-alt (the brief's shortcut) — only if real-shape S1 aborts

`pin_state s1` on the *live* claim (no deletion), commit, gate, `push_and_reconcile`. Both `kustomize-controller (Apply)` and `kube-controller-manager (Update)` then own `f:volumeName`; `s1_equiv` DIFFERS. Consequence, stated up front: **S2c may not stall** (Flux relinquishes its share; the value stays owned by KCM), so S2 could only show "the annotation is harmless", not "the annotation is what removes the stall"; S3, S6, S4, S5 remain valid. Record which of the two happened.

### S2c — the CONTROL: same commit WITHOUT the annotation (reproduce the stall)

*Hypothesis:* dropping the pin and the RD patch with no annotation stalls the whole ks with `spec is immutable`, the claim is untouched, and nothing else in the ks is applied.

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
slot_clear
UID0=$(pvc_uid); echo "$UID0" > "$PIN_DIR/uid-s2.txt"
pin_state control
GIT add -A kubernetes/rehearsal-pin
COMMIT "rehearsal-pin: CONTROL - drop the pin and the RD patch, no IfNotPresent (expect the immutable stall)"
pin_gate control                                                       # volumeName 0, sourceNamespace 0, annotation 0
rc=0; push_and_reconcile || rc=$?; echo "rc=$rc   (2 = stalled as predicted; 0 = NO stall — SURPRISE)"
ks_report
kn rehearsal-new get ks moveprobe2 -o json | jq -r '.status.conditions[]|select(.type=="Ready")|.message' | head -c 700
[ "$(pvc_uid)" = "$UID0" ] && echo "claim uid unchanged"
pvc_state
kn rehearsal-new get replicationdestination.volsync.backube moveprobe2-dst-local -o jsonpath='{.spec.kopia.sourceIdentity.sourceNamespace}{"\n"}'     # still rehearsal-old: the stalled ks applied NOTHING
EOF
```

**PASS (stall reproduced):** rc=2, message contains `PersistentVolumeClaim/rehearsal-new/moveprobe2 dry-run failed (Invalid): … spec is immutable after creation except resources.requests and volumeAttributesClassName for bound claims` with the diff `-"VolumeName": "pvc-…"` / `+"VolumeName": ""` (as in the first rehearsal's 4c); uid unchanged; RD still names `rehearsal-old`.
**SURPRISE:** rc=0. Record `pvc_state` and `s1_equiv`. Either the pin *is* removable under real-shape ownership (then trap 12 needs re-reading against this Flux) or S1 did not reach the hermes shape. Do not continue to S2 as "the fix" — stop and think.
**ABORT:** the claim uid changes / `deletionTimestamp` set / the PV or Longhorn volume vanishes (would require `force`; there is none).
**Rollback (recover):**

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
pin_state s1                                                           # live claim ⇒ pins the live PV (re-read)
GIT add -A kubernetes/rehearsal-pin
COMMIT "rehearsal-pin: recover - restore the pin (S1 state)"
pin_gate s1
rc=0; push_and_reconcile || rc=$?; echo "rc=$rc (want 0)"; ks_report
EOF
```

**Means for hermes:** this is exactly what removing the pin from `ai/hermes` today would do. A clean stall here is the *contrast* that makes S2 meaningful.

### S2 — THE FIX: one commit

*Hypothesis:* `ssa: IfNotPresent` on the desired claim + no `volumeName` + no RD `sourceNamespace` ⇒ ks `Ready=True`, no immutable error, live claim uid/volumeName unchanged, the RD patch is dropped **and applied** (a mutable CR), the RD does not re-run, and the annotation is **not** on the live claim (skipped apply writes nothing).

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
slot_clear
UID0=$(pvc_uid); PV=$(app_pv)
pvc_state | tee "$PIN_DIR/s2-before.json"
pin_state fix
GIT add -A kubernetes/rehearsal-pin
COMMIT "rehearsal-pin: FIX - ssa IfNotPresent on the claim; drop the volumeName and RD sourceNamespace patches (one commit)"
pin_gate fix                                                           # annotation 1, volumeName 0, sourceNamespace 0
rc=0; push_and_reconcile || rc=$?; echo "rc=$rc   (want 0)"
ks_report; ks_report | grep -c -i immutable || true                    # want: 0 matches
[ "$(pvc_uid)" = "$UID0" ] && [ "$(live_pv)" = "$PV" ] && echo "claim uid + volumeName UNCHANGED"
pvc_state | tee "$PIN_DIR/s2-after.json"
diff <(jq -S . "$PIN_DIR/s2-before.json") <(jq -S . "$PIN_DIR/s2-after.json") && echo "live claim state identical before/after (ownership included)"
kn rehearsal-new get pvc moveprobe2 -o jsonpath='{.metadata.annotations}{"\n"}'                       # is the ssa annotation on the LIVE object?  predicted: NO
kn rehearsal-new get replicationdestination.volsync.backube moveprobe2-dst-local -o json \
  | jq -c '{src:.spec.kopia.sourceIdentity,lastManual:.status.lastManualSync,image:.status.latestImage.name}'     # sourceNamespace gone; lastManual/image UNCHANGED vs s0-rd.json
for i in 1 2; do fx reconcile ks moveprobe2 -n rehearsal-new || true; done; ks_report                 # stable across forced reconciles
data_check                                                             # untouched
hermes_same "$(cat "$PIN_DIR/hermes-before.txt")"; inventory_ok; others_ready
EOF
```

**PASS:** rc=0, no `immutable` text; uid and `volumeName` unchanged; the diff is empty **or** contains only benign differences you can name (record it); RD `sourceNamespace` gone (proves the rest of the ks *was* applied) and the RD did **not** re-run (`lastManualSync`/`latestImage` unchanged); stable across two forced reconciles.
**Record either way (a finding, not a failure):** is the `ssa` annotation on the live claim (predicted absent) and who owns `f:volumeName` (predicted: still `kustomize-controller (Apply)` — frozen).
**FAIL:** any `immutable` message (⇒ `IfNotPresent` does not skip pre-dry-run on this build, or the strategic-merge patch did not render — compare `flux build` with the live desired via `kubectl -n flux-system logs deploy/kustomize-controller --since=5m`, read-only); uid changed.
**ABORT:** claim `Terminating`/uid changed; PV/Longhorn volume vanishes. **Rollback:** re-commit `s1` (as in S2c recovery) — the claim was never touched.
**Means for hermes:** *this is the answer to the brief.* If it passes, the hermes cleanup PR is one commit (Appendix A). If the annotation is absent from the live claim (predicted), note that removing it from git later re-arms the stall (the frozen ownership) — the annotation is permanent.

### S3 — what it costs: what is silently ignored

*Hypothesis:* after the fix, **nothing in the claim's desired spec/metadata ever reaches the live claim**, while every other object in the ks is still applied and the ks stays `Ready`.

**S3a — capacity** (order inside S3: **S3a → S3d → S3b**):

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
slot_clear 25                                                          # look-ahead: S3a and S3d must both finish before :45
pin_state fix-cap2                                                     # VOLSYNC_CAPACITY 1Gi -> 2Gi in ks.yaml
GIT add -A kubernetes/rehearsal-pin
COMMIT "rehearsal-pin: S3a - VOLSYNC_CAPACITY 1Gi -> 2Gi"
pin_gate fix-cap2
rc=0; push_and_reconcile || rc=$?; echo "rc=$rc (want 0)"
kn rehearsal-new get pvc moveprobe2 -o jsonpath='req={.spec.resources.requests.storage} actual={.status.capacity.storage}{"\n"}'      # predicted: req=1Gi actual=1Gi — NOT expanded
kn rehearsal-new get replicationsource.volsync.backube moveprobe2-local -o jsonpath='{.spec.kopia.capacity}{"\n"}'                  # 2Gi: the rest of the ks IS applied
kn rehearsal-new get replicationdestination.volsync.backube moveprobe2-dst-local -o jsonpath='{.spec.kopia.capacity}{"\n"}'        # 2Gi
pvc_state
EOF
```

**S3d — manual expansion (MANDATORY; makes live == git == 2Gi before S4). Runs IMMEDIATELY after S3a (m6): between S3a and S3d the RS/RD ask for 2Gi over a 1Gi claim, and a scheduled `:47` sync in that window would clone a 2Gi volume from a 1Gi snapshot (untested Longhorn path). S3a's `slot_clear 25` guarantees the pair finishes before `:45`:**

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
kn rehearsal-new patch pvc moveprobe2 -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
for i in $(seq 1 40); do [ "$(kn rehearsal-new get pvc moveprobe2 -o jsonpath='{.status.capacity.storage}')" = 2Gi ] && break; sleep 5; done   # Longhorn online expansion ~28 s, no restart [Rh-X]
kn rehearsal-new get pvc moveprobe2 -o jsonpath='req={.spec.resources.requests.storage} actual={.status.capacity.storage}{"\n"}'
pvc_state                                                              # who owns f:resources now? record (kubectl-patch Update vs Flux Apply)
fx reconcile ks moveprobe2 -n rehearsal-new || true; pvc_state         # Flux does not revert it (skipped)
wait_running rehearsal-new 12; data_check                              # pod not restarted; data intact
EOF
```

**S3b — label, annotation, storageClassName (an immutable field) in one commit** (all are skipped identically; each has its own live field, so attribution is unambiguous):

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
slot_clear
pin_state fix-meta
GIT add -A kubernetes/rehearsal-pin
COMMIT "rehearsal-pin: S3b - probe label, annotation and storageClassName on the claim"
pin_gate fix-meta
rc=0; push_and_reconcile || rc=$?; echo "rc=$rc (want 0)"
pvc_state                                                              # probeLbl null, probeAnn null, sc still longhorn-1-replica-local, ssa null (annotation not on the live object)
kn rehearsal-new get events --sort-by=.lastTimestamp | tail -8         # nothing about the claim
kn rehearsal-new get pvc moveprobe2 --show-managed-fields -o json | jq -c '[.metadata.managedFields[]|{m:.manager,op:.operation,spec:((.fieldsV1["f:spec"]//{})|keys)}]'   # ownership unchanged
EOF
```

Revert the probe (commit `fix-cap2` again, gate, `push_and_reconcile`). (Git is already at 2Gi and the live claim is 2Gi by now, so S3b touches neither.)

**PASS:** S3a/S3b: ks `Ready`, rc=0, the claim's `req`, `sc`, labels and annotations **unchanged**, RD/RS capacity **applied** (2Gi); S3d: expansion completes without a restart and Flux does not revert it. **Record the exact list** of what was silently ignored (capacity, label, annotation, `storageClassName`) and the `managedFields` ownership after the manual patch.
**SURPRISE:** the claim *is* updated by S3a/S3b (⇒ the skip is not what the source says — re-run S2 reasoning). **ABORT:** claim uid changes; ks `Ready=False`. **Rollback:** commit `fix` (1Gi) — but note the live claim would already be 2Gi.
**Means for hermes:** expansion (`VOLSYNC_CAPACITY`) becomes a **manual** `kubectl patch pvc` **plus** the git value (hermes' RD/RS capacity is applied from git and must match). Any future claim edit (class, mode, labels) is silent. Add this to the runbook next to the annotation.

### S6 — silent drift: a desired immutable mismatch stays silent

*Hypothesis:* a desired `volumeName` that differs from the bound one raises **no** error under `IfNotPresent` (no dry-run happens); the ks is `Ready` and reports nothing.

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
slot_clear
UID0=$(pvc_uid); PV=$(app_pv)
pin_state fix-vn                                                       # desired claim volumeName: pvc-00000000-0000-4000-8000-000000000000
GIT add -A kubernetes/rehearsal-pin
COMMIT "rehearsal-pin: S6 - desired volumeName differs from the bound one"
pin_gate fix-vn                                                        # volumeName 1 (the fake), annotation 1
rc=0; push_and_reconcile || rc=$?; echo "rc=$rc   (0 = silent, as predicted; 2 = an immutable error surfaced)"
ks_report
kn rehearsal-new get events --sort-by=.lastTimestamp | tail -8
kubectl -n flux-system logs deploy/kustomize-controller --since=5m | grep -i moveprobe2 | tail -8     # read-only: what does the controller log for a skipped entry?
[ "$(pvc_uid)" = "$UID0" ] && [ "$(live_pv)" = "$PV" ] && echo "claim untouched"
kn rehearsal-new get ks moveprobe2 -o json | jq -c '.status.inventory.entries[]|select(.id|test("PersistentVolumeClaim"))'   # still in the inventory
# optional read-only probe: does `flux diff` see it? (UNVERIFIED; it is a server-side dry-run, so it may error instead)
(cd "$R" && fx diff ks moveprobe2 -n rehearsal-new --path ./kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/app --kustomization-file ./kubernetes/rehearsal-pin/rehearsal-new/moveprobe2/ks.yaml) 2>&1 | head -20 || true      # cd $R: the paths are repo-relative
EOF
```

Revert: commit `fix-cap2`, gate, `push_and_reconcile`.
**PASS:** rc=0, ks `Ready=True`, no warning event, claim untouched — i.e. the drift is **silent**. **FAIL/SURPRISE:** rc=2 with an immutable error (the skip does not precede validation on this build). **ABORT:** uid changes. **Rollback:** the revert commit.
**Means for hermes:** after the fix, a wrong `volumeName`/class/mode in git can sit in the repo indefinitely with no signal; on a rebuild it becomes the claim. Mitigation options to weigh: a PR-time `flux build` assertion on the hermes claim (as the move's B5 gate did), or a periodic `kustomize build | kubectl diff` job (neither tested here).

### S5a — `prune: disabled` on an EXISTING claim (does the annotation from git land?)

*Hypothesis (from source):* it does **not** (the apply is skipped), so protection needs a manual annotate; a manual annotate survives Flux.

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
slot_clear
pin_state fixprune
GIT add -A kubernetes/rehearsal-pin
COMMIT "rehearsal-pin: S5a - add prune: disabled to the claim"
pin_gate fixprune                                                      # annotation 1, prune 1
rc=0; push_and_reconcile || rc=$?; echo "rc=$rc (want 0)"
pvc_state                                                              # prune:null ⇒ the annotation did NOT land on the existing claim
kn rehearsal-new annotate pvc moveprobe2 kustomize.toolkit.fluxcd.io/prune=disabled                # the one-off manual step hermes would need
for i in 1 2; do fx reconcile ks moveprobe2 -n rehearsal-new || true; done; pvc_state                # prune:"disabled" survives Flux (never applied)
EOF
```

**PASS (predicted):** `prune` null after the git commit; present after the manual annotate and **still present** after two reconciles. **SURPRISE:** the annotation lands from git (⇒ the skip does not block metadata; revisit S3b). **ABORT:** claim uid changes.
**Means for hermes:** if `prune: disabled` is wanted on `ai/hermes`, it is a one-off `kubectl annotate` — **not** a git change — or it only takes effect after a recreate. Document it as a manual step next to the PV reclaim.

### S4 — REBUILD SIMULATION: delete the claim, Flux recreates it unpinned from git

*Hypothesis:* the claim is recreated **unpinned** with **both annotations on the live object** (created from the desired manifest); the recreated RD's `restore-once` reads the **newest** series (`moveprobe2@rehearsal-new`, identity checked); the populated volume contains the post-'move' writes.

**S4-A — post-'move' writes and a fresh backup under the CURRENT series** (the `check_backup` rule; never inside a slot):

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
slot_clear
for i in 1 2; do kn rehearsal-new delete pod -l app.kubernetes.io/name=moveprobe2 --wait=true; wait_running rehearsal-new 60; done     # two more start lines
data_check | tee "$PIN_DIR/s4-before.txt"
NPRE=$(grep -o 'starts=[0-9]*' "$PIN_DIR/s4-before.txt" | head -1 | cut -d= -f2); echo "NPRE=$NPRE" | tee "$PIN_DIR/npre.txt"   # expected 4 (seed 1, S1 2, +2)
backup_now pin-pre-rebuild                                             # both RS: Created snapshot ≥1, Setting policy moveprobe2@rehearsal-new ≥1, SUCCESS ≥1, "Directory is empty" 0
EOF
```

Table to fill (proves "newest, not an old series"): backup `pin-seed1` → starts=1; `pin-pre-s1` → 1; `pin-pre-rebuild` → **NPRE (the maximum)**. Every restore must show NPRE (+1 after boot).

**S4-B — destroy (quiesce, `Delete`, claim + RD):**

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
slot_clear
PV=$(app_pv); echo "$PV" | tee "$PIN_DIR/pv-s4-old.txt"
fx suspend ks moveprobe2 -n rehearsal-new; fx suspend hr moveprobe2 -n rehearsal-new
kn rehearsal-new scale deploy/moveprobe2 --replicas=0
kn rehearsal-new wait --for=delete pod -l app.kubernetes.io/name=moveprobe2 --timeout=120s
no_consumers                                                           # FAILS the block if any pod, Completed helper Jobs included, references the claim (trap 3)
pv_reclaim "$PV" Delete                                                # prints Delete: the rebuild must actually lose the PV (re-arms trap 2, ~19 s)
kn rehearsal-new delete pvc moveprobe2 --wait=true --timeout=120s
kn rehearsal-new delete replicationdestination.volsync.backube moveprobe2-dst-local --wait=true --timeout=120s     # its dest PVC/snapshots are ownerRef'd and go with it
for i in $(seq 1 30); do [ -z "$(kubectl get pv "$PV" --ignore-not-found -o name)" ] && { echo "PV gone"; break; }; sleep 5; done
pv_delete "$PV"                                                        # 'gone' ⇒ only removes a leftover Longhorn volume, after the PV is confirmed absent
kubectl -n longhorn-system get volumes.longhorn.io "$PV" --ignore-not-found                         # nothing
EOF
```

**S4-C — Flux recreates (resume the ks), populate, start the app:**

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
fx resume ks moveprobe2 -n rehearsal-new
for i in $(seq 1 24); do kn rehearsal-new get pvc moveprobe2 >/dev/null 2>&1 && break; sleep 5; done
ks_report; pvc_state | tee "$PIN_DIR/s4-pvc-new.json"                  # NEW uid; spec.volumeName empty; ssa AND prune annotations present ON THE LIVE OBJECT; owners: Apply owns dataSourceRef/resources/storageClassName
kn rehearsal-new get replicationdestination.volsync.backube moveprobe2-dst-local -o json | jq -c '{src:.spec.kopia.sourceIdentity,manual:.spec.trigger.manual}'     # {"sourceName":"moveprobe2"}: NO sourceNamespace
for i in $(seq 1 40); do [ "$(kn rehearsal-new get replicationdestination.volsync.backube moveprobe2-dst-local -o jsonpath='{.status.latestMoverStatus.result}')" = Successful ] && break; sleep 10; done
RD=$(kn rehearsal-new get replicationdestination.volsync.backube moveprobe2-dst-local -o json)
jq -c '{req:.status.kopia.requestedIdentity,image:.status.latestImage.name,result:.status.latestMoverStatus.result}' <<<"$RD"      # requestedIdentity moveprobe2@rehearsal-new
VS=$(jq -r '.status.latestImage.name' <<<"$RD"); VSC=$(kn rehearsal-new get volumesnapshot "$VS" -o jsonpath='{.status.boundVolumeSnapshotContentName}')
kubectl get volumesnapshotcontent "$VSC" -o jsonpath='{.status.snapshotHandle}{"\n"}'                     # snap://<volume>/snapshot-<uid>
# TRAP 14a: the Longhorn snapshot BEHIND the image must exist and be readyToUse before the restore means anything
H=$(kubectl get volumesnapshotcontent "$VSC" -o jsonpath='{.status.snapshotHandle}'); SNAP=${H##*/}
kubectl -n longhorn-system get snapshots.longhorn.io "$SNAP" -o jsonpath='{.metadata.name} readyToUse={.status.readyToUse}{"\n"}'      # NotFound => the restore result is void (recover per 7.5-R)
EOF
```

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
fx resume hr moveprobe2 -n rehearsal-new                               # WaitForFirstConsumer: the pod is the consumer that lets the populator bind
kn rehearsal-new scale deploy/moveprobe2 --replicas=1
wait_running rehearsal-new 90 || echo "NOT RUNNING — trap 14 30-min clock; 7.5-R"
PV2=$(app_pv); echo "new PV=$PV2 (recorded)"; [ "$PV2" != "$(cat "$PIN_DIR/pv-s4-old.txt")" ] && echo "a NEW volume, as expected"
data_check | tee "$PIN_DIR/s4-after.txt"                               # sha OK; starts = NPRE + 1; every line of s4-before.txt present
NPRE=$(cut -d= -f2 "$PIN_DIR/npre.txt"); grep -o 'starts=[0-9]*' "$PIN_DIR/s4-after.txt" | head -1; echo "want starts=$((NPRE+1))"
diff <(grep '^start ' "$PIN_DIR/s4-before.txt") <(grep '^start ' "$PIN_DIR/s4-after.txt" | head -"$NPRE") && echo "every pre-rebuild start line restored, in order"
hermes_same "$(cat "$PIN_DIR/hermes-before.txt")"; inventory_ok; others_ready
EOF
```

**PASS:** new claim uid; desired manifest has **no** `volumeName` (gate proof) and the live claim's `volumeName` is set only by binding; **both annotations present on the live claim**; RD `requestedIdentity: moveprobe2@rehearsal-new` (not an older/other series); Longhorn snapshot behind `latestImage` exists; volume populated; `sha256sum` OK; `starts == NPRE+1` and the pre-rebuild lines restored in order (**the post-'move' writes are back — the newest series**); new PV recorded; hermes unchanged.
**7.5-R (trap 14, time-box 30 min per attempt, max 2):** if the prime PVC / clone wedges: check the Longhorn snapshot behind the image; `fx suspend ks`+`hr`; retrigger the RD with a **new** `spec.trigger.manual` and wait until `spec.trigger.manual == status.lastManualSync` (Flux reverts a hand-patched `manual` — the ks must be suspended); delete the `vs-prime-*` PVC; if the *app claim's own clone* failed (`cloneStatus.state: failed`) delete the claim (PV `Delete` removes the wedged volume) and let Flux recreate it. Runbook §3A step 5 is the reference. Record every step and the elapsed time.
**ABORT:** the restore returns data from a *wrong* series (`requestedIdentity` ≠ `moveprobe2@rehearsal-new`) or an **empty** volume (trap 1/S-b — `starts` < NPRE); the PV of an *unrelated* claim is touched; two failed recoveries.
**Rollback:** none needed beyond teardown (scratch data; the kopia series survives).
**Means for hermes:** proves the DR shape after the fix: a rebuilt cluster creates `ai/hermes` **unpinned** from git and populates it from the newest `hermes@ai` series, instead of hanging `Pending`. It also shows the annotations exist on a *created* claim (so `prune: disabled` in git works for a rebuilt one, unlike the existing one — S5a).

### S5 — PRUNE PROTECTION (optional hardening): delete the child Kustomization

*Hypothesis:* with `prune: disabled` **on the live claim** (S4 created it from git), deleting the child ks removes the rest of its inventory but not the claim; recreating the ks adopts the same claim (uid unchanged).

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
slot_clear
PV=$(app_pv); UID1=$(pvc_uid); echo "$UID1" > "$PIN_DIR/uid-s5.txt"
[ "$(kn rehearsal-new get pvc moveprobe2 -o jsonpath='{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}')" = disabled ] || { echo "no prune:disabled on the LIVE claim — ABORT S5"; exit 1; }
pv_reclaim "$PV" Retain                                                # safety net: if prune protection fails the volume survives
fx suspend ks rehearsal-apps -n flux-system                            # so the parent cannot recreate the child while we look. The CHILD is NOT suspended (a suspended child would orphan everything, trap 6)
kn rehearsal-new delete ks moveprobe2 --wait=true --timeout=300s
kn rehearsal-new get ks moveprobe2 2>&1 | tail -1                      # NotFound
kn rehearsal-new get pvc moveprobe2 -o json | jq -c '{uid:.metadata.uid,del:.metadata.deletionTimestamp,phase:.status.phase}'      # SAME uid, del null, Bound
kubectl get pv "$PV" -o jsonpath='{.status.phase}/{.spec.persistentVolumeReclaimPolicy}{"\n"}'                                     # Bound/Retain
kn rehearsal-new get hr,ocirepository,externalsecret,replicationsource.volsync.backube,replicationdestination.volsync.backube,deploy -o name 2>&1 | tail -3      # pruned: what survived is ONLY the claim
EOF
```

```bash
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
UID1=$(cat "$PIN_DIR/uid-s5.txt"); PV=$(app_pv)
fx resume ks rehearsal-apps -n flux-system
fx reconcile ks rehearsal-apps -n flux-system
for i in $(seq 1 24); do [ "$(kn rehearsal-new get ks moveprobe2 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break; sleep 10; done
ks_report
[ "$(pvc_uid)" = "$UID1" ] && echo "SAME claim adopted — not recreated"
kn rehearsal-new get ks moveprobe2 -o json | jq -c '.status.inventory.entries[]|select(.id|test("PersistentVolumeClaim"))'         # back in the inventory
wait_running rehearsal-new 40; data_check                              # HR fresh install onto the surviving claim; starts +1
pv_reclaim "$PV" Delete                                                # back to the fixture default
hermes_same "$(cat "$PIN_DIR/hermes-before.txt")"; inventory_ok; others_ready
EOF
```

**PASS:** ks gone; claim uid **unchanged**, no `deletionTimestamp`, PV `Bound/Retain`; everything else pruned; after recreation the claim is adopted (same uid), ks `Ready`, app runs, data intact. **ABORT:** the claim gets a `deletionTimestamp` or disappears (the Retained PV keeps the data; recover by an S1-style pinned create + `pv_repoint`, or just teardown); `flux resume` of the parent fails.
**Rollback:** `fx resume ks rehearsal-apps`. **Means for hermes:** answers whether the optional `prune: disabled` is a real safety net — and, together with S5a, *how* it must be applied to the existing claim (manual annotate) versus a rebuilt one (git).

## 8. What can go wrong (risk register)

| Risk | Mitigation |
| --- | --- |
| Longhorn populator wedge (trap 14) on the baseline deploy or in S4 | 30-min time-box, ≤ 2 recoveries, snapshot-behind-image check, Baseline-R / 7.5-R |
| A scheduled sync stamps the manual tag or fires mid-delete | `slot_clear`, `backup_now` in-flight gate |
| Trap 2 (PV `Delete` + a pruned claim = instant loss) | PV `Retain` from S1 to S4-B and again in S5; `pv_reclaim … Delete` only where stated; hermes PV refused by every guard |
| A mutation lands in the wrong cluster (fake harness) | `PIN_FAKE` interlock + dead `KUBECONFIG` + fake `flux`/`curl`; guards exit on UID mismatch |
| An immutable-field mismatch deletes the claim | impossible: no `force` anywhere (children inherit none from `cluster-apps`); a mismatch can only stall the ks |
| Alert noise | scoped silences (`rehearsal-.*`), expiry recorded, `PUSH` etc. refuse without a live one |
| kopia residue | §9 |

## 9. Time and cost

| Phase | Wall clock |
| --- | --- |
| P0–P2 (pre-flight, silence, push + bootstrap, SOPS check) | 15 min |
| Baseline (first deploy + backup + `s1_equiv` DIFFER) | 25 min; **+30–60 min** if trap 14 wedges (the first rehearsal's first deploy did) |
| S1 real-shape | 40 min |
| S2c (control + recovery) | 25 min |
| S2 (fix) | 20 min |
| S3 (a, b, revert, d) | 40 min |
| S6 | 20 min |
| S5a | 15 min |
| S4 (A, B, C) | 45 min; **+30–60 min** on a wedge |
| S5 | 35 min |
| Teardown + verification | 25 min |
| **Total** | **~4.5 h clean, ~6.5 h with one wedge.** The 10 h silence covers it; `AM_HOURS` max is 12. |

**Storage (Longhorn, 1 replica each):** claim 1→2 Gi, RD dest 1→2 Gi, three 2 Gi caches, snapshots; the S4 rebuild briefly doubles the claim + dest — **peak ≈ 15 Gi**. **kopia:** one 1 MiB blob plus a dozen small snapshots, in the shared local (Garage) and R2 repositories. **No paid API calls.** GitHub: one scratch branch push per commit (~20 commits), no PR.
**Residue that teardown cannot remove:** the kopia series `moveprobe2@rehearsal-new` in Garage and R2 (needs a kopia client) — record it in the results file. **A re-run must use a new app name (`moveprobe3`)**: the guards pin `moveprobe2` and the first deploy of a second run would restore from this run's series.

## 10. Teardown (full) and verification

Order matters: suspended Flux objects orphan their inventory when deleted (trap 6), retained PVs survive namespace deletion, Longhorn volumes outlive PVs. **Each block < 10 min.** Namespaces and Flux names are literal.

```bash
# T1 — stop watchers; unsuspend; enumerate PVs into the recorded list; make them deletable
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
watch_stop_all
for x in "ks rehearsal-apps -n flux-system" "ks moveprobe2 -n rehearsal-new" "hr moveprobe2 -n rehearsal-new"; do fx resume $x 2>/dev/null || true; done
kubectl get pv -o json | jq -r '.items[]|select((.spec.claimRef.namespace // "")|test("^rehearsal-(old|new)$"))|.metadata.name' | while read -r p; do adopt_pv "$p"; done
cat "$PIN_PVS"
while read -r pv; do [ -n "$pv" ] && { pv_reclaim "$pv" Delete || echo "skip $pv"; }; done < "$PIN_PVS"
EOF
# T2 — delete the parent (prunes the child and its inventory; the CLAIM survives if it carries prune: disabled on the live object — after S4/S5 it does — and goes with its namespace in T3, its PV already set to Delete by T1); namespaces survive (prune: disabled); then the source
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
kubectl -n flux-system delete ks rehearsal-apps --wait=false
for i in $(seq 1 48); do kubectl -n flux-system get ks rehearsal-apps >/dev/null 2>&1 || { echo "parent gone"; break; }; sleep 10; done
for ns in rehearsal-old rehearsal-new; do kubectl -n "$ns" get ks 2>&1 | head -3; done            # children pruned?
kubectl -n flux-system delete gitrepository rehearsal --ignore-not-found
EOF
# T3 — the namespaces
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
kubectl delete ns rehearsal-old rehearsal-new --wait=false
for i in $(seq 1 54); do [ -z "$(kubectl get ns --no-headers 2>/dev/null | grep '^rehearsal-' || true)" ] && { echo "namespaces gone"; break; }; sleep 10; done
EOF
# T4 — any PV still around and its Longhorn volume, by NAME from the recorded list; silences
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
while read -r pv; do [ -n "$pv" ] && { pv_delete "$pv" || echo "pv_delete refused/failed for $pv"; }; done < "$PIN_PVS"
am_unsilence
EOF
# T5 — the remote branch, then VERIFY (verify_clean needs the worktree to read the remote)
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
export PIN_WINDOW=yes
push_delete_branch                                                                 # exactly origin/rehearsal-pin
verify_clean                                                                       # namespaces, Flux CRs, labelled PVs, recorded PVs + Longhorn volumes, VolumeSnapshotContents, remote branch (fails CLOSED if unreadable), silences, watchers
others_ready
hermes_same "$(cat "$PIN_DIR/hermes-before.txt")"
EOF
# T6 — only after verify_clean printed "preflight clean" and returned 0: remove the local worktree and branch (explicit refs only)
/bin/bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/pinfix-guards.sh
git -C ~/.herdr/worktrees/flux-talos/hermes-to-ai worktree remove --force "$R"       # a worktree of the same repository; its own branch is not touched
git -C ~/.herdr/worktrees/flux-talos/hermes-to-ai branch -D rehearsal-pin
git ls-remote --heads origin rehearsal-pin                                           # empty
git -C ~/.herdr/worktrees/flux-talos/hermes-to-ai worktree list | grep -c rehearsal-pin || echo "worktree: none"
EOF
```

**Verification (each must return nothing / NotFound / 0)** is the `verify_clean` + `others_ready` + `hermes_same` block in T5 plus the last two lines of T6. `verify_clean` refuses to call the remote clean if it cannot read it (tested).

**Teardown rollback:** none (scratch objects only); if a step errors, re-run it — the guards refuse anything not on the recorded list. The guards, states file, test suite and `pinfix-state/` stay outside every repo; delete by hand when the results are written.

## 11. Decision table — what each outcome means for hermes

| Result | Meaning | Action on `ai/hermes` |
| --- | --- | --- |
| S1 `s1_equiv` EQUAL, S2c **stalls**, S2 **passes**, uid unchanged, **and S4 PASSES** (unpinned recreate + newest-series restore) | the fix works as proposed, *is* what removes the stall, **and** the DR path it exists for works | one cleanup commit (Appendix A). **S2 alone never ships it** |
| S2 passes but **S4 is inconclusive after 2 recoveries** (trap 14 wedge, time-box hit) | the stall fix is proven; the DR path — the *reason* for the change — is **not** | **do not ship Appendix A.** Either keep the pin, or ship only with the DR claim marked UNVERIFIED and a scheduled restore drill in `ai` as a precondition; record the wedge signature and elapsed times |
| **S1 `s1_equiv` DIFFERS → S1-alt** (real-shape not reached) | S2c/S2 cannot show that the annotation is what removes the stall (co-owned `f:volumeName`); only "harmless" | **do not ship on this evidence.** Re-run S1 real-shape, or treat S2 as inconclusive for hermes |
| S2c does **not** stall | trap 12 is not what the runbook says under real-shape ownership, or S1 was not real-shape | do not ship on this evidence; re-read the ownership record first |
| S2 shows an `immutable` error | `IfNotPresent` does not pre-empt validation on this build | keep the pin; open an upstream question |
| S3: capacity/label/class silently ignored | expansion becomes a manual `kubectl patch pvc` + a matching git value | add to the runbook; decide whether hermes will ever need it |
| S6 silent | drift is invisible after the fix | add a PR-time `flux build` assertion for the hermes claim, or accept it |
| S5a: annotation absent from the live claim; manual annotate survives | `prune: disabled` in git does not protect the *existing* claim | if wanted: `kubectl annotate` once, by hand, and record it |
| S5: claim survives and is re-adopted | `prune: disabled` on the live claim is a real safety net for a ks rename/move/removal | optionally annotate `ai/hermes` by hand |
| S4: unpinned recreate + newest-series restore + both annotations live | the DR path works; a rebuilt cluster no longer hangs `Pending` | drop the pin as in Appendix A |
| S4 restores an empty or older series | the DR claim in the review is wrong or the RD identity is wrong | do **not** ship; find out why before touching hermes |

**Precondition (m10) — re-check hermes' ownership right before merging Appendix A:** the S1 equivalence was measured against `ai/hermes` as it was at P0. Run `hermes_owners | diff - "$PIN_DIR/hermes-owners-before.json"`; if anything re-applied or patched the claim since (a manual `kubectl annotate prune=disabled`, a `kubectl patch` for size), the ownership differs and this rehearsal's S2 result no longer describes it — re-measure first.

**Preconditions for the real change (from the DR review, not tested here):** drop the RD `sourceNamespace` patch only after `hermes@ai` exists in the **local** repository (the RD reads local) — `check_backup ai hermes-local hermes@ai`. hermes' PV is still `Retain` (B10 pending); the fix is independent of it, but flipping to `Delete` re-arms trap 2 unless the claim is annotated `prune: disabled` on the *live* object.

## 12. Open questions / UNVERIFIED (nothing below has been run)

1. **Everything behavioural.** All hypotheses in §7 are from source reading and the first rehearsal; none has been observed on this cluster with `IfNotPresent`.
2. Whether the strategic-merge annotation patch renders identically in the in-cluster kustomize-controller as in the local `flux build` (closed by S4-C reading the annotation off a *fresh* live claim).
3. Whether the `ssa` annotation ever appears on the live claim of an existing object (source says no; S2 records it).
4. What `kube-controller-manager` / `kubectl-patch` ownership looks like after S3d and whether it changes the stall risk if the annotation is later removed.
5. Whether `flux diff` reports the S6 mismatch (optional probe) — i.e. whether a detection tool exists.
6. PVC-only recreation (no RD delete) restores the RD's *stale* `latestImage` — predicted from the populator design, **not run** (S4 deliberately recreates the RD too). Worth one line in the runbook if confirmed elsewhere.
7. A restore into a claim larger than the snapshot (1 Gi snapshot → 2 Gi request) is avoided by S3d; untested.
8. Real-size behaviour (20 Gi, ~570 MB), the HTTPRoute, hermes' HelmRelease and kopiur are out of scope by design.
9. Whether kopiur `H` schedules move before the day (re-check in P0).
10. Whether a second app (a rehearsal `moveprobe3`) is wanted for a re-run after the residue note in §9.

## Appendix A — the hermes change this rehearsal would clear (NOT applied; for the cleanup PR)

In `kubernetes/apps/ai/hermes/app/kustomization.yaml`, **replace** the two kind-targeted pin patches (`PersistentVolumeClaim` `volumeName`, `ReplicationDestination` `sourceNamespace`) with:

```yaml
patches:
  # Skip the claim once it exists: its spec is immutable after binding and Flux must never re-apply it (trap 12). The annotation must NEVER be
  # removed while the claim exists (frozen SSA ownership of f:volumeName). Consequences: capacity/label/class edits in git no longer reach the claim
  # (expand by hand). On a rebuilt cluster the claim is created unpinned and populated from hermes@ai.
  - target: {kind: PersistentVolumeClaim}
    patch: |-
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: not-used
        annotations:
          kustomize.toolkit.fluxcd.io/ssa: IfNotPresent
```

Gate: `flux build` must show `ssa: IfNotPresent` once and **no** `volumeName`/`sourceNamespace` line (the `fix` row of §5); optional `prune: disabled` is applied **by hand** to the live claim (S5a). **Preconditions:** the §11 row "S4 PASSES" (not S2 alone), and the m10 ownership re-check above.
