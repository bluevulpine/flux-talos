# Brief: self-hosted Matrix homeserver — evaluation

**Date:** 2026-09-24
**Status:** Decision made. Steps 1 (database provisioning) and 2 (ESS HelmRelease)
written on `claude/matrix-homeserver-evaluation-1d055g`, not yet deployed. Manual
first-deploy steps and verification: `kubernetes/apps/matrix/matrix-stack/README.md`.
**Decision:** Synapse + Matrix Authentication Service (MAS), deployed with Element's
ESS Community `matrix-stack` chart, bundled Postgres **off**, state on `postgres18`.
**Runner-up:** Tuwunel (lighter, but RocksDB on a PV only).

Versions and counts below were checked on 2026-09-24 against release tags and
kubesearch.dev. Items marked **UNVERIFIED** were not confirmed from a primary source.

---

## What the cluster already provides

| Need | Existing piece |
| --- | --- |
| Relational state | CNPG `postgres18` (3 instances, Barman WAL archiving to Garage, PITR) + the `postgres-init` pattern |
| SSO | Authentik (standard OIDC, as mealie/grafana/gitea/hermes use) |
| Redis for Synapse workers | Dragonfly (`database/dragonfly`, 3 replicas) |
| Media object storage | Garage S3 (already holds CNPG, Thanos, Talos backups) |
| Public ingress | `external` (Cloudflare tunnel, 100 MB body cap) and `external-pangolin` (VPS + Newt, no cap, raw TCP/UDP resources possible) |
| TURN / LiveKit | **None** — calls would be new components |

## Options

| Server | State | Status (Sep 2026) | Verdict |
| --- | --- | --- | --- |
| **Synapse + MAS** | **Postgres** (+ MAS own DB) | Synapse v1.161.0 (2026-09-15), MAS v1.25.1. Reference implementation. | **Chosen** |
| **Tuwunel** | RocksDB PV only | v1.9.2 (2026-09-20), 1–3 week cadence, funded maintainer. Native OIDC, native S3 media. | Runner-up |
| Continuwuity | RocksDB PV only | v26.9.0 (2026-09-16); most common in home-ops (~18 repos) | Fine; Tuwunel fits better |
| Dendrite | Postgres | Maintenance mode, last release v0.15.2 (2025-08); no native sliding sync | No |
| conduwuit | RocksDB | Archived (forked into Tuwunel / Continuwuity) | No |
| Conduit / Grapevine | RocksDB / SQLite | Conduit maintained (latest version **UNVERIFIED**); Grapevine "not ready for general use" | No |

### Why Synapse

- **State in Postgres.** Synapse is the only mature server with Postgres state. It inherits
  CNPG's HA, WAL archiving and PITR; a RocksDB server gets crash-consistent kopiur snapshots.
- **MAS + Authentik.** MAS takes Authentik as its upstream OIDC provider. Element X needs
  MAS for full functionality, and Synapse's experimental MSC3861 path has been removed in
  favour of the stable `matrix_authentication_service:` config. MAS adoption is one-way.
- **Media → Garage.** `synapse-s3-storage-provider` v1.7.0 (2026-08-18; requires Synapse
  ≥ 1.140) removes the need for a media PV.
