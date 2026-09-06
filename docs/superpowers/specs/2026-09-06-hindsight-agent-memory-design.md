# Hindsight agent memory — design

**Status:** draft, pending adversarial review
**Date:** 2026-09-06
**Requested by:** Derek (`@bluevulpine`)
**Research:** upstream docs read directly; every cluster claim verified against the live
cluster or the repo, and marked below where it is inference instead

## Summary

Add [Hindsight](https://github.com/vectorize-io/hindsight) (MIT, Vectorize.io) as a
long-term memory service for the cluster's agents: Claude Code sessions, the existing
`develop/hermes` agent, Buzz agents, and — later — Home Assistant automations.

Hindsight stores facts and experiences in isolated *banks* and exposes three operations:
`retain` (LLM-extracts facts from a transcript), `recall` (hybrid vector + BM25 + graph +
temporal search, **no LLM call**), and `reflect` (LLM-synthesised answer over many
memories).

**The whole thing is one new pod.** It is stateless; all state lands in the existing
`postgres18` CloudNativePG cluster, which already has everything it needs. No new database,
no new PVC, no new VolSync relationship, no new backup target, no GPU.

## Why this is low-risk

Two Flux `home-ops` repos already run Hindsight with this repo's exact conventions —
`kubernetes/apps/<ns>/<app>/app/`, `app-template` via `OCIRepository`, `&app` anchors,
`${SECRET_DOMAIN}`, ExternalSecret → OpenBao, an `envoy-internal` HTTPRoute. Both place it
in an `ai` namespace, and both run it beside Hermes.

| Repo | Image | Embed / rerank | LLM | Notable |
| --- | --- | --- | --- | --- |
| [`spiceratops/k8s-gitops`](https://github.com/spiceratops/k8s-gitops) | `hindsight-api:0.9.2` (full) | in-process (local BGE + MiniLM) | Gemini `gemini-3.5-flash` | `postgres-init:18` init container — the exact pattern in our CLAUDE.md. Probes commented out. **No tenant auth.** |
| [`deedee-ops/home-ops`](https://github.com/deedee-ops/home-ops) | `hindsight:0.9.2-slim` | offloaded to in-cluster TEI `embedder` + `reranker` | via a `bifrost` LLM gateway | CNPG `Database` CRD with `extensions: vector`; API-key tenant auth on; 3-rule HTTPRoute |

This design follows spiceratops' shape (simpler: no TEI workloads) and borrows
deedee-ops' two genuinely better decisions (tenant auth on; a route that exposes `/v1` and
`/mcp` separately from the UI).

## Verified cluster facts

Everything below was checked against the running cluster or this repo, not assumed:

- `postgres18` runs PostgreSQL **18.2**; `vector` **0.8.1** is *available and not yet
  installed in any database*. Hindsight needs 14+ and pgvector 0.8.0+ (the latter gates
  `ANN_ITERATIVE_SCAN`, which is on by default).
- CloudNativePG operator is **1.30.0**, and `Database.spec.extensions` with
  `ensure: present` **is** supported by the installed CRD.
- Nodes: `brokkr01..03` — amd64, 16 CPU, 62 GiB, currently 7–14% CPU / 20–32% memory.
  `jormungandr1..4` — arm64, 4 CPU, 7.8 GiB, at 32–48% CPU / **39–72% memory**.
- Gateways are `network/internal` and `network/external`; existing HTTPRoutes use
  `parentRefs: [{name: internal, namespace: network, sectionName: https}]`.
- `app-template` **5.1.0** is the house standard (73 of ~85 `ocirepository.yaml` files).
- There is no `ai` namespace today. `develop` (where Hermes lives) is labelled
  `pod-security.kubernetes.io/enforce: privileged` because Nexus needs a root init
  container.
- Latest Hindsight release is **v0.9.2** (2026-08-25).

## Architecture

### Namespace: new `ai`, not `develop`

Create `kubernetes/apps/ai/`. Two reasons, one of them load-bearing:

1. **`develop` is `pod-security: privileged`.** That was a deliberate concession for
   Nexus's `chownDataDir` init container, and it applies namespace-wide. Hindsight needs
   nothing of the sort, and putting a service that terminates agent memory for four
   consumers into a `privileged` namespace throws away enforcement we can have for free.
   `ai` gets `enforce: restricted`.
2. It gives the eventual TEI embedder / reranker / local-inference workloads a home, and
   matches both prior-art repos.

### Workloads

One `Deployment`, one pod, two containers:

| Container | Image | Port | Requests | Limits |
| --- | --- | --- | --- | --- |
| `api` | `ghcr.io/vectorize-io/hindsight-api:0.9.2` | 8888 | 100m / 1Gi | 4Gi |
| `control-plane` | `ghcr.io/vectorize-io/hindsight-control-plane:0.9.2` | 3000 | 50m / 256Mi | 1Gi |

Plus two init containers (see *Database bootstrap*).

The **full** `hindsight-api` image is deliberate: it loads the BGE embedder (~130 MB) and
the MiniLM cross-encoder reranker (~90 MB) in-process, which means embeddings and reranking
need **no external service and no API key**. The `-slim` image is smaller but forces both
onto remote providers or in-cluster TEI — that is the scale-out path, not the starting
point. Upstream's stated minimum for the full API is 1.5 GB, recommended 2 GB; the 4 Gi
limit is headroom for the reranker's batch forward passes.

**No separate worker StatefulSet.** Upstream's chart runs workers as a StatefulSet so each
pod derives a stable `HINDSIGHT_API_WORKER_ID` from its ordinal. At one replica that
machinery buys nothing — set `HINDSIGHT_API_WORKER_ID: hindsight` statically and let the
API run its in-process worker. Both prior-art repos do exactly this. If throughput ever
demands more, that is the moment to adopt the upstream chart, not before.

**Single replica**, `strategy: Recreate`. Scaling past one additionally requires
`HINDSIGHT_API_MCP_STATELESS: "true"` — noted so a future scale-up does not silently break
MCP sessions.

**Node placement:** `nodeSelector: {kubernetes.io/arch: amd64}`. The Pis are at 39–72%
memory on 7.8 GiB; a 1–4 Gi pod does not belong there. amd64 is a simpler and more durable
expression of that than an anti-affinity rule.

### Database bootstrap

Hindsight runs its own schema migrations on startup (`RUN_MIGRATIONS_ON_STARTUP`, default
`true`), but it cannot create the `vector` extension itself: **pgvector is not a PostgreSQL
"trusted" extension, so a non-superuser role cannot `CREATE EXTENSION`.** That gap is the
single most likely thing to break a naive first deploy.

Two init containers, in order — the chained pattern lidarr already uses in this repo
(`01-init-db` → `02-init-metadata`):

```yaml
initContainers:
  01-init-db:
    image:
      repository: ghcr.io/home-operations/postgres-init
      tag: 18
    envFrom:
      - secretRef:
          name: hindsight-secret
  02-init-vector:
    # Same image — it ships psql. Creates the extension as the superuser, in the
    # database 01-init-db just made. Idempotent; safe on every restart.
    image:
      repository: ghcr.io/home-operations/postgres-init
      tag: 18
    command: ["/bin/sh", "-c"]
    args:
      - |
        PGPASSWORD="$${INIT_POSTGRES_SUPER_PASS}" psql \
          -h "$${INIT_POSTGRES_HOST}" -U postgres -d hindsight \
          -c 'CREATE EXTENSION IF NOT EXISTS vector;'
    envFrom:
      - secretRef:
          name: hindsight-secret
```

Note the `$$` — Flux's `postBuild` envsubst runs over these manifests and would otherwise
eat `${...}`. This repo has been bitten by envsubst before; see
`feedback_never_kubectl_apply_envsubst_apps`.

**Considered and rejected:** CNPG's `Database` CRD (`spec.extensions: [{name: vector,
ensure: present}]`), which deedee-ops uses and which our 1.30.0 operator supports. It is
declaratively nicer, but its `owner` must be a role that already exists, so it does not
remove the need for role creation — it only moves the extension step. Adopting a CRD this
repo has never used, to replace half of a pattern CLAUDE.md documents and lidarr proves,
is a net increase in surface area for one app. Worth revisiting as a repo-wide change, not
as a side effect of this one.

### Secrets

One `ExternalSecret` → OpenBao key `hindsight`, PascalCase double-underscore fields per
house convention, plus the shared `cloudnative-pg` superuser extract:

```yaml
  target:
    template:
      engineVersion: v2
      data:
        # postgres-init
        INIT_POSTGRES_HOST: &dbHost postgres18-rw.database.svc.cluster.local
        INIT_POSTGRES_USER: &dbUser "{{ .Hindsight__Postgres__User }}"
        INIT_POSTGRES_PASS: &dbPass "{{ .Hindsight__Postgres__Password }}"
        INIT_POSTGRES_DBNAME: &dbName hindsight
        INIT_POSTGRES_SUPER_PASS: "{{ .Postgres__SuperPassword }}"
        # Hindsight
        HINDSIGHT_API_DATABASE_URL: "postgresql://{{ .Hindsight__Postgres__User }}:{{ .Hindsight__Postgres__Password }}@postgres18-rw.database.svc.cluster.local:5432/hindsight"
        HINDSIGHT_API_LLM_API_KEY: "{{ .Hindsight__Llm__ApiKey }}"
        HINDSIGHT_API_TENANT_API_KEY: "{{ .Hindsight__TenantApiKey }}"
        HINDSIGHT_CP_DATAPLANE_API_KEY: "{{ .Hindsight__TenantApiKey }}"
  dataFrom:
    - extract:
        key: hindsight
    - extract:
        key: cloudnative-pg
