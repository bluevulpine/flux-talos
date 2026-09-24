# matrix-stack

Synapse + Matrix Authentication Service via Element's ESS Community `matrix-stack`
chart, with state on the shared CNPG `postgres18` cluster. Why this and not Tuwunel /
Continuwuity / Dendrite: `docs/briefs/2026-09-24-matrix-homeserver-evaluation.md`.

## Layout

| Path | Flux Kustomization | What |
| --- | --- | --- |
| `db/` | `matrix-stack-db` | Job that provisions the `synapse` and `mas` roles + databases with `postgres-init`, then asserts Synapse's required `C` collation |
| `app/` | *(step 2, not yet written)* | ESS HelmRelease; will `dependsOn: matrix-stack-db` |

## Prerequisite: OpenBao key

`secret/matrix` must exist before `matrix-stack-db` can go Ready:

```bash
bao kv put secret/matrix \
  Synapse__Postgres__Password="$(openssl rand -hex 32)" \
  Mas__Postgres__Password="$(openssl rand -hex 32)"
```

Use hex (or at least no `'`): postgres-init interpolates the password into a
single-quoted SQL literal. Later steps add their fields to this key with
`bao kv patch`, never `put`, which would drop these.

## Rotating a database password

```bash
bao kv patch secret/matrix Synapse__Postgres__Password="$(openssl rand -hex 32)"
kubectl -n matrix annotate externalsecret matrix-db-init-secret force-sync="$(date +%s)" --overwrite
kubectl -n matrix delete job matrix-db-init --ignore-not-found   # Flux recreates + reruns it
```

Left alone, the Job reruns on every reconcile (`interval: 1h`) and converges the role
passwords anyway. Deleting it just makes that immediate.
