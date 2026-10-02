# Brief: Paperclip as a cluster workload

**Date:** 2026-10-02
**Status:** Research — not designed, not planned. Nothing deployed.
**Source:** https://docs.paperclip.ing (sitemap lastmod 2026-09-30), plus a survey of
`kubernetes/apps/{ai,productivity,database}`.

## What it is

Paperclip is a Node/TypeScript control plane that orchestrates AI coding agents
("companies", agents, issues, routines, budgets, approvals). It does not run models
itself: **adapters** launch CLI agents (`claude_local`, `codex_local`, `gemini_local`,
`opencode_local`, `hermes_local`, ...) as child processes inside its own container, or
call out over HTTP (`hermes_gateway`, `openclaw_gateway`, `http`).

## Runtime facts (from the deploy docs)

| Item | Value |
| --- | --- |
| Image | `ghcr.io/paperclipai/paperclip:{latest,beta,nightly,canary}`, plus `<version>` and `sha-<short>` tags. **Use the plain tag, not `-cloud`** (cloud variant only adds sandbox-provider plugins). Docs say the image is built `--target production`. |
| Versioning | Calendar: `YYYY.MDD.P` (e.g. `2026.525.0`). Renovate-friendly, but the image tag form (`v` prefix or not) needs checking against GHCR. |
| Port | `3100`; binds `127.0.0.1` unless `HOST=0.0.0.0` (or `PAPERCLIP_BIND`) |
| Health | `GET /api/health` |
| State dir | `PAPERCLIP_HOME` (image convention `/paperclip`): embedded PG (if no `DATABASE_URL`), uploads, **secrets master key**, agent workspaces |
| Mode | `PAPERCLIP_DEPLOYMENT_MODE=authenticated`, `PAPERCLIP_DEPLOYMENT_EXPOSURE=private`, `PAPERCLIP_AUTH_BASE_URL_MODE=explicit`, `PAPERCLIP_PUBLIC_URL=https://paperclip.${SECRET_DOMAIN}`, `PAPERCLIP_ALLOWED_HOSTNAMES=paperclip.${SECRET_DOMAIN}` |
| Proxy | `TRUST_PROXY=1` when behind Envoy (unset trusts nothing, so rate limiting sees the gateway IP) |
| Required secrets | `BETTER_AUTH_SECRET` (stable across restarts), `PAPERCLIP_AGENT_JWT_SECRET`, `PAPERCLIP_TOOL_ACTION_SIGNING_SECRET` (no fallback; signed tool approvals fail without it) |
| Auth | Better Auth, **email + password only** documented. No OIDC/Authentik path is documented (contrast `hermes`). |
| First boot | Authenticated mode prints a one-time `/board-claim/<token>?code=<code>` URL in the log; open it to become instance admin. Restart mints a new one. |
| Updates | Self-managed `paperclipai update` is for npm installs; in-cluster, bump the image tag via Renovate. **DB migrations run on upgrade and are not reversed by rollback.** |

## What it can reuse from this cluster

### Postgres: yes, required in practice

`DATABASE_URL` switches it off the embedded Postgres. Docs: embedded PG is
"intentionally local"; production uses hosted Postgres. Also supported:
`DATABASE_MIGRATION_URL` (separate DDL role). Plain Postgres via Drizzle ORM, with
migrations run at boot.

Map onto the existing pattern exactly as `productivity/n8n` does:

- `postgres-init` init container (`ghcr.io/home-operations/postgres-init:rolling`),
  `INIT_POSTGRES_*` from `paperclip-secret`, superuser from the shared
  `cloudnative-pg` key.
- Compose `DATABASE_URL` in the ExternalSecret template:
  `postgres://{{ .Paperclip__PostgresUser }}:{{ .Paperclip__PostgresPass }}@${POSTGRES_HOST}:5432/{{ .Paperclip__DbName }}`
  (URL-encode the password or use a hex/alnum one).
- `ks.yaml` `dependsOn`: `cloudnative-pg-cluster18` (database) and
  `external-secrets-openbao-store` (external-secrets). Not `cloudnative-pg-cluster`.
- Use the direct `postgres18-rw` service, not a pooler (the docs warn about running
  migrations through a pooled endpoint; they also say a pooled connection needs
  `prepare: false`, which is a code change).
- Open question: does it need extensions or `CREATE`-on-schema beyond ownership? The
  owner role from postgres-init should cover Drizzle; confirm on first boot.

### Dragonfly (Redis): not needed