```

### Authentication — not optional

**Hindsight's MCP and API endpoints are unauthenticated by default.** spiceratops'
deployment appears to leave them that way. With four consumers, some reaching the service
from off-pod, that means anything on the LAN can read and write every agent's memory —
including whatever Claude Code retained about this cluster's secrets handling.

Enable the built-in API-key tenant extension:

```yaml
HINDSIGHT_API_TENANT_EXTENSION: hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension
HINDSIGHT_API_TENANT_API_KEY: <from ExternalSecret>
```

Clients then send `Authorization: Bearer <key>`; a missing or wrong key returns 401. The
extension also scopes each request to a PostgreSQL schema, giving tenant isolation at the
database level.

The control plane authenticates to the data plane with the same key via
`HINDSIGHT_CP_DATAPLANE_API_KEY`.

### Routing

Internal gateway only. Three rules on one hostname, so the UI, the REST API, and the MCP
endpoint can be reasoned about (and later, restricted) separately:

```yaml
spec:
  hostnames: ["hindsight.${SECRET_DOMAIN}"]
  parentRefs:
    - name: internal
      namespace: network
      sectionName: https
  rules:
    - matches: [{path: {type: PathPrefix, value: /v1}}]
      backendRefs: [{name: hindsight-api, port: 8888}]
    - matches: [{path: {type: PathPrefix, value: /mcp}}]
      backendRefs: [{name: hindsight-api, port: 8888}]
    - matches: [{path: {type: PathPrefix, value: /}}]
      backendRefs: [{name: hindsight-controlplane, port: 3000}]
