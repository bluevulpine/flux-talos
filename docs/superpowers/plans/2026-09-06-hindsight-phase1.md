# Hindsight Agent Memory — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Hindsight 0.9.2 as a single pod in a new `ai` namespace, backed by the
existing `postgres18` CNPG cluster, with Claude Code as the sole consumer, gated by a
2026-09-27 evaluation.

**Architecture:** One `Deployment` (`api` + `control-plane` containers, two `postgres-init`
init containers) rendered by `app-template` 5.1.0 via `OCIRepository`. All durable state
lands in `postgres18`; the only local storage is a 1 Gi model-cache PVC. Two HTTPRoutes on
one hostname split by authentication posture: the control-plane UI behind Authentik
forward-auth, the `/v1` + `/mcp` API on bearer-token auth only.

**Tech Stack:** Flux CD (kustomize-controller + helm-controller), `app-template` 5.1.0,
CloudNativePG 1.30.0 / PostgreSQL 18.2 + pgvector 0.8.1, External Secrets Operator →
OpenBao, Envoy Gateway 1.9.1 (Gateway API), kube-prometheus-stack, Gatus.

**Spec:** `docs/superpowers/specs/2026-09-06-hindsight-agent-memory-design.md`

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from
the spec unless a line says otherwise.

- **Scope is Phase 1 only.** Hindsight + Claude Code. **Do not** wire up Hermes, Buzz
  agents, or Home Assistant. Do not move Hermes into `ai`.
- **`dependsOn` is `cloudnative-pg-cluster18`**, never `cloudnative-pg-cluster`. Flux does
  not error on a missing dependency target — the Kustomization parks in
  `dependency not ready` forever.
- **Namespace `ai` is `pod-security.kubernetes.io/enforce: baseline`**, not `restricted`.
  Load-bearing: Hermes cannot run `restricted` and is expected to move here later. The pod
  spec must still satisfy `restricted` by construction.
- **Use `${POSTGRES_HOST}` / `${POSTGRES_HOST_RO}`**, never a literal `postgres18-rw...`.
- **Every Kubernetes manifest starts with `# yaml-language-server: $schema=...`** per
  CLAUDE.md, and every `.yaml` file except `*.sops.yaml` must pass `yamlfmt` (block-style
  arrays, `---` document start, LF endings).
- **Commit messages use Scoped Commits** (`<scope>: <description>`), never Conventional
  Commits. No `feat:`/`fix:`/`chore:` prefixes.
- **Do not commit or push without being asked.** Tasks end at "changes staged and
  verified", not at `git commit`, unless the user has asked for a commit.
- **No `crds: CreateReplace`** on the HelmRelease — injected globally by the `cluster-apps`
  Flux patch.
- **No `# renovate:` annotation** on the Hindsight images. app-template nested container
  images are detected natively; omitting is the lighter choice.
- **Image tags: `0.9.2`** for both `ghcr.io/vectorize-io/hindsight-api` and
  `ghcr.io/vectorize-io/hindsight-control-plane`.
- **LLM: Anthropic + `claude-haiku-4-5`** (changed mid-execution from the spec's Gemini
  default, at the user's request to consolidate billing; see the LLM comment block in
  `app/helmrelease.yaml` for the full reasoning). Also set
  `HINDSIGHT_API_REFLECT_LLM_MODEL: claude-sonnet-5` and
  `HINDSIGHT_API_LLM_STRICT_SCHEMA: "true"`.
  **The `nous` and `claude-code` providers were evaluated and rejected**: both need
  interactive OAuth with a rotating, self-rewriting token store, which an unattended pod
  cannot hold. **OpenCode Zen is NOT being taken**, so its terms do not need reading for
  this build. (Nous Portal's terms WERE read: it trains on submitted prompts and outputs by
  default, with a "Privacy Mode" opt-out — relevant if that route is ever revisited.)
- **Do not enable the Batch API** (`HINDSIGHT_API_RETAIN_BATCH_ENABLED`).
- **`$$` escaping** in any shell `args:` block — Flux `postBuild` envsubst runs over these
  manifests and eats a bare `${...}`.

### Facts verified against upstream source and the live cluster during planning

Do not re-derive these; they are already checked.

| Fact | Evidence |
| --- | --- |
| Service keys `api` / `controlplane` render as `hindsight-api` / `hindsight-controlplane` | `helm template` of app-template 5.1.0 |
| Deployment renders as `hindsight` | same render (matters for the PrometheusRule selector) |
| app-template sets `enableServiceLinks: false` and `automountServiceAccountToken: false` by default | same render |
| Control plane's dataplane var is `HINDSIGHT_CP_DATAPLANE_API_URL` (**not** `..._URL`) | upstream `helm/hindsight/templates/controlplane-deployment.yaml:52` |
| Control plane also takes `HINDSIGHT_CP_HOSTNAME: 0.0.0.0`, `HINDSIGHT_CP_PORT: 3000`, `NODE_ENV: production` | upstream `helm/hindsight/values.yaml:321` |
| Model cache mounts at `/home/hindsight/.cache` | upstream `api-deployment.yaml:106` |
| Upstream runs uid/gid 1000, `fsGroup: 1000`, `readOnlyRootFilesystem: false` | upstream `values.yaml:397-408` |
| API probes: liveness/startup `/health/live`, readiness `/health`, port 8888 | upstream `values.yaml:44-61` |
| Control-plane probes are `tcpSocket: 3000` | upstream `values.yaml:276-287` |
| In-process worker runs unless dedicated workers exist — no enabling var needed | upstream `api-deployment.yaml:64` |
| Backlog gauges: `hindsight_async_operations{tenant,operation_type,status}`, `hindsight_consolidation_backlog{tenant}`, `hindsight_consolidation_failed{tenant}` | upstream `hindsight_api/metrics.py:1051-1069` |
| Env var names `HINDSIGHT_API_{DATABASE_URL,READ_DATABASE_URL,MIGRATION_DATABASE_URL,READ_DB_POOL_MIN_SIZE,READ_DB_POOL_MAX_SIZE,DB_POOL_MIN_SIZE,DB_POOL_MAX_SIZE,WORKER_ID,STORE_DOCUMENT_TEXT,OPERATION_RETENTION_DAYS,FAIL_ON_EXTRACTION_ERRORS,METRICS_BACKLOG_ENABLED,LLM_PROVIDER,LLM_MODEL,RETAIN_LLM_MODEL,HOST,PORT}` | upstream `hindsight_api/config.py` |
| `HINDSIGHT_API_TENANT_EXTENSION` + `HINDSIGHT_API_TENANT_API_KEY`; MCP auth is ON unless `HINDSIGHT_API_TENANT_MCP_AUTH_DISABLED=true` | upstream `extensions/builtin/tenant.py:44-67` |
| `postgres18-ro` Service exists in `database` | `kubectl get svc -n database` |
| Envoy Gateway is v1.9.1 | `kubectl get deploy -n network` |

### Deviation from the spec, decided during planning — read this

**The spec says to put `auth: authentik` on "the control-plane rule" of a single
three-rule HTTPRoute. That is not implementable in this repo and would silently fail
open.** `kubernetes/components/common/authentik-forward-auth/securitypolicy.yaml` selects
whole HTTPRoute *objects* via `targetSelectors.matchLabels`, not route rules — labels live
on `metadata`, so a label on one route covers all its rules. Applied as written, either the
UI stays unauthenticated (label omitted) or `/v1` and `/mcp` get forced into an interactive
OIDC flow that bearer-token clients cannot complete (label present).

**Resolution: two HTTPRoute objects on the same hostname.** This is not an invention — it
is the exact shape `media/calibre-web` already runs in production on
`ebooks.${SECRET_DOMAIN}`: `calibre-web-app` (`/`, label `auth: authentik`) plus
`calibre-web-kobo` (`/kobo`, no label) so Kobo devices bypass SSO. Gateway API merges
same-hostname routes on a listener and computes precedence across all of them by longest
path prefix, so `/v1` (3 chars) still beats `/` (1 char) regardless of which object it came
from. Verified live: two hostnames in this cluster already carry two HTTPRoutes each.

**Second out-of-tree edit beyond the one the brief names.** The brief mentions only
`referencegrant.yaml`. The spec additionally requires a `POSTGRES_HOST_RO` entry in
`kubernetes/components/common/cluster-config/cluster-settings.yaml`, because
`HINDSIGHT_API_READ_DATABASE_URL` points at the read replica and no app in this repo has
ever read from one, so the variable does not exist yet. This one fails **loudly** (Flux
≥ 2.9 errors on an unmapped `${VAR}`), so it blocks the build rather than slipping through.
Included in Task 1; flag it to the user at plan approval.

### Deploy-time prerequisite that is NOT part of this plan

The OpenBao key `hindsight` must exist before the ExternalSecret can sync, with fields
`Hindsight__Postgres__User`, `Hindsight__Postgres__Password`, `Hindsight__Llm__ApiKey`,
`Hindsight__TenantApiKey`. Creating it needs the user's Gemini API key and is an outward
mutation — **do not run `bao kv put` in this plan.** Task 8 documents the exact command in
the app README so the user can run it at deploy time.

