# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project knowledge

Serena is configured for this repo. At session start, activate the project and read `mem:core` for the source map and cluster topology. Follow references from there to `mem:tech_stack`, `mem:conventions`, `mem:suggested_commands`, and `mem:task_completion` as the task requires — do not load all memories up front.

## Critical rules

**Domains — which are public**: `derekjacobs.dev` (`SECRET_DOMAIN`) and `bluevulpine.net`
(`SECRET_DOMAIN_BLOG`) are **public** (decided 2026-10-04). They are already tied to this repo by
commit authorship and the `bluevulpine` GitHub owner, and their public hosts are in CT logs, so a
placeholder hides nothing. Prefer the existing `${SECRET_DOMAIN*}` placeholders anyway (no mass
rewrite), but a literal is acceptable where a placeholder cannot render — e.g. CoreDNS values,
which `bootstrap/helmfile.d` reads raw with no Flux substitution. The **other** domains
(`SECRET_DOMAIN_BLOGCOM`, `_MEDIA`, `_LAKE`, `_YOYO`, `_BON`) stay **hidden**: always use the
placeholder, never a literal.

**SOPS-encrypted files** (`*.sops.yaml`): never write decrypted content to disk. Use `sops -d <file>` to view and `sops <file>` to open the editor. Plaintext secrets must not appear in any file tracked by git (gitleaks runs on every pre-commit).

**Talos machine config** is rendered by topf from `talos/topf.yaml` + `talos/patches/` + `talos/schematics/` + the PKI in `talos/secrets.sops.yaml`; there is no generated directory to edit. `topf render -o <dir>` writes PLAINTEXT configs (PKI included): render into a `mktemp -d`, never into the tree, and delete it. `talos/talosconfig` (client admin cert + key, gitignored) comes from `topf talosconfig > talos/talosconfig`. Apply with `just talos apply-node <host>` / `apply-all`.

**YAML formatting**: all `.yaml` files except `*.sops.yaml` and `talos/topf.yaml` (partially SOPS-encrypted; yamlfmt would reformat the ciphertext) must pass `yamlfmt`. Block-style arrays, `---` document start, LF line endings. Lefthook enforces this on pre-commit — do not skip hooks.

**`crds: CreateReplace`** is injected globally via the `cluster-apps` Flux patch; do not add it to individual HelmRelease manifests.