```

Order matters: the `/` catch-all must come last. Tailnet clients reach this the same way
Hermes does — the `ts-exit-node` Connector advertises `172.16.8.0/24` and the internal
gateway is `172.16.8.2`.

Not exposed on the `external` gateway. If Buzz agents ever need off-LAN access that is a
separate, deliberate decision with its own threat model.

### The LLM dependency

`retain` and `reflect` call an LLM. **`recall` does not** — it is pure retrieval, ~0.6 s
upstream-reported. So the hot read path costs nothing per query regardless of this choice.

Start with a **remote API**: `HINDSIGHT_API_LLM_PROVIDER: gemini`,
`HINDSIGHT_API_LLM_MODEL: gemini-3.5-flash` (spiceratops' choice; upstream's default is
`gpt-5-mini`). Zero new workloads.

Hindsight supports per-operation LLM config
(`HINDSIGHT_API_{RETAIN,REFLECT,CONSOLIDATION}_LLM_*`), so a cheap extraction model and a
stronger reflect model can be split later without restructuring anything.

**Privacy, stated plainly:** this ships conversation content to a third party. For Claude
Code that changes little — the transcripts already go to Anthropic. For Home Assistant
memory it is a materially different decision, and is the main reason the HA consumer is
deferred to last.

**GPU: not required, and not for the reason people assume.** Two distinct questions:

- *Reranker.* Local MiniLM cross-encoder, ~22M params. Upstream says it "benefits from a
  GPU" under production traffic; at homelab request rates on a 16-core brokkr node, CPU is
  fine (default `RERANKER_LOCAL_MAX_CONCURRENT: 4`). If it ever hurts, TEI or Cohere is an
  env-var change. *This sizing judgement is inference, not measurement.*
- *Extraction LLM.* The only component that would want a GPU, and only if you move it
  in-cluster. Vectorize's own stack guide uses `gpt-oss-20b` at ~13 GB in 4-bit, which puts
  a 24 GB card at the entry point. Nothing in this design needs it.

If a GPU node arrives later, adopting it is one line: point
`HINDSIGHT_API_LLM_BASE_URL` at an in-cluster Ollama and set `PROVIDER: ollama`.

`HINDSIGHT_API_LLM_PROVIDER=claude-code` also exists (a Claude Code subscription as the
extraction backend). Not designed around: headless auth in an unattended pod is an
operability and terms question, not a config one.

### Storage

**None.** Deliberately no `components/volsync` — the departure from every other app in this
repo, so it is called out rather than left to be noticed:

- The API and control plane are stateless.
- All memory lives in `postgres18`, already covered by barman-cloud → Garage S3 plus the
  `cnpg-offsite` job.
- `/tmp` and the HuggingFace cache (`/home/hindsight/.cache`) are `emptyDir`.

Consequence: the ~220 MB of embedder + reranker weights **re-download on every pod
restart**. That is the reason for a generous startup probe (`failureThreshold: 30`,
`periodSeconds: 10` → 300 s) rather than a PVC. A cache PVC would trade a restart delay for
a VolSync relationship and a Longhorn volume, which is the worse deal for 220 MB of
re-fetchable content.

### Observability

- **Probes** (spiceratops left theirs commented out; deedee-ops' are correct and are what
  this uses): liveness and startup on `/health/live`, readiness on `/health`, port 8888.
- **Metrics:** Hindsight exposes Prometheus metrics natively → `ServiceMonitor`.
- **Gatus:** via the `gatus.home-operations.com/endpoint` HTTPRoute annotation, matching
  Hermes, with `group: ai`.
- **Homepage:** `gethomepage.dev/*` annotations, group `AI`.
- `automountServiceAccountToken: false` — app-template's default, and correct here since
  Hindsight never calls the Kubernetes API.

## Consumers

Phased, so recall quality is proven before the surface area grows.

**Phase 1 — Claude Code only.** First-class plugin:

```
claude plugin marketplace add vectorize-io/hindsight
claude plugin install hindsight-memory
```

Config in `~/.hindsight/claude-code.json`:

```json
{
  "hindsightApiUrl": "https://hindsight.<domain>",
  "hindsightApiToken": "<tenant api key>",
  "dynamicBankId": true,
  "dynamicBankGranularity": ["agent", "project"]
}
```

Hooks: `SessionStart` health-checks, `UserPromptSubmit` recalls and injects context,
`Stop` retains asynchronously (`retainEveryNTurns`, default 10).

**Phase 2 — Hermes.** `hermes config set memory.provider hindsight`. Documented upstream
pairing; both prior-art repos run it.

**Phase 3 — Buzz agents.** Same plugin (they use the Claude Code harness today), with
`dynamicBankGranularity: ["agent", "channel", "user"]` and `HINDSIGHT_CHANNEL_ID` /
`HINDSIGHT_USER_ID`.

**Phase 4 — Home Assistant.** The weak one. No native integration; it means driving the
REST API or MCP endpoint from an automation or a first-party collector. Real work, and it
is where the privacy question above actually bites. Explicitly out of scope for the initial
build.

## The decision infrastructure cannot make

`MEMORY.md` + qmd already provide durable memory for this repo: greppable, human-auditable,
version-controlled, and correctable by hand. Hindsight is a different trade — better recall,
worse legibility, and a store you cannot read with `grep`.

**Phase 1 should be run as an evaluation, not a migration.** Keep `MEMORY.md` authoritative
throughout. The question to answer before Phase 2 is whether Hindsight's recall surfaces
things the file store missed, or mostly returns what a `deep_search` would have found
anyway. If it is the latter, this is a pod that costs LLM tokens to duplicate a working
system, and the right call is to delete it.

## Caveats

- The "first memory system past 90%", the comparison tables, and arXiv 2512.12818 are all
  **Vectorize's own** material. Treat the benchmark framing as vendor claims.
- Vectorize themselves note Hindsight has **no native fact-validity windows** — it is a poor
  fit for anything needing an audit trail of when a fact stopped being true.
- Upstream is at 0.9.x. Pre-1.0 means breaking changes are plausible; pin the tag and let
  Renovate propose bumps rather than tracking a rolling tag.

## File plan

```
kubernetes/apps/ai/
├── kustomization.yaml           # namespace: ai, components/common, hindsight/ks.yaml
├── namespace.yaml               # pod-security enforce: restricted
└── hindsight/
    ├── ks.yaml                  # dependsOn cloudnative-pg-cluster + openbao store
    └── app/
        ├── kustomization.yaml
        ├── ocirepository.yaml   # app-template 5.1.0
        ├── externalsecret.yaml
        ├── helmrelease.yaml
        ├── httproute.yaml
        ├── servicemonitor.yaml
        └── gatus.yaml
```

`kubernetes/apps/ai/hindsight/ks.yaml` must declare:

```yaml
  dependsOn:
    - name: cloudnative-pg-cluster
      namespace: database
    - name: external-secrets-openbao-store
      namespace: external-secrets
```

and `kubernetes/flux/.../cluster-apps` (or wherever namespace kustomizations are
enumerated) needs the new `ai` namespace wired in.

## Open questions for review

1. Is a new `ai` namespace right, or should this live in `develop` beside Hermes despite
   the `privileged` PSS label?
2. Gemini Flash vs Groq vs OpenAI for extraction — cost and privacy differ; no strong
   opinion beyond "remote, cheap, swappable".
3. Should Phase 1 set an explicit success criterion (e.g. "recall surfaced something qmd
   did not, N times in two weeks") before Phase 2 is allowed to start?
