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
| Web UI | HyFix **MobileCM** | HyFix **MobileCM** |

### ⚠️ Both devices serve HyFix firmware

The device labelled **"Wingbits WB200" serves the same HyFix `MobileCM` UI** as the
GEODNET unit, favicon `hyfix.ico` included. Either the UniFi alias is attached to
the wrong client, or the WB200 is HyFix-manufactured hardware running common
firmware. **Resolve this before building anything** — it determines whether there
is an ADS-B receiver on this network at all, and the operator's description
("read SB feed", "health page with graphs") does not match what `.250` actually
serves.

Checked on `.250` and all returned **404**: `/data/aircraft.json`,
`/data/stats.json`, `/data/receiver.json`, `/tar1090/`, `/graphs1090/`,
`/skyaware/`, `/radar/`. So it is **not** a readsb/tar1090 stack. If a real ADS-B
feeder exists, it is a different device that has not been identified yet — worth
sweeping VLAN 50 for one.

The upside of the two devices sharing firmware: **one probe pattern covers both.**

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

1. **Is there actually a Wingbits/ADS-B device?** `.250` serves HyFix MobileCM and
   404s every readsb path. Sweep VLAN 50 before assuming.
2. **MobileCM auth.** `.68` returns 401. What scheme, and is the device serial the
   credential? If the local UI exposes satellite/fix data behind that auth, local
   scraping beats the GEODNET cloud console entirely. **Worth checking before
   building anything against a vendor API.**
3. **Does an off-the-shelf GEODNET/HyFix exporter exist?** Check before writing
   one. Same for MobileCM — if it has a JSON endpoint, this is a small job.
4. **Cloud vs local for GEODNET.** The console shows uptime/rewards/satellite
   counts. Local is preferable (no credentials in-cluster, no third-party
   dependency, works when their site is down), but only if the data is there.
5. **Alert thresholds for gpsd**, defined *before* building so the metric set is
   driven by the questions: `fix_mode < 3` for N minutes; satellites used below
   ~4; `ept` above a threshold.
6. **Is DietPi's node_exporter managed by anything?** If hand-installed, the
   textfile writer must be installed and documented the same way, or it is lost on
   the next rebuild.
7. **Rackpanel scene?** A `TIME`/`GNSS` scene — fix mode, satellites used, PPS
   jitter, device health — would fit the tile budget. See the rackpanel design's
   deferred-scene list.

## Starting points

```bash
ssh root@chronos 'gpspipe -w -n 40'        # raw TPV + SKY JSON
ssh root@chronos 'ls /run/node_exporter'   # where .prom files go
curl -sS -D- http://192.168.50.68/         # MobileCM, 401
curl -sSL -D- http://192.168.50.250/       # MobileCM, 302 -> /index.html
```
