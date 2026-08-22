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

## Metrics and the Grafana dashboard

Added 2026-08-22. Dashboard: **Pangolin Tunnel (newt / gerbil / traefik)**,
`grafana.<domain>/d/pangolin-tunnel`. It is the Pangolin counterpart to the
Cloudflare Tunnels (cloudflared) dashboard.

Three exporters, two of which live on the VPS:

| Source | Where | Port | Enabled by |
| --- | --- | --- | --- |
| **newt** | cluster | `2112` | `-metrics` flag in the HelmRelease |
| **gerbil** | VPS | `3004` | nothing — it ships the exporter on by default |
| **traefik** | VPS | `8082` | `metrics.prometheus` in `traefik_config.yml` |

The Pangolin app itself has **no** `/metrics`. Port 3002 answers 200 to
`/metrics`, but it is the Next.js catch-all returning the HTML app — do not
mistake that for an exporter.

### Cluster side (GitOps)

`kubernetes/apps/network/pangolin-newt/app/` carries the `-metrics` args, a
Service exposing the named `metrics` port, a ServiceMonitor, and the dashboard
ConfigMap. Two traps, both of which fail silently:

- The exporter defaults to `127.0.0.1:2112`. It **must** be
  `-metrics-admin-addr 0.0.0.0:2112` or nothing can scrape it.
- app-template stamps `app.kubernetes.io/service` with the **bare release name**
  when a release declares a single Service — not `<release>-<serviceKey>` as it
  does for multi-Service releases. A ServiceMonitor selecting the key name
  matches nothing and reports an empty target list with no error.

### VPS side (manual — not in this repo)

Both exporter ports are published **bound to the tailnet address**
(`100.65.0.27`), never `0.0.0.0`:

```yaml
# /opt/pangolin/docker-compose.yml, on the *gerbil* service --
# traefik uses network_mode: service:gerbil, so its ports belong there too.
      - 100.65.0.27:3004:3004 # gerbil Prometheus exporter (tailnet only)
      - 100.65.0.27:8082:8082 # traefik Prometheus exporter (tailnet only)
```

Binding to the tailnet IP **is** the access control, and it is the deliberate
choice rather than the only option: a port that was never published on the public
interface has no rule left to be reordered, flushed, or lost when docker
restarts, so it fails closed by construction.

The trap to avoid is reaching for a plain ufw rule. Docker DNATs published ports
before ufw's `INPUT` chain ever sees them, so an `0.0.0.0`-published port stays
reachable from the public IP no matter what ufw says. Docker does provide
`DOCKER-USER` for exactly this purpose and rules inserted there **do** apply — a
firewall approach is entirely possible, it is just more moving parts for the same
outcome. Verified from off-network against the public IP: `443` and `80` answer
(the controls, proving the probe reached the host), while `3004`, `8082` and
`3002` are filtered.

Traefik's exporter is on its own `metrics` entryPoint (`:8082`) so `/metrics` is
never served on the public `web`/`websecure` listeners.

Because the ports bind to a tailscale address, `/etc/systemd/system/docker.service.d/10-wait-tailscale.conf`
orders docker after `tailscaled` and waits for the address. Without it, a reboot
where dockerd wins the race fails the bind and crash-loops **gerbil** — which
also carries `:80`/`:443` for every Pangolin-routed hostname.

Prometheus reaches both via `ScrapeConfig`s in
`kubernetes/apps/observability/kube-prometheus-stack/app/scrapeconfig.yaml`,
scraping tailnet IPs directly (cluster CoreDNS cannot resolve `*.ts.net`). Pod
egress to the tailnet is masqueraded to the node's own tailnet address, so the
scrape arrives as `tag:server`; no Tailscale ACL change is needed.

### Reading the numbers

- `newt_tunnel_bytes_total{direction=...}` is from **newt's** perspective:
  `ingress` = internet → cluster (user uploads, e.g. Immich backups),
  `egress` = cluster → internet (users viewing). Confirmed in source, not just by
  inference: `proxy/manager.go:677` counts the write toward the origin as
  `ingress` and `:684` counts the write back toward the user as `egress`. It
  matches the empirical check too — 25 HTTP GETs produced ~18 kB egress against
  ~3 kB ingress.
  **Do not read these bytes as link utilisation.** They are counted at newt's own
  proxy layer, before WireGuard encapsulation, so the bytes actually crossing the
  258/135 Mbit WAN are strictly more than what this counter reports. (Newt is a
  raw TCP proxy to `external.network.svc:443`, so the origin-side TLS record
  framing *is* already inside the count — what is excluded is the WireGuard, UDP
  and IP overhead wrapped around it, not the TLS.) The dashboard draws the 258 Mbit figure as a reference line on
  the upload panel, but a series that appears to be approaching it has already
  saturated the link — treat the headroom it implies as optimistic.
