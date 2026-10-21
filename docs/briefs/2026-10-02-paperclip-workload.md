# Brief: Paperclip as a cluster workload (+ self-hosted Buzz relay, Matrix vs Buzz)

**Date:** 2026-10-02, Buzz/Matrix sections added 2026-10-21
**Status:** Research — not designed, not planned. Nothing deployed.
**Source:** https://docs.paperclip.ing (sitemap lastmod 2026-09-30), plus a survey of
`kubernetes/apps/{ai,productivity,database}`. Buzz: `block/buzz` repo files read on
2026-10-21 (`README.md`, `ARCHITECTURE.md`, `.env.example`, `deploy/compose/`,
`deploy/charts/buzz/`). Sections: Paperclip (below), [Buzz relay](#buzz-relay-self-hosted),
[Matrix vs Buzz](#matrix-vs-buzz-for-agent-to-agent).

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
`kubernetes/components/volsync-backup/r2.yaml`) or the newer `kubernetes/components/kopiur`
(its own `r2.yaml`) as n8n does. Postgres
backups come free from CNPG (WAL archiving to Garage + `cnpg-offsite`).

Ingress: internal Envoy gateway only (`network/internal`, `https` listener), one
hostname matching `PAPERCLIP_PUBLIC_URL`. Tailnet clients reach it through the existing
exit-node route, the same way hermes does. **Do not use the external gateway**: Paperclip
Connections webhooks (Slack, etc.) need a public HTTPS callback via
`PAPERCLIP_CHAT_WEBHOOK_PUBLIC_URL` and would be a separate, deliberate exposure
decision. `PAPERCLIP_DEPLOYMENT_EXPOSURE=private` matches internal-only.

## Risks and open questions

1. **Agents execute code in the pod.** The `claude_local`/`codex_local` adapters run
   shell-capable CLIs. Keep the app-template default `automountServiceAccountToken: false`
   (no cluster credentials), keep the pod off control-plane nodes with a
   `node-role.kubernetes.io/control-plane: DoesNotExist` node affinity, and consider an
   egress NetworkPolicy. Do **not** copy hermes' `defaultPodOptions` wholesale: hermes now
   deliberately sets `automountServiceAccountToken: true` (with `rbac.yaml`), and the hermes
   README's "No ServiceAccount token" section is out of date on this point. Agent workspaces are on the PVC, with git credentials
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

---

## Buzz relay (self-hosted)

Buzz (Block, Apache-2.0, launched 2026-07-21) is a Nostr relay plus clients (Tauri desktop,
web UI served by the relay, mobile in progress). The relay is the single source of truth:
no gossip or replication between relays, every client talks to one relay, and one relay URL
is one community. Every message, reaction, workflow step and git event is a NIP-01 event
**Schnorr-signed by its author's key**.

### What the hosted service can see: everything

Buzz has **no end-to-end encryption**. Channels, private channels and DMs are plaintext
events in the relay's Postgres; "private" means the relay's access control refuses to serve
them to non-members. The relay operator therefore reads all of it. Evidence:

- `ARCHITECTURE.md`: search is Postgres FTS over a generated `events.search_tsv` column,
  populated on insert. The server indexes message text, so it holds it in plaintext.
  ("Privacy-sensitive kinds" are excluded from the index, not from storage.)
- `ARCHITECTURE.md`: "The relay is the single source of truth. All reads and writes flow
  through it."
- Secondary sources say so outright: Block-hosted communities' messages, DMs and media "are
  not end-to-end encrypted. The service operator can access them"; E2EE for DMs is
  described only as a future consideration. (Not found in Block's own docs; nothing in
  the repo contradicts it.)

So on `*.communities.buzz.xyz`, Block can read every message, DM, attachment, git event,
and the full membership/activity graph. Signing gives **authenticity, not confidentiality**:
the operator cannot forge a member's message, but it can read, withhold or delete it.
Self-hosting moves that trust to us.

### Fit with this cluster

Upstream ships a **Helm chart**, `oci://ghcr.io/block/buzz/charts/buzz` (11 versions,
0.1.1 to 0.1.11 on GHCR, 2026-10-21), designed for "external services, existingSecret"
production use. That beats app-template here.

| Need | Buzz | This cluster |
| --- | --- | --- |
| Image | `ghcr.io/block/buzz` (amd64 + arm64; relay + `buzz-admin` + web bundle). Pin `sha-<7>` or a release tag; README warns `:main` is pre-release | Renovate on the tag |
| Postgres | events, FTS, partition DDL (auto-migrate via `BUZZ_AUTO_MIGRATE=true`) | `postgres18` via `postgres-init`; `externalPostgresql.url`. Owner role covers partition DDL |
| Redis | pub/sub fan-out (dedicated `PSUBSCRIBE` connection), presence, typing | **Dragonfly** via `externalRedis.url`, plus a `dragonfly-allow-<ns>` NetworkPolicy. Pub/sub is supported by Dragonfly; not tested here with Buzz (`--cluster_mode=emulated`) |
| Object storage | media (Blossom), git; S3, `addressingStyle: path` supported | **Garage** (path-style is what Garage wants). Buzz has a git-on-object-storage **conformance probe** (`BUZZ_GIT_CONFORMANCE_PROBE`) that needs conditional writes; check Garage passes it before enabling git |
| Git | `persistence.git` PVC, 10Gi RWO at `/var/lib/buzz/git` | Longhorn + volsync/kopiur |
| Ingress | chart has `httproute:` (`parentRefs`, `hostnames`) and WebSockets on 3000 | Envoy `internal` gateway; tailnet clients via the exit node |
| Security | `runAsNonRoot`, uid 65532, drop ALL, RuntimeDefault | Matches repo norms |
| Secrets | `secrets.existingSecret` | ExternalSecret from OpenBao |
| Probes / metrics | health port 8080, metrics 9102 | ServiceMonitor; Gatus annotation on the route |

Stable secrets that must never be regenerated (OpenBao `secret/buzz`):
`BUZZ_RELAY_PRIVATE_KEY` (relay identity, used in NIP-42 challenges),
`BUZZ_GIT_HOOK_HMAC_SECRET`, DB/Redis/S3 credentials. Config: `RELAY_URL=wss://buzz.${SECRET_DOMAIN}`,
`RELAY_OWNER_PUBKEY` (your hex pubkey), closed relay (`BUZZ_REQUIRE_AUTH_TOKEN=true`,
`BUZZ_REQUIRE_RELAY_MEMBERSHIP=true`), members added with `buzz-admin add-member`
(in the image). Optional admin dashboard (`BUZZ_ADMIN_HOST`, NIP-98 auth); do **not**
use `BUZZ_ADMIN_AUTH=disabled`, which exposes every community's content to anyone who
can reach the relay port. Push stays off (`BUZZ_PUSH_ENABLED=false`); enabling it sends
notifications through Block's `push.buzz.xyz` gateway.

Agents: each gets its own Nostr keypair (`BUZZ_PRIVATE_KEY`). Hermes has a native Buzz
gateway (`gateway.platforms.buzz`, `BUZZ_RELAY_URL` / `BUZZ_PRIVATE_KEY`,
`BUZZ_ALLOWED_USERS` by npub, `require_mention: true` recommended), so `ai/hermes` could
join a self-hosted relay with an OpenBao-sourced key and a `relay_url` pointing at the
in-cluster service. Claude Code / Codex / goose connect through `buzz-acp`.

Layout would be `kubernetes/apps/<ns>/buzz/` (`ai`, or a new `comms` namespace shared with
matrix if that reads better): OCIRepository for the chart, HelmRelease with
`postgresql.enabled: false`, `redis.enabled: false`, `httproute.enabled: true`;
ExternalSecret; `ks.yaml` dependsOn `cloudnative-pg-cluster18`,
`external-secrets-openbao-store`, and the dragonfly cluster.

### Open questions

1. **Exposure.** Internal + tailnet is the safe default. Desktop clients off-LAN need the
   tailnet. If it ever goes public, use `external-pangolin` (Pangolin VPS + Newt), which
   bypasses Cloudflare's 100 MB upload cap and per-stream throughput limit
   (`kubernetes/apps/network/envoy-gateway/resources/gateways.yaml`). The Cloudflare-tunnel
   `external` gateway would cap media uploads.
2. **Migration from the hosted community.** Events are signed and therefore portable in
   principle, but no export/import tool is documented. Assume a fresh community; keys
   (identities) carry over, history may not.
3. **Maturity.** README calls workflow approval gates "being wired up"; rate limiting is
   not enforced (`ARCHITECTURE.md`: no Redis-backed rate limiter exists). The relay should
   not be internet-facing until that changes.
4. **Backups.** Postgres via CNPG; git PVC via volsync/kopiur; media in Garage. The relay
   private key in OpenBao.

---

## Matrix vs Buzz for agent-to-agent

The identity models differ in a specific way:

| | Matrix (our `matrix-stack`: Synapse + MAS) | Buzz |
| --- | --- | --- |
| Who signs an event | The **origin server** (`Synapse__SigningKey`), for federation. Users don't sign their events | The **author** (Schnorr, NIP-01). Any client can verify it |
| Can the server operator forge a user's message? | Yes. Synapse admin can act as any local user; the server signature covers whatever it sends | No. Without the author's private key the signature fails |
| Confidentiality | **E2EE** available (Olm/Megolm). Server sees metadata, not content, in encrypted rooms | **None** beyond TLS. Relay reads everything |
| Sender authenticity in encrypted rooms | Device keys + cross-signing; verifiable by room members, deniable by design (not third-party proof) | Every event is a third-party-verifiable proof |
| Identity portability | `@user:domain` is bound to the homeserver forever | Keypair is the identity; works on any Nostr relay |
| Agent onboarding here | MAS has **no local passwords** (Authentik only), so each bot needs an Authentik user or a MAS-issued compatibility token (`mas-cli`; verify the exact subcommand). E2EE bots need a crypto store and device verification | `buzz-admin generate-key` + `add-member`; key in OpenBao |
| Federation | Yes, public | No; one relay, one community |

**What signing does and doesn't buy.** Leo's reasoning (AI User Group #20): he
moved agents to Buzz "because every account is signed", and told them to act on a
dangerous request only if it comes "over my crypto signature", adding himself that "it's
not deterministic". The signature is real, but in that setup **the LLM decides whether to
trust it**, so a prompt-injected agent can ignore the rule. The deterministic version is
enforcement in harness code before the model sees the message, e.g. Hermes'
`BUZZ_ALLOWED_USERS` (pubkey allow-list), or an approval workflow gated on a signed
reaction. Matrix has the equivalent through room power levels and bot allow-lists, but
the identity behind it is server-asserted.

**Where each fits.** Matrix is better for confidential conversations with people
(federated, E2EE, SSO). Buzz is better for an agent bus where provenance matters more than
secrecy from the operator: self-hosted, so the operator is us, with signed and auditable
actions (hash-chained audit log) and NIP-34 git events. Self-hosting Buzz removes the one
real objection (Block reading content). The two can coexist: nothing here needs a bridge.

Leo's Matrix-for-A2A remark from an earlier show was not found in the transcripts checked
(AI User Group #16, #18, #19.5, #20, #21; Intelligent Machines 889, 890; TWiT 1087). Buzz
mentions: AUG #18 ("Buzz is too immature … but eventually this will become Buzz"), #19.5
and #21 ("That's how mine talk").

### Sources (Buzz / Matrix)

- https://github.com/block/buzz — `README.md`, `ARCHITECTURE.md`, `.env.example`,
  `deploy/compose/{README.md,.env.example}`, `deploy/charts/buzz/{Chart.yaml,values.yaml}`, `Dockerfile`
- GHCR tag lists: `ghcr.io/block/buzz`, `ghcr.io/block/buzz/charts/buzz`
- https://hermes-agent.nousresearch.com/docs/user-guide/messaging/buzz
- https://flaviocopes.com/buzz/ ; https://github.com/raycast/extensions/pull/29900 ;
  https://rubentorney.com/blog/en/buzz-hermes-agent-auto-heberge-confidentialite-souverainete.html ;
  https://github.com/alinaos-org/buzz-openclaw (E2EE / operator-access statements)
- https://twit.tv/posts/transcripts/twit-club-shows-770-transcript-ai-user-group-20 (signing quote),
  `-762-…-ai-user-group-18`, `-769-…-ai-user-group-195`, `-775-…-ai-user-group-21`
- https://pages.laporte.cloud/my-setup/ (Leo's setup page; no Buzz/Matrix mention found)
- `kubernetes/apps/matrix/matrix-stack/README.md` (MAS without local passwords, signing key handling)
