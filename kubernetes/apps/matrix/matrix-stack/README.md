# matrix-stack

Synapse + Matrix Authentication Service (MAS) via Element's ESS Community
`matrix-stack` chart, with state on the shared CNPG `postgres18` cluster. Why this and
not Tuwunel / Continuwuity / Dendrite: `docs/briefs/2026-09-24-matrix-homeserver-evaluation.md`.

## Layout

| Path | Flux Kustomization | What |
| --- | --- | --- |
| `db/` | `matrix-stack-db` | Job that provisions the `synapse` and `mas` roles + databases with `postgres-init`, then asserts Synapse's required `C` collation |
| `app/` | `matrix-stack` (`dependsOn: matrix-stack-db`) | ESS HelmRelease, secrets, HTTPRoutes, public DNS, media PVC |

| Host | What | Reachable from |
| --- | --- | --- |
| `${SECRET_DOMAIN}` | `server_name`; only `/.well-known/matrix/*` is routed | internet (Cloudflare `external`) |
| `matrix.` | Synapse client + federation API (via HAProxy) | LAN + internet (Pangolin) |
| `matrix.` `/_synapse/admin` etc. | Synapse admin API, `/_synapse/mas` | **LAN / tailnet only** |
| `account.` | MAS — login, account management, Authentik callback | LAN + internet (Pangolin) |
| `account.` `/api/admin` | MAS admin API | **LAN / tailnet only** (404 at the Pangolin edge) |
| `chat.` | Element Web | LAN + internet (Pangolin) |
| `matrix-admin.` | Element Admin | **LAN / tailnet only** |

Deliberate departures from the chart defaults, each explained where it is set:

- **No chart Ingresses.** A HelmRelease `postRenderer` deletes them; `app/httproute.yaml`
  mirrors their paths. Re-diff the paths on chart upgrades (`helm template` the new
  version and compare the Ingress rules).
- **`/_synapse` is not all public.** The chart's Ingress exposes all of it; here only
  `/_synapse/client` is, so the admin API stays on the LAN.
- **`initSecrets` off.** Every secret is in OpenBao, above all the Synapse signing key.
- **No local passwords in MAS.** Authentik is the only way in.
- **`matrixRTC` off** until rollout step 6 (LiveKit needs UDP → Pangolin UDP resource).

## First deploy — one-time manual steps

Everything else is reconciled by Flux. These four are not:

1. **OpenBao.** Generate every chart secret (idempotent; never overwrites a field):

   ```bash
   ./scripts/matrix-generate-secrets.sh
   ```

2. **Authentik provider.** Create an OAuth2/OpenID **confidential** provider and an
   application with slug **`matrix`** (the MAS issuer is
   `https://sso.${SECRET_DOMAIN}/application/o/matrix/`):
   - Redirect URI (strict):
     `https://account.${SECRET_DOMAIN}/upstream/callback/01M3AYCYVJ7HE0FG3HPQYC0ZE7`
   - Scopes: `openid`, `profile`, `email`
   - Store the credentials:

     ```bash
     bao kv patch secret/matrix Mas__Authentik__ClientId=... Mas__Authentik__ClientSecret=...
     ```

   The Authentik **username** becomes the Matrix ID (`@<username>:${SECRET_DOMAIN}`) and
   can never be renamed. Restrict who may sign in with the application's policy
   bindings — anyone Authentik lets through gets a Matrix account.

3. **Pangolin resources.** Add an HTTP resource for each of `matrix.`, `account.` and
   `chat.${SECRET_DOMAIN}`, exactly as in `docs/runbooks/pangolin-vps-setup.md` step 4.
   The public CNAMEs come from `app/dnsendpoint.yaml`; without the resources they
   resolve to a VPS that does not know the hosts.

4. **Apex DNS.** `matrix-well-known` attaches the apex to the Cloudflare `external`
   gateway, so external-dns-cloudflare will try to publish an apex CNAME to the tunnel.
   If the apex already has a record external-dns does not own, it is left alone — then
   whatever serves the apex must forward `/.well-known/matrix/` here. Check with the
   verification below either way.

## Verify

```bash
curl -s https://${SECRET_DOMAIN}/.well-known/matrix/server   # {"m.server": "matrix.<domain>:443"}
curl -s https://${SECRET_DOMAIN}/.well-known/matrix/client   # m.homeserver.base_url only; clients find MAS via /_matrix/client/v1/auth_metadata
curl -s https://matrix.${SECRET_DOMAIN}/_matrix/client/versions
curl -s -o /dev/null -w '%{http_code}\n' https://matrix.${SECRET_DOMAIN}/_synapse/admin/v1/server_version  # from OUTSIDE the LAN: 404
```

Then <https://federationtester.matrix.org/#${SECRET_DOMAIN}>. Join a small room before a
large one (#matrix:matrix.org pulls a lot of state on first join).

**First admin.** After signing in once through Authentik:

```bash
kubectl -n matrix exec deploy/matrix-stack-matrix-authentication-service -- \
  mas-cli manage promote-admin <username> --config /conf/mas-config.yaml
```

That lets the user *request* admin in Element Admin; it does not make every session admin.

## Operations

**Rotating a database password.** Order matters. Synapse and MAS restart
automatically (Reloader) the moment `matrix-stack-secret` changes, and a restarted pod
can only connect once the `matrix-db-init` Job has set the new password on the role.
So update the database first, the app secret last:

```bash
bao kv patch secret/matrix Synapse__Postgres__Password="$(openssl rand -hex 32)"
# 1. database side: sync the Job's secret, rerun the Job, wait for it
kubectl -n matrix annotate externalsecret matrix-db-init-secret force-sync="$(date +%s)" --overwrite
kubectl -n matrix delete job matrix-db-init --ignore-not-found
flux -n matrix reconcile ks matrix-stack-db       # recreates the Job now instead of within the hour
kubectl -n matrix wait --for=condition=complete job/matrix-db-init --timeout=5m
# 2. app side: Reloader rolls Synapse / MAS with the new password
kubectl -n matrix annotate externalsecret matrix-stack-secret force-sync="$(date +%s)" --overwrite
```

`matrix-stack-secret` also refreshes by itself every 5 minutes, so do step 1 promptly.
If it wins the race, the restarted pods fail database auth until the Job has run, then
recover on their next retry. Left entirely alone after a `bao kv patch`, that window
lasts until the Job's next hourly run. Use hex or alphanumerics: `postgres-init` puts
the password inside a single-quoted SQL literal.

**Never rotate `Synapse__SigningKey` by overwriting it.** It is the server's federation
identity. A real rotation keeps the old key as an `old_signing_keys` entry; the script
refuses to replace an existing field for this reason.

**Media** is on the `synapse-media` PVC (VolSync local + R2, same as most apps) until
rollout step 4 moves it to Garage S3.