- `newt_site_online` has **never** worked, in any build — this is not a 1.15.0
  regression and 1.16.0 does not fix it. Upstream, the only thing that can move
  the gauge is `SetOnline(b bool)` at `internal/state/telemetry_view.go:53`, and
  it has **zero callers anywhere** in the tree, so the metric is pinned at
  `{site_id="self"} 0` permanently. Its neighbour `TouchHeartbeat` is uncalled
  for the same reason, which is why `newt_site_last_heartbeat` never emits at all
  rather than emitting something stale. No upstream issue tracks this; the only
  related one is fosrl/newt#131, the closed feature request that added these
  metrics in the first place. So use `newt_websocket_connected` and do not wait
  for a version bump. Note also that `newt_tunnel_sessions` and
  `newt_site_online` use `site_id="self"` while every other newt metric uses the
  real site ID, so joining on `site_id` across metrics does not work.
- `newt_tunnel_sessions` **disappears** rather than reporting 0 when idle; the
  dashboard uses `or vector(0)`.
- A control channel that reads DOWN is an outage **already in progress**, not a
  warning. The data plane can keep forwarding on the established WireGuard
  session after the control channel drops — but **how long is unknown**, and the
  "roughly ten minutes" figure this runbook used to quote should not be planned
  around. It was observed once, on 2026-08-22, and never isolated: the same
  mistake deleted the A record that every Pangolin hostname CNAMEs onto, and both
  the CNAMEs and that A record carry a **300s TTL**, so public resolvers were
  aging out their cached answers on an entirely separate clock while the control
  channel was failing. Two independent countdowns, one observation — the ten
  minutes cannot be attributed to WireGuard session survival, and the real grace
  period may be far shorter. Measuring it properly means leaving DNS completely
  alone and denying the newt pod egress to the VPS on `443/tcp` while leaving
  `21820/udp` open, then timing how long traffic keeps flowing. Until someone
  does that, treat DOWN as "already dark".

### Restarting the VPS stack

`docker compose up -d` recreates gerbil and traefik (pangolin is untouched).
Expect a brief 502 on every Pangolin-routed hostname while Newt re-handshakes;
it cleared on the first retry when this was done on 2026-08-22.

### ⚠️ Never apply this app with `kustomize build | kubectl apply`

`dnsendpoint.yaml` uses `${SECRET_DOMAIN}` and the dashboard JSON uses `$$` for
Grafana's `$__rate_interval`. Both are resolved by Flux's **envsubst**, which
`kustomize build` does not run. Applying by hand on 2026-08-22 published a
literal `pangolin.${SECRET_DOMAIN}`, external-dns removed the real
`pangolin.<domain>` record, and newt lost the hostname it needs to authenticate
— every Pangolin-routed hostname was dark about ten minutes later.

Losing that one record breaks users **and** the tunnel by two separate
mechanisms, which is worth holding on to when reading the timeline: the app
hostnames are CNAMEs onto `pangolin.<domain>`, so external resolution dies on its
own 300s TTL whether or not the tunnel is healthy. That is why the ten minutes
above must not be read as a WireGuard grace period (see "Reading the numbers"),
and why recovery has both a tunnel-side and a user-side half.

Recovery, in order:

1. `flux -n network resume ks pangolin-newt` (if suspended) and reconcile — this
   restores the correct DNSEndpoint.
2. `kubectl rollout restart -n network deploy/external-dns-cloudflare` to
   republish the record.
3. The zone's negative TTL is **1800s**, so the LAN resolver and the Talos host
   resolver (`169.254.116.108`) keep serving NXDOMAIN for up to 30 minutes.
   Restarting CoreDNS is *not* enough — it forwards to those.
4. **Restore the _tunnel_ without waiting out the TTL.** Pinning the hostname on
   the newt pod lets newt re-authenticate immediately:

   ```bash
   kubectl patch deploy -n network pangolin-newt --type=json \
     -p '[{"op":"add","path":"/spec/template/spec/hostAliases","value":[{"ip":"<vps-ip>","hostnames":["pangolin.<domain>"]}]}]'
   ```

   Remove it (or let Flux revert it) once DNS resolves again.

   Be honest about what this buys: `hostAliases` rewrites resolution **inside the
   newt pod only**. An external user never asks the cluster anything — they
   resolve `photos.<domain>`, follow the CNAME to `pangolin.<domain>`, and get
   nothing back from their own resolver while that record is missing. A perfectly
   healthy tunnel is still a total outage for them. This step fixes the connector,
   not the service.

5. **Restore _user-facing_ service.** Confirm the A record is genuinely back at
   the authoritative source and at a public resolver — step 2 should republish
   it, but verify rather than assume:

   ```bash
   dig +short pangolin.<domain> @1.1.1.1
   dig +short photos.<domain> @1.1.1.1   # should CNAME → pangolin.<domain>
   ```

   Then wait out the public negative TTL (the zone's SOA minimum, 1800s — nothing
   you control can shorten what a third-party resolver has already cached). If
   that is too long to sit through, the only real lever is to temporarily replace
   the app CNAMEs with A records pointing straight at the VPS IP, bypassing the
   missing name entirely. Revert them once `pangolin.<domain>` resolves again,
   otherwise a future VPS IP change will silently break exactly the hostnames you
   edited and nothing else — a failure mode that is very hard to spot.