`Hindsight__Postgres__Password` must be constrained to `[A-Za-z0-9]`. Hindsight takes a
DSN rather than discrete fields, so an `@`, `/`, `:` or `#` parses wrong and presents as a
bad credential.

---

## File Structure

**Create — new tree:**

| File | Responsibility |
| --- | --- |
| `kubernetes/apps/ai/kustomization.yaml` | namespace root: `namespace: ai`, `components/common`, resources = namespace + hindsight ks |
| `kubernetes/apps/ai/namespace.yaml` | Namespace `ai` at `enforce: baseline`, `prune: disabled`, with the verification comment |
| `kubernetes/apps/ai/hindsight/ks.yaml` | Flux Kustomization; `dependsOn` cluster18 + openbao store; `postBuild` APP/NS |
| `kubernetes/apps/ai/hindsight/app/kustomization.yaml` | lists the app resources; **no** `components/volsync` |
| `kubernetes/apps/ai/hindsight/app/ocirepository.yaml` | app-template 5.1.0 |
| `kubernetes/apps/ai/hindsight/app/externalsecret.yaml` | OpenBao `hindsight` + shared `cloudnative-pg`; DSNs, tenant key, pool sizes |
| `kubernetes/apps/ai/hindsight/app/pvc.yaml` | 1 Gi model cache, `longhorn-1-replica-local`, standalone |
| `kubernetes/apps/ai/hindsight/app/helmrelease.yaml` | the workload: 2 init containers, 2 containers, probes, securityContext, services |
| `kubernetes/apps/ai/hindsight/app/httproute.yaml` | **two** HTTPRoutes: API (no auth) + control plane (`auth: authentik`) |
| `kubernetes/apps/ai/hindsight/app/servicemonitor.yaml` | selects `hindsight-api` only; the control plane exposes no metrics |
| `kubernetes/apps/ai/hindsight/app/prometheusrule.yaml` | Down + ImagePullFailing + RetainBacklog + ConsolidationFailing |
| `kubernetes/apps/ai/hindsight/README.md` | OpenBao prerequisite, Claude Code plugin config, exit criterion, teardown |

**Modify — outside the new tree:**

| File | Change |
| --- | --- |
| `kubernetes/apps/identity/authentik/app/referencegrant.yaml` | add an `ai` namespace entry to `spec.from` |
| `kubernetes/components/common/cluster-config/cluster-settings.yaml` | add `POSTGRES_HOST_RO` |
| `CLAUDE.md` | **separate commit** — stale `cloudnative-pg-cluster` → `cloudnative-pg-cluster18` |

**Deliberately not created:** `gatus.yaml`. The spec's file plan lists one, but its own
Observability section specifies the `gatus.home-operations.com/endpoint` HTTPRoute
annotation, which is this repo's pattern for HTTP-routed apps (`hermes`, `longhorn`). The
only standalone `gatus.yaml` files here are for non-HTTP services (`postgres18`,
`dragonfly`). The annotation approach is used.

---

## Task 1: Out-of-tree prerequisites

Both edits are prerequisites for the `ai` tree and are independently verifiable. Doing them
first means the `ai` Kustomization has somewhere to land when it appears.

**Files:**
- Modify: `kubernetes/components/common/cluster-config/cluster-settings.yaml`
- Modify: `kubernetes/apps/identity/authentik/app/referencegrant.yaml`

**Interfaces:**
- Produces: `${POSTGRES_HOST_RO}` substitution variable, consumed by Task 4's ExternalSecret.
- Produces: `ai` in the ReferenceGrant, consumed by Task 6's `auth: authentik` HTTPRoute label.

- [ ] **Step 1: Add `POSTGRES_HOST_RO` to cluster-settings**

In `kubernetes/components/common/cluster-config/cluster-settings.yaml`, immediately after
the existing `POSTGRES_HOST:` line, add:

```yaml
  # In-cluster CNPG READ-ONLY endpoint (replicas only; postgres18-ro excludes the
  # primary). Added for hindsight, the first app here to read from a replica —
  # its recall path is read-only and is the hot path, so it is pointed at the
  # replicas while writes and migrations keep using ${POSTGRES_HOST} above.
  # Same one-line-cutover rationale: a major-version swap changes this line, not
  # every consumer.
  POSTGRES_HOST_RO: "postgres18-ro.database.svc.cluster.local"
```

- [ ] **Step 2: Verify the RO Service actually exists before relying on the name**

Run:
```bash
kubectl get svc -n database postgres18-ro
```
Expected: one row, `ClusterIP`, port `5432/TCP`. If this 404s, stop — the variable would
point at nothing and Hindsight's read pool would fail at startup.

- [ ] **Step 3: Add `ai` to the Authentik ReferenceGrant**

In `kubernetes/apps/identity/authentik/app/referencegrant.yaml`, inside `spec.from`, add a
new entry. Place it first in the list so the alphabetical-ish grouping is not disturbed
mid-file — position does not matter functionally. Insert directly above the
`# Network namespace` entry:

```yaml
    # AI namespace (hindsight control-plane UI)
    - group: gateway.envoyproxy.io
      kind: SecurityPolicy
      namespace: ai
```

- [ ] **Step 4: Confirm the grant edit parses and the entry is present**

Run:
```bash
kubectl apply --dry-run=client -f kubernetes/apps/identity/authentik/app/referencegrant.yaml -o jsonpath='{range .spec.from[*]}{.namespace}{"\n"}{end}'
```
Expected: a list of namespaces that includes `ai`. Client-side dry-run is deliberate here —
a server-side one would need the `identity` namespace context and adds nothing, since the
only question is whether the list now contains `ai`.

- [ ] **Step 5: Verify why this matters, so the check is not cargo-culted**

Run:
```bash
grep -n 'matchLabels' -A2 kubernetes/components/common/authentik-forward-auth/securitypolicy.yaml
```
Expected: `auth: authentik`. This confirms the SecurityPolicy that `components/common`
renders into `ai` selects on that label, and the ReferenceGrant is what lets it reach
`ak-outpost-sso-proxy` in `identity`. Without the grant the policy attaches and does
nothing — no error, UI open.

- [ ] **Step 6: Format check**

Run:
```bash
yamlfmt -lint kubernetes/components/common/cluster-config/cluster-settings.yaml kubernetes/apps/identity/authentik/app/referencegrant.yaml
```
Expected: no output (exit 0).

---

## Task 2: The `ai` namespace and its Flux wiring

Creates the namespace with a provisional `baseline` label. **The verification comment is
written in Task 7**, once there is a real rendered pod to check it against — writing the
comment now would assert what has not been verified, which is exactly the error the spec's
review caught in draft one.

**Files:**
- Create: `kubernetes/apps/ai/namespace.yaml`
- Create: `kubernetes/apps/ai/kustomization.yaml`

**Interfaces:**
- Produces: namespace `ai`; the `kustomization.yaml` references `./hindsight/ks.yaml`,
  created in Task 3. Between Task 2 and Task 3 the kustomize build will fail on the missing
  file — that is expected and is resolved by Task 3.

- [ ] **Step 1: Create `kubernetes/apps/ai/namespace.yaml`**

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: ai
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
  labels:
    # PROVISIONAL — the verification comment is filled in by the PSS task once
    # there is a rendered pod to check against. Do not ship this file with this
    # comment still here.
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: latest
```

- [ ] **Step 2: Create `kubernetes/apps/ai/kustomization.yaml`**

Modelled on `kubernetes/apps/kopiur-system/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ai
components:
  - ../../components/common
resources:
  - ./namespace.yaml
  - ./hindsight/ks.yaml
```

- [ ] **Step 3: Verify no Flux wiring change is needed elsewhere**

Run:
```bash
grep -n 'path:' kubernetes/flux/cluster/ks.yaml
```
Expected: a line pointing at `./kubernetes/apps`. kustomize-controller recurses and
autodetects namespace directories, so adding `kubernetes/apps/ai/` requires no edit under
`kubernetes/flux/`. Commit `4b8f51c5` added the whole `kopiur-system` namespace touching
only files inside its own directory — confirm with:
```bash
git show --stat 4b8f51c5 | head -20
```
Expected: every changed path is under `kubernetes/apps/kopiur-system/`.

- [ ] **Step 4: Confirm the Namespace object itself is valid server-side**

Run:
```bash
kubectl create --dry-run=server -f kubernetes/apps/ai/namespace.yaml
```
Expected: `namespace/ai created (server dry run)`. This validates the PSA label *value* is
one the API server accepts — an invalid level is rejected here. It does **not** prove pods
will pass; that is Task 7.

---

## Task 3: Flux Kustomization for hindsight

**Files:**
- Create: `kubernetes/apps/ai/hindsight/ks.yaml`

**Interfaces:**
- Consumes: namespace `ai` from Task 2.
- Produces: `${APP}` = `hindsight` and `${NS}` = `ai` substitutions for the app manifests.

- [ ] **Step 1: Verify the dependsOn target name before writing it**

This is gate #1 from the spec and the single most likely silent failure. Run:
```bash
kubectl get kustomization -n flux-system --no-headers -o custom-columns=NAME:.metadata.name | grep -i cloudnative
```
Expected: `cloudnative-pg-cluster18` present, and **no** bare `cloudnative-pg-cluster`.
Cross-check the repo:
```bash
grep -n 'name: &app' kubernetes/apps/database/cloudnative-pg/ks.yaml
```
Expected: includes `cloudnative-pg-cluster18`.

- [ ] **Step 2: Create `kubernetes/apps/ai/hindsight/ks.yaml`**

Shape follows `kubernetes/apps/observability/rackpanel/ks.yaml` (a non-VolSync app, so
`APP` and `NS` only — no `GATUS_*` or `VOLSYNC_*` vars; nothing in
`kubernetes/components/` consumes `GATUS_PORT`/`GATUS_SERVICE`).

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app hindsight
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn:
    # NOT `cloudnative-pg-cluster` — that Kustomization does not exist. The real
    # name is `cloudnative-pg-cluster18` and every sibling app uses the 18
    # suffix. Flux does not error on a missing dependsOn target; it parks in
    # `dependency not ready` forever, with no alert and no event.
    - name: cloudnative-pg-cluster18
      namespace: database
    - name: external-secrets-openbao-store
      namespace: external-secrets
  path: ./kubernetes/apps/ai/hindsight/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: home-kubernetes
    namespace: flux-system
  targetNamespace: ai
  wait: false
  interval: 30m
  retryInterval: 1m
  timeout: 5m
  postBuild:
    substitute:
      APP: *app
      NS: ai
```

