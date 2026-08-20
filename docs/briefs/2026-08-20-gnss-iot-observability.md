# Brief: GNSS / IoT observability — chronos gpsd, GEODNET, Wingbits

**Date:** 2026-08-20
**Status:** Brief — not designed, not planned. Enough context to start cold.
**Origin:** Started while pulling a lat/long off chronos for rackpanel's sunrise/sunset tile, then widened.

Three related devices, one shared theme: **GNSS hardware whose health is currently
invisible.** Two of them have a specific, known failure mode that existing
monitoring cannot see.

---

## The actual goal (stated by the operator, and it changes the design)

> "Occasionally the HyFix and Wingbits still show up on the network, but are
> inaccessible from their UI and need a PoE power cycle. That's my main goal —
> getting an alert so I know when I need to look and bounce them."

**This rules out the obvious implementation.** Both devices are already visible in
UniFi via unpoller (`unpoller_client_*`), so a presence-based alert looks
attractive and is *exactly wrong*: in the failure mode the device is still
associated to Wi-Fi and still answers at L2/L3. Presence data would report it
healthy for the entire outage.

The check must be **application-layer**: does the device still serve HTTP?

**Gatus is already deployed** (`kubernetes/apps/observability/gatus/`) with
endpoints configured in `app/helmrelease.yaml` (~line 109), and the repo already
uses `gatus.home-operations.com/endpoint` annotations elsewhere (homepage,
scrypted, frigate). That is almost certainly the right tool — no new component.

---

## Device inventory (measured 2026-08-20)

| | "HyFix GeodNet" | "Wingbits WB200" |
| --- | --- | --- |
| IP | `192.168.50.68` | `192.168.50.250` |
| MAC OUI | Espressif | AMPAK |
| VLAN | 50 (IOT) | 50 (IOT) |
| AP | Living Room IW6 | Roof Mesh |
| `GET /` | **HTTP 401** | **HTTP 302** → `/index.html` |
| Web UI (`:80`) | HyFix **MobileCM** | HyFix **MobileCM** |
| Also serves | — | `:8088` Wingbits monitor, `:8504` tar1090, `:8542` graphs1090 |
| Hostname | — | `hyfix.funb.us` |

### Both devices are HyFix hardware — but the WB200 also runs a full ADS-B stack

**Confirmed by the operator: the Wingbits WB200 is HyFix-manufactured.** That is
why both devices serve the same HyFix `MobileCM` UI on port 80.

⚠️ **An earlier draft of this brief concluded the WB200 "is not a readsb/tar1090
stack". That was wrong — port 80 was the only port probed.** The ADS-B services
run on non-default ports, which is exactly why they were missed:

| Port on `192.168.50.250` | What it is |
| --- | --- |
| `:80` | HyFix **MobileCM** (302 → `/index.html`) — same firmware as the GEODNET unit |
| `:8088` | **Wingbits Station Monitor** (references readsb + wingbits) |
| `:8504` | **tar1090** (lighttpd) — `?icao=<hex>` for a specific aircraft |
| `:8542` | **graphs1090** (lighttpd) — `?timeframe=365d`. This is the "graphs, not Grafana": collectd + RRDtool |

Also reachable as **`hyfix.funb.us`**.

### The readsb JSON is available and rich

`:8504/data/{aircraft,stats,receiver}.json` all return **200**. `stats.json` is
the prize:

- Top level: `aircraft_with_pos`, `aircraft_without_pos`, `aircraft_count_by_type`,
  **`estimated_ppm`** (receiver frequency error), **`gain_db`** (RF gain), `now`
- Windows: `last1min`, `last5min`, `last15min`, `total`
- Per window: `messages`, `messages_valid`, **`max_distance`** (antenna reach),
  `position_count_total`, `tracks`, plus
  `local.{samples_processed, samples_dropped, samples_lost, modes, bad, unknown_icao}`
  and a `cpu` breakdown

Sampled live: 34 aircraft tracked, `samples_dropped: 0`, `samples_lost: 0`.