**Commit authorship for agent-written changes**: each agent commits under its
own credential where one exists, so git history is the identity register.
Agents on a shared bot credential (currently
`bluevulpine-bot[bot] <188733095+bluevulpine-bot[bot]@users.noreply.github.com>`)
MUST self-identify on every commit: author with per-command flags
(`git -c user.name=... -c user.email=... commit` — **never** `git config`, which
inside a worktree writes the shared `.git/config` and silently rewrites the
human's repo-local identity), plus trailers naming the agent and its harness:

```
Co-Authored-By: Bosun <bosun@users.noreply.github.com>
Agent-Harness: hermes-agent
```

Known agents: Fizz (`fizz-bot-bvn[bot]`, Buzz framework), Bosun
(`bluevulpine-bot[bot]`, Hermes Agent harness), Deckhand (`deckhand-bot-bvn[bot]`,
Hermes Agent harness, Paperclip-driven Renovate triage). New agents should get
their own GitHub App rather than silently joining a shared one.
**Do not infer authorship convention from `git log`**: every non-Renovate commit
before 2026-09-09 is authored `Derek Jacobs` because the bot account did not
exist yet, not because human authorship is the convention. The point of bot
accounts is that what an agent commits is clearly separate from what Derek
commits.

**Commit messages use Scoped Commits, never Conventional Commits**: the subject
is `<scope>: <description>` where the scope is the app, component or area
changed (the directory name, e.g. `thanos`, `tailscale`, `actions-runner-controller`)
and the description starts lowercase and says what changed. Several scopes are
comma-separated (`litellm, hindsight: ...`). No `feat:`/`fix:`/`chore:`/`docs:`/`ci:`
type prefix and no `(scope)` parentheses, even when the word names a directory.
For a change that only touches documentation, use the specific area as the
scope (`CLAUDE.md: ...`, `runbooks: ...`), not `docs:`. This applies to PR titles
too: PRs are merged with merge commits, so the title is what appears in `main`'s
history (on the merge commit's second line).
Automated commits keep their own format and are the exceptions: Renovate
(`:semanticCommits`, `.renovate/semanticCommits.json5`) and Flux image automation
(`chore(images):`). Do not retitle their PRs or change their templates to match.
Do not infer the rule from `git log` either: automated commits and older history
use other styles.

**Renovate version tracking**: annotate a version with `# renovate: datasource=...` when
Renovate cannot detect it natively — a bare version string in `talos/topf.yaml`, a URL
containing a version, a tool pinned in a script. See `talos/topf.yaml` for the pattern.
The annotation goes on the line *directly above* the value (`#1715` fixed one that was
misplaced).

Three cases where the rule is **not** "always annotate":

- **app-template nested container images** (`controllers.*.containers.*.image`) are detected
  natively with no annotation. `kubernetes/apps/productivity/n8n` has none and Renovate has
  opened nine bump PRs for it (#1695, #1617, #1594, …). Annotating anyway is fine and ~47 of
  111 HelmReleases do — the repo is deliberately mixed here. Prefer no annotation for a plain
  semver tag; add one when you want an explicit datasource/depName, as `hermes` (#1743) and
  `timescaledb` (#1715) do.
- **A HelmRelease's top-level `image.repository`/`image.tag`** is already extracted by the
  built-in **`flux`** manager, which parses `values:` inside Flux HelmRelease CRs. Adding an
  annotation there makes **two managers match one line and Renovate open two PRs for one
  bump** — this happened to `gitea` three times (#1389, #1540, #1681). Do not annotate these.

  **`helm-values` is not the manager involved**, despite the name looking right: per
  Renovate's docs it only matches files literally named `values.yaml`/`values.yml`, so it can
  never match a `helmrelease.yaml`. Two successive fixes suppressed the wrong manager and the
  duplicate kept slipping through. `.renovate/overrides.json5` is the authority here and
  explains it at length — read it rather than re-deriving.
- **`chartRef` / OCIRepository versions** are also `flux`-managed. No annotation.

If you add an annotation, check the Renovate Dependency Dashboard (issue #1) afterward for a
duplicate entry.

## Adding a new application

Follow the existing layout under `kubernetes/apps/<namespace>/<app>/`:
- `namespace.yaml` + `kustomization.yaml` at the namespace level
- `app/helmrelease.yaml` using an OCIRepository ref and an `&app` name anchor. **Do not add
  `install.strategy` / `upgrade.strategy`** — the `cluster-apps` patch injects
  `strategy: {name: RetryOnFailure}` into every HelmRelease, the same mechanism as the
  `crds: CreateReplace` rule above. No manifest in the repo declares it (0 of 113).
  An explicit `install.remediation.retries` / `upgrade.cleanupOnFail` /
  `upgrade.remediation.strategy: rollback` block is **optional**, not standard: 58 of 113
  HelmReleases carry one, and the `app-template` web apps a new app usually patterns itself on
  (mosquitto, homebox, vaultwarden) do not.
- `app/externalsecret.yaml` if runtime secrets are needed (pull from OpenBao via External Secrets Operator — `secretStoreRef: openbao`)
- Include `# yaml-language-server: $schema=...` at the top of every Kubernetes manifest.
  **Confirm the URL returns JSON before copying one from a neighbouring file.**
  `kubernetes-schemas.pages.dev` answers **`200` with an HTML page** for any group it does not
  host — indistinguishable from a live schema by status code alone — and it does not host
  `image.toolkit.fluxcd.io` at all. For those kinds use
  `https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/<kind>-image-v1.json`.

Secrets come exclusively from OpenBao via `ExternalSecret` (`secretStoreRef` → `openbao` / `ClusterSecretStore`, `engineVersion: v2`). OpenBao field naming is PascalCase double-underscore: `App__Category__Field` (e.g. `Frigate__Mqtt__User`). Never commit secret values.

## Flux image automation (first-party Drone images)

Auto-updating a Gitea-hosted image tag needs an `ImageRepository` + `ImagePolicy`
+ `ImageUpdateAutomation` set under `kubernetes/apps/flux-system/<app>/app/`, plus
a `$imagepolicy` marker on the image line. Two rules that are easy to get wrong
and fail silently (a bad marker suffix caused a 14h `kia-collector` outage):

- **Marker suffix matches the node.** Combined `image: repo:tag` scalar → **no**
  `:tag` suffix (`{"$imagepolicy": "flux-system:<app>"}`). Dedicated `tag:`
  subfield → **`:tag`** suffix. A `:tag` marker on a combined scalar overwrites it
  with the bare tag → `ImagePullBackOff`.
- **One automation per app, `update.path` scoped to that app's dir.** `Setters`
  rewrites every marker under the path, so a `./kubernetes` (whole-repo) scan
  silently drives other apps' images.

Full pattern, gotchas (incl. ImagePullBackOff not tripping job-failure alerts, and
Grafana `${...}` vs postBuild envsubst) and diagnosis commands:
**`docs/runbooks/flux-image-automation.md`**.

## Validating changes

Run `lefthook run pre-commit` before committing. For a broader local diff against the cluster:

```bash
flux-local test
```

To apply a single app's kustomization directly:

```bash
just kube apply-ks kubernetes/apps/<namespace>/<app>
```

**Pushing to `main` auto-reconciles.** A GitHub webhook triggers Flux the moment
a push lands on the trunk — reconciliation is near-instant, not on the poll
interval. Do **not** run `flux reconcile ...` after a push; just wait a moment and
verify the cluster reflects the change (e.g. `kubectl get <resource> -o jsonpath=...`).
Only reconcile manually if the webhook path is known-broken or you pushed to a
non-trunk branch.

## Querying metrics: use Thanos, not Prometheus

**Prometheus retains only 2 days.** That is deliberate — it is the standard
Thanos pattern (short local window, sidecar ships blocks to object storage).
Long-term history lives in Thanos:

| | endpoint | retention |
| --- | --- | --- |
| Prometheus (local) | `kube-prometheus-stack-prometheus.observability.svc:9090` | **2d only** |
| **Thanos (use this)** | `thanos-query-frontend.observability.svc:10902` | raw 14d / 5m 30d / **1h 60d** |

Both speak the same `/api/v1/query` and `/api/v1/query_range` API, so the only
difference is the host. Querying Prometheus for anything older than 48h returns
a truncated series that *looks* like "we don't collect that" rather than an
error — which is exactly how a 2026-08-13 gateway investigation initially
concluded there was no history, when 60 days of it existed in Thanos.

Do **not** "fix" this by raising `retention:` in the kube-prometheus-stack
HelmRelease. It would duplicate what Thanos already stores. (For sizing context
if it ever does come up: ~2.2 GB/day, on a 105 GB PVC using 5.8 GB.)

Two traps when reading the results:

- **Aggregate away label churn.** Exporters that restart with changed labels
  split one logical series into many. `unpoller_device_memory_utilization_ratio{name="Morpheus"}`
  was 7 separate series over 60d; without `max by(name)(...)` you silently get
  one fragment and misread the trend.
- **A flat series is not proof of no signal.** Check the multi-day shape before
  concluding a metric is useless — the same UDM memory ratio looked flat and
  uninformative over 44h but was a clean sawtooth over 60d.

## Postgres bootstrap: the `postgres-init` init container

Apps that need a Postgres database on the CloudNativePG `postgres18` cluster never
hand-create the role or database: they run the `postgres-init` init container, wired
through the HelmRelease + ExternalSecret. **It RESETS the role's password on every
start**, so rotating a credential is `bao kv patch` plus a pod roll, never a hand-written
`ALTER ROLE`. The full wiring, env table, multi-database variant, `dependsOn` trap and
reference implementations are in the `postgres-init` skill
(`.claude/skills/postgres-init/SKILL.md`); invoke it when adding or rotating one.
