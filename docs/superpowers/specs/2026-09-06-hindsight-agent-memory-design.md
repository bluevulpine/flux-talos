# Hindsight agent memory — design

**Status:** draft, pending adversarial review
**Date:** 2026-09-06
**Requested by:** Derek (`@bluevulpine`)
**Research:** upstream docs and source read directly; cluster claims verified against the
live cluster or the repo. Reviewed adversarially on 2026-09-06 by two independent passes
(fact-check and design/ops), which found three blockers and one security hole in the first
draft — see *Review corrections* at the end for what changed and what the first draft got
wrong. Claims marked *inference* are judgement, not measurement.

## Summary

Add [Hindsight](https://github.com/vectorize-io/hindsight) (MIT, Vectorize.io) as a
long-term memory service for the cluster's agents: Claude Code sessions, the existing
`develop/hermes` agent, Buzz agents, and — later — Home Assistant automations.

Hindsight stores facts and experiences in isolated *banks* and exposes three operations:
`retain` (LLM-extracts facts from a transcript), `recall` (hybrid vector + BM25 + graph +
temporal search, **no LLM call**), and `reflect` (LLM-synthesised answer over many
memories).

**The whole thing is one new pod.** All memory lands in the existing `postgres18`
CloudNativePG cluster, which already has everything it needs. No new database, no new
VolSync relationship, no new backup target, no GPU — one small PVC for the model cache, and
that is the entire storage footprint.

**Read this before the architecture.** Vectorize themselves note Hindsight has **no native
fact-validity windows**: it has no concept of a fact ceasing to be true. This repo's memory
set is full of entries that expire — "cross-seed v7 PENDING", "tuppr upgrade gate RESOLVED",
"BWSM migration complete". Recall injects what it finds into a prompt as trusted prior
context, so a stale fact does not merely fail to help, it actively misleads an agent holding
`kubectl` against this cluster. That is why Phase 1 below is an evaluation with a
**zero-wrong-facts** exit criterion and a delete-by date, not a rollout.

## Before you start — the gates that fail silently

Each of these is explained in full further down. They are collected here because every one
of them fails *quietly*: no error, no alert, just a thing that does not work. Three of the
five were mistakes in the first draft of this document.

- [ ] **`dependsOn` must be `cloudnative-pg-cluster18`**, not `cloudnative-pg-cluster`. Flux
      does not error on a missing target — the Kustomization parks in
      `dependency not ready` forever. *(CLAUDE.md's Postgres section carries the same stale
      name; fixing it is a separate change.)*
- [ ] **Add `ai` to `kubernetes/apps/identity/authentik/app/referencegrant.yaml`** *before*
      relying on the `auth: authentik` label. Without the grant, the `SecurityPolicy`
      cannot reference `ak-outpost-sso-proxy` and the label does nothing — leaving the
      control-plane UI open, which is the exact hole this design exists to close.
- [ ] **Dry-run the PSS label before committing it:**
      `kubectl label --dry-run=server --overwrite ns ai pod-security.kubernetes.io/enforce=baseline`.
      This repo's standard (`kopiur-system`, `media`) is to verify, then record how.
- [ ] **Use `${POSTGRES_HOST}`**, never a literal `postgres18-rw...`. 31 apps honour this;
      hardcoding breaks the next major-version cutover silently.
- [ ] **If taking the OpenCode Zen path: read its terms first.** Free tiers commonly train
      on submitted data, and that would undo the retention reasoning below. This one can
      change the answer from "tune it" to "no".

## Why this is low-risk

Two Flux `home-ops` repos already run Hindsight with this repo's exact conventions —
`kubernetes/apps/<ns>/<app>/app/`, `app-template` via `OCIRepository`, `&app` anchors,
`${SECRET_DOMAIN}`, ExternalSecret → OpenBao, an `envoy-internal` HTTPRoute. Both place it
in an `ai` namespace, and both run it beside Hermes.

| Repo | Image | Embed / rerank | LLM | Notable |
| --- | --- | --- | --- | --- |
| [`spiceratops/k8s-gitops`](https://github.com/spiceratops/k8s-gitops) | `hindsight-api:0.9.2` (full) | in-process (local BGE + MiniLM) | Gemini `gemini-3.5-flash` | `postgres-init` init container — the same pattern our CLAUDE.md documents, though they pin `:18` where all 22 of our consumers use `:rolling`. Probes commented out. **No tenant auth.** |
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

Create `kubernetes/apps/ai/`. The honest reason is the second one:

1. `develop` is `pod-security: privileged` — a deliberate concession for Nexus's
   `chownDataDir` init container that applies namespace-wide. Hindsight needs nothing of the
   sort, so a namespace that can enforce more is mildly preferable. **This is a weak reason
   and should not be oversold:** PSS constrains what the Hindsight pod can do *to its node*.
   It does nothing about who can reach Hindsight, which is the actual threat in the auth
   section below. The first draft used a namespace-isolation argument to answer a
   network-reachability problem; the control that answers that problem is the
   `auth: authentik` label, not the PSS level.
2. **It gives the eventual TEI embedder / reranker / local-inference workloads a home**, and
   matches both prior-art repos. That is sufficient on its own.

**On the PSS label — do not write it before verifying it.** This repo has an explicit,
twice-demonstrated standard: `kubernetes/apps/kopiur-system/namespace.yaml` and
`kubernetes/apps/media/namespace.yaml` both carry comments recording that the label was
checked against rendered output (kopiur) or a server-side dry-run (media) *before* being
committed — media even quotes the command. The first draft of this design asserted
`restricted` without doing either, which was the error those comments exist to prevent.

`restricted` is achievable here, but **only by construction** — app-template 5.1.0 supplies
none of it. Empirically, no app-template workload in this repo currently runs under
`restricted`, and `grep -rn seccompProfile kubernetes/apps` returns 36 hits with **zero** in
an app-template HelmRelease. PSA also evaluates init containers, so `01-init-db` and
`02-init-vector` must comply too. That means the HelmRelease must carry:

```yaml
    defaultPodOptions:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
```

plus, on **all four** containers (both init, both app):

```yaml
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
```

deedee-ops does exactly this and is the working reference. With that in place the namespace
follows kopiur's shape:

```yaml
metadata:
  name: ai
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled   # or Flux can prune the namespace
  labels:
    # See the Hermes trade-off immediately below: this is `baseline`, not
    # `restricted`. The pod spec still complies with restricted by construction.
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: latest
```

#### Deciding the level now, because Hermes may join later

Hermes is currently in `develop` and arguably belongs in `ai` — it is an agent, not a
development tool, and `develop` is `privileged` only because of Nexus. But **Hermes cannot
run under `restricted`**, and its own HelmRelease comments say why: the image's s6-overlay
entrypoint must start as root to `chown /opt/data` before dropping to uid 10000, and it adds
`CHOWN, DAC_OVERRIDE, SETGID, SETUID`. `restricted` requires `runAsNonRoot` and permits no
added capability except `NET_BIND_SERVICE`. `baseline` permits all four and does not require
non-root, so Hermes fits `baseline` and only `baseline`.

PSA is namespace-level, so there is no per-pod exemption. That makes it a genuine either/or:

| Option | Hindsight | Hermes |
| --- | --- | --- |
| A — `ai` is `restricted` | `restricted` ✅ | stays in `develop` at `privileged` ❌ |
| B — `ai` is `baseline` | `baseline` (weaker) | moves in at `baseline` ✅ (improvement) |

**Decision: Option B. `ai` is `baseline`, and Hermes moves there eventually.** Two workloads
at `baseline` beats one `restricted` plus one `privileged`; `media` already establishes
`baseline` as an accepted level in this repo; and it means the namespace does not have to be
relabelled later, which would be a change that silently starts rejecting pods.

Concretely, the namespace becomes:

```yaml
metadata:
  name: ai
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
  labels:
    # baseline, not restricted — chosen so Hermes can move here from `develop`.
    # Hermes CANNOT run restricted: its s6-overlay entrypoint starts as root to
    # chown /opt/data before dropping to uid 10000, and it adds CHOWN,
    # DAC_OVERRIDE, SETGID, SETUID. restricted requires runAsNonRoot and allows
    # no added capability except NET_BIND_SERVICE. baseline permits all four.
    # Verify with a server-side dry-run before committing (see below).
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: latest
```

**Keep the hardened `securityContext` on Hindsight anyway.** `baseline` is the namespace
floor, not a licence to skip the pod spec — Hindsight complies with `restricted` by
construction and should keep doing so. If Hermes ever leaves, the namespace can be tightened
without touching Hindsight.

**Moving Hermes is its own change, not part of this one.** It has a 20 Gi PVC with a VolSync
relationship whose schedules were hand-deconflicted (#1736 cleared eleven exact mover
collisions), and this repo's memory records real pain with stuck movers and stale handles.
A namespace move means migrating that PVC. The dashboard hostname and OIDC redirect are
namespace-independent, so those are not a concern.

**Implementation gate:** before committing whichever label you choose, render and check it,
exactly as media's comment records:

```bash
kubectl label --dry-run=server --overwrite ns ai \
  pod-security.kubernetes.io/enforce=restricted
```

Do not use `components/psa-privileged` — that component is for privileged namespaces;
`baseline` and `restricted` ones hand-write the labels, as `media` and `kopiur-system` do.

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

Hindsight runs its own schema migrations on startup
(`HINDSIGHT_API_RUN_MIGRATIONS_ON_STARTUP`, default `true`). It *attempts* to create the
extension — `migrations.py:_ensure_pgvector_extension_in_public` — but that attempt fails
for the app role, because **pgvector is not a PostgreSQL "trusted" extension** (confirmed:
`vector.control` at v0.8.1 has no `trusted = true`), so a non-superuser cannot
`CREATE EXTENSION vector`. The failure surfaces as
`"pgvector extension is required but not installed"`. That is the single most likely thing
to break a naive first deploy.

Two init containers, in order — the chained pattern lidarr already uses in this repo
(`01-init-db` → `02-init-metadata`):

```yaml
initContainers:
  01-init-db:
    image:
      repository: ghcr.io/home-operations/postgres-init
      tag: rolling
    envFrom:
      - secretRef:
          name: hindsight-secret
  02-init-vector:
    # Same image — it ships psql. Creates the extension as the superuser, in the
    # database 01-init-db just made. Idempotent; safe on every restart.
    image:
      repository: ghcr.io/home-operations/postgres-init
      tag: rolling
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

**Use `${POSTGRES_HOST}`, never the literal hostname.** `cluster-settings.yaml` exists so a
major-version cluster swap is a one-line cutover; 31 apps honour it and exactly one does
not. The first draft of this design hardcoded `postgres18-rw...` in three places, which
would have made Hindsight the second — and would have broken silently at the next cutover.

```yaml
  target:
    template:
      engineVersion: v2
      data:
        # postgres-init
        INIT_POSTGRES_HOST: &dbHost ${POSTGRES_HOST}
        INIT_POSTGRES_USER: &dbUser "{{ .Hindsight__Postgres__User }}"
        INIT_POSTGRES_PASS: &dbPass "{{ .Hindsight__Postgres__Password }}"
        INIT_POSTGRES_DBNAME: &dbName hindsight
        INIT_POSTGRES_SUPER_PASS: "{{ .Postgres__SuperPassword }}"
        # Hindsight takes a DSN, not discrete host/user/pass fields — unlike every
        # other Postgres app here. That makes the password percent-encoding-sensitive:
        # an `@`, `/`, `:` or `#` in Hindsight__Postgres__Password parses wrong and
        # presents as a bad credential. Constrain the OpenBao generator to [A-Za-z0-9].
        HINDSIGHT_API_DATABASE_URL: &dsn "postgresql://{{ .Hindsight__Postgres__User }}:{{ .Hindsight__Postgres__Password }}@${POSTGRES_HOST}:5432/hindsight"
        # Migrations get their own connection so a saturated app pool cannot wedge them.
        HINDSIGHT_API_MIGRATION_DATABASE_URL: *dsn
        # Recall is read-only and is the hot path — send it to the replicas.
        # ${POSTGRES_HOST_RO} DOES NOT EXIST YET. Add it to
        # kubernetes/components/common/cluster-config/cluster-settings.yaml
        # alongside POSTGRES_HOST, pointing at postgres18-ro.database.svc.cluster.local.
        # No app in this repo reads from a replica today, which is why there is no
        # variable — but hardcoding the literal here would reintroduce the exact
        # cutover breakage the paragraph above exists to prevent. Unlike that case
        # this one fails loudly: Flux >= 2.9 errors on an unmapped ${VAR}.
        HINDSIGHT_API_READ_DATABASE_URL: "postgresql://{{ .Hindsight__Postgres__User }}:{{ .Hindsight__Postgres__Password }}@${POSTGRES_HOST_RO}:5432/hindsight"
        HINDSIGHT_API_LLM_API_KEY: "{{ .Hindsight__Llm__ApiKey }}"
        HINDSIGHT_API_TENANT_API_KEY: "{{ .Hindsight__TenantApiKey }}"
        HINDSIGHT_CP_DATAPLANE_API_KEY: "{{ .Hindsight__TenantApiKey }}"
  dataFrom:
    - extract:
        key: hindsight
    - extract:
        key: cloudnative-pg
```

### Connection pool — cap it, or take a quarter of the cluster's budget

`postgres18` runs `max_connections: "400"` across ~34 databases, **no app in this repo sets
a client pool size, and there is no pgbouncer/`Pooler` anywhere**. Hindsight's defaults are
`DB_POOL_MAX_SIZE: 100` — a quarter of the entire cluster budget, for one evaluation pod.

The exhaustion mode is nasty because it is self-obscuring: `/health` acquires a database
connection, so on pool exhaustion readiness *and* liveness fail and Kubernetes restarts the
pod. Upstream notes a restart usually does not help. You get a crashloop that reads as an
app bug while other apps (Authentik, Immich) start failing to connect first, pointing the
investigation somewhere else entirely.

```yaml
HINDSIGHT_API_DB_POOL_MIN_SIZE: "2"
HINDSIGHT_API_DB_POOL_MAX_SIZE: "20"
HINDSIGHT_API_READ_DB_POOL_MAX_SIZE: "10"
```

`cluster18/prometheusrule.yaml` has six alerts and **none** watches connection count against
`max_connections` (`BackendsWaiting > 300` is lock waits, not slot exhaustion). That gap
predates this work and should be closed regardless:

```yaml
- alert: CNPGConnectionsNearLimit
  expr: sum(cnpg_backends_total{namespace="database"}) / 400 > 0.75
  for: 10m
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

Clients then send `Authorization: Bearer <key>`; a missing or wrong key returns 401.

**This is single-tenant bearer auth, and nothing more.** The name invites a wrong reading —
`ApiKeyTenantExtension.authenticate()` compares against one expected key and returns
`TenantContext(schema_name=get_config().database_schema)`, a single hardcoded schema
(default `public`) for every authenticated request. Upstream's own docstring says so: *"For
multi-tenant setups with separate schemas per tenant, implement a custom TenantExtension."*
There is **no per-consumer isolation**: any holder of the key reads and writes every bank.
That is a real input to the phased-consumer plan below, not a footnote.

#### The control-plane UI is a second door, and the API key does not lock it

`HINDSIGHT_API_TENANT_API_KEY` protects `/v1` and `/mcp`. It does **not** protect the
Next.js control plane, which proxies to the dataplane using
`HINDSIGHT_CP_DATAPLANE_API_KEY` — the very key we just provisioned. Left as-is, `curl
https://hindsight.${SECRET_DOMAIN}/` from anywhere on the LAN or the tailnet returns a
fully-authenticated web UI over every memory bank, and the net security gain over
spiceratops' "no auth at all" is approximately zero. deedee-ops has this hole too; it is
not a safe thing to copy.

Close it with the control that `components/common` already injects into every namespace —
one label on the control-plane rule of the HTTPRoute:

```yaml
  labels:
    auth: authentik   # components/common/authentik-forward-auth SecurityPolicy selects this
```

Precedent: `kubernetes/apps/longhorn-system/longhorn/resources/httproute.yaml:18`. This
requires the `ai` entry in `referencegrant.yaml` noted in the file plan — without it the
`SecurityPolicy` cannot reference `ak-outpost-sso-proxy` and the label silently does
nothing.

Upstream's own alternative is `HINDSIGHT_CP_ACCESS_KEY`, a shared secret that gates the UI
and all `/api/*` routes except `/api/health` (enforced in
`hindsight-control-plane/src/middleware.ts`). Authentik is better here — it is SSO the
cluster already runs, rather than a second shared secret to rotate.

#### The key is cluster-admin-equivalent, and the write half is the dangerous half

One credential grants full read **and write** across every bank, and it will exist
simultaneously in `~/.hindsight/claude-code.json` on a laptop (plaintext — not SOPS, not
OpenBao), in the Hermes pod, in Buzz agents, and later in Home Assistant.

Write is what makes it severe. `UserPromptSubmit` injects recalled memories **directly into
the prompt** of a Claude Code session that holds `kubectl` against this cluster. Anyone with
the key can plant a memory and have it delivered to a future session as trusted prior
context — a persistent prompt-injection channel into an agent with cluster reach, with a
multi-week fuse. Treat `Hindsight__TenantApiKey` as a cluster-admin-equivalent credential
and rotate it on the same footing.

Consequence for the phase plan: **Home Assistant (Phase 4) needs a second Hindsight
instance, not a second bank.** With one key and one schema, banks are a naming convention,
not a boundary.

### Data retention — the two defaults that store every transcript twice, forever

Neither of these is obvious, and together they are the most consequential thing in this
document:

| Var | Default | Effect |
| --- | --- | --- |
| `HINDSIGHT_API_STORE_DOCUMENT_TEXT` | `true` | Persists raw source text beside the extracted facts (`documents.original_text`, `chunks.chunk_text`) |
| `HINDSIGHT_API_OPERATION_RETENTION_DAYS` | `0` | Keeps terminal operation rows **including their task payload** indefinitely. Upstream: *"Hindsight does not scrub the task payload when an operation finishes."* |

At defaults, every retained transcript is stored **twice** in `postgres18`, permanently —
replicated across three CNPG instances, WAL-archived to Garage S3 on tardis, and swept
offsite to **Storj** by `cnpg-offsite`. (Not R2 — an earlier draft said R2, which is the
VolSync leg, not the Postgres one.) The "all state lands in postgres18, already backed up"
framing above is a backup virtue and a **proliferation problem** at the same time.

#### Encryption at rest — the two legs differ, and only one is protected

This materially changes how much the second copy matters, so it is worth stating precisely:

| Copy | Encrypted? | Evidence |
| --- | --- | --- |
| Live `postgres18` (3 replicas, Longhorn) | **No** (not verified otherwise) | no CNPG-level encryption configured |
| Garage bucket on tardis | **No** | `objectstore.yaml` sets `compression: bzip2` on `wal` and `data` and **no `encryption:` field**. barman-cloud supports `AES256`/`aws:kms`; it is not set. Compression is not encryption. |
| Storj offsite | **Yes, end-to-end** | `RCLONE_CONFIG_STORJ_TYPE: storj` — the *native* backend with an access grant, which encrypts client-side before erasure coding. The externalsecret comment says so explicitly: "the native `storj` backend is used rather than the S3 gateway: it talks to the satellite directly." Storj cannot read it. |

So the offsite copy — the one in someone else's cloud — is the copy that *is* protected. The
unencrypted copies are the live database and the Garage bucket, both on hardware in the
house. That is a materially different risk profile from "our transcripts are sitting in a
third party's object store in the clear", and it is the reason storing document text is a
defensible choice rather than a reckless one.

**`encryption: AES256` on the ObjectStore will NOT work here — do not try it.** An earlier
draft called this "a one-line change"; that was wrong. barman-cloud's `encryption` field
means **SSE-S3** (`x-amz-server-side-encryption: AES256`), and barman does not encrypt
anything client-side — it only asks the bucket to store objects encrypted. Garage's own
compatibility documentation says it implements **no server-side encryption at all**:

> "We think that you can either encrypt your server partition or do client-side encryption,
> so we did not implement server-side encryption for Garage."

Only SSE-C (customer-provided keys) is implemented, and barman-cloud does not support SSE-C
— upstream issue [EnterpriseDB/barman#1071](https://github.com/EnterpriseDB/barman/issues/1071)
requests exactly that and is still open, noting that the field rejects any value other than
`AES256` or `aws:kms`. So the setting is unusable against Garage, and the downside of
finding that out in production is a **failing WAL archive**, which is not a cosmetic
failure mode.

Even if it did work, the security value would be thin: SSE-S3 on a self-hosted store means
Garage holds the keys on the same machine as the data, so it does nothing against the threat
that actually motivates it — someone walking off with tardis's drives.

**The real fix is the one Garage names: encrypt the partition.** ZFS native encryption on
the pool backing Garage, with a key not stored on that box. That is a NAS-side change, it
cannot be applied to an existing dataset in place, and it is out of scope here — but it is
the correct answer and should be tracked separately.

**Two gaps remain unverified:** whether tardis's ZFS pool already uses native encryption,
and whether the Longhorn volumes under `postgres18` are encrypted. If both are off, physical
access to tardis or a node reads every transcript.

There is no redaction, sanitisation, or pattern filter anywhere in `retain.py`. `retainMission`
is a *prompt instruction* — the raw text is sent in full regardless of what gets extracted.
The only real levers are `retainRoles` and `retainToolCalls`.

One point in the design's favour: **`retainToolCalls` defaults to `false`**, so `sops -d`
output, `kubectl get secret -o yaml`, and bash results are *not* shipped. That materially
narrows exposure. But user and assistant prose in this repo routinely names OpenBao paths,
`Postgres__SuperPassword`, and `INIT_POSTGRES_SUPER_PASS` handling.

Upstream states that disabling document text does **not** degrade recall — "recall reads
from the extracted memories, never from the raw text." So this is close to free:

**Decision: keep document text, bound the operation payloads.** These are two *different*
copies and they deserve different answers:

```yaml
# KEEP the raw text. It is the provenance copy — the thing that lets you judge
# whether a recalled fact is right, which the exit criterion depends on. With
# Hermes in scope this is not optional: Hermes' turns are NOT in claude-sessions,
# so qmd cannot supply provenance for them and this is the only source record.
HINDSIGHT_API_STORE_DOCUMENT_TEXT: "true"
# But do NOT keep a second, accidental copy. Terminal operation rows carry the
# full retain payload and are retained forever by default — that is the same
# transcript again, as a debug artifact. 14d is enough to debug a failed retain.
HINDSIGHT_API_OPERATION_RETENTION_DAYS: "14"
# Surface silently-dropped facts instead of marking the retain completed.
HINDSIGHT_API_FAIL_ON_EXTRACTION_ERRORS: "true"
```

The reasoning that changed: the offsite copy is end-to-end encrypted (above), so the
exposure is confined to hardware in the house; and with Hermes in scope, the
"qmd already holds the source" argument only covers one of two consumers. One deliberate,
queryable copy beats two copies where the second is an unbounded debug artifact.

**This is a reversible decision, and worth revisiting at the Phase 1 gate.** If the
evaluation shows recall rarely needs provenance, flipping `STORE_DOCUMENT_TEXT` to `false`
costs nothing going forward — though it will not retroactively purge what is already stored.

#### What the document-text decision actually trades

Provenance against exposure. Recorded in full because the decision above went one way and
could reasonably go the other:

- **Lost: the ability to see what a fact was extracted from.** Recall returns "Derek decided
  X"; with raw text you can read the passage it came from, without it you judge the fact in
  isolation. That bears directly on the zero-wrong-facts exit criterion, which is easier to
  run with document text on.
- **Lost: re-extraction.** Improve the model or the prompt later and you cannot re-run
  extraction over stored text; you would have to re-retain from source.
- **Kept: recall quality.** Upstream is explicit that recall reads extracted memories, never
  raw text. *Note this claim is about recall specifically — I have not verified whether
  `reflect` benefits from raw text, and it plausibly might.*
- **Gained: the verbatim copy is the part that hurts most if the database, a base backup, or
  the R2 offsite copy leaks.** Extracted facts are lossy and abstracted; a transcript is not.

**For Claude Code alone the provenance loss would be close to zero**, because its source
transcripts already live in `claude-sessions` and `mcp__qmd__deep_search` finds the
originating session for any suspect fact. Hindsight's copy would be redundant.

**Hermes breaks that argument, and Hermes is in scope.** Hermes' turns are not in
`claude-sessions` and never will be — nothing indexes them. Turning document text off would
leave its memories with no source record at all, which is precisely the condition under
which a wrong fact becomes unfalsifiable. That asymmetry is what decided it.

Set `"retainToolCalls": false` explicitly in the plugin config rather than inheriting it.
Its trade is narrower and clearly worth taking: you lose memory of command *outputs* — which
in this repo is real operational context — but the surrounding prose still narrates what
happened, and it is the single control that keeps `sops -d` and `kubectl get secret` output
from ever being sent.
And accept the honest conclusion: **there is no retain-side filter**, so the only pre-send
control is not retaining at all. If a project is too sensitive, exclude it — do not rely on
`retainMission` to protect it.

The earlier "for Claude Code that changes little — the transcripts already go to Anthropic"
was a dodge and is withdrawn. It changes the number of third parties from one to two, and it
changes retention from a vendor's policy to *forever, in your own Postgres, replicated
offsite*.

### Routing

Internal gateway only. Three rules on one hostname — **split by authentication posture,
which is what makes the split load-bearing rather than decorative**: the control-plane rule
carries `auth: authentik` and goes through Envoy forward-auth/SSO; the `/v1` and `/mcp`
rules must *not*, because the Claude Code plugin and Hermes authenticate with a bearer
token and cannot complete an interactive OIDC flow.

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

Rule *order* is not what makes this work, and it is worth not believing otherwise: Gateway
API precedence is exact-path first, then **longest prefix by character count**, then method,
header count, query-param count — list order is only a final tiebreaker. `/v1` (3 chars)
beats `/` (1 char) wherever it sits. deedee-ops lists `/` first and works fine. Listing the
catch-all last is a readability convention here, not a correctness requirement.

Tailnet clients reach this the same way
Hermes does — the `ts-exit-node` Connector advertises `172.16.8.0/24` and the internal
gateway is `172.16.8.2`.

Not exposed on the `external` gateway. If Buzz agents ever need off-LAN access that is a
separate, deliberate decision with its own threat model.

### The LLM dependency

`retain` and `reflect` call an LLM. **`recall` does not** — it is pure retrieval, so the hot
read path costs no tokens regardless of this choice.

Upstream's performance table gives recall as **100–600 ms**, and names the bottleneck
explicitly: *"Re-ranker (on CPU) — optimization: use GPU for re-ranking, or reduce budget."*
Quote the range, not the ceiling, and note what the top of it means: 600 ms **is** the CPU
reranker. That directly qualifies the GPU discussion below.

Start with a **remote API**: `HINDSIGHT_API_LLM_PROVIDER: gemini`,
`HINDSIGHT_API_LLM_MODEL: gemini-3.5-flash` (spiceratops' choice; upstream's default is
`gpt-5-mini`). Zero new workloads.

Hindsight supports per-operation LLM config
(`HINDSIGHT_API_{RETAIN,REFLECT,CONSOLIDATION}_LLM_*`). **Note that consolidation is not
optional background work** — `HINDSIGHT_API_ENABLE_AUTO_CONSOLIDATION` defaults to `true`
and fires an LLM call after every retain, delete, and update. Any cost model that ignores it
is structurally incomplete.

#### Cost — bounded, not hand-waved

The first draft refused to give a number. That was a cop-out; the number is estimable and it
changes the model choice.

*Assumptions:* `retainEveryNTurns: 10`; `retainMode: full-session` retains only messages
after `retention_progress.start_index`, so cost is **linear, not quadratic**;
`retainToolCalls: false` → prose only, ~2,500 chars/turn → ~25,000 chars per retain;
`HINDSIGHT_API_RETAIN_CHUNK_SIZE: 3000` → ~9 extraction calls; ~17 facts/chunk;
prompt caching on; Gemini 3.5 Flash at $1.50/M in, $9.00/M out.

| | cost |
| --- | --- |
| Extraction, 9 chunks | $0.109 |
| Auto-consolidation, ~150 new facts | $0.035 |
| **Per 10-turn retain** | **≈ $0.14** |

| Volume | Retains/day | Monthly |
| --- | --- | --- |
| Light — 1 session/day, 30 turns | 3 | **~$13** |
| Moderate — 3 sessions/day, 40 turns | 12 | **~$50** |
| Heavy — this repo's long infra sessions | 30 | **~$126** |

Phase 1 alone. Hermes runs continuously and, at its stock `retain_every_n_turns: 1`, retains
ten times more often per turn — set it to `10` to match Claude Code before enabling it.

**~80% of the cost is output tokens**, which makes Flash the wrong default on exactly the
axis that dominates. Take the model lever:

```yaml
# Structured extraction against a schema is the easiest job in the pipeline.
# Keep full Flash for reflect, where reasoning quality actually shows up.
HINDSIGHT_API_RETAIN_LLM_MODEL: gemini-3.5-flash-lite
```

#### OpenCode Zen free models — plausible, with three caveats

Hindsight takes any OpenAI-compatible endpoint (`PROVIDER: openai` +
`HINDSIGHT_API_LLM_BASE_URL`), which is exactly how deedee-ops routes through its `bifrost`
gateway. OpenCode Zen exposes `https://opencode.ai/zen/v1` and currently offers a free set
(Nemotron Ultra, Lightning, MiMo, Ling Flash, big-pickle, Muse Spark, plus Grok Code Fast 1
free "for a limited time"). Hermes knows this family natively — the deployed build carries
`opencode-zen`, `opencode-free`, and even `opencode-zen-free-keyless` provider modes. So
mechanically, yes, this would work.

Three reasons not to make it the *default*, in decreasing order of importance:

1. **Terms, and it cuts against a decision already made.** The retention posture above is
   acceptable partly because transcripts go to a paid Google API, which does not train on API
   data. A free coding-model tier is a different bargain and free tiers commonly do train on
   submitted data. **Check the terms before pointing this at transcripts** — this is the one
   caveat that could make the answer "no" outright rather than "tune it".
2. **Extraction is not a coding task.** These are coding-tuned models. Hindsight's retain path
   is schema-constrained fact extraction from conversational prose, and extraction quality is
   precisely what the whole system's value rests on. Structured-output/grammar support on a
   free tier is also unproven — note `HINDSIGHT_API_LLM_STRICT_SCHEMA` defaults to `false`.
3. **Rate limits versus the default concurrency.** `HINDSIGHT_API_LLM_MAX_CONCURRENT` is `32`,
   and one retain is ~9 extraction calls plus consolidation. That will hit a free quota
   immediately; it would need dropping to single digits. And upstream OpenCode warns plainly
   that "free model IDs can be promotional and go away."

**The right shape if you want to try it** is Hindsight's multi-LLM failover, not a straight
swap — free tier primary, a known-good paid model as the safety net, so a vanished model ID
or a quota wall degrades instead of silently failing retains:

```yaml
HINDSIGHT_API_LLM_STRATEGY: '{"mode": "failover"}'
HINDSIGHT_API_LLM_0_PROVIDER: openai
HINDSIGHT_API_LLM_0_BASE_URL: https://opencode.ai/zen/v1
HINDSIGHT_API_LLM_0_MODEL: <free-model-id>
HINDSIGHT_API_LLM_0_MAX_CONCURRENT: "4"
HINDSIGHT_API_LLM_1_PROVIDER: gemini
HINDSIGHT_API_LLM_1_MODEL: gemini-3.5-flash-lite
```

Treat it as a Phase 1 experiment measured on the exit criterion's **zero-wrong-facts** bar —
that is exactly the test a weaker extraction model would fail, and it costs nothing extra to
run since the gate is being run anyway.

**Do not take the Batch API lever**, despite its flat 50% off both input and output. It
would halve cost again, but it turns retain into a minutes-to-hours SLA, and Hermes'
`prefetch_waits_for_retain: True` / `prefetch_retain_drain_timeout: 10.0` means its prefetch
would time out on every turn and recall would stop including the turn that just happened.
The setting is server-wide, so it cannot be scoped to Claude Code only. See open question 1.

Better than estimating: Hindsight records every LLM call with token usage in an
`llm_requests` table, exposed at `/llm-requests` per bank, **including failed calls**. Read
actual spend from there — which is what makes the cost gate in the exit criterion free to
enforce.

**Privacy, stated plainly:** this ships conversation content to a third party. For Claude
Code that changes little — the transcripts already go to Anthropic. For Home Assistant
memory it is a materially different decision, and is the main reason the HA consumer is
deferred to last.

**GPU: not required, and not for the reason people assume.** Two distinct questions:

- *Reranker.* Local MiniLM cross-encoder, ~22M params. Upstream names it the recall
  bottleneck and names a GPU as the fix — so "CPU is fine here" is a claim about *our*
  request rate, not a contradiction of upstream. At homelab concurrency on a 16-core brokkr
  node the 100–600 ms range is acceptable for an auto-recall injected at prompt submit.
  **This is inference, not measurement** — the honest test is to watch p95 recall latency
  after Phase 1 and move to TEI (an env-var change:
  `HINDSIGHT_API_RERANKER_PROVIDER: tei`) if it drifts. Default concurrency cap is
  `HINDSIGHT_API_RERANKER_LOCAL_MAX_CONCURRENT: 4`.
- *Extraction LLM.* The only component that would want a GPU, and only if you move it
  in-cluster. Vectorize's own stack guide uses `gpt-oss-20b` at ~13 GB in 4-bit, which puts
  a 24 GB card at the entry point. Nothing in this design needs it.

If a GPU node arrives later, adopting it is one line: point
`HINDSIGHT_API_LLM_BASE_URL` at an in-cluster Ollama and set `PROVIDER: ollama`.

`HINDSIGHT_API_LLM_PROVIDER=claude-code` also exists (a Claude Code subscription as the
extraction backend). Not designed around: headless auth in an unattended pod is an
operability and terms question, not a config one.

### Storage

**One 1 Gi cache PVC, and deliberately no `components/volsync`** — the departure from most
apps in this repo, so it is called out rather than left to be noticed:

- The API and control plane hold no durable state; the PVC below is a rebuildable cache.
- All memory lives in `postgres18`, already covered by barman-cloud → Garage S3 plus the
  `cnpg-offsite` job.
- `/tmp` and the HuggingFace cache (`/home/hindsight/.cache`) are `emptyDir`.

**One PVC, for the model cache — and the reason is availability, not latency.** The first
draft rejected this on the grounds that a cache PVC "would trade a restart delay for a
VolSync relationship." That was a false dilemma: VolSync is opt-in per app here, and
`karakeep`, `tracearr`, `plex`, `satisfactory` and `valheim` all carry a standalone
`app/pvc.yaml` with no `components/volsync`. The real choice is a 1 Gi PVC versus **putting
`huggingface.co` on the critical startup path of a service four agents depend on**.

The image is ~1.42 GB compressed across 15 layers (two ~565 MB torch layers). With
`strategy: Recreate` the old pod dies first, so a node drain means: full image pull on a
node that may not have it, extract, ~220 MB weight fetch from HuggingFace, torch import,
then migrations — all inside the 300 s startup probe. If HuggingFace is slow or down,
Hindsight **cannot start at all** and agent memory is offline for the duration.

```yaml
persistence:
  hf-cache:
    type: persistentVolumeClaim
    accessMode: ReadWriteOnce
    size: 1Gi
    storageClass: longhorn-1-replica-local   # deliberately no volsync — it is a cache
    globalMounts:
      - path: /home/hindsight/.cache
```

Keep the generous startup probe regardless (`failureThreshold: 30`, `periodSeconds: 10` →
300 s) for the cold-pull case. **Measure the real drain cost during Phase 1** — the estimate
is 3–6 minutes of unavailability per drain, per HelmRelease upgrade, and per Talos upgrade
cycle, and it is currently unmeasured.

### Observability

- **Probes.** Liveness and startup on `/health/live`, readiness on `/health`, port 8888 —
  matching the upstream chart's own values, and its rationale: *"`/health/live` performs no
  database access: a slow or unreachable database must gate traffic, never restart pods."*
  spiceratops left theirs commented out; do not copy that.
- **Metrics.** `GET /metrics` is registered unconditionally on the API's own port 8888
  (`api/http.py`, prometheus_client) — no enabling env var needed. The control plane
  (Next.js) exposes **none**, so the `ServiceMonitor` must select the **api** service only.
  No `release:` label is required: the cluster's Prometheus has `serviceMonitorSelector: {}`.
- **Alerts — a pair, not one.** The house pattern (12 `prometheusrule.yaml` files, e.g.
  `kubernetes/apps/home/chargepoint-collector/app/prometheusrule.yaml`) always pairs a
  `Down` alert with an `ImagePullFailing` alert, because
  `docs/runbooks/flux-image-automation.md` records that `ImagePullBackOff` does *not* fire
  the pod-failure alert. For a large image behind the Nexus pull-through mirror that second
  alert is not optional:

  ```yaml
  - alert: HindsightDown
    expr: kube_deployment_status_replicas_ready{namespace="ai", deployment="hindsight"} == 0
    for: 15m
  - alert: HindsightImagePullFailing
    expr: kube_pod_container_status_waiting_reason{namespace="ai", reason=~"ImagePullBackOff|ErrImagePull|InvalidImageName"} > 0
    for: 15m
  ```

  Neither catches the failure mode that actually matters — pod `1/1 Running`, retains
  failing, memory silently frozen. Set `HINDSIGHT_API_METRICS_BACKLOG_ENABLED: "true"` and
  alert on a growing retain backlog.
- **Gatus:** via the `gatus.home-operations.com/endpoint` HTTPRoute annotation with
  `group: ai`, matching Hermes — but **do not count it as paging coverage**. Every
  annotation-based endpoint in this repo sets only `group:`; only the four hand-written
  endpoints in `observability/gatus/app/resources/config.yaml` declare
  `alerts: [{type: pushover}]`. Whether an auto-discovered route pages is not determinable
  from the repo. Treat Gatus as a dashboard tile and let the PrometheusRule above do the
  paging.
- **Homepage:** `gethomepage.dev/*` annotations, group `AI`.
- `automountServiceAccountToken: false` — app-template's default, and correct here since
  Hindsight never calls the Kubernetes API.
- **Renovate: no `# renovate:` annotation needed** — but this is a preference, not a rule,
  and an earlier draft of this document overstated it. The facts: app-template nested images
  are detected natively (`kubernetes/apps/productivity/n8n` carries no annotation and has
  nine bump PRs), so `0.9.2` needs nothing. The documented duplicate-PR collision
  (`.renovate/overrides.json5`, gitea #1389/#1540/#1681) applies to a HelmRelease's
  **top-level `image.repository`/`image.tag`**, which the **`flux`** manager extracts from
  the `values:` block. It is *not* `helm-values` — that manager only matches files literally
  named `values.yaml`, and suppressing it was the wrong fix twice running. On the Dependency
  Dashboard the annotated app-template images (`hermes` #1743, `timescaledb` #1715) each
  appear once, so annotating one does not currently duplicate. Either choice is defensible;
  omitting is the lighter one. Check the Dashboard after the first bump.

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

**How the consumer degrades when Hindsight is down** — verified from the plugin source,
better than feared in two places and worse in one:

- `SessionStart` — 5 s timeout, `sys.exit(0)` on any error. Does **not** block or
  meaningfully slow session start.
- `Stop` — `async: true`, 15 s. Fine.
- `UserPromptSubmit` — **not async**. `recall.py` uses a 10 s per-call timeout and returns
  on exception, so a down Hindsight adds **~10 s of silent latency to every prompt**,
  indefinitely, with the error only on stderr. One line fixes it, since `recall.py` passes
  `requestTimeoutSeconds` through as a client override:

  ```json
  { "requestTimeoutSeconds": 3 }
  ```

**Retain durability is better than the design needs to worry about**, and is worth writing
down so nobody re-investigates it: retain is a DB-backed queue with worker claiming,
`WORKER_MAX_RETRIES: 3`, `LLM_MAX_RETRIES: 3` with exponential backoff capped at 60 s, and
`RETAIN_WALL_TIMEOUT: 3600` after which a task is marked `failed` rather than wedging a
slot. A Gemini outage **queues, retries, then fails cleanly** — it does not crash the pod or
drop silently. Consolidation additionally has a 300 s reconcile sweep that re-schedules banks
stranded by a terminal LLM failure.

**Phase 2 — Hermes. Confirmed in scope.** `hermes config set memory.provider hindsight`.
Documented upstream pairing; both prior-art repos run it. Three things follow from keeping
it, and they are why it is not a free addition:

**Cadence — resolved by reading the plugin in the running pod, not inferred.** Hermes
v0.21.0 ships Hindsight as a first-class provider (`hermes memory setup` lists it alongside
honcho/mem0/openviking) with the `hindsight_client` SDK already vendored. The plugin lives
at `/opt/hermes/plugins/memory/hindsight/`. Findings:

- **`retain_every_n_turns` exists and defaults to `1` — retain on *every* turn.** The Claude
  Code plugin defaults to `10`. So at stock settings Hermes retains **10× more often per
  turn**, and it is the continuously-running consumer. This is the single biggest cost lever
  in the whole design.
- **It is tunable, but not through `hermes memory setup`.** That wizard's schema
  (`config_schema.py`) exposes only five fields — `mode`, `api_key`, `api_url`, `bank_id`,
  `recall_budget`. `retain_every_n_turns` is in the plugin's broader declared key list and is
  set in `$HERMES_HOME/hindsight/config.json` — here `/opt/data/hindsight/config.json`, which
  is on the VolSync-backed PVC.
- **Cost is linear, not quadratic** — but conditionally. `sync_turn()` ships only
  `_session_turns[_last_retained_turn_count:]` when the server supports
  `update_mode='append'`; otherwise it resends **the entire session on every retain**. The
  gate is `_MIN_VERSION_FOR_UPDATE_MODE_APPEND = "0.5.0"` and we deploy 0.9.2, so append is
  supported and retains stay incremental. Worth knowing the failure mode exists: if the probe
  fails for any reason it falls back to the quadratic path and only logs a warning.
- Other defaults that matter: `auto_recall: True` but `recall_sync: False`, so recall runs in
  the background and is injected on the *next* turn — it adds no latency to the reply path.
  `recall_max_tokens: 4096` (four times Claude Code's 1024). `recall_types: "observation"`,
  i.e. the consolidated layer only. `observation_scopes` defaults to `combined`; the
  `all_combinations` option is flagged "expensive" upstream — do not set it.

**Set `retain_every_n_turns` deliberately before enabling Hermes.** Matching Claude Code's
`10` is the obvious starting point. Enable Hermes *after* the Phase 1 gate regardless, so
there is a clean single-consumer cost baseline to compare against.

Auto-consolidation still compounds: it fires after every retain and dedups against the whole
bank, so two continuously-writing consumers make each other's consolidation passes more
expensive.
- **It is why document text stays on.** Hermes' turns are not in `claude-sessions`; nothing
  else records them.
- **It shares the one API key**, and it is the consumer with `kubectl` and `talosctl` in its
  container. The write-side prompt-injection concern above is most acute here.

Give it its own bank (`dynamicBankGranularity` has no meaning for Hermes — set the bank
explicitly) so Phase 1's Claude Code memories stay separable for evaluation.

**Phase 3 — Buzz agents.** Same plugin (they use the Claude Code harness today), with
`dynamicBankGranularity: ["agent", "channel", "user"]` and `HINDSIGHT_CHANNEL_ID` /
`HINDSIGHT_USER_ID`.

**Phase 4 — Home Assistant.** The weak one. No native integration; it means driving the
REST API or MCP endpoint from an automation or a first-party collector. Real work, and it
is where the privacy question above actually bites. Explicitly out of scope for the initial
build.

## Relationship to qmd and MEMORY.md — supplemental, not a replacement

`MEMORY.md` + qmd already provide durable memory for this repo: greppable, human-auditable,
version-controlled, and correctable by hand. Hindsight is a different trade — better recall,
worse legibility, and a store you cannot read with `grep`.

**Hindsight cannot replace qmd, for three structural reasons:**

1. **Different corpora.** qmd indexes 1,429 documents across eight collections —
   `terra-fabula` canon, `tf-manuscript`, `writing-published`, `buzz-channels`,
   `tf-research`. Hindsight only knows what has been *retained from agent sessions*. It
   would never contain the Terra Fabula bibles unless bulk-ingested through its document
   API, which is possible but is a separate project.
2. **Different failure modes.** qmd's index is derived from files you own and is rebuildable
   from scratch at any time. Hindsight's store is derived, lossy, and — after extraction —
   not reconstructible from its own contents.
3. **Different cost.** qmd is free to query. Hindsight costs tokens on every retain and every
   reflect.

The honest framing is **supplemental**: Hindsight is a *session-memory* layer, qmd is a
*corpus-search* layer. They overlap only on `claude-sessions`, and there qmd is the one with
provenance.

### The reachability argument — real, but not free as designed

qmd is an MCP server local to this host: Claude Code on this machine can use it, and nothing
else can. Hindsight is a network service, which genuinely does fix that — **but only for
clients that can reach it, and the design above deliberately puts it on the internal gateway
only.**

That distinction matters and cuts differently per client:

| Client | Reaches internal-only Hindsight? |
| --- | --- |
| Claude Code on this host | Yes |
| Claude Code on another machine of yours | Yes — the `ts-exit-node` Connector advertises `172.16.8.0/24` |
| Hermes, Buzz agents (in-cluster) | Yes |
| **claude.ai web sessions** | **No** |

Web sessions run server-side in Anthropic's cloud, not on your tailnet, so an MCP connector
would need a **publicly reachable HTTPS endpoint with its own auth** — the `external`
gateway or a Pangolin/Cloudflare path. That is a real decision with real cost: it makes agent
memory internet-reachable, and per the auth section a single bearer token holder can *write*
memories that get injected into a `kubectl`-holding agent's prompt.

**Recommendation: do not expose it externally during Phase 1.** The reachability win is
genuine and is arguably the strongest argument for Hindsight over qmd, but it should be
bought deliberately after recall quality is proven — not bundled into the initial deploy.
If it is taken later, it needs OAuth via Authentik rather than a shared bearer token, and it
should be its own design decision with its own threat model.

**Phase 1 is an evaluation, not a migration.** Keep `MEMORY.md` authoritative throughout.

### Exit criterion — evaluate on 2026-09-27, no extensions

An evaluation with no criterion, no date, and no owner is how a pod becomes permanent
infrastructure. This one has all three.

Sample the last 20 `UserPromptSubmit` prompts that triggered a recall injection. Run each
query through `mcp__qmd__deep_search` over `claude-sessions`. Classify every Hindsight-recalled
fact as **novel-and-correct**, **redundant** (qmd found it too), or **wrong**.

Proceed to Phase 2 only if all three hold:

1. ≥30% of recalled facts are novel-and-correct.
2. **Zero** confidently-wrong facts. Not "few" — zero.
3. Actual spend over the window, read from `/llm-requests` rather than estimated, is under
   **$25**.

Any one fails → delete per the Teardown section. No "let's give it another month."

The zero-wrong-facts bar is what makes this a test rather than a formality, and it is the
bar Hindsight is most likely to fail. `feedback_no_unverified_claims` is this repo's
operating principle; a store that asserts stale facts **is strictly worse than no store**,
because recall launders them into the prompt as trusted prior context. In a memory set full
of entries like "cross-seed v7 PENDING", "tuppr upgrade gate RESOLVED", and "BWSM migration
complete", facts stop being true constantly — and Hindsight has no fact-validity windows to
notice.

## Teardown

Written before deployment, deliberately — `project_postgres18_migration.md` records what
happens otherwise: `postgres16-v8` sat orphaned in `s3://cnpg/` for seven weeks, 5,394
objects and **82.3 GiB**, with `retentionPolicy` configured the whole time and irrelevant.
*"Nothing will do it for you and nothing will alert."*

Ordering matters. Per `project_sops_age_arch.md`, ESO's finalizer deletes the Secret when the
ExternalSecret goes, even under an Orphan policy — so do the database work **first**, while
credentials still exist.

```bash
# 0. FIRST, while hindsight-secret still exists:
#    pg_dump -U postgres -Fc hindsight > hindsight-final.dump   # only if keeping anything
#    DROP DATABASE hindsight; DROP ROLE hindsight;              # as superuser
# 1. remove kubernetes/apps/ai/hindsight/ and kubernetes/apps/ai/
#    verify nothing depends on it first (feedback_flux_kustomization_removal):
#    grep -rl hindsight kubernetes/apps --include=ks.yaml
# 2. the namespace carries prune: disabled — kubectl delete ns ai BY HAND
# 3. bao kv delete .../hindsight   (and rotate anything the key touched)
# 4. laptop: claude plugin uninstall hindsight-memory && rm -rf ~/.hindsight
#    and remove the hook entries from ~/.claude/settings.json
# 5. NOT reversible: every transcript already sent to Google.
```

Two things worth stating plainly. **CNPG PITR cannot restore `hindsight` alone** — it
restores the whole cluster to a point in time, dragging all ~34 databases with it, and base
backups are weekly. Hindsight is the one database here where the shared backup is
effectively unusable for a targeted rollback. And **deleting the Kustomization un-deploys a
pod; it does not un-send the data.**

## Caveats

- The "first memory system past 90%", the comparison tables, and arXiv 2512.12818 are all
  **Vectorize's own** material. Treat the benchmark framing as vendor claims.
- Vectorize themselves note Hindsight has **no native fact-validity windows** — it is a poor
  fit for anything needing an audit trail of when a fact stopped being true.
- Upstream is at 0.9.x, and `HINDSIGHT_API_RUN_MIGRATIONS_ON_STARTUP` is `true`. Renovate
  policy is already safe — automerge is allowlist-based and `ghcr.io/vectorize-io/*` matches
  none of the six rules, so every bump is a manual PR. The gap is what happens *after* the
  merge: Renovate classifies `0.9.2 → 0.10.0` as a **minor**, which reads as routine, but
  pre-1.0 minors are exactly where breaking schema changes live. Flux reconciles on push,
  the pod restarts, Alembic runs, and per the Teardown section there is no way to restore
  just this database. Put the warning where the person merging will see it:

  ```yaml
  image:
    repository: ghcr.io/vectorize-io/hindsight-api
    # PRE-1.0. Renovate calls 0.9.x -> 0.10.x a "minor"; upstream may mean "breaking".
    # Migrations run on startup and are one-way, and CNPG PITR cannot restore this
    # database without restoring all ~34. Before merging any bump past the patch digit:
    #   kubectl -n database exec postgres18-1 -- \
    #     pg_dump -U postgres -Fc hindsight > hindsight-<ver>.dump
    #
    # No `# renovate:` annotation on purpose — native detection already tracks this
    # line, and doubling up produces duplicate PRs (.renovate/overrides.json5, gitea).
    tag: 0.9.2
  ```

## File plan

```
kubernetes/apps/ai/
├── kustomization.yaml           # namespace: ai, components/common, hindsight/ks.yaml
├── namespace.yaml               # prune: disabled + enforce-version: latest; PSS level
│                                #   VERIFIED by dry-run before committing, not asserted
└── hindsight/
    ├── ks.yaml                  # dependsOn cloudnative-pg-cluster18 + openbao store
    └── app/
        ├── kustomization.yaml
        ├── ocirepository.yaml   # app-template 5.1.0
        ├── externalsecret.yaml
        ├── helmrelease.yaml
        ├── httproute.yaml       # `auth: authentik` label on the control-plane rule only
        ├── pvc.yaml             # 1Gi model cache, standalone (no components/volsync)
        ├── servicemonitor.yaml  # selects the api service only; CP exposes no metrics
        ├── prometheusrule.yaml  # Down + ImagePullFailing + RetainBacklog + ConsolidationFailing
        └── gatus.yaml
```

Every file needs its `# yaml-language-server: $schema=` header per CLAUDE.md.

`kubernetes/apps/ai/hindsight/ks.yaml` must declare:

```yaml
  dependsOn:
    # NOT `cloudnative-pg-cluster` — that Kustomization does not exist. The real
    # name is `cloudnative-pg-cluster18` (kubernetes/apps/database/cloudnative-pg/ks.yaml:30),
    # and every sibling app uses the 18 suffix. Flux does not error on a missing
    # dependsOn target; it parks in `dependency not ready` forever. CLAUDE.md's
    # Postgres section carries the same stale name and should be fixed with this.
    - name: cloudnative-pg-cluster18
      namespace: database
    - name: external-secrets-openbao-store
      namespace: external-secrets
```

**No change is needed under `kubernetes/flux/`.** `kubernetes/flux/cluster/ks.yaml:12` points
at `./kubernetes/apps` with no `kustomization.yaml` at that path — kustomize-controller
recurses and autodetects. Commit `4b8f51c5` added the whole `kopiur-system` namespace
touching only four files, all inside its own directory.

**Two files outside the app directory need editing.**
`kubernetes/components/common/cluster-config/cluster-settings.yaml` needs a
`POSTGRES_HOST_RO` entry beside `POSTGRES_HOST` — Hindsight is the first app here to read
from a CNPG replica, so the variable does not exist yet. This one fails loudly rather than
silently (Flux ≥ 2.9 errors on an unmapped `${VAR}`), so it will not slip through, but it
does block the build until added.

And:
`kubernetes/apps/identity/authentik/app/referencegrant.yaml` enumerates source namespaces
explicitly. `components/common` renders a `SecurityPolicy` into every namespace, and in a
new `ai` namespace that policy cannot reference `ak-outpost-sso-proxy` until `ai` is added
to the grant. Without it, the `auth: authentik` label described in the Authentik section
above silently does nothing.

## Open questions

1. **Batch API for retain — recommendation is now NO, at least initially.**
   `HINDSIGHT_API_RETAIN_BATCH_ENABLED: "true"` uses Gemini's Batch API for a flat **50% off
   both input and output**, at the cost of turning retain into an SLA — upstream says
   "typically minutes", with a 24 h ceiling. That looked free when retain was just an async
   `Stop` hook. Reading the Hermes plugin changed the picture: it sets
   `prefetch_waits_for_retain: True` with `prefetch_retain_drain_timeout: 10.0`, i.e. the
   background prefetch waits up to 10 s for the just-completed retain to become
   *recall-visible* so the next recall includes the turn that just happened. **Under batch
   that wait always times out**, and Hermes stops remembering what it just said until the
   batch lands. The setting is server-wide, so it cannot be enabled for Claude Code and
   disabled for Hermes. Since `gemini-3.5-flash-lite` for extraction already delivers most of
   the saving with no latency cost, take that first and leave batch off.

2. **Encrypting the Garage copy** — resolved as *not* via barman-cloud (see above; Garage
   implements no server-side encryption). The open item is whether to put ZFS native
   encryption on the tardis pool, which is a NAS-side project of its own.

3. **Sensitivity: resolved — no project is being excluded.** Personal tooling and fiction
   work, the latter published anyway. Worth recording *why* that is safe, because the reason
   is not "nothing here is sensitive": it is that `retainToolCalls: false` keeps `sops -d`
   output, `kubectl get secret`, and bash results from ever being sent. Prose still mentions
   OpenBao paths and secret-handling procedure, and that is accepted. **Revisit if
   `retainToolCalls` is ever turned on** — that single flag is what makes this answer hold.

## Review corrections

This document was reviewed adversarially on 2026-09-06 by two independent passes. What they
found, recorded because the errors are instructive:

**Three blockers in the first draft:**

1. `dependsOn: cloudnative-pg-cluster` — **no such Kustomization**; the real name is
   `cloudnative-pg-cluster18`. Flux does not error on a missing dependency target, it parks
   forever. CLAUDE.md carries the same stale name and should be corrected alongside.
2. `enforce: restricted` asserted without verification, against a bar this repo has set twice
   (`kopiur-system` and `media` both document *how* their label was checked). app-template
   supplies none of the required fields, and PSA evaluates init containers too.
3. **The auth section did not do what it claimed.** The API key protects `/v1` and `/mcp`;
   the control-plane UI proxies with that same key and was left wide open. Net gain over
   "no auth" was approximately zero.

**Three claims stated as verified that were not** — the reason the header's wording was
softened. `ApiKeyTenantExtension` gives no schema isolation; `restricted` compatibility was
predicted; the `cluster-apps` wiring step does not exist (namespaces are discovered by
directory presence).

**Also corrected:** hardcoded `postgres18-rw` instead of `${POSTGRES_HOST}` (would have been
the repo's second violation out of 32 consumers); unbounded connection pool; `emptyDir` for
the model cache justified by a false dilemma; no cost estimate; no teardown; no exit
criterion; recall latency quoted at its ceiling; Gateway API rule ordering justified by a
rule that does not exist.

**One reviewer conflict, and neither reviewer was fully right.** The fact-check pass called
the missing `# renovate:` annotation a convention violation; the design pass said adding one
would be actively harmful. Checked directly: native detection works for app-template nested
images (`n8n`, nine bump PRs, no annotation), so none is *needed*. But the harm claim does
not survive either — the documented duplicate (gitea, three times) is a HelmRelease
*top-level* image block, and the annotated app-template images each appear once on the
Dependency Dashboard. Verdict: omit for a plain semver tag, but it is a preference, not a
correctness issue.

**A third pass then caught that both of us had the mechanism wrong**, via the Claude review
on PR #1754. The conflicting manager is **`flux`**, not `helm-values` — `helm-values` only
matches files literally named `values.yaml` and can never match a `helmrelease.yaml`. This
document had asserted `helm-values`, and had also attributed a phrase to
`.renovate/overrides.json5` ("not app-template") that does not appear in it. Both errors came
from reading a **pre-#1751 copy** of that file off a stale branch and never re-reading it
after branching from `origin/main` — where #1751 had already corrected exactly this
misdiagnosis, for the third time (#1389, #1540, #1681). The lesson generalises past Renovate:
*re-read a file after changing base*, and quote it rather than paraphrasing from memory.

**Verified and survived scrutiny:** the pgvector not-trusted finding and the `02-init-vector`
container; the `$$` envsubst escaping; the probe split (`/health/live` for liveness matters
more than the draft knew — `/health` acquires a DB connection, so liveness there would
restart-loop the pod on every `postgres18` failover); full image over slim; no worker
StatefulSet at one replica; `nodeSelector` over anti-affinity; both prior-art repos and every
row of the comparison table.