- [ ] **Step 3: Verify the Kustomization parses**

Run:
```bash
kubectl apply --dry-run=client -f kubernetes/apps/ai/hindsight/ks.yaml
```
Expected: `kustomization.kustomize.toolkit.fluxcd.io/hindsight created (dry run)`.

---

## Task 4: Secrets and storage

**Files:**
- Create: `kubernetes/apps/ai/hindsight/app/externalsecret.yaml`
- Create: `kubernetes/apps/ai/hindsight/app/pvc.yaml`
- Create: `kubernetes/apps/ai/hindsight/app/ocirepository.yaml`

**Interfaces:**
- Consumes: `${POSTGRES_HOST}` and `${POSTGRES_HOST_RO}` from Task 1.
- Produces: Secret `hindsight-secret` (consumed by every container in Task 5 via
  `envFrom`), PVC `hindsight-hf-cache`, OCIRepository `hindsight`.

- [ ] **Step 1: Create `kubernetes/apps/ai/hindsight/app/ocirepository.yaml`**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: hindsight
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 5.1.0
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

- [ ] **Step 2: Create `kubernetes/apps/ai/hindsight/app/externalsecret.yaml`**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/external-secrets.io/externalsecret_v1.json
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: &name hindsight-secret
spec:
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: *name
    template:
      engineVersion: v2
      data:
        # --- postgres-init (init containers 01 and 02) ---
        INIT_POSTGRES_HOST: &dbHost ${POSTGRES_HOST}
        INIT_POSTGRES_USER: &dbUser "{{ .Hindsight__Postgres__User }}"
        INIT_POSTGRES_PASS: "{{ .Hindsight__Postgres__Password }}"
        INIT_POSTGRES_DBNAME: &dbName hindsight
        # Superuser comes from the SHARED cloudnative-pg key, not per-app, so it
        # lives in exactly one place. Used to bootstrap the role/database and to
        # CREATE EXTENSION vector (see 02-init-vector in the HelmRelease).
        INIT_POSTGRES_SUPER_PASS: "{{ .Postgres__SuperPassword }}"

        # --- Hindsight database connections ---
        # Hindsight takes a DSN, not discrete host/user/pass fields — unlike
        # every other Postgres app here. That makes the password
        # percent-encoding-sensitive: an `@`, `/`, `:` or `#` in
        # Hindsight__Postgres__Password parses wrong and presents as a bad
        # credential, not as a malformed URL. Constrain the OpenBao generator to
        # [A-Za-z0-9]. See README.md.
        HINDSIGHT_API_DATABASE_URL: &dsn "postgresql://{{ .Hindsight__Postgres__User }}:{{ .Hindsight__Postgres__Password }}@${POSTGRES_HOST}:5432/hindsight"
        # Migrations get their own connection so a saturated app pool cannot
        # wedge them.
        HINDSIGHT_API_MIGRATION_DATABASE_URL: *dsn
        # Recall is read-only and is the hot path — send it to the replicas.
        # ${POSTGRES_HOST_RO} was added to cluster-settings.yaml for this app;
        # hardcoding postgres18-ro here would break the next major-version
        # cutover silently, which is the whole reason ${POSTGRES_HOST} exists.
        HINDSIGHT_API_READ_DATABASE_URL: "postgresql://{{ .Hindsight__Postgres__User }}:{{ .Hindsight__Postgres__Password }}@${POSTGRES_HOST_RO}:5432/hindsight"

        # --- credentials ---
        HINDSIGHT_API_LLM_API_KEY: "{{ .Hindsight__Llm__ApiKey }}"
        # ONE key, cluster-admin-equivalent. It grants full read AND WRITE across
        # every bank — there is no per-consumer isolation (ApiKeyTenantExtension
        # resolves every authenticated request to one hardcoded schema). Write is
        # the dangerous half: recalled memories are injected directly into the
        # prompt of a Claude Code session holding kubectl, so a planted memory is
        # a persistent prompt-injection channel with a multi-week fuse. Rotate on
        # the same footing as a cluster-admin credential.
        HINDSIGHT_API_TENANT_API_KEY: "{{ .Hindsight__TenantApiKey }}"
        # The control plane proxies to the dataplane with the SAME key. This is
        # why the UI needs Authentik in front of it — the API key does not
        # protect it; it is what makes the UI fully authenticated to anyone who
        # reaches it.
        HINDSIGHT_CP_DATAPLANE_API_KEY: "{{ .Hindsight__TenantApiKey }}"
  dataFrom:
    - extract:
        key: hindsight
    - extract:
        key: cloudnative-pg
```

Note `&dbName` is declared for readability parity with the repo's other externalsecrets;
if `yamlfmt` or a linter flags the unused anchor, drop the anchor and keep the literal
value `hindsight`.

- [ ] **Step 3: Create `kubernetes/apps/ai/hindsight/app/pvc.yaml`**

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hindsight-hf-cache
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      # ~220 MB of weights (BGE embedder ~130 MB + MiniLM cross-encoder ~90 MB).
      # Upstream's chart defaults this to 5Gi; 1Gi is ~4x headroom for what the
      # full image actually fetches.
      storage: 1Gi
  # Deliberately NO components/volsync: this is a rebuildable cache, not state.
  # All durable memory lives in postgres18, already covered by barman-cloud ->
  # Garage S3 plus the cnpg-offsite job. VolSync is opt-in per app here —
  # karakeep, tracearr, plex, satisfactory and valheim all carry a standalone
  # pvc.yaml with no volsync component.
  #
  # The PVC exists for AVAILABILITY, not latency: without it, every pod move
  # puts huggingface.co on the critical startup path of a service the agents
  # depend on. With strategy: Recreate the old pod dies first, so a node drain
  # means full 1.42 GB image pull + extract + ~220 MB weight fetch + torch
  # import + migrations, all inside the 300s startup probe.
  storageClassName: longhorn-1-replica-local
```

- [ ] **Step 4: Verify the storage class exists**

Run:
```bash
kubectl get storageclass longhorn-1-replica-local
```
Expected: one row. If missing, stop — the PVC would sit `Pending` and the pod would never
schedule.

- [ ] **Step 5: Verify both substitution variables now resolve**

Run:
```bash
kubectl get cm -n flux-system cluster-settings -o jsonpath='{.data.POSTGRES_HOST}{"\n"}{.data.POSTGRES_HOST_RO}{"\n"}' 2>/dev/null
grep -nE 'POSTGRES_HOST(_RO)?:' kubernetes/components/common/cluster-config/cluster-settings.yaml
```
Expected: the repo grep shows both keys. The live ConfigMap will only show
`POSTGRES_HOST_RO` after Task 1 is reconciled to the cluster — an empty second line here is
expected pre-merge and is not a failure.

- [ ] **Step 6: Format check**

Run:
```bash
yamlfmt -lint kubernetes/apps/ai/hindsight/app/*.yaml
```
Expected: no output.

---

## Task 5: The HelmRelease

The largest single file. Everything else is scaffolding around this.

**Files:**
- Create: `kubernetes/apps/ai/hindsight/app/helmrelease.yaml`

**Interfaces:**
- Consumes: OCIRepository `hindsight`, Secret `hindsight-secret`, PVC `hindsight-hf-cache`
  (Task 4).
- Produces: Deployment `hindsight`; Services `hindsight-api` (8888) and
  `hindsight-controlplane` (3000), consumed by Task 6's HTTPRoutes and ServiceMonitor.

