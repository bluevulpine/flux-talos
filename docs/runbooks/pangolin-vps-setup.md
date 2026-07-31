# Pangolin VPS setup (external ingress for Immich)

Stand up a self-hosted [Pangolin](https://docs.pangolin.net) server on an
external VPS and connect the cluster to it with a **Newt** connector, giving
Immich (and later other services) a public path that is **not** subject to
Cloudflare Tunnel's two hard limits:

- **100 MB proxied-upload cap** — Immich mobile uploads of full-res photos/videos
  `413` through cloudflared. Hard limit on CF Free/Pro, every connector/transport.
- **~1.6 MB/s per-stream throughput** — measured 2026-07-31 (see below). Retiring
  the Raspberry-Pi tunnel connectors lifted this from ~0.5 → ~1.6 MB/s, but ~1.6
  MB/s is intrinsic to CF Tunnel: the cluster WAN itself does 258/135 Mbit
  down/up, so the tunnel — not the link — is the ceiling.

A direct Pangolin/WireGuard path is limited only by the cluster's ~135 Mbit
upload and the VPS bandwidth (≈10× the CF tunnel) with **no upload cap**.

> Scope: keep **Cloudflare** as the front door for most services (free WAF, DDoS
> protection, IP hiding). Route **only** Immich (and other >100 MB / high-
> throughput services) through Pangolin. This also limits how much traffic hits
> the VPS's (often metered) egress.

## Architecture

```
                          ┌───────────────── external VPS (public IP) ─────────────────┐
  Immich users ──HTTPS──► │  Traefik (LE certs)  →  Gerbil (WireGuard server)          │
                          │  Pangolin (dashboard/API)                                  │
                          └───────────────▲──────────────────────────┬─────────────────┘
                                          │ outbound WireGuard        │ (no inbound to home)
                                          │ (Newt dials OUT)          ▼
                          ┌───────────────┴──── cluster (this repo) ──────────────────┐
                          │  Newt connector (pangolin-newt, network ns, amd64)         │
                          │     └─ forwards to  external.network.svc.cluster.local:443 │
                          │  Envoy `external` Gateway → existing HTTPRoutes → services │
                          └────────────────────────────────────────────────────────────┘
```

Newt targets the **same internal origin cloudflared uses**
(`external.network.svc.cluster.local:443`), so Envoy HTTPRoutes, cert-manager
certs, and authentik are untouched. Pangolin only replaces the transport leg for
the hostnames you move to it.

The cluster side is GitOps-managed: `kubernetes/apps/network/pangolin-newt/`.
The VPS side is **not** in this repo — it is the manual setup below.

## 1. Provision the VPS

- **Size:** 1 vCPU / 1–2 GB RAM is plenty (Pangolin is light). Pick a provider
  with generous/unmetered egress — all Immich traffic transits it.
- **OS:** Debian 12+ or Ubuntu 22.04+.
- **Public IPv4**, SSH key-only login, unattended-upgrades enabled.
- **Firewall (ufw/provider):** allow only
  - `22/tcp` (SSH, ideally source-restricted)
  - `80/tcp`, `443/tcp` (Traefik)
  - `51820/udp` (Gerbil WireGuard)
  - `21820/udp` (Newt connector traffic)

## 2. DNS

Point these at the VPS public IP (Cloudflare can stay as DNS provider, but set
these records **DNS-only / grey-cloud** so they are not CF-proxied):

- `pangolin.<domain>` — the dashboard.
- The app hostname(s) you are moving, e.g. `photos.<domain>` (Immich).

> **Split-horizon caveat:** internal clients resolve `<app>.<domain>` to the LAN
> Envoy IP (`172.16.8.2`) and will keep using the fast internal path — they never
> touch the VPS. Only off-LAN users go through Pangolin. (This is also why tunnel
> throughput tests must force the public edge with `curl --resolve`.)

## 3. Install the Pangolin stack

On the VPS, install Docker + Compose, then run the official installer:

```bash
curl -fsSL https://get.docker.com | sh
# Pangolin installer (interactive): asks for root domain + dashboard domain,
# provisions pangolin + gerbil + traefik via docker-compose, gets LE certs.
# See https://docs.pangolin.net/self-host/quick-install for the current command.
```

Provide your root domain (`<domain>`) and dashboard domain
(`pangolin.<domain>`). Traefik obtains its own Let's Encrypt certs (independent
of the cluster's cert-manager wildcard).

## 4. Create Org, Site, and Resource

In the Pangolin dashboard (`https://pangolin.<domain>`):

1. **Organization** — create one.
2. **Site** — create a site of type **Newt**. This mints the connector
   credentials: **Newt ID**, **Newt Secret**, and the **endpoint** URL. Save
   these for step 5. (Do **not** install Newt on the VPS — it runs in the
   cluster.)
3. **Resource** — add an HTTP resource for the app hostname (e.g.
   `photos.<domain>`), attached to the Site above, with **target**:
   - host: `external.network.svc.cluster.local`
   - port: `443`, TLS to backend enabled
   - Host header / SNI: preserve the original host so Envoy routes correctly.
   - Leave Pangolin's own SSO **off** (authentik already fronts the app via
     Envoy) — transport-only.

## 5. Store the connector credentials in OpenBao

Add a `pangolin` key with these fields (PascalCase double-underscore per repo
convention — matches `kubernetes/apps/network/pangolin-newt/app/externalsecret.yaml`):

| OpenBao field | Value |
| --- | --- |
| `Pangolin__Endpoint` | `https://pangolin.<domain>` |
| `Pangolin__NewtId` | the Newt ID from step 4 |
| `Pangolin__NewtSecret` | the Newt Secret from step 4 |

```bash
# via the OpenBao CLI (adjust to your auth/mount)
bao kv put <mount>/pangolin \
  Pangolin__Endpoint="https://pangolin.<domain>" \
  Pangolin__NewtId="<newt-id>" \
  Pangolin__NewtSecret="<newt-secret>"
```

## 6. Enable the cluster connector

Merge the `feat/pangolin-newt-immich` PR (kept as a **draft** until steps 1–5 are
done — before the `pangolin` OpenBao key exists, the ExternalSecret fails and
Newt crashloops). On merge, Flux deploys `pangolin-newt` in the `network`
namespace; Newt reads the creds, dials the VPS, and registers the Site.

## 7. Verify

```bash
# connector is up and registered
kubectl -n network logs deploy/pangolin-newt | grep -iE "connect|registered|tunnel"

# from OFF-LAN (or force the edge), a >100 MB upload should now succeed and
# throughput should track ~135 Mbit, not ~1.6 MB/s:
curl -o /dev/null -s -w 'up=%{speed_upload}B/s http=%{http_code}\n' \
  -F file=@big-video.mp4 https://photos.<domain>/...   # (Immich upload endpoint)
```

## Notes / future

- **HA:** started as a single Newt replica; a pod restart drops the tunnel for a
  few seconds. Newer Pangolin supports multiple connectors per Site — add a
  second replica (with anti-affinity) if Immich uptime demands it.
- **Rollback:** the hostname's DNS still has its CF-proxied record available;
  flip DNS back to the Cloudflare path to revert instantly. cloudflared and Newt
  target the same origin, so both can serve in parallel during migration.
- **Expansion:** to move another service, add a Pangolin Resource + flip that
  hostname's DNS — no cluster change needed (Newt already targets the shared
  Envoy origin).

Related: `docs/runbooks/flux-image-automation.md`, and the memory
`project_cloudflare_tunnel_pi_retire_pangolin`.
