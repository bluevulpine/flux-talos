# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project knowledge

Serena is configured for this repo. At session start, activate the project and read `mem:core` for the source map and cluster topology. Follow references from there to `mem:tech_stack`, `mem:conventions`, `mem:suggested_commands`, and `mem:task_completion` as the task requires — do not load all memories up front.

## Critical rules

**SOPS-encrypted files** (`*.sops.yaml`): never write decrypted content to disk. Use `sops -d <file>` to view and `sops <file>` to open the editor. Plaintext secrets must not appear in any file tracked by git (gitleaks runs on every pre-commit).

**`talos/clusterconfig/`** is gitignored and contains generated machine configs. Do not edit these files directly; the source of truth is `talos/talconfig.yaml`. Regenerate with `just talos gen-config`.

**YAML formatting**: all `.yaml` files except `*.sops.yaml` must pass `yamlfmt`. Block-style arrays, `---` document start, LF line endings. Lefthook enforces this on pre-commit — do not skip hooks.

**`crds: CreateReplace`** is injected globally via the `cluster-apps` Flux patch; do not add it to individual HelmRelease manifests.

**Renovate version tracking**: when adding a chart or tool version that Renovate should update, annotate it with the appropriate `# renovate: datasource=...` comment (see existing entries in `talos/talconfig.yaml` for the pattern).

## Adding a new application

Follow the existing layout under `kubernetes/apps/<namespace>/<app>/`:
- `namespace.yaml` + `kustomization.yaml` at the namespace level
- `app/helmrelease.yaml` using an OCIRepository ref, `&app` name anchor, and standard remediation blocks (retries: 3, cleanupOnFail, rollback strategy)
- `app/externalsecret.yaml` if runtime secrets are needed (pull from OpenBao via External Secrets Operator — `secretStoreRef: openbao`)
- Include `# yaml-language-server: $schema=...` at the top of every Kubernetes manifest

Secrets come exclusively from OpenBao via `ExternalSecret` (`secretStoreRef` → `openbao` / `ClusterSecretStore`, `engineVersion: v2`). OpenBao field naming is PascalCase double-underscore: `App__Category__Field` (e.g. `Frigate__Mqtt__User`). Never commit secret values.

## Validating changes

Run `lefthook run pre-commit` before committing. For a broader local diff against the cluster:

```bash
flux-local test
```

To apply a single app's kustomization directly:

```bash
just kube apply-ks kubernetes/apps/<namespace>/<app>
```

## Postgres bootstrap: the `postgres-init` init container

Apps that need a Postgres database on the CloudNativePG `postgres16` cluster do
**not** hand-create the database or role. Instead they run the
[`ghcr.io/home-operations/postgres-init`](https://github.com/home-operations/containers/tree/main/apps/postgres-init)
image as an init container. On every start it idempotently connects as the
superuser and ensures the app's role **and** database(s) exist (creating them,
and granting the role ownership/access, if missing). It is safe to re-run.

It is driven entirely by `INIT_POSTGRES_*` env, sourced from the app's secret:

| Env var | Meaning |
| --- | --- |
| `INIT_POSTGRES_HOST` | `postgres16-rw.database.svc.cluster.local` (RW service) |
| `INIT_POSTGRES_USER` | app role to create/own the database(s) |
| `INIT_POSTGRES_PASS` | password for that app role |
| `INIT_POSTGRES_DBNAME` | database name — **space-separate for multiple** (see below) |
| `INIT_POSTGRES_SUPER_PASS` | superuser password, used only to bootstrap |

The superuser password is **not** stored per-app. It is reused from the shared
`cloudnative-pg` OpenBao key via a second `dataFrom.extract` block, exposed as
the template field `{{ .Postgres__SuperPassword }}`. This keeps the super
password in exactly one place.

### Wiring (HelmRelease + ExternalSecret)

In the HelmRelease, declare it as an init container that loads the app secret —
it runs to completion before the app container starts:

```yaml
initContainers:
  01-init-db:
    image:
      repository: ghcr.io/home-operations/postgres-init
      tag: rolling
    envFrom:
      - secretRef:
          name: <app>-secret
```

In the ExternalSecret, pull the app's own creds from its key and the superuser
from the shared `cloudnative-pg` key:

```yaml
  target:
    template:
      engineVersion: v2
      data:
        INIT_POSTGRES_HOST: &dbHost postgres16-rw.database.svc.cluster.local
        INIT_POSTGRES_USER: &dbUser "{{ .App__Postgres__User }}"
        INIT_POSTGRES_PASS: &dbPass "{{ .App__Postgres__Password }}"
        INIT_POSTGRES_DBNAME: app_db
        INIT_POSTGRES_SUPER_PASS: "{{ .Postgres__SuperPassword }}"
  dataFrom:
    - extract:
        key: app                # the app's own OpenBao key
    - extract:
        key: cloudnative-pg     # shared superuser → Postgres__SuperPassword
```

The `ks.yaml` should `dependsOn` the cluster so ordering is correct:

```yaml
  dependsOn:
    - name: cloudnative-pg-cluster
      namespace: database
    - name: external-secrets-openbao-store
      namespace: external-secrets
```

### One user, one database

The common case — a single role owning a single database. Example:
`kubernetes/apps/home/frigate/app/externalsecret.yaml`
(`INIT_POSTGRES_DBNAME: frigate`).

### One user, multiple databases

`INIT_POSTGRES_DBNAME` accepts a **space-separated** list; the one app role is
granted access to every database in it. Example:
`kubernetes/apps/media/lidarr/app/externalsecret.yaml`:

```yaml
        LIDARR__POSTGRES__MAINDB: lidarr_main
        LIDARR__POSTGRES__LOGDB: lidarr_log
        ...
        INIT_POSTGRES_USER: *dbUser
        INIT_POSTGRES_DBNAME: lidarr_main lidarr_log   # two DBs, one role
```

(Lidarr also shows chaining a second init container `02-init-metadata` after the
DB bootstrap for app-specific post-create SQL — a useful pattern when you need to
seed or patch config once the databases exist.)

### Reference implementations in this repo

- Single DB: `kubernetes/apps/home/frigate/app/` (also consumes MQTT creds),
  `kubernetes/apps/productivity/n8n/app/`.
- Multiple DBs: `kubernetes/apps/media/lidarr/app/`.
- DB + MQTT + JSONB archival: `kubernetes/apps/home/helium-archiver/app/`.
