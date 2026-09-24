# Rehearsal plan: Flux-level dry run of `volsync-app-namespace-move.md` on a throwaway app

**Status: PLAN + FIXTURES + GUARDS FILE ONLY (revision 3, after `plan-review.md` and `plan-review-2.md`).** Nothing has been pushed, applied, or committed. Cluster access so far: `kubectl get/describe` and read-only
`--raw` GETs. Purpose: close the runbook's **Known untested** list (`docs/runbooks/volsync-app-namespace-move.md`, "Known untested" 1-13) by rehearsing the move on a scratch app, `moveprobe`
(`APP=moveprobe` ⇒ kopia username `moveprobe`, so it can never collide with a real series such as `hermes`).

Inputs: live `cluster-apps` Kustomization + patches, live `home-kubernetes` GitRepository, `kubernetes/components/{volsync-claim,volsync-backup,common/cluster-config}`, the live ReplicationSource schedule grid, `develop/hermes/{ks,app}`,
the reviewed runbook, `docs/rehearsal/plan-review.md` (rev 1: NO-GO) and `docs/rehearsal/plan-review-2.md` (rev 2: NO-GO until 4 MAJORs fixed — all fixed below).

## Changes since review 2

| # | Sev | Finding | Fixed in |
| --- | --- | --- | --- |
| N1 | MAJOR | `move_gate` passed a stale `targetNamespace`/`path` or an unedited parent kustomization; recipe interleaved "edit" comments in a heredoc | guards `move_gate` rewritten: (1) **whole-tree** porcelain (`kubernetes/rehearsal`) empty, (2) `volumeName\|sourceNamespace` count = want, (3) **every `metadata.namespace` in the app build == target ns**, (4) the **parent (`rehearsal-apps`) build has exactly one child Kustomization named `$APP`, in the target ns, `spec.path == ./kubernetes/rehearsal/<ns>/<app>/app`, `targetNamespace == <ns>`**. **Tested against a scratch repo:** correct move PASS; stale `targetNamespace` FAIL; stale `path` FAIL; ks.yaml not listed in the new namespace kustomization FAIL; uncommitted FAIL; wrong want FAIL. Recipe split into **EDIT (by hand, outside any heredoc)** and **COMMIT+GATE+PUSH** blocks (§6). The same assertions are in the **runbook B5 gate** (hermes form, `cluster-apps` parent build → `ai hermes ./kubernetes/apps/ai/hermes/app ai`) |
| N2 | MAJOR | baseline `check_backup` ran without its wait | §5.2 baseline: bounded `wait_manual` (50×10s) per RS **then** `check_backup … \|\| rc=1` per RS; same pattern in S1 B3 (§6) and S10 |
| N3 | MAJOR | S3 left the app at `replicas: 0`; unbounded `until`; commit as a comment | **S3 split at the commit** (A quiesce → commit block → B rebind → C NEW cleanup → **D exit step**: commit removing `replicas: 0`, `wait_running`, `data_check` expecting `starts` +1; stated as **S1's precondition**). **Every loop is bounded** (`wait_pv_phase`, `wait_manual`, `wait_running`, `for i in $(seq …)`) |
| N4 | MAJOR | `rehearsal_pv_ok` returned 0 ("gone") on any read error; Longhorn delete ran after a failed PV delete | guards: `kubectl get pv --ignore-not-found -o name`; a **read error ⇒ REFUSE (return 1)**; "gone" only on a confirmed empty result; `pv_delete` deletes the Longhorn volume **only after the PV delete succeeded and a re-read confirms it is gone**, all checked explicitly (errexit is off inside functions in `&&` lists). Tested: API error ⇒ REFUSE, listed-but-absent ⇒ `gone:` |
| N5 | MINOR | `APP` unvalidated | guards: allowlist `moveprobe\|moveprobe[0-9]`, else `exit 1` (tested: `APP=hermes` ⇒ refused) |
| N6 | MINOR | recipe `PV=<placeholder>` = bash syntax error | recipe uses `PV=$(app_pv)`; no placeholders remain |
| N7 | MINOR | stand-alone blocks used unbound `$PV` | new guards `app_pv` (records the app PV once in `$REH_DIR/app-pv-$APP.txt`, verifies with `rehearsal_pv_ok`); **every** block that uses `$PV` starts with `PV=$(app_pv)` |
| N8 | MINOR | `others_ready` false-aborts on `Ready=Unknown` | guards: fail at once only on `Ready=False`; otherwise not-True must persist **3 polls 20s apart**; rehearsal namespaces excluded |
| N9 | MINOR | S1 B11 self-contradictory | S1 B11 now contains S3's **evidence → clean → assert-empty** block (bounded retry for GC still finishing) |
| N10 | MINOR | S8 Block-mode details; steps were comments | guards `s8_pvc`/`s8_job`/`s8_wait` (Block PVCs; **all Jobs `runAsUser: 0`**, `volumeDevices` + `dd`); S8 steps are **commands**; Pending-claims pre-check kept (documented as over-strict) |
| N11 | MINOR | S10a blocks up to 59 min; poll was a comment; leaves `manual` set | S10a: bounded waits, start at **:44** or `run_in_background`, result poll in a second block; **manual removed after 10a** and `nextSyncTime`/next-`:47` confirmed before 10b |
| N12 | MINOR | teardown timeouts > tool limit; leaked watchers | teardown split into blocks each < 10 min (`--wait=false` + bounded polls); `watch_start`/`watch_stop_all` record PIDs in `$REH_DIR`; watchers killed after B6 and in teardown |
| N13 | MINOR | drill Job as uid 10000 can't read root-owned restore | guards `ro_run` (uid 0, read-only, node-pinned, waits complete/failed, always logs); B5b drill and `ls -ln` use it, recorded separately |
| N14 | MINOR | stale text | §1/§5.1 say **kube-system UID**, not context name; Flux Alertmanager labels are **VERIFIED** (notification-controller v1.9.1 `alertmanager.go:109-116`), §10 updated |
| — | requested | `auth can-i` pre-flight (review §2) | §5.2 step 0 |
| — | requested | `am_open` should trap `am_close` | guards: `trap am_close EXIT` inside `am_open`, curl `--retry`; silence expiry `AM_HOURS` (default 8) |
| — | requested | `bash -n` + `shellcheck` on guards | both **clean** (§0) |

(The earlier "Changes since review" table for review 1 is preserved in the git history of this plan's predecessor; all its items remain in force: guards file per-command, bash, `PUSH` function, null-safe `jq`, unannotated `rehearsal-new`, no 7b, etc.)

## 0. What exists now

| Item | State |
| --- | --- |
| Worktree `~/.herdr/worktrees/flux-talos/rehearsal-move`, branch `rehearsal-move` from `origin/main` (`6b23c57c`) | created; **`git branch --unset-upstream rehearsal-move` was run**. No `git config user.*` run there |
| Fixtures `kubernetes/rehearsal/` + `kubernetes/rehearsal-bootstrap/` in that worktree | written; `rehearsal-old` annotated (= develop), `rehearsal-new` **not** annotated (= ai); hermes' control-plane `nodeAffinity` present; **uncommitted, unpushed** |
| `~/.herdr/worktrees/flux-talos/rehearsal-guards.sh` (+ `rehearsal-state/`) | **`bash -n` clean and `shellcheck -s bash` clean**; orchestrator's **kube-system UID check kept** at the top; tested read-only/in a scratch repo: `move_gate` (6 cases), `rehearsal_pv_ok` (API error, absent, hermes, unlisted, empty), `APP` allowlist, `kn` refusal, `PUSH` with arguments, `inventory_ok` fail-closed, s8/`ro_run` YAML rendering |
| Runbook `volsync-app-namespace-move.md` B5 | gate carries the N1 assertions (hermes form) |
| `flux build` proof | §3 |

## 1. HARD GUARDRAILS (a violation = stop and run teardown)

1. **Never touch** namespaces `develop`, `ai`, any hermes object (`hermes*`, PV `pvc-12f54114-9e99-442b-bae4-53a9cb239d69`), the `cluster-apps` Kustomization, the `home-kubernetes` GitRepository, or `main`. The guards file identifies the cluster by its **kube-system UID** (`793124f9-…`, verified equal via both the LAN kubeconfig `admin@home-kubernetes` and the tailnet `tso-talos…` proxy) and `exit 1`s on any mismatch or API error.
2. **The only push target is `origin rehearsal-move`, only via `PUSH`** (no arguments, hard-coded refspec, refuses off-branch). Never a bare `git push`; **never open a PR** (`flux-local`/`image-pull`/`labeler`/Claude review run on PRs to `main`; nothing triggers on a bare branch push).
3. **No secret values** — not printed, not written. Only key **names** appear (§4).
4. **No `kustomize build | kubectl apply`, no `kubectl apply -k`, no `kubectl apply` of anything containing `${VAR}`.** The only hand-applied Flux objects are the two in `kubernetes/rehearsal-bootstrap/` (no `${`). Everything else reaches the cluster **only through Flux** reading `rehearsal-move`. *Stated exceptions:* (a) helper Jobs/PVCs used as test tooling (`data_check`, `ro_run`, S8 `s8_*`) — only via `kn` into `rehearsal-old`/`rehearsal-new`, no `${}`; (b) Alertmanager silences via the API (no `Alert` CR edits).
5. **Every mutation goes through the guards:** `kn` for namespaced objects; `pv_patch`/`pv_delete`/`pv_repoint` for PVs, each calling `rehearsal_pv_ok`: not hermes' PV, in `$REH_PVS`, labelled `rehearsal=move`, `claimRef` namespace `rehearsal-*` (or empty, accepted **only** because list + label passed), **a read error refuses**. `pv_delete` deletes the Longhorn volume **only after the PV is confirmed gone**. **No bare `kubectl patch/delete pv`.**
6. **Blast-radius check after bootstrap and after every push:** `inventory_ok` (fails closed on null) and `others_ready` (retries; see §5.1); failure ⇒ ABORT + teardown.
7. Commits only via `COMMIT` (bot identity per command, scoped message, trailers). Never `git config` in the worktree; never touch the `hermes-to-ai` branch.
8. `flux reconcile …` only against `rehearsal-apps`, `moveprobe`, `rehearsal` (GitRepository). *Note:* the live `Receiver/github-webhook` reacts to a push on **any** branch by reconciling `GitRepository/home-kubernetes` **and `Kustomization/cluster-apps`** — a harmless no-op re-apply of `main`; expect a transient `Ready=Unknown` on other Kustomizations (`others_ready` tolerates it).
9. Do not cordon/drain/label nodes or touch Longhorn settings; move the pod only by deleting **the moveprobe pod** or by a Flux commit (`nodeSelector`).
10. Time-box: > 30 min stalled on a Longhorn provisioning error (`snapshot.longhorn.io … not found`, `volsync-mover-stuck.md`) ⇒ record and move on.
11. **Every loop is bounded and every block finishes < 10 min** (the tool limit); long waits use the bounded helpers or `run_in_background`.

## 2. Fixtures (in the `rehearsal-move` worktree, uncommitted)

```
kubernetes/rehearsal/README.md
kubernetes/rehearsal/rehearsal-old/kustomization.yaml       # namespace: rehearsal-old; ns + cluster-config + ./moveprobe/ks.yaml
kubernetes/rehearsal/rehearsal-old/namespace.yaml           # prune disabled, privileged-movers=true (mirrors develop), PSA baseline
kubernetes/rehearsal/rehearsal-old/moveprobe/ks.yaml        # child Flux ks (mirrors develop/hermes/ks.yaml), sourceRef GitRepository/rehearsal
kubernetes/rehearsal/rehearsal-old/moveprobe/app/{kustomization,ocirepository,helmrelease}.yaml
kubernetes/rehearsal/rehearsal-new/kustomization.yaml       # namespace: rehearsal-new; ns + cluster-config (no apps until S2/S1)
kubernetes/rehearsal/rehearsal-new/namespace.yaml           # prune disabled, NO privileged-movers annotation (mirrors ai), PSA baseline
kubernetes/rehearsal-bootstrap/{README.md,gitrepository.yaml,rehearsal-apps.yaml}    # the two hand-applied CRs; OUTSIDE ./kubernetes/rehearsal
```

| Production | Rehearsal |
| --- | --- |
| `GitRepository/home-kubernetes`: `https://github.com/bluevulpine/flux-talos.git`, **no `secretRef`** (verified live), branch `main`, 1m | `GitRepository/rehearsal`: same URL/auth, branch `rehearsal-move`, 1m |
| `Kustomization/cluster-apps`: `path ./kubernetes/apps`, `prune: true`, `decryption: sops` (no `secretRef`; kustomize-controller's `--sops-age-secret=sops-age` is the fallback), `retryInterval 2m`, `timeout 5m`, `wait:false`, no `dependsOn`, **3 patches** | `Kustomization/rehearsal-apps`: `path ./kubernetes/rehearsal`, the **same three patches verbatim** (live-vs-fixture diff identical), same decryption/prune/timeouts, `interval: 5m`, no `dependsOn` |
| `apps/<ns>/kustomization.yaml` sets `namespace:`; lists ns + `components/common` + each `ks.yaml` | `rehearsal-old/`/`rehearsal-new/` do the same but include **only `components/common/cluster-config`** (no `metadata.namespace`, so the parent's `namespace:` places `cluster-settings`/`cluster-secrets`; no write elsewhere) |
| `develop` annotated `privileged-movers` → `ai` **not** annotated (PSA baseline) | **`rehearsal-old` annotated, `rehearsal-new` not annotated, both PSA baseline** — the post-move backup (B9) and B5b drill run with the mover caps `ai` will really have |
| hermes: app-template 5.2.1 HelmRelease from OCIRepository, `Recreate`, `existingClaim`, `volsync-claim` + `volsync-backup`, control-plane `nodeAffinity` | same chart/version/shape including the `nodeAffinity` |

**Fixture app.** `docker.io/library/busybox:1.37` (multi-arch, pulled during the smoke test), non-root (`runAsUser 10000`, `fsGroup 10000`, `OnRootMismatch`, read-only rootfs, drop ALL, seccomp RuntimeDefault), 64Mi limit. First start writes `/data/marker.txt`, a 1 MiB `blob.bin`, `SHA256SUMS`; **every** start appends `start <pod> <utc>` to `/data/starts.log` — `sha256sum -c` proves the original bytes; `starts.log` proves **continuity** (an empty or older-snapshot volume lacks the post-move lines).
**Substitutions:** `APP=moveprobe`, `NS=rehearsal-old`, `VOLSYNC_CAPACITY=1Gi`, `VOLSYNC_STORAGECLASS=longhorn-1-replica-local`, `VOLSYNC_CLONE_STORAGECLASS=longhorn-1-replica`, `VOLSYNC_SNAPSHOTCLASS=longhorn-snapclass`, `VOLSYNC_ACCESSMODES=ReadWriteOnce`, `VOLSYNC_COPYMETHOD=Snapshot`, `VOLSYNC_CACHE_CAPACITY=2Gi`.
**Schedule slot.** From every live `ReplicationSource` schedule (2026-09-23, ~100 sources): nothing at minute **47** hourly or **45** in hour 06; hour 03 empty (`kopia-maint-r2`): `"47 * * * *"` / `"45 6 * * *"`. Re-check the grid on the day.

## 3. `flux build` proof (local; re-run after fixture changes)

| Build | Result |
| --- | --- |
| **A. Old layout** (`--path …/rehearsal-old/moveprobe/app --kustomization-file …/ks.yaml -n rehearsal-old`) | rc 0; ExternalSecret ×2, HelmRelease, OCIRepository, PVC, RD, RS ×2; `volumeName\|sourceNamespace` = 0; substitutions land; control-plane `nodeAffinity` renders |
| **B. Moved layout + kind-targeted patches** | `volumeName: <pv>` **and** `sourceNamespace: rehearsal-old`; all objects `namespace: rehearsal-new` |
| **C. Name-targeted patches (first-draft mistake)** | 0 lines ⇒ gate fires |
| **D. Parent** (`flux build ks rehearsal-apps …`) | both Namespaces, `cluster-settings`/`cluster-secrets` per namespace, child `Kustomization moveprobe` with all three patches applied |
| **E. Annotations** | `privileged-movers`: `rehearsal-old` 1, `rehearsal-new` 0 |
| **F. `move_gate` behaviour** (scratch repo, tested) | baseline PASS; correct forward move PASS; stale `targetNamespace` FAIL; stale `path` FAIL; ks.yaml unlisted in the new namespace kustomization FAIL (0 children); uncommitted FAIL; want mismatch FAIL |

Not provable by a build: SOPS decryption under the scratch parent (first check after bootstrap); kustomize-controller's embedded kustomize matching the CLI (inferred).

## 4. What the volsync ExternalSecrets need from OpenBao (key NAMES only; nothing created)

`components/volsync-backup/{local,r2}.yaml` render `ExternalSecret moveprobe-volsync-local`/`-r2`, `secretStoreRef: ClusterSecretStore/openbao` (live: Ready, no namespace conditions), `dataFrom.extract`:

| ExternalSecret | OpenBao key (read) | Fields templated |
| --- | --- | --- |
| `moveprobe-volsync-local` | `volsync-local-template` | `VolSync__Local__KopiaRepository`, `__KopiaPassword`, `__AwsAccessKeyId`, `__AwsSecretKey`, `__AwsS3Endpoint` |
| `moveprobe-volsync-r2` | `volsync-r2-template` | `VolSync__R2__KopiaRepository`, `__KopiaPassword`, `__AwsAccessKeyId`, `__AwsSecretKey`, `__AwsS3Endpoint` |

**Reuse read-only; no scratch key is needed** (the shared per-repository template keys all ~46 apps read). Consequences: (a) `moveprobe` writes to the **real** Garage and R2 kopia repositories as `moveprobe@rehearsal-old`/`-new` (tiny, distinct). **This residue cannot be removed without a kopia client and persists after teardown** — a second run would restore `moveprobe@rehearsal-old` from run 1 at first deploy and fail the baseline `starts=1` check. **A re-run must use `APP=moveprobe2`** (rename the fixture directory and `APP`/`name` values; the guards accept `moveprobe` or `moveprobeN`). Record the residue in `results.md`.
(b) the `cluster-secrets` copy (SOPS, decrypted by Flux, never printed) lands only in the two scratch namespaces; (c) `external-secrets-openbao-store` (Ready) stays in `dependsOn`.

## 5. Session setup

### 5.1 The guards file — how every command is run

**Rule:** every command starts with `source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh` and runs under `bash` (tool calls keep no functions/variables; zsh does not word-split unquoted variables). Pattern:

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh      # first line of EVERY block; exits 1 unless the cluster's kube-system UID matches
# ... steps ...
EOF
```

`set -euo pipefail` is on; a step that legitimately returns non-zero is written `|| true`. State lives in `~/.herdr/worktrees/flux-talos/rehearsal-state/`. **Every block below must finish in < 10 min** (tool limit).

| Function | Contract |
| --- | --- |
| `GIT …`, `COMMIT "<subject>"`, `PUSH` | bot identity per command; `COMMIT` adds `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>` + `Claude-Session: https://claude.ai/code/session_011n8fwmnSb2pwCXEpoykL42` (lefthook pre-commit — gitleaks + yamlfmt — runs and may rewrite YAML); `PUSH` takes no args, hard-coded `rehearsal-move:refs/heads/rehearsal-move` |
| `move_gate <ns> <want>` | run **after `COMMIT`, before `PUSH`**. All of: whole `kubernetes/rehearsal` tree committed; `<want>` (0/1/2) `volumeName\|sourceNamespace` lines (2 forward move, 1 rollback into the series' own ns); **every `metadata.namespace` in the app build == `<ns>`**; **parent build has exactly one child Kustomization `$APP`, equal to `<ns> $APP ./kubernetes/rehearsal/<ns>/$APP/app <ns>`** |
| `kn <ns> …` | `kubectl -n <ns> …` for `rehearsal-old`/`rehearsal-new` only |
| `record_pv <ns> <pvc>`, `adopt_pv <pv>`, `app_pv` | record + label (`rehearsal=move`) a PV; `app_pv` records the app's PV once in `rehearsal-state/app-pv-$APP.txt` and returns it verified — **use `PV=$(app_pv)` at the top of every block that needs `$PV`** |
| `rehearsal_pv_ok`, `pv_patch`, `pv_repoint <pv> <ns> <name>`, `pv_delete` | the PV guard and the only PV mutators (read error ⇒ refuse; Longhorn delete only after the PV is confirmed gone) |
| `inventory_ok` | `rehearsal-apps` inventory non-empty and only `rehearsal-*` objects + the two Namespaces; fails closed |
| `others_ready` | Kustomizations outside `rehearsal-*`: `Ready=False` ⇒ fail at once; not-True must persist 3 polls, 20s apart (`Ready=Unknown` after a Receiver-triggered reconcile is noise) |
| `wait_manual <ns> <rs> <tag> [tries]`, `wait_pv_phase <pv> <phase> [tries]`, `wait_running <ns> [tries]` | **bounded** waits (≤ ~500s by default); non-zero on timeout |
| `check_backup <ns> <rs> <identity>` | R-3 acceptance; returns non-zero on any miss |
| `data_check <ns>` | uid-10000 read-only Job: `sha256sum -c` + `starts.log`; pins `nodeName` to the app pod's node if one exists; waits complete **or** failed; always logs; always deletes the Job |
| `ro_run <ns> <pvc> "<cmd>"` | **uid-0** read-only Job on a PVC (root-owned restores are unreadable to uid 10000); node-pinned; always logs/deletes |
| `s8_pvc`, `s8_job`, `s8_wait` | S8 Block-mode helpers (uid 0) |
| `watch_start <name> <cmd…>` / `watch_stop_all` | background watchers with PIDs in `rehearsal-state/` |
| `am_silence` / `am_unsilence` | Alertmanager silences (`AM_HOURS`, default 8; `am_open` traps `am_close`, curl retries) |
| `APP` | allowlisted: `moveprobe` or `moveprobeN`, else exit 1 |

### 5.2 Pre-flight, bootstrap and baseline

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
# 0. PRE-FLIGHT: is THIS identity allowed to do everything the plan needs? (SelfSubjectAccessReviews — non-mutating.
#    The tailnet path runs as user `tailscale-auth` through an impersonating proxy: its RBAC and `port-forward` support are UNVERIFIED.)
for q in "patch pv" "delete volumes.longhorn.io -n longhorn-system" "create pods/portforward -n observability" "create persistentvolumeclaims -n rehearsal-old"; do
  printf '%-58s ' "can-i $q"; kubectl auth can-i $q || { echo "  ^^ NOT ALLOWED — fix the identity before starting (a mid-rehearsal Forbidden strands a scenario)"; }
done
# 1. alert noise: silences BEFORE anything is created
am_silence          # namespace=~rehearsal-.* ; obj_namespace=~rehearsal-.* ; name=~rehearsal-apps|rehearsal   (Flux labels VERIFIED: alertname, severity, reason, kind, name, namespace)
EOF
```

If `can-i` is `no` for any line, or `am_silence` cannot port-forward, **stop** and fix access (or use the LAN kubeconfig).

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
# 2. commit + push the fixtures; GATE the committed files first
GIT add kubernetes/rehearsal kubernetes/rehearsal-bootstrap
COMMIT "rehearsal: add moveprobe fixtures (throwaway)"
move_gate rehearsal-old 0                       # committed; parent has exactly one child $APP in rehearsal-old; 0 patch lines
grep -c '\${' "$R"/kubernetes/rehearsal-bootstrap/*.yaml | grep -v ':0$' || true      # want no output
PUSH
# 3. the ONLY hand-applied Flux objects
kubectl apply -f "$R/kubernetes/rehearsal-bootstrap/gitrepository.yaml" -f "$R/kubernetes/rehearsal-bootstrap/rehearsal-apps.yaml"
flux reconcile source git rehearsal -n flux-system
flux reconcile ks rehearsal-apps -n flux-system
# 4. blast-radius checks (guardrail 6)
sleep 60; inventory_ok; others_ready
flux get ks rehearsal-apps -n flux-system        # Ready ⇒ SOPS decrypted the scratch copy of cluster-secrets
EOF
```

Baseline (app healthy in `rehearsal-old`) — two blocks, so each stays < 10 min:

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
flux get ks "$APP" -n "$OLD"; kn "$OLD" get hr,pod,pvc,replicationsource.volsync.backube,replicationdestination.volsync.backube
PV=$(app_pv); echo "PV=$PV"
data_check "$OLD"                                # sha OK, starts=1 (pinned to the app pod's node)
for RS in "$APP-local" "$APP-r2"; do kn "$OLD" patch replicationsource.volsync.backube "$RS" --type merge -p '{"spec":{"trigger":{"manual":"seed-1"}}}'; done
EOF
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
rc=0
# N2: explicit BOUNDED wait for THIS run before looking at any log (otherwise check_backup reads the PREVIOUS run's logs)
for RS in "$APP-local" "$APP-r2"; do wait_manual "$OLD" "$RS" seed-1 || rc=1; done
[ "$rc" -eq 0 ] || { echo "seed-1 did not complete — do NOT accept a backup"; exit 1; }
rc=0
check_backup "$OLD" "$APP-local" "$APP@$OLD" || rc=1
check_backup "$OLD" "$APP-r2"    "$APP@$OLD" || rc=1
inventory_ok; others_ready
[ "$rc" -eq 0 ] && echo "BASELINE OK" || { echo "BASELINE BACKUP CHECK FAILED"; exit 1; }
EOF
```

Baseline notes: the first-deploy PVC populates from `moveprobe-dst-local` (`restore-once`) with no snapshots under `moveprobe@rehearsal-old` — by [S-b] an empty volume (what a first deploy wants); record the RD's `Successful` and the elapsed time.
**ABORT baseline if:** `others_ready`/`inventory_ok` fail; ExternalSecrets not `SecretSynced`; the pod is not Running; the marker/sha check fails; `starts` ≠ 1 (kopia residue from an earlier run — §4); `seed-1` times out. **Rollback baseline:** teardown (§8).

## 6. Scenarios

**Execution order: 7 → 2 → 3 → 1 (with 4, 5, 6, 10 embedded) → 8; 9 is embedded in 1 and proven at teardown.** The chain reuses one app instance: S2 ends by completing the move by hand; S3 rolls it back by forward commit **and leaves the app running in `$OLD` (its exit step is S1's precondition)**; S1 is the clean, fully-instrumented move. Numbers match the runbook/brief list. Each scenario ends with a `results.md` line: *command → observed → PASS/FAIL/SURPRISE*.

### The move recipe (scenarios 1, 2, 3) — EDIT then COMMIT+GATE+PUSH

**Step E — EDIT (by hand, in `$R`, outside any heredoc).** For a move `FROM → TO` (`rehearsal-old → rehearsal-new`, or the reverse for S3):

1. `git -C "$R" mv kubernetes/rehearsal/FROM/moveprobe kubernetes/rehearsal/TO/moveprobe`
2. `kubernetes/rehearsal/FROM/kustomization.yaml`: **remove** `- ./moveprobe/ks.yaml`. `kubernetes/rehearsal/TO/kustomization.yaml`: **add** `- ./moveprobe/ks.yaml`.
3. `moveprobe/ks.yaml`: `path: ./kubernetes/rehearsal/TO/moveprobe/app`, `targetNamespace: TO`, `postBuild.substitute.NS: TO`.
4. `moveprobe/app/kustomization.yaml`: the kind-targeted patches — `volumeName: <output of app_pv>` and, **forward moves only**, `sourceNamespace: FROM` (rollback into the series' own namespace: `volumeName` only, `want=1`).
5. `moveprobe/app/helmrelease.yaml`: temporary `controllers.moveprobe.replicas: 0`.

**Step C — COMMIT + GATE + PUSH (only after Step E is complete; edit `TO` and `WANT` first):**

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
TO=rehearsal-new; WANT=2                                     # S3 rollback: TO=rehearsal-old WANT=1
PV=$(app_pv); echo "PV=$PV"
GIT add -A kubernetes/rehearsal
COMMIT "rehearsal: move $APP -> $TO"
move_gate "$TO" "$WANT"                                      # set -e stops here on FAIL; the commit stays LOCAL — fix, COMMIT again, re-gate. Never PUSH on FAIL
PUSH; flux reconcile source git rehearsal -n flux-system; flux reconcile ks rehearsal-apps -n flux-system --with-source
sleep 30; inventory_ok; others_ready
EOF
```

### Scenario 7 — deliberate name-targeted patch: the gate fires *(Known untested #13; validates R-1)*

1. In a **scratch copy** (nothing pushed): name-targeted patches (`name: moveprobe`, `name: moveprobe-dst-local`) in the moved layout; the build shows 0 `volumeName\|sourceNamespace` lines ⇒ `move_gate` fails "0 lines, want 2" (§3-C, §3-F). Restore the kind targets ⇒ both lines return. **PASS** = the gate refuses the wrong patch and passes the right one.
2. **7b (live consequence) is dropped** (review 1 #8): after S1 the NEW PVC exists and is bound, so a name-targeted push asks SSA to remove `volumeName` from a bound claim (that is 4c's failure) and the RD doesn't re-run, so `requestedIdentity` stays stale. The live proof that the *correct* patch reached the objects is B5b's `requestedIdentity` check. A live wrong-patch demonstration, if wanted, is a separate 4th cycle with `APP=moveprobe2`. Not scheduled.
3. **ABORT:** never PUSH on a gate FAIL. **Rollback:** discard the scratch copy.

### Scenario 2 — same move WITHOUT resuming the old ks: confirm the orphan behaviour *(Known untested #6; [R-2], traps 6/7)*

Start: app healthy in `$OLD`. Runs the **wrong** runbook on purpose, then recovers.

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
PV=$(app_pv)
pv_patch "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'                  # B4 — the guard even here
flux suspend ks "$APP" -n "$OLD"; flux suspend hr "$APP" -n "$OLD"
kn "$OLD" scale "deploy/$APP" --replicas=0; kn "$OLD" wait --for=delete pod -l app.kubernetes.io/name="$APP" --timeout=180s
echo "now: Step E (edit) then Step C (commit+gate+push) with TO=rehearsal-new WANT=2 — and NO 'flux resume ks'"
EOF
```

Observe after the parent reconciles:

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
PV=$(app_pv)
kn "$OLD" get ks "$APP" 2>&1 || true                                    # NotFound: the child Kustomization object is gone
kn "$OLD" get pvc,hr,replicationsource.volsync.backube,replicationdestination.volsync.backube,externalsecret,ocirepository,deploy,svc -o json \
  | jq -r '.items[]|"\(.kind)/\(.metadata.name) del=\(.metadata.deletionTimestamp // "null") ownerKs=\(.metadata.labels["kustomize.toolkit.fluxcd.io/name"] // "-")"'
kubectl get pv "$PV" -o json | jq -c '{phase:.status.phase,claim:(.spec.claimRef|{namespace,name})}'
kn "$NEW" get ks,hr,pvc -o wide
EOF
```

- **PASS (orphan reproduced, R-2/R-12 confirmed):** ks object gone from `$OLD`; **every** listed object still exists with **`del=null`** ("Bound" alone proves nothing: a PVC held by pvc-protection is also Bound); HR still `suspend: true`; PV `Bound` to `rehearsal-old/moveprobe`; `$NEW` PVC `Pending`.
- **SURPRISE (record, do not "fix"):** any `deletionTimestamp`, or PVC/PV disappearing (contradicts the source reading; `Retain` is why nothing is lost). **ABORT:** the PV or its Longhorn volume vanishes (`kubectl get pv $PV`; `kubectl -n longhorn-system get volumes.longhorn.io $PV`).

Recovery (orphan cleanup, then finish the move by hand — exercises S8's re-point and part of S5):

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
PV=$(app_pv)
kn "$OLD" delete replicationsource.volsync.backube --all; kn "$OLD" delete replicationdestination.volsync.backube --all
kn "$OLD" delete externalsecret --all; kn "$OLD" delete ocirepository "$APP"
kn "$OLD" delete helmrelease "$APP"                                     # suspended ⇒ NO uninstall (trap 7)
echo "--- orphaned by the suspended HR (record):"; kn "$OLD" get deploy,svc,sa,secret -o name | grep -E "$APP" || true
kn "$OLD" delete deploy,svc,sa -l app.kubernetes.io/instance="$APP" --ignore-not-found
kn "$OLD" get secret -o name | grep "sh.helm.release.v1.$APP" | xargs -n1 -I{} kubectl -n "$OLD" delete {} || true
kn "$OLD" get pods -o json | jq -r --arg c "$APP" '.items[]|select(.spec.volumes[]?.persistentVolumeClaim.claimName==$c)|.metadata.name'   # want empty (trap 3)
kn "$OLD" delete pvc "$APP"                                             # PV Retain ⇒ Released
wait_pv_phase "$PV" Released
pv_repoint "$PV" "$NEW" "$APP"
kn "$NEW" get pvc "$APP" -o wide                                        # Bound to $PV  (scenario 8 evidence, in situ)
data_check "$NEW"                                                       # sha OK, starts unchanged (pod still at 0 ⇒ Job runs anywhere)
EOF
```

**S2 exit step (own block):** commit removing `replicas: 0` (edit `helmrelease.yaml`, `GIT add -A kubernetes/rehearsal; COMMIT "rehearsal: start $APP in NEW"; move_gate rehearsal-new 2; PUSH; reconcile`), then `wait_running "$NEW"` and `data_check "$NEW"` (**`starts` +1**). **PASS:** data intact. **Rollback:** the PV is `Retain` throughout; `pv_repoint "$PV" "$OLD" "$APP"` (S3).

### Scenario 3 — rollback by forward commit + claimRef re-point *(Known untested #4; [R-6], runbook §5)*

Start: app **running** in `$NEW` after S2 (its `starts.log` has lines written since the move — the crux).

**3A — quiesce (block 1):**

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
PV=$(app_pv); rehearsal_pv_ok "$PV"                                    # still Retain
flux suspend hr "$APP" -n "$NEW"; kn "$NEW" scale "deploy/$APP" --replicas=0
kn "$NEW" wait --for=delete pod -l app.kubernetes.io/name="$APP" --timeout=180s
kn "$NEW" get pods -o json | jq -r --arg c "$APP" '.items[]|select(.spec.volumes[]?.persistentVolumeClaim.claimName==$c)|.metadata.name'   # empty
flux resume ks "$APP" -n "$NEW"
kn "$NEW" get hr "$APP" -o jsonpath='{.spec.suspend}{"\n"}'; kn "$NEW" get deploy "$APP" -o jsonpath='{.spec.replicas}{"\n"}'   # true / 0  (B4b checks)
EOF
```

**3B — the forward commit:** recipe Step E with `FROM=rehearsal-new`, `TO=rehearsal-old` (patches: `volumeName` only), then Step C with `TO=rehearsal-old WANT=1`.

**3C — rebind (block 2, after the push):**

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
PV=$(app_pv)
wait_pv_phase "$PV" Released                                            # bounded (≈5 min); TIMEOUT ⇒ trap 3/6: look for Completed pods or a still-suspended ks
pv_repoint "$PV" "$OLD" "$APP"
kn "$OLD" get pvc "$APP" -o wide
data_check "$OLD"                                                       # sha OK AND starts.log contains the lines written while the app ran in NEW
kn "$OLD" get events --field-selector involvedObject.name="$APP" | grep -c VolSyncPopulator || true    # want 0
EOF
```

**3D — NEW-namespace orphan cleanup (mandatory before S1).** The NEW HelmRelease was suspended at GC ⇒ no uninstall. Evidence, clean, assert empty (bounded retry: terminating `pvc`/`volsync-moveprobe-*` objects still match `grep "$APP"` while GC finishes):

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
echo "--- S3 evidence: what the suspended HR orphaned in $NEW ---"
kn "$NEW" get deploy,svc,sa,secret -o name | grep -E "$APP" || true
kn "$NEW" delete deploy,svc,sa -l app.kubernetes.io/instance="$APP" --ignore-not-found
kn "$NEW" get secret -o name | grep "sh.helm.release.v1.$APP" | xargs -n1 -I{} kubectl -n "$NEW" delete {} || true
for i in $(seq 1 12); do
  left=$(kn "$NEW" get all,secret,sa,pvc -o name | grep -E "$APP" || true)
  [ -z "$left" ] && { echo "NEW clean"; exit 0; }
  echo "still present (GC finishing?): $left"; sleep 10
done
echo "NEW NOT CLEAN — do not start S1" >&2; exit 1
EOF
```

**3D′ — exit step (S1's precondition): restart the app in `$OLD`.** Edit `helmrelease.yaml` (remove `replicas: 0`), `GIT add -A kubernetes/rehearsal; COMMIT "rehearsal: start $APP in OLD"; move_gate rehearsal-old 1; PUSH`; reconcile; then:

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
wait_running "$OLD"; data_check "$OLD"                                  # sha OK, starts = previous + 1
kn "$OLD" get hr "$APP" -o jsonpath='suspend={.spec.suspend} '; kn "$OLD" get deploy "$APP" -o jsonpath='replicas={.spec.replicas}{"\n"}'   # false / 1
EOF
```

- **PASS:** post-move lines preserved (`starts.log`), the retained PV — not a kopia restore — came back; `moveprobe` ks Ready in `$OLD`; no `VolSyncPopulator*` events; `$NEW` clean; **the app is running in `$OLD` with replicas 1** (S1's precondition).
- **Optional 3b (proves R-6):** from a healthy state do a plain `git revert` of the move commit instead: expect `$OLD`'s PVC without `volumeName`, the RD restoring the last snapshot into a **new** volume, and `starts.log` lacking post-move lines. SKIPPED if time-boxed (burns a move cycle).
- **SURPRISE:** PVC `Pending` after the re-point (record `describe pvc` + PV status); SSA errors (feeds S4). **ABORT:** `rehearsal_pv_ok` refuses. **Rollback of the rollback:** the same recipe toward `$NEW`.

### Scenario 1 — full runbook B0–B11 incl. pre-merge gate *(Known untested #1, #7, #8, #9, #10, #11, #12; embeds 4, 5, 6, 10)*

**Precondition (from S3D′):** app **running** in `$OLD` with `replicas: 1`, `$NEW` clean. Follow the runbook **verbatim** with the guards. Each row is a block; every block starts with `source …` and, if it needs the PV, `PV=$(app_pv)`.

| Runbook step | Rehearsal command / capture | Evidences |
| --- | --- | --- |
| B0 | `PV=$(app_pv)`; capture `$SC`, `lastSyncTime`s; baseline listing **as uid 0** to the state dir: `ro_run "$OLD" "$APP" 'find . -type f -print0 \| sort -z \| xargs -0 sha256sum; ls -ln' > "$REH_DIR/baseline.txt"` | — |
| **S10a** (before B1; app running) | see S10 | **10a / Known untested #12** |
| B1 | `flux suspend ks/hr`, scale 0, no pod references the PVC | trap 3 |
| B3 | the explicit block below | **10b** |
| B4 | `PV=$(app_pv); pv_patch "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'` | 9 (first half) |
| B4b | `flux resume ks`; HR `.spec.suspend` = true, Deployment replicas = 0 | Known untested #6 |
| B5 | Step E → **before the push** start watchers: `watch_start pvc-new kubectl -n rehearsal-new get pvc -w`, `watch_start pv kubectl get pv "$PV" -w`; then Step C (`TO=rehearsal-new WANT=2`) | **5** |
| B5b | `requestedIdentity` = `moveprobe@rehearsal-old`; PVC `.spec.volumeName` = `$PV`; RD `Successful`; **drill (uid 0, N13):** `ro_run "$NEW" volsync-moveprobe-dst-local-dest 'find . -type f -print0 \| sort -z \| xargs -0 sha256sum' > drill.txt` diffed against `baseline.txt` (content only), then **`ro_run "$NEW" volsync-moveprobe-dst-local-dest 'ls -ln'` recorded separately** — `rehearsal-new` is unannotated (= `ai`), so expect **`root:root`** per [S-priv] (the fixture files are uid 10000 in the original); then **delete the dest PVC** and retrigger the RD (`manual: restore-2`) to observe whether VolSync recreates it | Known untested #9-analog, #11; R-7 |
| B6 | `wait_pv_phase "$PV" Released`; `kubectl get pvc -A --field-selector=status.phase=Pending` (know what else waits); `pv_repoint "$PV" rehearsal-new moveprobe`; PVC → Bound; no `VolSyncPopulator*` events; **then `watch_stop_all`** (N12) | **8**, **5**, Known untested #2, #3 |
| B7 | `data_check "$NEW"` vs baseline (static files) | — |
| B8 | remove `replicas: 0` (2nd commit, gated with `move_gate rehearsal-new 2`). **Before** it: `kn "$NEW" get deploy moveprobe -o jsonpath='{.spec.replicas}'` = 0 with `Recreate`; after: `wait_running "$NEW"`, `data_check` (`starts` +1) | Known untested #8 |
| **S4** (after B8) | see S4 | **4** |
| B9 | trigger/wait; `check_backup "$NEW" "$APP-local" "$APP@$NEW"` and `-r2` (unannotated ns ⇒ the real `ai` mover shape) | — |
| **S6** (after B9) | see S6 | **6** |
| B10 | `PV=$(app_pv); pv_patch "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'`; read back | **9** |
| B11 | the **evidence → clean → assert-empty** block below, run for `$OLD` | R-8, R-12 |

**B3 — explicit block (N2; own tool call, bounded):**

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
for RS in "$APP-local" "$APP-r2"; do
  echo "$RS in-flight start: [$(kn "$OLD" get replicationsource.volsync.backube "$RS" -o json | jq -r '.status.lastSyncStartTime // ""')]"   # must be [] — if not, wait for it to finish first
done
T0=$(date -u +%FT%TZ); TAG="pre-move-$(date +%s)"; echo "T0=$T0 TAG=$TAG" | tee "$REH_DIR/b3.txt"        # T0 AFTER the pod is gone (B1)
for RS in "$APP-local" "$APP-r2"; do
  kn "$OLD" patch replicationsource.volsync.backube "$RS" --type merge -p '{"spec":{"trigger":{"manual":"'"$TAG"'"}}}'
done
rc=0
for RS in "$APP-local" "$APP-r2"; do wait_manual "$OLD" "$RS" "$TAG" || rc=1; done
[ "$rc" -eq 0 ] || { echo "manual run did not complete — do NOT proceed"; exit 1; }
rc=0
for RS in "$APP-local" "$APP-r2"; do
  LST=$(kn "$OLD" get replicationsource.volsync.backube "$RS" -o json | jq -r '.status.lastSyncTime // ""')
  if [[ "$LST" > "$T0" ]]; then echo "$RS lastSyncTime $LST > T0 $T0"; else echo "$RS STALE ($LST <= $T0): a pre-quiesce sync stamped the tag — trigger again" >&2; rc=1; fi
  check_backup "$OLD" "$RS" "$APP@$OLD" || rc=1
done
[ "$rc" -eq 0 ] && echo "B3 ACCEPTED (both RS)" || { echo "B3 REJECTED"; exit 1; }
EOF
```

**B11 — evidence → clean → assert-empty for `$OLD` (N9; the real B11 the hermes runbook needs).** The OLD HelmRelease was suspended at GC ⇒ no uninstall ⇒ orphaned Deployment/Service/SA/`sh.helm.release.v1.moveprobe.*`:

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
echo "--- S1 B11 evidence: what the suspended HR orphaned in $OLD ---"
kn "$OLD" get deploy,svc,sa,secret -o name | grep -E "$APP" || true
kn "$OLD" delete deploy,svc,sa -l app.kubernetes.io/instance="$APP" --ignore-not-found
kn "$OLD" get secret -o name | grep "sh.helm.release.v1.$APP" | xargs -n1 -I{} kubectl -n "$OLD" delete {} || true
for i in $(seq 1 12); do
  left=$(kn "$OLD" get all,secret,sa,pvc,hr,ks,externalsecret,replicationsource.volsync.backube,replicationdestination.volsync.backube -o name | grep -E "$APP" || true)
  [ -z "$left" ] && { echo "OLD clean (only cluster-settings/cluster-secrets remain)"; exit 0; }
  echo "still present (owner-GC finishing?): $left"; sleep 10
done
echo "OLD NOT CLEAN" >&2; exit 1
EOF
```

**Scenario 5 (B6 ordering) — pass criteria.** From the watch logs (`rehearsal-state/pvc-new.log`, `pv.log`): the `$NEW` PVC appears **before** the `$OLD` PVC is gone and before the PV is `Released` (`Pending`), then goes `Bound` after the re-point without recreation. Record timestamps. **5b (fallback):** if it stays `Pending` > 5 min after the re-point, `kn "$NEW" delete pvc "$APP"` and confirm Flux recreates it **with** `volumeName` and it binds; **ABORT** if the recreated claim lacks `volumeName` (gate bypassed).

**Scenario 4 (SSA ownership of `volumeName`, ≥ 2 reconciles and a spec change) — after B8.**

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
kubectl -n longhorn-system get pods -l app=longhorn-manager -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'     # Longhorn version (v1.12.1 on 2026-09-23)
kn "$NEW" get pvc "$APP" -o json | jq '.metadata.managedFields[]|{manager,operation,spec:((.fieldsV1["f:spec"] // {})|keys)}'      # who owns f:volumeName / f:dataSourceRef
for k in pvc/"$APP" replicationdestination.volsync.backube/"$APP-dst-local" replicationsource.volsync.backube/"$APP-local" replicationsource.volsync.backube/"$APP-r2" pvc/volsync-"$APP"-dst-local-dest; do
  echo "$k $(kn "$NEW" get "$k" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo absent)"; done | tee "$REH_DIR/s4-uids-before.txt"
for i in 1 2; do flux reconcile ks "$APP" -n "$NEW" --with-source; done
flux get ks "$APP" -n "$NEW"; kn "$NEW" get ks "$APP" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}{"\n"}'
EOF
```

Spec change: edit `moveprobe/ks.yaml` `VOLSYNC_CAPACITY: 1Gi` → `2Gi` (PVC request **and** RS/RD capacity), `GIT add -A kubernetes/rehearsal; COMMIT "rehearsal: capacity 2Gi"; move_gate rehearsal-new 2; PUSH`, reconcile, then:

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
kn "$NEW" get pvc "$APP" -o jsonpath='{.spec.volumeName} {.spec.resources.requests.storage} {.status.capacity.storage}{"\n"}'
for k in pvc/"$APP" replicationdestination.volsync.backube/"$APP-dst-local" replicationsource.volsync.backube/"$APP-local" replicationsource.volsync.backube/"$APP-r2" pvc/volsync-"$APP"-dst-local-dest; do
  echo "$k $(kn "$NEW" get "$k" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo absent)"; done | diff "$REH_DIR/s4-uids-before.txt" - || true
kn "$NEW" get pod -l app.kubernetes.io/name="$APP" -o jsonpath='{.items[0].metadata.name} restarts={.items[0].status.containerStatuses[0].restartCount}{"\n"}'
EOF
```

- **PASS:** ks stays `Ready` across both reconciles and the spec change; `volumeName` unchanged; PVC request and `status.capacity` reach 2Gi.
- **Longhorn/online-expansion note:** Longhorn manager **v1.12.1**; the app pod is **running**, so this is an **online** expansion — record whether it completes without a pod restart (`restartCount` unchanged) and how long `status.capacity` takes (`allowVolumeExpansion: true`, verified).
- **Record:** which of PVC/RD/RS/dest-PVC were **recreated** (UID diff). **SURPRISE:** an `immutable`/`Forbidden` error in the ks message — capture verbatim (converts runbook trap 12 to observed).
- **4c (optional, LAST, revert after):** commit **removing** the `volumeName` patch (gate `want=1`… the gate will FAIL by design: for 4c run Step C **without** `move_gate`, the only sanctioned exception, with `TO=rehearsal-new`, and record that you did) → predict the ks stalls with an immutable-field SSA error. **Rollback:** re-add the patch, `move_gate rehearsal-new 2`, push.
- **ABORT:** any error text naming a namespace other than `rehearsal-*`.

**Scenario 6 (Longhorn `kubernetesStatus` + locality after the rebind) — after B9.** **Criteria up front:**

| Question | PASS | FAIL / FINDING |
| --- | --- | --- |
| `kubernetesStatus` | `namespace == rehearsal-new` and `pvcName == moveprobe` after the rebind | still `rehearsal-old` (it did after release in the smoke test) — cosmetic, record |
| Locality (`dataLocality: best-effort`, 1 replica) | **CLOSED only if** the pod lands on a **different brokkr node** than before **and** a replica appears on the pod's node (best-effort rebuild) within ~10 min | same node, or a Pi (`jormungandr*` have **no Longhorn disks**, a replica can never be local there) ⇒ **NOT CLOSED** — say so; do not claim it |

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
PV=$(app_pv)
kubectl -n longhorn-system get volumes.longhorn.io "$PV" -o json | jq '{ns:(.status.kubernetesStatus.namespace // ""),pvc:(.status.kubernetesStatus.pvcName // ""),locality:.spec.dataLocality,node:(.status.currentNodeID // ""),state:.status.state,robust:.status.robustness}'
kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume="$PV" -o jsonpath='{range .items[*]}replica-node={.spec.nodeID}{"\n"}{end}'
kn "$NEW" get pod -l app.kubernetes.io/name="$APP" -o jsonpath='pod-node={.items[0].spec.nodeName}{"\n"}'
kn "$NEW" delete pod -l app.kubernetes.io/name="$APP"          # moveprobe pod ONLY; then wait_running and repeat the three reads (up to 3 tries)
EOF
```

**6b (only if locality is still open after 3 tries):** a Flux commit adding `defaultPodOptions.nodeSelector: {kubernetes.io/hostname: <a different brokkr node>}` (gated) forces the move without touching any node; observe replica placement; revert.

**Scenario 9 (`Delete` on a bound PV) — B10, then prove the effect.**

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
PV=$(app_pv)
pv_patch "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
kubectl get pv "$PV" -o json | jq -c '{reclaim:.spec.persistentVolumeReclaimPolicy,phase:.status.phase}'      # Delete, Bound
EOF
```

**PASS:** accepted on the Bound PV, read back, PV stays `Bound`. **Effect proof (teardown, §8):** deleting the PVC removes the PV **and** the Longhorn volume. **Rollback:** patch back to `Retain`. **ABORT:** phase changes or the patch is rejected (record the error).

**Scenario 10 (schedule → manual → schedule; in-flight `lastManualSync` race).**

*10a — deterministic in-flight race (before B1, app running; Known untested #12).* **Start block 1 at `:44`** (or with `run_in_background: true`) so it fits the 10-minute tool limit; **all loops bounded**:

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
RS="$APP-local"
for i in $(seq 1 60); do [ "$(date +%M)" = 46 ] && break; sleep 5; done                 # schedule is "47 * * * *"; ≤5 min
st=""
for i in $(seq 1 150); do                                                                # ≤ 5 min, 2s steps: catch a sync IN FLIGHT
  st=$(kn "$OLD" get replicationsource.volsync.backube "$RS" -o json | jq -r '.status.lastSyncStartTime // ""')
  [ -n "$st" ] && break; sleep 2
done
[ -n "$st" ] || { echo "no in-flight sync caught — retry at the next :47"; exit 1; }
TAG="race-$(date +%s)"; T1=$(date -u +%FT%TZ); echo "TAG=$TAG T1=$T1" > "$REH_DIR/s10a.txt"
kn "$OLD" patch replicationsource.volsync.backube "$RS" --type merge -p '{"spec":{"trigger":{"manual":"'"$TAG"'"}}}'     # patched IMMEDIATELY, sync in flight
EOF
```

Block 2 (result poll, ≤ 8 min):

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
RS="$APP-local"
for i in $(seq 1 48); do
  kn "$OLD" get replicationsource.volsync.backube "$RS" -o json | jq -c '.status|{t:(now|todate),start:(.lastSyncStartTime // ""),last:(.lastSyncTime // ""),manual:(.lastManualSync // ""),reason:(.conditions[0].reason // "")}'
  sleep 10
done | tee "$REH_DIR/s10a-poll.log"
EOF
```

Record: does `lastManualSync == $TAG` after **that** already-running (scheduled) sync finishes; is `lastSyncTime` before/after `T1`; does a **second** sync start (R-4's failure mode). A 1 MiB sync still takes ~1-2 min on Longhorn, so the window is catchable; if missed, retry at the next `:47`.
**Cleanup 10a → 10b (N11):** 10a leaves `spec.trigger.manual=race-…` set, which suppresses scheduled syncs — **remove it before 10b** and confirm the schedule is live:

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
kn "$OLD" patch replicationsource.volsync.backube "$APP-local" --type json -p '[{"op":"remove","path":"/spec/trigger/manual"}]'
kn "$OLD" get replicationsource.volsync.backube "$APP-local" -o json | jq -c '{trigger:.spec.trigger,next:(.status.nextSyncTime // "")}'      # {"schedule":"47 * * * *"} and a nextSyncTime
EOF
```

Confirm the next `:47` actually fires (`lastSyncStartTime` advances) — do other work meanwhile; do not start 10b until it has.

*10b — schedule→manual→schedule (inside B3/B4b):*

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
kn "$OLD" get replicationsource.volsync.backube "$APP-local" -o jsonpath='{.spec.trigger}{"\n"}'          # {"schedule":"47 * * * *"} — clean, thanks to the 10a cleanup
# B3 (block above) → record .spec.trigger again (both keys?)
# B4b: flux resume ks → flux reconcile ks → record .spec.trigger AGAIN
kn "$OLD" get replicationsource.volsync.backube "$APP-local" -o json | jq '.metadata.managedFields[]|{manager,trigger:((.fieldsV1["f:spec"]["f:trigger"] // {})|keys)}'     # who owns f:manual vs f:schedule
EOF
```

- **PASS:** `manual` present after the patch; `lastSyncTime > T0`; after the resume the RS is back on `schedule` — **or** record that `manual` **persists** (owned by `kubectl-patch`, not removed by the ks; then the next `:47` may not fire since `manual` has precedence — wait past `:47`).
- **Why it matters:** in the hermes move the old RS is pruned, so a lingering `manual` is harmless; in a rollback or a failed move that keeps the RS it silently stops scheduled backups. **Finding either way.**
- **Rollback:** remove `/spec/trigger/manual` as above.

### Scenario 8 — claimRef re-point binding a Released PV, with a competing claim *(Known untested #3; [R-5])*

Standalone with a **bait** PV so the app's data is never the guinea pig. All bait/thief/wanted objects are `volumeMode: Block` (uid-0 `volumeDevices`/`dd` Jobs via `s8_*`), so no production `Filesystem` claim can match the bait while it is `Available`. Block provisioning on `longhorn-1-replica-local` is **UNVERIFIED**; if refused, fall back to Filesystem **only** with the Pending-claims pre-check and each thief/consumer created in the **same command** as the claimRef removal. The Pending-claims pre-check is cluster-wide and unfiltered by StorageClass — over-strict on purpose.

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
# pre-check: nothing anywhere is Pending
kubectl get pvc -A -o json | jq -e '[.items[]|select(.status.phase=="Pending")]|length==0' >/dev/null || { echo "Pending claims exist — ABORT S8"; exit 1; }
# 1. bait: PVC + writer Job in $OLD; record; Retain; free it
s8_pvc "$OLD" bait; s8_job "$OLD" bait-writer bait write; s8_wait "$OLD" bait-writer
BAIT=$(record_pv "$OLD" bait); echo "BAIT=$BAIT"
pv_patch "$BAIT" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kn "$OLD" delete job bait-writer --wait=true; kn "$OLD" delete pvc bait --wait=true
wait_pv_phase "$BAIT" Released
# 2. removal-only (the R-5 hazard): remove claimRef, and IN THE SAME COMMAND create the thief + its consumer
pv_patch "$BAIT" --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
s8_pvc "$NEW" thief; s8_job "$NEW" thief-reader thief read
s8_wait "$NEW" thief-reader || true                                                     # EXPECT: thief binds $BAIT and reads back bait-marker-1234
echo "thief bound to: $(kn "$NEW" get pvc thief -o jsonpath='{.spec.volumeName}')  (== $BAIT ⇒ R-5 hazard confirmed)"
# 3. reset — never leave the PV claimRef-less: delete thief, wait Released, and re-point at once
kn "$NEW" delete job thief-reader --wait=true; kn "$NEW" delete pvc thief --wait=true
wait_pv_phase "$BAIT" Released
pv_repoint "$BAIT" "$NEW" wanted
# 4. re-point test: BOTH `thief` and `wanted` exist; only `wanted` may bind $BAIT
s8_pvc "$NEW" wanted; s8_pvc "$NEW" thief
s8_job "$NEW" wanted-reader wanted read; s8_job "$NEW" thief-reader thief read
s8_wait "$NEW" wanted-reader; s8_wait "$NEW" thief-reader
echo "wanted -> $(kn "$NEW" get pvc wanted -o jsonpath='{.spec.volumeName}')   thief -> $(kn "$NEW" get pvc thief -o jsonpath='{.spec.volumeName}')   (want: wanted==$BAIT, thief!=$BAIT)"
EOF
```

Cleanup block (**never end S8 with a claimRef-less PV**; also the S8 abort path):

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
BAIT=$(grep -v -x "$(app_pv)" "$REH_PVS" | tail -1)                         # the last recorded PV that is not the app's
kn "$NEW" delete job --all --wait=true; kn "$NEW" delete pvc wanted thief --ignore-not-found --wait=true
pv_delete "$BAIT"                                                            # guarded: accepts an empty claimRef because it is listed and labelled; deletes the Longhorn volume only after the PV is gone
kubectl get pv -l rehearsal=move -o json | jq -r '.items[]|select((.spec.claimRef // null)==null)|.metadata.name'     # must print nothing
EOF
```

- **PASS:** removal-only lets the thief bind; the re-point reserves the PV for `wanted` (marker reads back) and the thief provisions its own volume.
- **FINDING if different:** if the thief does **not** bind under removal-only, downgrade R-5 to "unproven hazard" but keep the re-point (harmless).
- **ABORT:** Pending claims exist; `rehearsal_pv_ok` refuses; any helper lands outside `rehearsal-*`. **Rollback:** the cleanup block above.

## 7. Known-untested → scenario coverage

| Runbook "Known untested" | Closed by |
| --- | --- |
| 1 SSA ownership of `volumeName` under real Flux | **4** (+4c) |
| 2 B6 ordering (PVC created before PV freed) | **5** in S1 (and S2 recovery) |
| 3 claimRef re-point binding | **8**, S1 B6, S2 recovery, S3 |
| 4 rollback paths | **3** (+3b), S2's "rollback of recovery" |
| 5 Longhorn `kubernetesStatus` / locality | **6** — `kubernetesStatus` closed; **locality NOT closed unless the pod moves to a different brokkr node** (6b) |
| 6 resumed ks vs HelmRelease `spec.suspend` | S1 B4b, S3A |
| 7 schedule→manual on a live RS | **10b** |
| 8 `replicas: 0` with `Recreate` | S1 B5/B8 |
| 9 restore of the real 570 MB series | **not closed** (tiny data); B5b drill is a mechanics proof only |
| 10 route hand-over | **not covered** (no route in the fixture; outside the blast radius) — verify by hand in the real move |
| 11 `Delete` on a bound PV; deleting the RD's dest PVC | **9**; S1 B5b (delete the dest PVC **and observe the RD afterwards**) |
| 12 fork's manual/tag semantics | **10a** — closed only if the poll caught the in-flight window |
| 13 in-cluster kustomize-controller vs local build | S1/S2 gate then **B5b** (`requestedIdentity`, `.spec.volumeName` on the live objects) |

Not rehearsed by design: HTTPRoute hand-over, hermes' size/timing (570 MB, ~44Gi drill), hermes' s6 root entrypoint under `ai`'s PSA baseline, Reloader + `ExternalSecret hermes-secret`, hermes' HelmRelease remediation, kopiur.

## 8. Teardown (full) and verification

Order matters: **suspended** Flux objects orphan their inventory when deleted (trap 6), retained PVs survive namespace deletion, Longhorn volumes outlive PVs. Namespaces are spelled out literally. **Each block is < 10 min** (N12): waits are `--wait=false` + bounded polls.

```bash
# Block T1 — enumerate, unsuspend, make PVs deletable
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
watch_stop_all
kubectl get pv -o json | jq -r '.items[]|select((.spec.claimRef.namespace // "")|test("^rehearsal-(old|new)$"))|.metadata.name' | while read -r p; do adopt_pv "$p"; done
kubectl get pv -l rehearsal=move -o name; cat "$REH_PVS"
for ns in rehearsal-old rehearsal-new; do flux resume ks --all -n "$ns" 2>/dev/null || true; flux resume hr --all -n "$ns" 2>/dev/null || true; done
while read -r pv; do [ -n "$pv" ] && { pv_patch "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' || true; }; done < "$REH_PVS"
EOF
# Block T2 — delete the parent (prunes children -> apps + PVCs); namespaces survive (prune: disabled)
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
kubectl -n flux-system delete ks rehearsal-apps --wait=false
for i in $(seq 1 48); do kubectl -n flux-system get ks rehearsal-apps >/dev/null 2>&1 || { echo "parent gone"; break; }; sleep 10; done
for ns in rehearsal-old rehearsal-new; do kubectl -n "$ns" get ks 2>&1 | head -3; done            # children pruned?
kubectl -n flux-system delete gitrepository rehearsal --ignore-not-found
EOF
# Block T3 — the namespaces (take cluster-settings/cluster-secrets copies, helper Jobs, leftovers with them)
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
kubectl delete ns rehearsal-old rehearsal-new --wait=false
for i in $(seq 1 54); do [ -z "$(kubectl get ns --no-headers 2>/dev/null | grep '^rehearsal-' || true)" ] && { echo "namespaces gone"; break; }; sleep 10; done
EOF
# Block T4 — any PV still around (Released/Retain/claimRef-less leftovers) and its Longhorn volume — guarded, by NAME from the recorded list
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
while read -r pv; do [ -n "$pv" ] && { pv_delete "$pv" || echo "pv_delete refused/failed for $pv"; }; done < "$REH_PVS"
am_unsilence
EOF
# Block T5 — remote branch and local worktree/branch (explicit refs only)
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
git -C "$R" push origin --delete rehearsal-move
git -C ~/.herdr/worktrees/flux-talos/hermes-to-ai worktree remove --force "$R"
git -C ~/.herdr/worktrees/flux-talos/hermes-to-ai branch -D rehearsal-move
EOF
```

**Verification (each must return nothing / NotFound):**

```bash
bash <<'EOF'
source ~/.herdr/worktrees/flux-talos/rehearsal-guards.sh
kubectl get ns | grep rehearsal || echo "ns: none"
kubectl -n flux-system get ks,gitrepository | grep rehearsal || echo "flux objects: none"
kubectl get pv -o json | jq -r '.items[]|select(((.spec.claimRef.namespace // "")|test("^rehearsal-"))or((.metadata.labels.rehearsal // "")=="move"))|.metadata.name'
while read -r pv; do [ -n "$pv" ] && { kubectl get pv "$pv" 2>&1 | tail -1; kubectl -n longhorn-system get volumes.longhorn.io "$pv" 2>&1 | tail -1; }; done < "$REH_PVS"     # all NotFound
kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r '.items[]|select((.status.kubernetesStatus.namespace // "")|test("^rehearsal-"))|.metadata.name'
kubectl get volumesnapshotcontent -o json | jq -r '.items[]|select((.spec.volumeSnapshotRef.namespace // "")|test("^rehearsal-"))|.metadata.name'
others_ready
git ls-remote --heads origin rehearsal-move                                        # empty
git -C ~/.herdr/worktrees/flux-talos/hermes-to-ai worktree list | grep rehearsal || echo "worktree: none"
wc -c < "$REH_SILENCES"; ls "$REH_DIR"/watch-*.pid 2>/dev/null || echo "no watchers"      # 0 ; none
kubectl -n develop get pvc hermes -o jsonpath='{.status.phase}{"\n"}'; kubectl -n develop get replicationsource.volsync.backube hermes-local -o jsonpath='{.status.lastSyncTime}{"\n"}'   # hermes untouched
EOF
```

**Residue teardown cannot remove:** kopia series `moveprobe@rehearsal-old` and `moveprobe@rehearsal-new` in the shared local (Garage) **and** R2 repositories (distinct, a few KB each; needs a kopia client). Record them in `results.md`; **a re-run must use `APP=moveprobe2`**. The guards file and `rehearsal-state/` stay (outside every repo); delete by hand when fully closed.
**Teardown rollback:** none — scratch objects only. If a step errors, re-run it; the guards refuse anything not on the recorded list.

## 9. Cost, timing, stop conditions

- Storage per app instance: PVC 1Gi (2Gi after S4) + RD dest 1Gi + 3 caches × 2Gi (Longhorn, 1 replica); S8 adds ~3 × 1Gi Block. Peak well under 20Gi (the hermes B5b drill will be ~44Gi).
- Wall clock: bootstrap 15 min; S7 5; S2 ~45; S3 ~50 (with 3D/3D′); S1 ~75 (+ waiting for a `:47` slot for S10a/B9); S8 ~30; S4c optional 15; teardown 20. The 8h silence covers ~6h of work; re-run `am_silence` (or `AM_HOURS=12`) if it spills over.
- Stop the rehearsal (and tear down) on: a guardrail violation; a non-rehearsal Kustomization `Ready=False` or not-Ready for 3 polls (`others_ready`); `inventory_ok` failing; SOPS decryption failing in a way that touches `flux-system` sops config.
- Afterwards: write `docs/rehearsal/results.md` (commands, observed output, PASS/FAIL/SURPRISE per scenario, secrets redacted, kopia residue recorded) and update the runbook's **Known untested**/traps with observed facts.

## 10. Open items before running

1. The repo is public over unauthenticated HTTPS (live `home-kubernetes` has no `secretRef`), so `GitRepository/rehearsal` needs no auth. A branch push triggers no workflow; it **does** fire `Receiver/github-webhook`, reconciling `home-kubernetes` **and `cluster-apps`** — a harmless no-op re-apply of `main`.
2. Confirm SOPS decrypts `cluster-secrets` for `rehearsal-apps` in `flux-system` (same keys as `cluster-apps`; `--sops-age-secret=sops-age` fallback) — first check after bootstrap (`flux get ks rehearsal-apps`).
3. Flux's Alertmanager provider label names are **verified** (notification-controller v1.9.1 `alertmanager.go:109-116`: `alertname`, `severity`, `reason`, `kind`, `name`, `namespace`, `reportingcontroller`); VolSync series carry `obj_namespace`/`obj_name` (`namespace=` is the exporter's). The three silence matchers are provably scoped to `rehearsal-*` / the two scratch CR names.
4. Block-mode provisioning on `longhorn-1-replica-local` for S8 (UNVERIFIED) — else the documented Filesystem fallback.
5. **Identity/permissions:** the tailnet kubeconfig runs as `tailscale-auth` through an impersonating proxy; whether it may `patch pv`, `delete volumes.longhorn.io`, `create pods/portforward` and whether `port-forward` works through it is UNVERIFIED — the §5.2 `auth can-i` pre-flight answers it before anything is created.
6. Optionally run a second S1 B5b drill with the annotation added to `rehearsal-new` to compare restored ownership (annotated → `10000`-owned; unannotated → `root:root`).
7. Re-check the schedule grid on the day.
