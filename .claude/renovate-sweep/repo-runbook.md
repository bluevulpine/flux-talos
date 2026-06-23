# Renovate sweep — repo runbook

Cluster-specific commands, gotchas, and the flow for making derived fixes. This repo
is Flux GitOps on a 7-node Talos cluster; merges to `main` trigger Flux via webhook.

## Flux sources & reconcile

- The canonical GitRepository is **`home-kubernetes`** (HTTPS, tracks `main`) — every
  Kustomization's `sourceRef` points to it. Reconcile THIS when you need Flux to pick
  up a merge.
- A second GitRepository **`flux-talos-ssh`** (SSH, `secretRef: github-deploy-key`)
  exists *by design* for write-back: the `bluevulpine-blog` ImageUpdateAutomation pushes
  tag-bump commits through it (the HTTPS source is read-only). Only image automation
  uses it — don't reconcile it expecting to refresh the whole cluster.
- Reconcile patterns:
  ```
  flux reconcile source git home-kubernetes -n flux-system
  flux reconcile kustomization cluster-apps -n flux-system --with-source
  flux reconcile helmrelease <name> -n <ns> --with-source
  flux reconcile kustomization <app> -n flux-system            # per-app KS
  ```
- A `flux reconcile ... --with-source` may still report the *previous* revision if the
  git source hasn't fetched the merge yet — explicitly reconcile `home-kubernetes`
  first, then re-check.

## Shell / tooling gotchas (this environment)

- **`rtk`** proxies and summarizes CLI output to save tokens. It can mangle output and
  some regexes; when you need raw output use `rtk proxy <cmd>`. Prefer `awk`-based
  filtering over fancy regex.
- **No foreground `sleep`** — it's blocked. To wait on a condition use an
  `until <check>; do sleep N; done` loop (optionally `run_in_background: true`). Don't
  chain short sleeps.
- **Dev tooling lives under mise/Homebrew, not always on PATH.** `lefthook`, `yamlfmt`
  may be absent in the non-interactive shell. Homebrew is at `/opt/homebrew/bin` and
  provides **`yq`** and **`kubeconform`** — use them to validate manifests:
  ```
  /opt/homebrew/bin/yq 'true' <file>                 # YAML well-formed
  /opt/homebrew/bin/kubeconform -strict -summary <file>
  ```
- If you need the user to run an interactive command (e.g. a login), suggest they type
  `! <command>` in the prompt.

## Validating manifests before merge

- The PR's own CI runs **flux-local** (Diff + Test) and **Image Pull** — wait for green.
- Watch CI without `--watch` (which can hang): poll
  `until [ "$(gh pr checks <#> | grep -c pending)" = 0 ]; do sleep 15; done`.
- Locally, validate edited manifests with `yq` + `kubeconform` (above). Schema headers
  (`# yaml-language-server: $schema=...`) and `yamlfmt` block style are enforced by
  lefthook on the user's side.

## Derived-fix flow (worktree → PR → CI → merge)

When a PR is safe *except* for a trivial config gap (missing RBAC, a label, a small
reorg), fix it and merge, then continue monitoring:

1. `EnterWorktree` (named), then `git fetch origin main && git reset --hard origin/main`
   so you branch from the true latest main (avoids reverting others' merges).
2. Make the minimal edit. **Document the WHY** in a comment (repo convention) — explain
   the failure mode and constraint, not just the mechanic.
3. Validate with `yq` + `kubeconform`.
4. Commit (end message with the `Co-Authored-By: Claude ...` trailer), push the branch,
   `gh pr create`.
5. Wait for CI green, then `gh pr merge <#> --merge`.
6. `ExitWorktree` (keep), reconcile the source + affected HR/KS, and monitor.

If SSH/GitHub is flaky, retry with backoff; `gh api` (HTTPS) can substitute for SSH git
operations.

## Repo conventions to respect

- New apps: `kubernetes/apps/<ns>/<app>/` with `helmrelease.yaml` (OCIRepository ref,
  `&app` anchor, standard remediation), optional `externalsecret.yaml` (OpenBao via
  ESO, `secretStoreRef: openbao`, `engineVersion: v2`, PascalCase `App__Cat__Field`).
- `crds: CreateReplace` is injected globally by the `cluster-apps` patch — never per-HR.
- Annotate any new tracked version with the matching `# renovate: datasource=...`.
- Secrets only from OpenBao; never commit plaintext (gitleaks runs pre-commit).
- Postgres apps use the `ghcr.io/home-operations/postgres-init` init container, not
  hand-created DBs.

## Known recurring traps (seen in prior sweeps)

- **Image automation "no tags in database":** the image-reflector-controller keeps its
  scanned-tag DB in ephemeral storage. After a reflector restart, the ImageRepository's
  cached `.status` makes it report "tags did not change" and it never re-populates the
  DB, so ImagePolicies go `READY=False / no tags in database` and first-party image
  auto-updates (bluevulpine-blog, helium-archiver) silently stop. Fix: delete the
  ImageRepository objects and reconcile the per-app KS (`bluevulpine-blog`,
  `helium-archiver-image`) so Flux recreates them fresh → policies resolve. Recurs on
  every reflector restart.
- **Operators installed via the bjw-s app-template chart** carry non-standard labels
  (`app.kubernetes.io/name=...`), so upstream operator assumptions (self-RBAC, generated
  NetworkPolicies keyed on `control-plane=controller-manager`) can silently break. A
  degraded operator may still report its CR `Ready` while not reconciling. See the
  dragonfly notes in `rollout-and-health.md`.