- [ ] **Step 1: Create `kubernetes/apps/ai/hindsight/app/helmrelease.yaml`**

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: &app hindsight
spec:
  chartRef:
    kind: OCIRepository
    name: *app
  interval: 1h
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      strategy: rollback
      retries: 3
  values:
    controllers:
      hindsight:
        type: deployment
        annotations:
          reloader.stakater.com/auto: "true"
        # Recreate, not RollingUpdate: the model-cache PVC is RWO, so a rolling
        # update would deadlock on the new pod waiting for a volume the old pod
        # still holds. Scaling past one replica additionally requires
        # HINDSIGHT_API_MCP_STATELESS: "true" — noted so a future scale-up does
        # not silently break MCP sessions.
        strategy: Recreate
        initContainers:
          # Creates the hindsight role and database as the superuser, then grants
          # the role ownership. Idempotent; safe on every restart.
          01-init-db:
            image:
              repository: ghcr.io/home-operations/postgres-init
              tag: rolling
            envFrom: &envFrom
              - secretRef:
                  name: hindsight-secret
            securityContext: &hardened
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
          # Hindsight's own migrations TRY to create the extension
          # (migrations.py:_ensure_pgvector_extension_in_public) but that attempt
          # fails for the app role: pgvector is NOT a PostgreSQL "trusted"
          # extension (vector.control at 0.8.1 has no `trusted = true`), so a
          # non-superuser cannot CREATE EXTENSION vector. It surfaces as
          # "pgvector extension is required but not installed" and is the single
          # most likely thing to break a naive first deploy.
          #
          # Same image as 01 — it ships psql. Runs as the superuser against the
          # database 01 just made. Idempotent.
          02-init-vector:
            dependsOn: 01-init-db
            image:
              repository: ghcr.io/home-operations/postgres-init
              tag: rolling
            envFrom: *envFrom
            command: ["/bin/sh", "-c"]
            args:
              # $$ escapes each ${VAR}: these are runtime shell vars from the
              # secret, not Flux postBuild substitutions. kustomize-controller
              # runs envsubst over this whole manifest and since Flux v2.9.0 an
              # unmapped ${VAR} fails hard. $$ makes Flux emit a literal ${VAR}
              # for the shell to expand at container runtime.
              - |
                PGPASSWORD="$${INIT_POSTGRES_SUPER_PASS}" psql \
                  -h "$${INIT_POSTGRES_HOST}" -U postgres -d "$${INIT_POSTGRES_DBNAME}" \
                  -c 'CREATE EXTENSION IF NOT EXISTS vector;'
            securityContext: *hardened
        containers:
          api:
            image:
              repository: ghcr.io/vectorize-io/hindsight-api
              # PRE-1.0. Renovate calls 0.9.x -> 0.10.x a "minor", which reads as
              # routine; upstream may mean "breaking". Migrations run on startup
              # (HINDSIGHT_API_RUN_MIGRATIONS_ON_STARTUP defaults true) and are
              # one-way, and CNPG PITR cannot restore this database alone — it
              # restores the whole cluster, dragging all ~34 databases with it.
              # Before merging any bump past the patch digit:
              #   kubectl -n database exec postgres18-1 -- \
              #     pg_dump -U postgres -Fc hindsight > hindsight-<ver>.dump
              #
              # No `# renovate:` annotation on purpose — app-template nested
              # images are detected natively (n8n carries none and has nine bump
              # PRs), and doubling up risks duplicate PRs.
              #
              # The FULL image, not -slim: it loads the BGE embedder and the
              # MiniLM cross-encoder reranker in-process, so embeddings and
              # reranking need no external service and no API key. -slim forces
              # both onto remote providers or in-cluster TEI — that is the
              # scale-out path, not the starting point.
              tag: 0.9.2
            envFrom: *envFrom
            env:
              TZ: "${TIMEZONE}"
              HINDSIGHT_API_HOST: 0.0.0.0
              # Set explicitly on upstream's advice: if enableServiceLinks were
              # ever true, Kubernetes would inject HINDSIGHT_API_PORT as
              # "tcp://<ip>:8888" from the hindsight-api Service and the app
              # would fail to parse its own port. app-template defaults
              # enableServiceLinks to false, so this is belt-and-braces.
              HINDSIGHT_API_PORT: &apiPort 8888
              # At one replica the upstream worker StatefulSet (whose whole point
              # is deriving a stable worker id from a pod ordinal) buys nothing.
              # Set the id statically and let the API run its in-process worker.
              HINDSIGHT_API_WORKER_ID: hindsight

              # --- auth: NOT optional ---
              # Without this, /v1 and /mcp are unauthenticated and anything on
              # the LAN can read and write every agent's memory. Note the name
              # oversells it: this is single-tenant bearer auth. authenticate()
              # compares one expected key and returns one hardcoded schema for
              # every request — there is NO per-consumer isolation, so banks are
              # a naming convention, not a boundary.
              HINDSIGHT_API_TENANT_EXTENSION: hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension

              # --- connection pool: cap it ---
              # postgres18 runs max_connections=400 across ~34 databases, no app
              # here sets a client pool size, and there is no pgbouncer/Pooler.
              # Hindsight's default DB_POOL_MAX_SIZE is 100 — a quarter of the
              # entire cluster budget for one evaluation pod. The exhaustion mode
              # is self-obscuring: /health acquires a connection, so on pool
              # exhaustion readiness AND liveness fail and the pod restarts,
              # reading as an app bug while Authentik and Immich start failing to
              # connect first and point the investigation elsewhere.
              HINDSIGHT_API_DB_POOL_MIN_SIZE: "2"
              HINDSIGHT_API_DB_POOL_MAX_SIZE: "20"
              HINDSIGHT_API_READ_DB_POOL_MAX_SIZE: "10"

              # --- retention ---
              # KEEP the raw text: it is the provenance copy, the thing that lets
              # you judge whether a recalled fact is right — which the
              # zero-wrong-facts exit criterion depends on. Reversible at the
              # Phase 1 gate, though flipping it will not retroactively purge
              # what is already stored.
              HINDSIGHT_API_STORE_DOCUMENT_TEXT: "true"
              # But do NOT keep a second, accidental copy. Terminal operation
              # rows carry the full retain payload and default to being kept
              # FOREVER (0 = no pruning) — that is the same transcript again, as
              # a debug artifact, replicated across three CNPG instances and
              # swept offsite. 14d is enough to debug a failed retain.
              HINDSIGHT_API_OPERATION_RETENTION_DAYS: "14"
              # Surface silently-dropped facts instead of marking the retain
              # completed.
              HINDSIGHT_API_FAIL_ON_EXTRACTION_ERRORS: "true"

              # --- LLM ---
              # recall makes NO LLM call — it is pure retrieval, so the hot read
              # path costs no tokens regardless of what is set here. retain and
              # reflect do, and auto-consolidation (on by default) fires an extra
              # call after every retain, delete and update.
              HINDSIGHT_API_LLM_PROVIDER: gemini
              HINDSIGHT_API_LLM_MODEL: gemini-3.5-flash
              # ~80% of retain cost is OUTPUT tokens, which makes full Flash the
              # wrong default on the axis that dominates. Structured extraction
              # against a schema is the easiest job in the pipeline; keep full
              # Flash for reflect, where reasoning quality actually shows up.
              HINDSIGHT_API_RETAIN_LLM_MODEL: gemini-3.5-flash-lite

              # --- observability ---
              # Neither HindsightDown nor HindsightImagePullFailing catches the
              # failure mode that actually matters: pod 1/1 Running, retains
              # failing, memory silently frozen. This enables the backlog gauges
              # the PrometheusRule alerts on.
              HINDSIGHT_API_METRICS_BACKLOG_ENABLED: "true"
            probes:
              # Liveness on /health/live, which performs NO database access.
              # /health does acquire a connection, so liveness there would
              # restart-loop the pod on every postgres18 failover. Readiness on
              # /health is correct: a pod that cannot reach the database should
              # leave the Service and rejoin when it recovers.
              liveness:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /health/live
                    port: *apiPort
                  initialDelaySeconds: 0
                  periodSeconds: 10
                  timeoutSeconds: 5
                  failureThreshold: 3
              readiness:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /health
                    port: *apiPort
                  initialDelaySeconds: 0
                  periodSeconds: 10
                  timeoutSeconds: 5
                  failureThreshold: 3
              # 300s. Cold start on a node without the image is a 1.42 GB pull
              # across 15 layers (two ~565 MB torch layers), extract, ~220 MB
              # weight fetch if the cache PVC is empty, torch import, then
              # Alembic migrations.
              startup:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /health/live
                    port: *apiPort
                  initialDelaySeconds: 10
                  periodSeconds: 10
                  timeoutSeconds: 5
                  failureThreshold: 30
            securityContext:
              allowPrivilegeEscalation: false
              # false, matching upstream: the process writes to the HuggingFace
              # cache and to /tmp. Both are mounted volumes below, but the image
              # is not built for a read-only root and upstream does not claim it.
              readOnlyRootFilesystem: false
              capabilities:
                drop: ["ALL"]
            resources:
              requests:
                cpu: 100m
                memory: 1Gi
              limits:
                # Upstream's stated minimum for the full API is 1.5 GB,
                # recommended 2 GB. 4Gi is headroom for the reranker's batch
                # forward passes.
                memory: 4Gi
          control-plane:
            image:
              repository: ghcr.io/vectorize-io/hindsight-control-plane
              # See the pre-1.0 warning on the api image above — bump both
              # together; they are one release.
              tag: 0.9.2
            envFrom: *envFrom
            env:
              TZ: "${TIMEZONE}"
              NODE_ENV: production
              HINDSIGHT_CP_HOSTNAME: 0.0.0.0
              HINDSIGHT_CP_PORT: &cpPort 3000
              # Same pod, so container loopback. Note the var is
              # ..._DATAPLANE_API_URL, not ..._DATAPLANE_URL — verified against
              # upstream's controlplane-deployment.yaml; the shorter name is
              # wrong and would leave the UI unable to reach the API.
              HINDSIGHT_CP_DATAPLANE_API_URL: http://localhost:8888
            probes:
              # tcpSocket, matching upstream: the Next.js control plane has no
              # health endpoint of its own that is safe to probe.
              liveness: &cpProbe
                enabled: true
                custom: true
                spec:
                  tcpSocket:
                    port: *cpPort
                  initialDelaySeconds: 30
                  periodSeconds: 10
                  timeoutSeconds: 5
                  failureThreshold: 3
              readiness: *cpProbe
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: false
              capabilities:
                drop: ["ALL"]
            resources:
              requests:
                cpu: 50m
                memory: 256Mi
              limits:
                memory: 1Gi
    defaultPodOptions:
      # The namespace enforces `baseline`, but this pod complies with
      # `restricted` by construction and should keep doing so — baseline is the
      # namespace floor, not a licence to skip the pod spec. If Hermes never
      # moves in, the namespace can be tightened without touching this file.
      # PSA evaluates INIT containers too, which is why 01-init-db and
      # 02-init-vector carry the same hardened securityContext.
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
      # amd64 only. The Pis (jormungandr1..4) are 4 CPU / 7.8 GiB and already at
      # 39-72% memory; a 1-4 Gi pod does not belong there. A nodeSelector is a
      # simpler and more durable expression of that than an anti-affinity rule.
      nodeSelector:
        kubernetes.io/arch: amd64
    service:
      api:
        controller: hindsight
        ports:
          http:
            port: *apiPort
      controlplane:
        controller: hindsight
        ports:
          http:
            port: *cpPort
    persistence:
      hf-cache:
        existingClaim: hindsight-hf-cache
        globalMounts:
          - path: /home/hindsight/.cache
      tmp:
        type: emptyDir
        globalMounts:
          - path: /tmp
