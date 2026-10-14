---
name: postgres-init
description: How apps on this cluster get a Postgres role and database: the ghcr.io/home-operations/postgres-init init container, its INIT_POSTGRES_* env, the HelmRelease + ExternalSecret wiring (shared superuser via the cloudnative-pg key), ks.yaml dependsOn, one-vs-many database variants, and reference implementations. Use when adding a Postgres-backed app, rotating an app's Postgres password, or debugging why an app's database or role is missing.
---

# Postgres bootstrap: the `postgres-init` init container

Apps that need a Postgres database on the CloudNativePG `postgres18` cluster do
**not** hand-create the database or role. Instead they run the
[`ghcr.io/home-operations/postgres-init`](https://github.com/home-operations/containers/tree/main/apps/postgres-init)
image as an init container. On every start it idempotently connects as the
superuser and ensures the app's role **and** database(s) exist (creating them,
and granting the role ownership/access, if missing). It is safe to re-run.

**It also RESETS the role's password on every start**, which is easy to miss and
is the single most useful thing about it. `createuser` is gated on the role being
absent, but the `ALTER USER ... WITH ENCRYPTED PASSWORD` that follows is
unconditional. So rotating an app's Postgres credential is two steps and no
ordering puzzle:

```bash
bao kv patch secret/<app> <App>__PostgresPass=<new>   # patch, not put
kubectl -n <ns> annotate externalsecret <app>-secret force-sync="$(date +%s)" --overwrite
```

Reloader rolls the pod, the init container re-syncs the database side itself, and
OpenBao and Postgres never disagree. Do **not** hand-write an `ALTER ROLE` for
this — reach for one only when the change must take effect without a restart.
Verified 2026-09-09 during a mealie rotation:

```
Update password for user mealie ...
ALTER ROLE
```

It is driven entirely by `INIT_POSTGRES_*` env, sourced from the app's secret:

| Env var | Meaning |
| --- | --- |
| `INIT_POSTGRES_HOST` | `${POSTGRES_HOST}` — `postgres18-rw.database.svc.cluster.local` (RW service) |
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
        INIT_POSTGRES_HOST: &dbHost ${POSTGRES_HOST}   # postgres18-rw.database.svc.cluster.local
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
    # NOTE the `18` suffix — there is no `cloudnative-pg-cluster` Kustomization.
    # Flux does not error on a missing dependsOn target; the Kustomization parks
    # in `dependency not ready` indefinitely, with no event and no alert, so an
    # app that gets this wrong simply never deploys and nothing says why.
    - name: cloudnative-pg-cluster18
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
