# CLAUDE.md

Repo-wide guidance for agents working in this GitOps repository. App-specific
notes live in each app's own `README.md`.

## Repository shape

- Flux-managed mono-repo. Everything reconciles through Flux — **no `kubectl
  apply` of one-off resources.**
- Apps live under `kubernetes/apps/<namespace>/<app>/` with a `ks.yaml` (Flux
  `Kustomization`) plus an `app/` dir holding the four-file scaffold:
  `ocirepository.yaml`, `helmrelease.yaml` (usually the bjw-s `app-template`
  chart), `externalsecret.yaml`, and `kustomization.yaml`.
- Each app's `ks.yaml` is registered in its namespace's
  `kubernetes/apps/<namespace>/kustomization.yaml`.
- Secrets come exclusively from OpenBao via `ExternalSecret`
  (`secretStoreRef` → `openbao` / `ClusterSecretStore`, `engineVersion: v2`).
  OpenBao field naming is PascalCase double-underscore: `App__Category__Field`
  (e.g. `Frigate__Mqtt__User`). Never commit secret values.

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
    - name: external-secrets-stores
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