- **Dragonfly** can back worker replication (Redis pub/sub) — drag0n141/home-ops does this.
- **Bridges.** mautrix bridges each want their own Postgres DB (`postgres-init` handles
  this with a space-separated `INIT_POSTGRES_DBNAME`). Bridge compatibility is best on
  Synapse; Tuwunel has had MSC4190 end-to-bridge-encryption bugs (#327, reported fixed).
- **Sliding sync** (MSC4186, accepted July 2026) is native in Synapse; no proxy needed.

### Why ESS over hand-wiring

ESS Community (`element-hq/ess-helm`, chart `matrix-stack`, 26.9.x; AGPLv3, pitched at
non-commercial ≲100 users) versions together Synapse (+ HAProxy-routed workers), MAS,
Element Web, Element Admin, `.well-known` delegation and optional MatrixRTC (LiveKit +
lk-jwt-service). It supports external Postgres (`postgres.enabled: false`,
`synapse.postgres`, `matrixAuthenticationService.postgres`) and external Redis/Valkey.
wrmilling/k3s-gitops runs it on CNPG Postgres 18.

The alternative — ananace `matrix-synapse` chart or app-template + MAS on app-template,
as drag0n141 does — fits repo conventions more naturally but leaves MAS↔Synapse
compatibility and worker routing to us.

Known friction with ESS on this cluster:

1. **Ingress only.** The chart renders `Ingress` objects, not Gateway API. Disable them and
   write HTTPRoutes.
2. **No hook for `postgres-init`.** Handled by the standalone provisioning Job
   (`kubernetes/apps/matrix/matrix-stack/db/`, step 1).
3. **Synapse requires `C` collation / ctype.** CNPG's initdb defaults are `C`, and
   `cluster18.yaml` does not override them, but `postgres18` was bootstrapped by import
   from `postgres16`. The provisioning Job asserts it rather than assuming.
4. **Footprint.** ~2 GB / 2 CPU across the stack vs ~1 GB for Tuwunel. Immaterial on 8 nodes.

### When Tuwunel would be the better call

For 1–20 users it is lighter and simpler: one binary, native OIDC (Authentik), native S3
media (Garage), MatrixRTC via a single `livekit_url`. If running MAS + HAProxy + workers
feels like too much machinery, Tuwunel on a Longhorn PV with kopiur is the answer
(nicolerenee/infra is the template). A cited 2026 benchmark had one Tuwunel process beat an
18-worker Synapse in 3 of 4 scenarios at 200 users (**UNVERIFIED** — snippet only).

## Networking

- **`server_name` is permanent.** Use the apex `${SECRET_DOMAIN}` (`@user:domain`),
  delegated to `matrix.${SECRET_DOMAIN}` via `/.well-known/matrix/server` →
  `{"m.server":"matrix.${SECRET_DOMAIN}:443"}`. No port 8448.
- **Client/federation hosts on `external-pangolin`** — avoids the Cloudflare 100 MB 413 and
  Cloudflare bot/WAF challenges on `/_matrix/federation` and `/_matrix/key`. Public DNS via
  `DNSEndpoint`, as immich does.
- **`.well-known` on the apex route** is tiny and fine behind Cloudflare.
  `/.well-known/matrix/client` needs CORS headers. Check what currently owns the apex route.
- **Calls are phase 2.** LiveKit needs UDP, which the Cloudflare tunnel cannot carry. A
  Pangolin raw UDP/TCP resource can, with LiveKit advertising the VPS public IP. Media then
  hairpins through the VPS, bounded by the ~135 Mbit upstream.

## What other GitOps repos run (kubesearch.dev, 2026-09-24)

- onedr0p, bjw-s, buroa, szinn: no Matrix server. joryirving runs Synapse + LiveKit only for
  WorkAdventure.
- **Continuwuity ~18** (all app-template). kashalls/home-cluster is closest on ingress:
  Envoy Gateway, `.well-known` delegation to `:443`, Cloudflare-proxied, RocksDB PVC.
- **Synapse ~8.** drag0n141/home-ops ≈ this cluster: ananace chart, CNPG, Dragonfly as
  Redis, `postgres-init` via postRenderer, MAS, mautrix-whatsapp/-discord.
  lucas-dclrcq/homelabitty: MAS + many mautrix bridges + hookshot.
- **ESS `matrix-stack` 4.** wrmilling/k3s-gitops (CNPG PG18, workers, mautrix-slack).
- **Tuwunel 3.** nicolerenee/infra (app-template, 20Gi RocksDB PVC, OIDC, HTTPRoutes).
- Bridges seen: mautrix-meta 3, -discord 3, -whatsapp 3, -signal 1, -slack 1, -irc 1,
  heisenbridge 3. LiveKit ~8.

## Rollout

1. **DB provisioning** — `matrix` namespace, OpenBao key, ExternalSecret, and a
   Flux-managed Job running `postgres-init` for the `synapse` and `mas` roles/databases,
   plus a collation assertion. Replayable; no manual SQL.
2. ESS HelmRelease: bundled Postgres off → `postgres18`; Redis → Dragonfly; chart ingress
   off, own HTTPRoutes on `external-pangolin`; MAS upstream → Authentik. `dependsOn` the
   step-1 Kustomization.
3. Apex `.well-known` route. Federation Tester; join a small room before a large one.
4. S3 media provider → Garage. **Open question:** whether the ESS Synapse image ships
   `synapse-s3-storage-provider` (unverified). If not, it needs a derived image or an
   `extraInitContainers` install into a shared volume — settle this before starting.
5. Bridges — own DB each, `msc4190: true`.
6. LiveKit + lk-jwt-service over a Pangolin UDP resource.

## Sources

- https://github.com/element-hq/synapse/releases
- https://element-hq.github.io/matrix-authentication-service/setup/homeserver.html
- https://element-hq.github.io/synapse/latest/upgrade.html
- https://github.com/element-hq/ess-helm (README, `charts/matrix-stack/values.yaml`)
- https://github.com/matrix-construct/tuwunel/releases, discussions/227, issues/416, issues/327
- https://matrix-construct.github.io/tuwunel/calls/matrix_rtc.html
- https://forgejo.ellis.link/continuwuation/continuwuity/releases
- https://matrix.org/blog/2026/09/18/this-week-in-matrix-2026-09-18/
- https://matrix.org/blog/2024/11/14/moving-to-native-sliding-sync/
- https://github.com/element-hq/dendrite
- https://github.com/matrix-org/synapse-s3-storage-provider
- https://docs.mau.fi/bridges/general/end-to-bridge-encryption.html
- https://kubesearch.dev
- CNPG initdb locale defaults: https://github.com/cloudnative-pg/cloudnative-pg/blob/main/docs/src/bootstrap.md
