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

**Renovate version tracking**: annotate a version with `# renovate: datasource=...` (on the
line directly above it) where Renovate cannot detect it natively, such as a bare version in
`talos/topf.yaml`, a URL or a script pin. App-template nested images are deliberately mixed:
an annotation there is optional, not a violation. **Never annotate a HelmRelease's top-level
`image.repository`/`image.tag` or a `chartRef`/OCIRepository version**: the `flux` manager
already tracks them and a second match opens duplicate PRs. The full rules and history are in
the `renovate-annotations` skill (`.claude/skills/renovate-annotations/SKILL.md`); read it
before adding or removing an annotation.

## Adding a new application

Apps live under `kubernetes/apps/<namespace>/<app>/`. Do not add `install.strategy` /
`upgrade.strategy` to a HelmRelease: the `cluster-apps` patch injects it, like
`crds: CreateReplace`. Secrets come exclusively from OpenBao via `ExternalSecret`
(`secretStoreRef: openbao`); never commit secret values. The layout, HelmRelease shape,
OpenBao field naming and the schema-URL check are in the `new-app` skill
(`.claude/skills/new-app/SKILL.md`); invoke it when adding an app.

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

The `image.toolkit.fluxcd.io` kinds take their `$schema` from
`https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/<kind>-image-v1.json`:
`kubernetes-schemas.pages.dev` does not host that group and answers `200` with an HTML page.

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

**Prometheus retains only 2 days**, deliberately. Query history from Thanos at
`thanos-query-frontend.observability.svc:10902` (same API). Prometheus returns a truncated
series for older ranges, not an error, so a wrong endpoint looks like missing data. Do not
raise Prometheus `retention:`. Before raising Thanos store-gateway memory limits after an
OOMKill, check `thanos_compact_halted`. Retention tiers, the halted-compactor check and two
series-reading traps are in the `querying-metrics` skill
(`.claude/skills/querying-metrics/SKILL.md`); invoke it before querying metrics.

## Postgres bootstrap: the `postgres-init` init container

Apps that need a Postgres database on the CloudNativePG `postgres18` cluster never
hand-create the role or database: they run the `postgres-init` init container, wired
through the HelmRelease + ExternalSecret. **It RESETS the role's password on every
start**, so rotating a credential is `bao kv patch` plus a pod roll, never a hand-written
`ALTER ROLE`. The full wiring, env table, multi-database variant, `dependsOn` trap and
reference implementations are in the `postgres-init` skill
(`.claude/skills/postgres-init/SKILL.md`); invoke it when adding or rotating one.