`samples_dropped` / `samples_lost` are direct receiver-health signals,
`max_distance` tracks antenna performance over time, and `gain_db` /
`estimated_ppm` catch tuning drift. This is a genuinely good metric surface —
**and scraping it doubles as the health check, because a hung device cannot
serve it.** Prefer this over probing port 80 for the WB200.

Check for an existing readsb/dump1090 Prometheus exporter before writing one;
several exist, and `stats.json` is a well-known scrape target.

### Health-check shape

A *healthy* MobileCM answers quickly with 401 or 302. A hung one — the failure
mode — will time out or refuse. So:

- Expect `[STATUS] < 500` **and** a tight `[RESPONSE_TIME]` bound. **Do not**
  expect `200`: `.68`'s healthy steady state is `401`, and a naive `== 200` check
  would alert permanently.
- Keep the timeout short (a few seconds). The signal is "stopped answering", and a
  long timeout delays the page you actually want.
- Alert only after N consecutive failures, to ride out Wi-Fi blips on an IOT VLAN.

### Possible follow-on: automate the remediation

Both devices are PoE and UniFi-managed. UniFi's API can cycle a PoE port, so the
alert could eventually become auto-remediation (cycle the port, wait, re-check,
escalate only if it fails twice). **Do not build this first.** Get the detection
right, watch it for a few cycles, confirm the failure signature is unambiguous —
an auto-power-cycler firing on a false positive is worse than the outage.

---

## chronos: scrape gpsd

`chronos` is the cluster's **time source** — every Talos node syncs to
`chronos.funb.us`. GPS health here is time health, and etcd is sensitive to clock
behaviour.

What exists today is `node_timex_pps_*` (jitter, frequency, stability). Those come
from the **kernel PPS discipline**, not gpsd: they show the pulse arriving and how
steady it is, but nothing about satellite count, fix quality or dilution of
precision. A receiver slowly going deaf under a failing antenna would surface late
as jitter rather than early as a declining satellite count.

### Already true (don't re-derive)

| Fact | Value |
| --- | --- |
| SSH | **`root@chronos` works** with the existing `id_ed25519`. `dietpi@` does **not**. |
| Host | Raspberry Pi, DietPi, kernel `6.12.47+rpt-rpi-v8`, Tailscale `100.104.24.17` |
| gpsd | `3.25.1~dev`, active, device `/dev/ttyAMA0` |
| Tools | `/usr/local/bin/{gpspipe,gpsctl,cgps}` |
| Scraping | already `job=node-exporter, instance=chronos`; config in `kubernetes/apps/observability/kube-prometheus-stack/app/scrapeconfig.yaml` |
| **Textfile collector** | **already enabled**: `--collector.textfile.directory=/run/node_exporter` |

That last row is the important one: **a script writing `.prom` files into
`/run/node_exporter` flows into the existing scrape** — no new exporter, no new
target, no Prometheus config change. `/run` is tmpfs, so the writer must be a
boot-started timer, not a one-shot.

### What gpsd offers (sampled live; position values omitted)

**TPV**, once per second: `mode` (3 = 3D fix), `status` (2 = **DGPS**),
**`ept` = 0.005** (estimated time error, s — the headline metric for a time
server), `eph`/`epv` ≈ 5 m, `epx`/`epy` ≈ 4–6 m, `sep` 6.6, `speed`/`climb`
(≈0 for a fixed install, so non-zero is a fault signal), `magvar`.

**SKY**: 10 satellites visible, **7 used**. Full DOP set — `gdop 4.03`,
`pdop 1.38`, `hdop 1.06`, **`tdop 1.91`**, `vdop 0.88`. Per satellite: `PRN`, `az`,
`el`, `gnssid`, `svid`, `ss` (signal strength), `used`.

### ⚠️ Do not export raw coordinates

The obvious implementation exports `lat`/`lon` as gauges. **Don't.** It writes a
home address into the TSDB, into Thanos object storage, and into any dashboard
screenshot. The flux-talos repo is public and dashboards get shared.

