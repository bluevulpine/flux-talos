# matrix-stack (bluevulpine.net)

Second Matrix homeserver: Synapse + MAS via ESS Community `matrix-stack`. Derek's
external identity, `@bluevulpine:bluevulpine.net`. The first homeserver,
`kubernetes/apps/matrix/matrix-stack` (derekjacobs.dev), is the agent/A2A space.
Design: `docs/superpowers/specs/2026-10-02-matrix-bluevulpine-design.md`.

Mirrors the derekjacobs.dev tree. **Deviations, each deliberate:**

| What | Here | Why |
| --- | --- | --- |
| Postgres roles/DBs | `synapse_bluevulpine`, `mas_bluevulpine` | shared `postgres18`; `synapse`/`mas` are taken |
| OpenBao key | `secret/matrix-bluevulpine` | never share a key: it holds the signing key |
| Media PVC | plain `./app/pvc.yaml`, `longhorn-2-replica` | kopiur-only app; `volsync-claim`'s dataSourceRef targets a VolSync object that never exists |
| Backups | `components/kopiur`, staging on `longhorn-1-replica` | new apps are born on kopiur |
| Element Web / Admin | disabled | the shared Element Web in the derekjacobs.dev release serves `chat.bluevulpine.net` |
| Apex well-known | `external` + `internal` | LAN clients hit the internal gateway for the blog apex |

## Hosts

| Host | What | Reachable from |
| --- | --- | --- |
| `bluevulpine.net/.well-known/matrix/*` | delegation | everywhere (rest of the apex is the blog) |
| `matrix.` | Synapse client + federation API | LAN + internet (Pangolin) |
| `matrix.` `/_synapse/*` except `/_synapse/client` | Synapse admin etc. | **LAN / tailnet only** |
| `account.` | MAS (login, account, Authentik callback) | LAN + internet |
| `account.` `/api/admin` | MAS admin API | **LAN / tailnet only** (404 at the Pangolin edge) |
| `chat.` | Element Web (shared, lives in `kubernetes/apps/matrix`) | LAN + internet |

## Prerequisites (before merging)

1. **Secrets**: `./scripts/matrix-generate-secrets.sh secret/matrix-bluevulpine`
   (idempotent; `--dry-run` first).
2. **Authentik**:
   - Group `matrix-bluevulpine-users`; add `bluevulpine`.
   - OAuth2/OpenID Provider "Provider for Matrix (bluevulpine.net)", confidential,
     with the same authorization/invalidation flows, property mappings, signing
     key, `sub_mode: user_username` and `issuer_mode: per_provider` as "Provider
     for Matrix".
     - Redirect URI (strict):
       `https://account.bluevulpine.net/upstream/callback/01M3YQ563JRK4NR03FA7JVPD2H`
   - Application `matrix-bluevulpine` (slug exactly that) with that provider.
     Bind the group to it.
3. **Client credentials**:
   `bao kv patch secret/matrix-bluevulpine Mas__Authentik__ClientId='…' Mas__Authentik__ClientSecret='…'`
   (single quotes).
4. **Pangolin**, only **after** each CNAME resolves publicly: HTTP resources for
   `matrix.` and `account.bluevulpine.net`, targeting the `external-pangolin`
   gateway like the other Pangolin apps. If a geo rule is added on `matrix.`, it
   must exempt `/_matrix/federation/*` and `/_matrix/key/*`.

The ULID is fixed and is part of the redirect URI. **Never change it.**

## Verify

```bash
curl -s https://bluevulpine.net/.well-known/matrix/server   # {"m.server": "matrix.bluevulpine.net:443"}
curl -s https://bluevulpine.net/.well-known/matrix/client   # m.homeserver.base_url
curl -s https://matrix.bluevulpine.net/_matrix/client/versions
curl -s -o /dev/null -w '%{http_code}\n' https://matrix.bluevulpine.net/_synapse/admin/v1/server_version  # outside the LAN: 404
curl -s -o /dev/null -w '%{http_code}\n' https://bluevulpine.net/   # the blog: still 200
kubectl -n matrix-bluevulpine get snapshots.kopiur.home-operations.com   # first of each leg: Succeeded
```

Then <https://federationtester.matrix.org/#bluevulpine.net>.

**Cert check:** a new Pangolin host can be stuck on Traefik's self-signed fallback
if its resource was created before DNS resolved. If the issuer is
`TRAEFIK DEFAULT CERT`, restart Traefik on the VPS:
`echo | openssl s_client -connect matrix.bluevulpine.net:443 -servername matrix.bluevulpine.net | openssl x509 -noout -issuer`

## Operations

**Rotating a database password.** Same order as the derekjacobs.dev README, with
`-n matrix-bluevulpine` and `secret/matrix-bluevulpine`.

**Media recovery.** The PVC has no `dataSourceRef`, so if it is deleted and
recreated it comes up **empty**. Restore by hand from kopiur. Snapshot identity:
`synapse-media@matrix-bluevulpine:/data`, in `kopia-local` and `kopia-r2`.

**Rollback.** Revert the PR. Deleting the Kustomizations by hand doesn't stick,
because `cluster-apps` recreates them. Reverting prunes the media PVC, **and with
it the data** (`reclaimPolicy: Delete`). What survives:
- kopia snapshots
- the Postgres databases
- the OpenBao key
- the namespace