```

- [ ] **Step 2: Render the HelmRelease to confirm it produces what the other files expect**

`helm` on this host has a `credsStore` that is not installed, so point `DOCKER_CONFIG` at a
clean directory first.

Run:
```bash
SCRATCH=$(mktemp -d)
mkdir -p "$SCRATCH/dockercfg" && echo '{"auths":{}}' > "$SCRATCH/dockercfg/config.json"
python3 - <<'PY' > "$SCRATCH/values.yaml"
import re, sys, yaml
doc = yaml.safe_load(open('kubernetes/apps/ai/hindsight/app/helmrelease.yaml'))
yaml.safe_dump(doc['spec']['values'], sys.stdout, default_flow_style=False)
PY
DOCKER_CONFIG="$SCRATCH/dockercfg" helm template hindsight \
  oci://ghcr.io/bjw-s-labs/helm/app-template --version 5.1.0 \
  -f "$SCRATCH/values.yaml" > "$SCRATCH/render.yaml"
echo "--- names ---"
grep -nE '^kind:|^  name:' "$SCRATCH/render.yaml"
echo "--- security ---"
grep -nE 'runAsNonRoot|runAsUser|seccompProfile|allowPrivilegeEscalation|drop|kubernetes.io/arch' "$SCRATCH/render.yaml"
echo "SCRATCH=$SCRATCH"
```

Expected:
- `Service` named `hindsight-api` and `Service` named `hindsight-controlplane`
- `Deployment` named `hindsight`
- `runAsNonRoot: true`, `runAsUser: 1000`, `seccompProfile.type: RuntimeDefault` at pod level
- `allowPrivilegeEscalation: false` and `drop: [ALL]` on **four** containers (2 init + 2 app)
- `kubernetes.io/arch: amd64` present

Keep `$SCRATCH` — Task 7 reuses `render.yaml`.

- [ ] **Step 3: Format check**

Run:
```bash
yamlfmt -lint kubernetes/apps/ai/hindsight/app/helmrelease.yaml
```
Expected: no output.

---

## Task 6: Routing and monitoring

**Files:**
- Create: `kubernetes/apps/ai/hindsight/app/httproute.yaml`
- Create: `kubernetes/apps/ai/hindsight/app/servicemonitor.yaml`
- Create: `kubernetes/apps/ai/hindsight/app/prometheusrule.yaml`
- Create: `kubernetes/apps/ai/hindsight/app/kustomization.yaml`

**Interfaces:**
- Consumes: Services `hindsight-api` / `hindsight-controlplane` and Deployment `hindsight`
  from Task 5; the `ai` ReferenceGrant entry from Task 1.

- [ ] **Step 1: Create `kubernetes/apps/ai/hindsight/app/httproute.yaml` — two routes**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/gateway.networking.k8s.io/httproute_v1.json
# TWO HTTPRoute objects on ONE hostname, split by AUTHENTICATION POSTURE.
#
# This is not stylistic. components/common renders a SecurityPolicy into every
# namespace whose `targetSelectors.matchLabels: {auth: authentik}` selects whole
# HTTPRoute OBJECTS — labels live on metadata, so a label cannot be scoped to
# one rule. One three-rule route would therefore either leave the control-plane
# UI open (no label) or force /v1 and /mcp through an interactive OIDC flow that
# bearer-token clients cannot complete (label present).
#
# media/calibre-web already runs exactly this shape in production on
# ebooks.${SECRET_DOMAIN}: calibre-web-app (`/`, auth: authentik) plus
# calibre-web-kobo (`/kobo`, no label) so Kobo devices bypass SSO.
#
# Rule ORDER across the two objects is not what makes this work. Gateway API
# precedence is exact-path first, then longest prefix by character count, then
# method, header count, query-param count — object and list order are only final
# tiebreakers. `/v1` (3 chars) beats `/` (1 char) wherever it sits.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hindsight-api
  # NO `auth: authentik` label, deliberately. The Claude Code plugin
  # authenticates with a bearer token (Authorization: Bearer <tenant key>) and
  # cannot complete an interactive OIDC redirect. Adding the label here would
  # break every consumer. These paths are protected by
  # HINDSIGHT_API_TENANT_EXTENSION instead — a missing or wrong key returns 401,
  # and MCP auth is on unless HINDSIGHT_API_TENANT_MCP_AUTH_DISABLED is set,
  # which it is not.
spec:
  hostnames: ["hindsight.${SECRET_DOMAIN}"]
  # Internal gateway ONLY. Not exposed on `external`: a single bearer-token
  # holder can WRITE memories that get injected into a kubectl-holding agent's
  # prompt. If claude.ai web sessions ever need this, that is a separate
  # decision with its own threat model and should use OAuth via Authentik, not a
  # shared token. Tailnet clients already reach this route the same way Hermes
  # does — ts-exit-node advertises 172.16.8.0/24 and the internal gateway is
  # 172.16.8.2.
  parentRefs:
    - name: internal
      namespace: network
      sectionName: https
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1
      backendRefs:
        - name: hindsight-api
          port: 8888
    - matches:
        - path:
            type: PathPrefix
            value: /mcp
      backendRefs:
        - name: hindsight-api
          port: 8888
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hindsight-controlplane
  annotations:
    gatus.home-operations.com/endpoint: |
      group: ai
    gethomepage.dev/enabled: "true"
    gethomepage.dev/name: "Hindsight"
    gethomepage.dev/group: "AI"
    gethomepage.dev/icon: "mdi-brain"
    gethomepage.dev/description: "Agent memory"
  labels:
    # The API key does NOT protect this UI — the control plane proxies to the
    # dataplane using that same key, so without this label
    # `curl https://hindsight.${SECRET_DOMAIN}/` from anywhere on the LAN or the
    # tailnet returns a fully-authenticated web UI over every memory bank, and
    # the security gain over running with no auth at all is approximately zero.
    #
    # Requires `ai` in kubernetes/apps/identity/authentik/app/referencegrant.yaml
    # — without the grant the SecurityPolicy cannot reference
    # ak-outpost-sso-proxy and this label SILENTLY does nothing.
    #
    # Chosen over upstream's HINDSIGHT_CP_ACCESS_KEY because it is SSO the
    # cluster already runs, rather than a second shared secret to rotate.
    auth: authentik
spec:
  hostnames: ["hindsight.${SECRET_DOMAIN}"]
  parentRefs:
    - name: internal
      namespace: network
      sectionName: https
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: hindsight-controlplane
          port: 3000