Searched all 267 pages in the sitemap for redis/dragonfly/valkey. The only hits are
unrelated words in plugin/API/changelog text. **No Redis dependency is documented**, so
skip the dragonfly NetworkPolicy and secret plumbing. Revisit if a plugin asks for one.
(If it ever does: `dragonfly.database.svc.cluster.local:6379` is ready, but a
`NetworkPolicy` `dragonfly-allow-<ns>` is required per client namespace; see
`database/dragonfly/cluster/networkpolicy.yaml`. `litellm` is the model, with its
namespaced key prefix.)

### Object storage (Garage S3): optional, deferred

Storage provider is `local_disk` (default) or `s3` (AWS/MinIO/R2). Configured by
`paperclipai configure --section storage` into the instance config file, not obviously
env-driven. With a single replica on a PVC, `local_disk` is enough and is covered by
volsync/kopiur. Garage is in the cluster (`secret/garage`) if multi-replica ever matters.
**Verify an env path exists before relying on S3**; the docs only show the CLI.

### LiteLLM gateway: probably the best LLM wiring

`ai/litellm` is the in-cluster gateway, with per-app virtual keys
(`LiteLLM__Keys__<App>` in `secret/litellm`, restricted models and parallelism, as
`n8n` does). Anthropic-compatible clients accept a base URL override, so
`claude_local` agents can be pointed at it with `ANTHROPIC_BASE_URL` +
`ANTHROPIC_API_KEY=<virtual key>` in the adapter `env`. This keeps spend and rate limits
in one place and avoids a raw provider key in Paperclip. Caveat: Claude Code's
Max/OAuth flow cannot go through LiteLLM; only API-key mode can.

### Hermes: an existing sibling

`ai/hermes` is already running. Paperclip has a `hermes_gateway` adapter (HTTP/SSE to a
Hermes API server, `apiKey` = Hermes `API_SERVER_KEY`). Today Hermes deliberately binds
its API to container loopback (`API_SERVER_HOST=127.0.0.1`) and keeps it out of the
Service, so using it from Paperclip means a **deliberate, security-relevant change**:
exposing 8642 to the pod network and a NetworkPolicy limiting it to the paperclip pod.
Alternative: `hermes_local`, which launches Hermes as a child process inside the Paperclip
container (the image would need the CLI). Recommend leaving this out of v1.

### Secrets: OpenBao / ESO

All secrets via `ExternalSecret` to `openbao`; PascalCase keys: `Paperclip__PostgresUser`,
`Paperclip__PostgresPass`, `Paperclip__DbName`, `Paperclip__BetterAuthSecret`,
`Paperclip__AgentJwtSecret`, `Paperclip__ToolActionSigningSecret`. Paperclip also has its
own secret store (`local_encrypted`, master key on disk under `PAPERCLIP_HOME`, override
via `PAPERCLIP_SECRETS_MASTER_KEY`). **Set `PAPERCLIP_SECRETS_MASTER_KEY` from OpenBao**
so the key is not only on the PVC, and set `PAPERCLIP_SECRETS_STRICT_MODE=true`. Provider
vaults only support AWS Secrets Manager today; there is no OpenBao/Vault integration
(HashiCorp Vault is draft metadata only), so ESO-injected env is the path.

## Fit with repo patterns

Closest analogues: `ai/hermes` (agent harness, single RWO PVC, `Recreate`, Reloader,
Envoy HTTPRoute) and `productivity/n8n` (Postgres via postgres-init, ExternalSecret,
kopiur).

Proposed layout `kubernetes/apps/ai/paperclip/` (namespace `ai` already exists and is
allowed by the dragonfly policy, should that ever matter):

```
ks.yaml                      # dependsOn cloudnative-pg-cluster18, external-secrets-openbao-store,
                             # kopiur-repositories (if using components/kopiur)
app/
  kustomization.yaml         # components: volsync-claim + (kopiur | volsync-backup)
  ocirepository.yaml         # bjw-s app-template, same tag as hermes (5.2.1 at time of writing)
  helmrelease.yaml
  externalsecret.yaml
  httproute.yaml             # parentRef internal/network:https; gethomepage + gatus annotations
```

Then add `./paperclip/ks.yaml` to `kubernetes/apps/ai/kustomization.yaml`.

HelmRelease notes:

- `strategy: Recreate` (one PVC, RWO; Paperclip runs agent processes and workspaces on it).
- `reloader.stakater.com/auto: "true"`.
- Probes: HTTP `/api/health` on 3100 (plain `httpGet` works since it binds `0.0.0.0`).
- `HOST: 0.0.0.0`, `PAPERCLIP_HOME: /paperclip`, `PAPERCLIP_BIND` left to default or `lan`.
- Resources: docs suggest 1 vCPU / 2 GB for the VPS case; start at ~200m / 1Gi request and a
  memory limit around 4Gi, since agent CLIs are spawned in-container.
- Security context: the docs do not state the image's user. Check the `Dockerfile`
  before choosing between `runAsNonRoot` + `fsGroup` (n8n pattern) and the hermes
  root-then-drop pattern. The npm-oriented docs warn Postgres refuses to run as root, but
  that applies to the embedded DB, which we turn off.
- Do not add `install.strategy`/`upgrade.strategy` or `crds:` (injected by `cluster-apps`).
- Renovate: an app-template nested container image with a plain semver tag is detected
  natively; but this uses calendar versions with possible `v` prefix, so consider an
  explicit `# renovate: datasource=docker depName=ghcr.io/paperclipai/paperclip` annotation
  as `hermes` does. Check the Dependency Dashboard (#1) for duplicates afterward.
- Pin the OCI chart tag to match `hermes`/`n8n` to avoid Renovate churn.

Storage/backup: PVC of ~20Gi (workspaces accrue git checkouts). The PVC carries the
secrets master key unless overridden, so back it up. Reuse the hermes volsync settings
(`longhorn-1-replica-local`, `Snapshot` copy method, offset cron from the grid in
`components/volsync/r2.yaml`) or the newer `components/kopiur` as n8n does. Postgres
backups come free from CNPG (WAL archiving to Garage + `cnpg-offsite`).

Ingress: internal Envoy gateway only (`network/internal`, `https` listener), one
hostname matching `PAPERCLIP_PUBLIC_URL`. Tailnet clients reach it through the existing
exit-node route, the same way hermes does. **Do not use the external gateway**: Paperclip
Connections webhooks (Slack, etc.) need a public HTTPS callback via
`PAPERCLIP_CHAT_WEBHOOK_PUBLIC_URL` and would be a separate, deliberate exposure
decision. `PAPERCLIP_DEPLOYMENT_EXPOSURE=private` matches internal-only.

## Risks and open questions

1. **Agents execute code in the pod.** The `claude_local`/`codex_local` adapters run
   shell-capable CLIs. Same blast-radius reasoning as the hermes README: no ServiceAccount
   token (app-template default), keep off control-plane nodes (copy hermes' affinity), and
   consider an egress NetworkPolicy. Agent workspaces are on the PVC, with git credentials
   handed to agents as Paperclip secrets.
2. **No SSO.** Local accounts only (Better Auth email/password). Acceptable for a
   single operator on the internal gateway; revisit if teammates are added.
3. **Credentials into agents.** Prefer LiteLLM virtual key (above) over raw
   `ANTHROPIC_API_KEY`. Adapter env secrets must be `secret_ref`s into Paperclip's store
   under strict mode, so they are entered once in the UI and live in Postgres, encrypted
   with the master key. A DB restore without the master key loses them; hence putting the
   key in OpenBao.
4. **Image details unverified.** I could not read the upstream `Dockerfile`/chart
   (this session's GitHub scope is this repo only). Confirm: runtime user/UID, whether
   `/paperclip` is the right mount (docs show `PAPERCLIP_HOME=/paperclip` for the plain
   `docker run`), tag naming, arch support (dragonfly pins `kubernetes.io/arch: amd64` because its image is
   not multi-arch, which suggests the cluster may have non-amd64 nodes; not verified), and whether `HOST` and `PAPERCLIP_BIND` interact.
5. **Calendar-versioned, fast-moving project.** Releases are frequent and
   migrations are one-way; pin the tag, read release notes before merging Renovate PRs.
   No Helm chart is published that I found; app-template is the route.
6. **Gatus/homepage**: add the annotations like hermes; health at `/api/health`.

## Suggested first slice

1. OpenBao keys (`secret/paperclip`), ExternalSecret, postgres-init, HelmRelease with
   `DATABASE_URL`, internal HTTPRoute, volsync claim. No S3, no Redis, no Hermes, no
   public exposure.
2. Claim the board via the log URL; create one company and one `claude_local` agent
   pointed at LiteLLM.
3. Then decide on: kopiur vs volsync, egress policy, Hermes gateway, S3.

Validate with `lefthook run pre-commit` and `flux-local test` before pushing.