It is also not what the interesting question needs. "How much does the fix drift?"
is answered by **distance from a fixed reference**, not absolute position:

```
gpsd_position_offset_metres    # haversine(current fix, configured reference)
```

with the reference stored on chronos (e.g. `/etc/gpsd-metrics.conf`), never
committed. Full drift signal preserved; the TSDB never learns where the antenna
is. Same treatment for altitude — export offset, not value.

Precedent: rackpanel's sunrise/sunset tile ships Thief River Falls city centre
(48.1191, -96.1811) instead of the real fix. Measured cost: **8.0 km displacement
→ 0.4 minutes of sunrise/sunset error**, i.e. nothing at `HH:MM` resolution.

### Candidate metrics

```
gpsd_up                              # 1 when gpsd answered
gpsd_fix_mode                        # 0-3
gpsd_fix_status                      # 2 = DGPS
gpsd_satellites_visible
gpsd_satellites_used
gpsd_time_error_seconds              # ept
gpsd_dop{type="gdop|pdop|hdop|tdop|vdop"}
gpsd_position_error_metres{axis="h|v|x|y|sep"}
gpsd_position_offset_metres          # drift vs reference
gpsd_satellite_snr_db{prn="..."}     # optional; see cardinality note
```

Per-PRN SNR is the cardinality risk — ~30 series that churn as satellites rise and
set. Prefer min/mean/max across *used* satellites by default.

---

## Open questions

1. **~~Is there an ADS-B device?~~ Resolved: yes.** `.250` runs readsb behind
   tar1090/graphs1090 on `:8504`/`:8542`, with JSON at `:8504/data/`. Start there.
2. **MobileCM auth.** Both devices return the MobileCM UI on `:80`; `.68` gives a
   401. The operator will supply a login. Once available, check whether the UI
   exposes satellite/fix data locally — **local scraping would beat the GEODNET
   cloud console entirely** (no credentials in-cluster, no third-party dependency,
   works when their site is down).
3. **Firmware-update detection (operator request).** Both devices run the same
   MobileCM firmware, so one check covers both. Likely behind the `:80` login, so
   it depends on Q2. Shape: scrape the reported firmware version as a labelled
   gauge (`hyfix_firmware_info{device,version} 1`) and alert on *change* rather
   than on a hardcoded "latest" — that needs no upstream version feed and still
   tells you when something shifted under you.
4. **Does an off-the-shelf GEODNET/HyFix/readsb exporter exist?** Check before writing
   one. Same for MobileCM — if it has a JSON endpoint, this is a small job.
5. **Cloud vs local for GEODNET.** The console shows uptime/rewards/satellite
   counts. Local is preferable (no credentials in-cluster, no third-party
   dependency, works when their site is down), but only if the data is there.
6. **Alert thresholds for gpsd**, defined *before* building so the metric set is
   driven by the questions: `fix_mode < 3` for N minutes; satellites used below
   ~4; `ept` above a threshold.
7. **Is DietPi's node_exporter managed by anything?** If hand-installed, the
   textfile writer must be installed and documented the same way, or it is lost on
   the next rebuild.
8. **Rackpanel scene?** A `TIME`/`GNSS` scene — fix mode, satellites used, PPS
   jitter, device health — would fit the tile budget. See the rackpanel design's
   deferred-scene list.

## Starting points

```bash
ssh root@chronos 'gpspipe -w -n 40'        # raw TPV + SKY JSON
ssh root@chronos 'ls /run/node_exporter'   # where .prom files go
curl -sS -D- http://192.168.50.68/         # MobileCM, 401
curl -sSL -D- http://192.168.50.250/       # MobileCM, 302 -> /index.html
curl -sS http://192.168.50.250:8504/data/stats.json   # readsb stats -- the prize
curl -sS -o /dev/null -w '%{http_code}\n' http://192.168.50.250:8088/  # Wingbits monitor
```