```

- [ ] **Step 2: Create `kubernetes/apps/ai/hindsight/app/servicemonitor.yaml`**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/monitoring.coreos.com/servicemonitor_v1.json
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: hindsight
spec:
  # Selects the API service ONLY. GET /metrics is registered unconditionally on
  # the API's own port 8888 (api/http.py, prometheus_client) with no enabling
  # env var. The Next.js control plane exposes NO metrics endpoint, so including
  # hindsight-controlplane here would add a permanently-failing target.
  #
  # NOTE the label key: app-template stamps Services with
  # `app.kubernetes.io/service: <release>-<serviceKey>`. There is no `controller`
  # or `component` label on the Service — selecting on either matches nothing,
  # silently. No `release:` label is required either: this cluster's Prometheus
  # runs serviceMonitorSelector: {}.
  selector:
    matchLabels:
      app.kubernetes.io/instance: hindsight
      app.kubernetes.io/service: hindsight-api
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

- [ ] **Step 3: Create `kubernetes/apps/ai/hindsight/app/prometheusrule.yaml`**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/monitoring.coreos.com/prometheusrule_v1.json
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: hindsight
spec:
  groups:
    - name: hindsight.rules
      rules:
        # Gatus also watches this host, but do NOT count that as paging cover:
        # every annotation-based Gatus endpoint in this repo sets only `group:`,
        # and only the four hand-written endpoints in
        # observability/gatus/app/resources/config.yaml declare pushover alerts.
        # Treat Gatus as a dashboard tile; these rules do the paging.
        - alert: HindsightDown
          annotations:
            summary: >-
              Hindsight has no ready replicas — agent memory recall and retain
              are both offline. Check `kubectl logs -n ai deploy/hindsight -c
              api`. Most likely causes: postgres18 unreachable (readiness probes
              /health, which acquires a DB connection), the pgvector extension
              missing (02-init-vector failed), or connection-pool exhaustion.
          expr: |
            kube_deployment_status_replicas_ready{namespace="ai", deployment="hindsight"} == 0
          for: 15m
          labels:
            severity: critical

        # A Deployment whose image can't be pulled never becomes ready, so
        # HindsightDown WILL eventually fire — but ImagePullBackOff does not trip
        # the pod-failure alert (docs/runbooks/flux-image-automation.md, Gotcha
        # 3), and this names the cause directly. Not optional for a 1.42 GB image
        # behind the Nexus pull-through mirror.
        - alert: HindsightImagePullFailing
          annotations:
            summary: >-
              Hindsight pod {{ $labels.pod }} can't pull its image
              ({{ $labels.reason }}). Check the image refs in
              kubernetes/apps/ai/hindsight/app/helmrelease.yaml and the Nexus
              pull-through mirror.
          expr: |
            kube_pod_container_status_waiting_reason{namespace="ai", pod=~"hindsight-.*", reason=~"ImagePullBackOff|ErrImagePull|InvalidImageName"} > 0
          for: 15m
          labels:
            severity: critical

        # The failure mode neither alert above catches: pod 1/1 Running, retains
        # failing, memory silently frozen. Gated on
        # HINDSIGHT_API_METRICS_BACKLOG_ENABLED: "true" in the HelmRelease.
        # Gauge is refreshed every 30s by a background task
        # (BACKLOG_METRICS_REFRESH_SECONDS), so a 30m window is many samples.
        - alert: HindsightRetainBacklog
          annotations:
            summary: >-
              Hindsight has {{ $value | printf "%.0f" }} operations stuck in
              pending/processing for 30m — retains are queuing, not completing,
              and memory is going stale while the pod reads healthy. Check the
              Gemini API key and quota first (`kubectl logs -n ai
              deploy/hindsight -c api | grep -i llm`), then the worker.
          expr: |
            sum(hindsight_async_operations{namespace="ai", status=~"pending|processing"}) > 50
          for: 30m
          labels:
            severity: warning

        # Consolidation fires after every retain and dedups against the whole
        # bank. Permanent failures are recoverable via the consolidation recovery
        # endpoint, but nothing retries them on its own beyond the 300s reconcile
        # sweep, so a non-zero count that persists is a real backlog.
        - alert: HindsightConsolidationFailing
          annotations:
            summary: >-
              Hindsight has {{ $value | printf "%.0f" }} memories whose
              consolidation permanently failed — the observation layer that
              recall reads is falling behind the raw memories. Recoverable via
              the consolidation recovery endpoint; check LLM errors at
              /llm-requests first.
          expr: |
            sum(hindsight_consolidation_failed{namespace="ai"}) > 0
          for: 1h
          labels:
            severity: warning
```

- [ ] **Step 4: Create `kubernetes/apps/ai/hindsight/app/kustomization.yaml`**

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./ocirepository.yaml
  - ./externalsecret.yaml
  - ./pvc.yaml
  - ./helmrelease.yaml
  - ./httproute.yaml
  - ./servicemonitor.yaml
  - ./prometheusrule.yaml
```

Note there is deliberately no `components:` block — see the reasoning in `pvc.yaml`.

- [ ] **Step 5: Verify the metric names against a real Prometheus, not against the source**

The three backlog series were read from upstream's `metrics.py`, where they are declared as
OpenTelemetry instruments with dotted names (`hindsight.async_operations`). The Prometheus
exporter maps `.` to `_` and, for gauges whose unit is a `{...}` annotation, appends no
suffix — so `hindsight_async_operations` is expected. **That mapping is an inference until
the pod is scraped.** After deploy, confirm with:

```bash
kubectl -n ai exec deploy/hindsight -c api -- \
  sh -c 'wget -qO- http://localhost:8888/metrics' | grep -E '^hindsight_(async_operations|consolidation)'
```
Expected: the three series present with a `tenant` label. If the exporter added a suffix
(e.g. `_operations`), correct the `expr:` in `prometheusrule.yaml` — a wrong series name
makes the alert permanently silent, which is the exact failure class this design is about.

- [ ] **Step 6: Format check**

Run:
```bash
yamlfmt -lint kubernetes/apps/ai/hindsight/app/*.yaml kubernetes/apps/ai/*.yaml
```
Expected: no output.

---

## Task 7: PSS verification, then write the namespace comment

This is the spec's gate #3, and the brief calls it out as needing doing rather than
reading. `kubectl label --dry-run=server ns ai` cannot be the whole answer here because the
namespace does not exist yet and, even once it does, that command only reports violations
among **pods already in the namespace** — for a new namespace it reports nothing, which
looks like a pass and proves nothing.

The verification that actually answers the question is a server-side dry-run **pod create**
against namespaces already running at each level: `media` (`baseline`) and `kopiur-system`
(`restricted`). PSA evaluates on pod admission, and `--dry-run=server` runs admission
without persisting anything.

**Files:**
- Modify: `kubernetes/apps/ai/namespace.yaml` (replace the provisional comment)

- [ ] **Step 1: Confirm the two reference namespaces are at the levels assumed**

Run:
```bash
kubectl get ns media kopiur-system \
  -o custom-columns=NS:.metadata.name,ENFORCE:.metadata.labels.pod-security\\.kubernetes\\.io/enforce
```
Expected: `media baseline` and `kopiur-system restricted`. If either differs, pick another
namespace at that level before continuing — the test is only as good as the bed.

- [ ] **Step 2: Extract the rendered pod spec into standalone Pods**

Reuse `$SCRATCH/render.yaml` from Task 5 Step 2 (re-run that step if the temp dir is gone).

```bash
python3 - "$SCRATCH/render.yaml" <<'PY' > "$SCRATCH/psa-pod.yaml"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get('kind') == 'Deployment']
assert len(docs) == 1, f"expected one Deployment, got {len(docs)}"
tpl = docs[0]['spec']['template']
out = []
for ns in ('media', 'kopiur-system'):
    pod = {
        'apiVersion': 'v1', 'kind': 'Pod',
        'metadata': {'name': 'hindsight-psa-probe', 'namespace': ns},
        'spec': dict(tpl['spec']),
    }
    # Strip references to objects that do not exist in the test namespace; PSA
    # runs before those are resolved, so this does not weaken the check.
    pod['spec'].pop('volumes', None)
    for key in ('containers', 'initContainers'):
        for c in pod['spec'].get(key, []):
            c.pop('volumeMounts', None)
            c.pop('envFrom', None)
    out.append(pod)
yaml.safe_dump_all(out, sys.stdout, default_flow_style=False)
PY
```

- [ ] **Step 3: Run the dry-run against `baseline` and against `restricted`**

```bash
kubectl create --dry-run=server -f "$SCRATCH/psa-pod.yaml" 2>&1
```

Expected: **two** `pod/hindsight-psa-probe created (server dry run)` lines and **no**
`violates PodSecurity` message for either namespace. The `restricted` line is the one that
proves "complies with restricted by construction"; the `baseline` line proves the level the
namespace will actually enforce.

If `restricted` fails, the pod spec is wrong — fix `helmrelease.yaml` and re-run. Do **not**
lower the claim in the comment to match a failure.

- [ ] **Step 4: Also run the command the spec names, and record what it does and does not show**

```bash
kubectl label --dry-run=server --overwrite ns media pod-security.kubernetes.io/enforce=baseline
```
Expected: just the labeled line, no warnings — which is the shape `media`'s own comment
records. Run it against `media` rather than `ai` because `ai` does not exist yet; the point
of running it is to have seen the output format that a violation would produce.

- [ ] **Step 5: Replace the provisional comment in `namespace.yaml` with what was verified**

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: ai
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
  labels:
    # baseline, NOT restricted — and the choice is load-bearing, not a
    # concession. Hermes is expected to move here from `develop` (which is
    # `privileged` only because Nexus needs a root init container), and Hermes
    # CANNOT run restricted: its s6-overlay entrypoint starts as root to chown
    # /opt/data before dropping to uid 10000, and it adds CHOWN, DAC_OVERRIDE,
    # SETGID, SETUID. restricted requires runAsNonRoot and allows no added
    # capability except NET_BIND_SERVICE. baseline permits all four.
    #
    # PSA is namespace-level with no per-pod exemption, so this is a genuine
    # either/or: `ai` restricted means Hermes stays in `develop` at privileged.
    # Two workloads at baseline beats one restricted plus one privileged, and it
    # means the namespace never has to be relabelled later — a change that would
    # silently start rejecting pods.
    #
    # VERIFIED BEFORE this label was written, not predicted. `ai` did not exist
    # yet, so `kubectl label --dry-run=server ns ai` would have reported nothing
    # and proved nothing (it only reports violations among pods already in the
    # namespace). Instead the rendered Hindsight pod spec was dry-run CREATED
    # into namespaces already at each level — PSA evaluates on pod admission,
    # and --dry-run=server runs admission without persisting:
    #
    #   helm template hindsight oci://ghcr.io/bjw-s-labs/helm/app-template \
    #     --version 5.1.0 -f <this HelmRelease's .spec.values>
    #   # extract .spec.template into a Pod, then:
    #   kubectl create --dry-run=server -f pod.yaml   # namespace: media
    #   kubectl create --dry-run=server -f pod.yaml   # namespace: kopiur-system
    #
    # Both admitted with no PodSecurity violation. media is baseline (the level
    # enforced here) and kopiur-system is restricted — so Hindsight complies with
    # restricted BY CONSTRUCTION and should keep doing so. baseline is the
    # namespace floor, not a licence to skip the pod spec. If Hermes never moves
    # in, this can be tightened without touching the HelmRelease.
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: latest
```

Note this deliberately omits `warn:`/`audit:` labels. `media` carries all three;
`kopiur-system` carries only `enforce`. Since the pod already satisfies `restricted`, a
`warn: baseline` would never fire and adds nothing — follow `kopiur-system`.

- [ ] **Step 6: Confirm the provisional comment is gone**

Run:
```bash
grep -n 'PROVISIONAL' kubernetes/apps/ai/namespace.yaml
```
Expected: no output (exit 1).

---

## Task 8: App README

The OpenBao prerequisite, the plugin config, and the exit criterion all need a home in the
repo. `develop/hermes/README.md` sets the precedent for an app-level README here.

**Files:**
- Create: `kubernetes/apps/ai/hindsight/README.md`

- [ ] **Step 1: Write the README**

````markdown
# Hindsight — agent memory

Long-term memory for the cluster's agents. Design and reasoning:
`docs/superpowers/specs/2026-09-06-hindsight-agent-memory-design.md`.

**Phase 1 is an evaluation, not a migration.** `MEMORY.md` and qmd stay authoritative
throughout. Hindsight is supplemental — a *session-memory* layer, where qmd is a
*corpus-search* layer. It cannot replace qmd: different corpora (qmd indexes 1,429 docs
across eight collections; Hindsight knows only what has been retained from agent sessions),
different failure modes (qmd's index is rebuildable from files you own; Hindsight's store is
derived, lossy, and not reconstructible from its own contents), different cost (qmd is free
to query).

## Before first deploy — create the OpenBao key

The ExternalSecret will not sync until `hindsight` exists in OpenBao with all four fields.

```bash
bao kv put <mount>/hindsight \
  Hindsight__Postgres__User=hindsight \
  Hindsight__Postgres__Password='<generate: [A-Za-z0-9] ONLY>' \
  Hindsight__Llm__ApiKey='<Gemini API key>' \
  Hindsight__TenantApiKey='<generate: long random>'
```

**The password character set is not a style preference.** Hindsight takes a DSN rather than
discrete host/user/pass fields — the only Postgres app here that does — so an `@`, `/`, `:`
or `#` parses wrong and presents as a bad credential rather than a malformed URL.

**`Hindsight__TenantApiKey` is a cluster-admin-equivalent credential.** One key grants full
read *and write* across every bank, with no per-consumer isolation. Write is the dangerous
half: recalled memories are injected directly into the prompt of a Claude Code session
holding `kubectl` against this cluster, so anyone with the key can plant a memory and have it
delivered to a future session as trusted prior context — a persistent prompt-injection
channel with a multi-week fuse. Rotate it on that footing.

## Consumer — Claude Code (the only Phase 1 consumer)

```
claude plugin marketplace add vectorize-io/hindsight
claude plugin install hindsight-memory
```

`~/.hindsight/claude-code.json` (note: plaintext on the laptop — not SOPS, not OpenBao):

```json
{
  "hindsightApiUrl": "https://hindsight.<domain>",
  "hindsightApiToken": "<Hindsight__TenantApiKey>",
  "dynamicBankId": true,
  "dynamicBankGranularity": ["agent", "project"],
  "retainToolCalls": false,
  "requestTimeoutSeconds": 3
}
```

Both non-default lines are load-bearing:

- **`retainToolCalls: false`** is already the plugin default, but set it explicitly. It is
  the single control that keeps `sops -d` output, `kubectl get secret -o yaml`, and bash
  results from ever being sent to Google. There is no redaction, sanitisation, or pattern
  filter anywhere in `retain.py` — `retainMission` is a *prompt instruction*, and the raw
  text is sent in full regardless of what gets extracted. The only pre-send control is not
  retaining at all. **Revisit the whole sensitivity analysis if this is ever turned on.**
- **`requestTimeoutSeconds: 3`** bounds the one hook that degrades badly. `SessionStart`
  (5 s, `sys.exit(0)` on error) and `Stop` (`async: true`, 15 s) are fine when Hindsight is
  down. `UserPromptSubmit` is **not** async and defaults to a 10 s per-call timeout, so a
  down Hindsight would add ~10 s of silent latency to *every prompt*, indefinitely, with the
  error only on stderr.

## Evaluation gate — 2026-09-27, no extensions

Sample the last 20 `UserPromptSubmit` prompts that triggered a recall injection. Run each
query through `mcp__qmd__deep_search` over `claude-sessions`. Classify every Hindsight-recalled
fact as **novel-and-correct**, **redundant** (qmd found it too), or **wrong**.

Proceed to Phase 2 (Hermes) only if all three hold:

1. ≥30% of recalled facts are novel-and-correct.
2. **Zero** confidently-wrong facts. Not "few" — zero.
3. Actual spend over the window, read from `/llm-requests` (which records token usage per
   call, including failed calls) rather than estimated, is under **$25**.

Any one fails → tear down per below. No "let's give it another month."

The zero-wrong bar is what makes this a test rather than a formality, and it is the bar
Hindsight is most likely to fail. Vectorize themselves note it has **no fact-validity
windows** — no concept of a fact ceasing to be true. This repo's memory set is full of
entries that expire ("cross-seed v7 PENDING", "tuppr upgrade gate RESOLVED", "BWSM migration
complete"). A store that asserts stale facts is strictly worse than no store, because recall
launders them into the prompt as trusted prior context.

Also measure during the window, since both are currently unmeasured guesses:

- **p95 recall latency.** Upstream gives 100–600 ms and names the CPU reranker as the
  bottleneck. If it drifts, moving to TEI is one env var
  (`HINDSIGHT_API_RERANKER_PROVIDER: tei`).
- **Drain cost.** Estimated 3–6 minutes of unavailability per node drain, per HelmRelease
  upgrade, and per Talos upgrade cycle.

## Not in Phase 1

Hermes (Phase 2, confirmed in scope), Buzz agents (Phase 3), Home Assistant (Phase 4).
Hermes is deferred deliberately so there is a clean single-consumer cost baseline. When it
is enabled, **set `retain_every_n_turns` first**: it defaults to `1` in Hermes' plugin
versus `10` in the Claude Code plugin, so at stock settings the continuously-running
consumer retains 10× more often per turn. It is set in
`$HERMES_HOME/hindsight/config.json`, not through the `hermes memory setup` wizard, whose
schema exposes only five fields.

Home Assistant needs a **second Hindsight instance, not a second bank** — with one key and
one schema, banks are a naming convention, not a boundary.

## Teardown

Ordering matters. ESO's finalizer deletes the Secret when the ExternalSecret goes, even
under an Orphan policy, so do the database work **first**, while credentials still exist.

```bash
# 0. FIRST, while hindsight-secret still exists:
#    pg_dump -U postgres -Fc hindsight > hindsight-final.dump   # only if keeping anything
#    DROP DATABASE hindsight; DROP ROLE hindsight;              # as superuser
# 1. verify nothing depends on it, then remove the tree:
#    grep -rl hindsight kubernetes/apps --include=ks.yaml
#    rm -rf kubernetes/apps/ai/hindsight kubernetes/apps/ai
# 2. the namespace carries prune: disabled — kubectl delete ns ai BY HAND
# 3. bao kv delete .../hindsight   (and rotate anything the key touched)
# 4. laptop: claude plugin uninstall hindsight-memory && rm -rf ~/.hindsight
#    and remove the hook entries from ~/.claude/settings.json
# 5. NOT reversible: every transcript already sent to Google.
```

**CNPG PITR cannot restore `hindsight` alone** — it restores the whole cluster to a point in
time, dragging all ~34 databases with it, and base backups are weekly. This is the one
database here where the shared backup is effectively unusable for a targeted rollback.
Deleting the Kustomization un-deploys a pod; it does not un-send the data.

## Known gap, pre-existing and not introduced here

`cluster18/prometheusrule.yaml` has six alerts and **none** watches connection count against
`max_connections` (`BackendsWaiting > 300` is lock waits, not slot exhaustion). Hindsight
caps its own pool at 20+10, but the cluster-wide gap should be closed regardless:

```yaml
- alert: CNPGConnectionsNearLimit
  expr: sum(cnpg_backends_total{namespace="database"}) / 400 > 0.75
  for: 10m
```
````

---

## Task 9: Full-repo validation

**Files:** none created; this task verifies Tasks 1–8 together.

- [ ] **Step 1: Build the `ai` kustomization locally**

Run:
```bash
kustomize build kubernetes/apps/ai
```
Expected: a Namespace plus a Flux Kustomization plus the `components/common` resources
(alerts, SecurityPolicy, cluster-config), with no errors. `${SECRET_DOMAIN}` and
`${POSTGRES_HOST_RO}` appear as literals here — kustomize does not run envsubst; Flux does.

- [ ] **Step 2: Build the app directory**

Run:
```bash
kustomize build kubernetes/apps/ai/hindsight/app
```
Expected: OCIRepository, ExternalSecret, PVC, HelmRelease, two HTTPRoutes, ServiceMonitor,
PrometheusRule — eight documents (HTTPRoute is two).

- [ ] **Step 3: Confirm exactly two HTTPRoutes and exactly one carries the auth label**

Run:
```bash
kustomize build kubernetes/apps/ai/hindsight/app \
  | yq 'select(.kind == "HTTPRoute") | .metadata.name + " auth=" + (.metadata.labels.auth // "none")'
```
Expected:
```
hindsight-api auth=none
hindsight-controlplane auth=authentik
```
If `hindsight-api` shows `auth=authentik`, the Claude Code plugin will be redirected into an
OIDC flow it cannot complete. If `hindsight-controlplane` shows `auth=none`, the UI is open.

- [ ] **Step 4: Run flux-local against the repo**

Run:
```bash
flux-local test
```
Expected: passes. This renders every Kustomization including the new one and catches an
unresolvable `${VAR}`.

- [ ] **Step 5: Run the pre-commit hooks**

Run:
```bash
lefthook run pre-commit
```
Expected: all hooks pass — `yamlfmt`, and `gitleaks` in particular. Do **not** skip hooks.
Note the ExternalSecret contains only Go-template references (`{{ .Hindsight__... }}`), never
values, so gitleaks has nothing to find; if it flags something, a real secret got typed in.

- [ ] **Step 6: Server-side dry-run the whole app directory**

Run:
```bash
kustomize build kubernetes/apps/ai/hindsight/app \
  | sed -e 's/\${SECRET_DOMAIN}/derekjacobs.dev/g' \
        -e 's/\${POSTGRES_HOST}/postgres18-rw.database.svc.cluster.local/g' \
        -e 's/\${POSTGRES_HOST_RO}/postgres18-ro.database.svc.cluster.local/g' \
        -e 's/\${TIMEZONE}/America\/Chicago/g' \
  | kubectl apply --dry-run=server -n ai -f - 2>&1
```
Expected: every object validates, **except** that objects in namespace `ai` will error with
`namespaces "ai" not found` until the namespace exists. That specific error is expected and
is not a failure of this step; any *other* error (a bad field, an unknown CRD version, a
schema violation) is. Substituting the values by hand here mirrors what Flux's envsubst will
do, so it catches the schema problems a client-side dry-run would miss.

- [ ] **Step 7: Report status to the user — do not commit**

Summarise: files created, the two out-of-tree edits, the PSS verification result verbatim,
and the OpenBao key that still has to be created before deploy. **Do not run `git commit` or
`git push`** — the user has not asked. Wait for an explicit request.

---

## Task 10: CLAUDE.md stale `dependsOn` fix — SEPARATE COMMIT

The brief is explicit that this is a separate concern and needs its own commit. It is
sequenced last so it never gets folded into the deployment change by accident.

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Find every stale occurrence**

Run:
```bash
grep -n 'cloudnative-pg-cluster' CLAUDE.md
```
Expected: at least one hit in the Postgres bootstrap section's `ks.yaml` `dependsOn`
example, reading `- name: cloudnative-pg-cluster` with no `18`.

- [ ] **Step 2: Confirm what the correct name is, from the repo rather than memory**

Run:
```bash
grep -rn 'cloudnative-pg-cluster' kubernetes/apps/database/cloudnative-pg/ks.yaml
grep -rhn 'name: cloudnative-pg-cluster' kubernetes/apps --include=ks.yaml | sort | uniq -c
```
Expected: the real Kustomization is `cloudnative-pg-cluster18`, and every consuming app
already uses the `18` suffix. CLAUDE.md is the only stale reference.

- [ ] **Step 3: Correct the example, and say why it matters**

Replace the `dependsOn` block in CLAUDE.md's Postgres bootstrap section with:

```yaml
  dependsOn:
    # NOTE the `18` suffix — there is no `cloudnative-pg-cluster` Kustomization.
    # Flux does not error on a missing dependsOn target; the Kustomization parks
    # in `dependency not ready` indefinitely, with no event and no alert.
    - name: cloudnative-pg-cluster18
      namespace: database
    - name: external-secrets-openbao-store
      namespace: external-secrets
```

- [ ] **Step 4: Verify no stale name remains**

Run:
```bash
grep -n 'cloudnative-pg-cluster' CLAUDE.md | grep -v 'cluster18'
```
Expected: no output (exit 1).

- [ ] **Step 5: Stage this change separately and tell the user it is ready as its own commit**

```bash
git add CLAUDE.md
git status --short
```
Expected: `M  CLAUDE.md` and nothing else staged. Suggested message, if the user asks for
the commit:

```
claude-md: correct the Postgres bootstrap dependsOn to cloudnative-pg-cluster18

The documented example named `cloudnative-pg-cluster`, which does not exist —
the Kustomization is `cloudnative-pg-cluster18`, and every consuming app in
kubernetes/apps already uses that name. Flux does not error on a missing
dependsOn target; it parks in `dependency not ready` with no event and no
alert, so an app following this example would simply never deploy and nothing
would say why. Caught while writing the hindsight deployment, which would have
been the next app misled by it.
```

---

## Self-Review

**Spec coverage.** Every section of the design maps to a task: the five silent-failure gates
(Task 1 Steps 1–5, Task 3 Step 1, Task 7, Task 4 Step 5, and the Global Constraints note on
OpenCode Zen); namespace and PSS (Tasks 2, 7); workloads, init containers, pool caps,
retention, LLM, node placement (Task 5); secrets (Task 4); storage (Task 4); auth (Tasks 1,
5, 6); routing (Task 6); observability (Task 6); consumers, exit criterion, teardown, and the
qmd relationship (Task 8); Renovate policy (Global Constraints + the image comment in Task 5);
CLAUDE.md (Task 10).

**Deliberate non-coverage, stated so it is a choice rather than a gap:**
- Phases 2–4 (Hermes, Buzz, HA) — out of scope per the brief; documented in Task 8's README.
- `CNPGConnectionsNearLimit` — a pre-existing cluster-wide gap the spec says "should be
  closed regardless". Adding it would edit `cluster18/prometheusrule.yaml`, a third
  out-of-tree file the brief did not authorise. Recorded in the README instead; raise it as
  a follow-up.
- ZFS native encryption on tardis — the spec's own open question 2, explicitly a NAS-side
  project.
- External gateway exposure — the spec recommends against it for Phase 1.

**Placeholder scan:** no TBDs. Every step carries the literal file content or the exact
command with its expected output. The one genuinely deferred item is the Prometheus metric
name suffix (Task 6 Step 5), which is labelled as an inference with a named
verification command and a stated consequence, rather than presented as fact.

**Type consistency:** service keys `api`/`controlplane` in Task 5 produce `hindsight-api` /
`hindsight-controlplane`, which is what Task 6's HTTPRoute `backendRefs` and ServiceMonitor
`app.kubernetes.io/service` selector use, and what the Task 5 Step 2 render asserts. The
Deployment is `hindsight`, matching `deployment="hindsight"` in the PrometheusRule. Secret
name `hindsight-secret` is consistent across the ExternalSecret target and all four
`envFrom` references. PVC `hindsight-hf-cache` matches `existingClaim`. `&apiPort` (8888)
and `&cpPort` (3000) anchor every port reference within the HelmRelease.
