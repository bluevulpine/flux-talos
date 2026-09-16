# Runbook: WAN upload collapse from a failing SFP+ cage

Every LAN host uploaded to the internet at ~20 Mbit/s on a 500/500 fibre line,
while the router itself managed 200+. Downloads were fine. Root cause was a
failing SFP+ **cage** on the UDM SE (`eth10`), corrupting ~0.2% of received
frames. Diagnosed and fixed 2026-09-15.

The fix took five minutes. Finding it took hours, because the fault is
invisible to every test that stays on the LAN. That is what this document is
for.

## The one idea worth remembering

**A fixed packet-loss rate costs you throughput in proportion to RTT.**

Single-flow TCP throughput follows the Mathis relation
`≈ MSS / (RTT × √loss)`. So the *same* 0.26% loss produces:

| Path | RTT | Result |
| --- | --- | --- |
| LAN (vault → router) | 0.2 ms | 1.98 Gbit/s — looks perfectly healthy |
| Internet (vault → Cloudflare) | 11 ms | **20 Mbit/s** |

A LAN throughput test therefore **cannot** clear a link. `iperf3` across the
bad cage reported 1.98 Gbit/s while silently logging 2,940 retransmits. Read
the retransmit column, not the bitrate.

Corollary: downloads stayed fast throughout, because the sender there is
Cloudflare. Loss only punishes the congestion control of whoever is *sending*.
**One-directional slowness with healthy downloads points at your own egress.**

## Symptoms

- Every LAN host (NAS, k8s pods) uploads at ~20-30 Mbit/s; downloads 230-310.
- The router itself uploads at 114-240 Mbit/s from the same WAN.
- Slow hosts are *stable* (±5%) while the router's own speed swings wildly.
  That stability is the tell: congestion varies, a loss ceiling does not.
- Parallel streams scale (1 → 20, 4 → 98, 8 → 168 Mbit/s), so aggregate
  bandwidth is fine. Anything that samples with multiple streams — including
  UniFi's built-in speed test — reports a healthy line and hides this.

## Diagnosis

### 1. Confirm it is egress-side, not the cluster

Test from a plain LAN host with no Kubernetes/Cilium/Tailscale in the path:

```bash
ssh vault 'head -c 20000000 /dev/zero >/tmp/u.bin
  curl -o /dev/null -s -w "up: %{speed_upload} B/s\n" \
    --data-binary @/tmp/u.bin https://speed.cloudflare.com/__up; rm -f /tmp/u.bin'
```

If a non-cluster host shows it too, stop looking at the cluster.

### 2. Compare a forwarded host against the router itself, interleaved

Run them back to back. **Do not compare measurements taken minutes apart** —
the ISP link here swings 114-240 Mbit/s on its own, enough to fake or mask a
result. One round of ours showed only a 1.9× gap purely from ISP variance,
where the true figure was ~9×.

### 3. Read the TCP socket, not the stopwatch

```bash
ssh vault 'ss -tin dst 162.159.0.0/16 | sed -n 3p'
```

The smoking gun was:

```
cubic rtt:11.17/0.873 mss:1388 cwnd:14 ssthresh:13
bytes_sent:28704645 bytes_retrans:90220
```

- `cwnd:14 × mss:1388 × 8 / rtt:0.011` = 19 Mbit/s — exactly what was measured,
  so the flow is **cwnd-limited**, not app- or receiver-limited.
- `bytes_retrans/bytes_sent` = 0.29% → feed into Mathis, the numbers close.
- RTT is *low and stable* (mdev 0.87 ms), so jitter is not the cause here.
- No `dsack_dups` / `reord_seen` → real loss, not reordering.

### 4. Prove it is physical, not congestion: vary the rate

```bash
for rate in 100M 500M 1000M 0; do
  ssh vault "iperf3 -c <router> -t 6 -b $rate | grep sender"
done
```

| Rate | Retr | Loss |
| --- | --- | --- |
| 100 Mbit/s | 127 | 0.26% |
| 500 Mbit/s | 609 | 0.25% |
| 1000 Mbit/s | 1340 | 0.27% |
| unlimited | 2940 | 0.29% |

**Flat loss across all rates = physical layer fault.** Buffer exhaustion or
shaping would start near zero and climb steeply with offered load.

### 5. Find the interface

```bash
ssh root@morpheus 'for i in $(ip -o link show | awk -F": " "{print \$2}"); do
  ip -s link show $i | awk -v n=$i "/RX:/{getline; if (\$3+0>0) print n\" err=\"\$3\" pkt=\"\$2}"
done'
```

`eth10` showed `rx_errors 4,800,042 / rx_packets 2,616,180,931` = 0.183%, with
`tx_errors 0`. Sample it three times ten seconds apart — a cumulative counter
proves nothing unless it is **still incrementing**:

```
t1 err=4800140 pkt=2616233742
t2 err=4800180 pkt=2616264533     +40 / +30,791  = 0.13%
t3 err=4800235 pkt=2616300606     +55 / +36,073  = 0.15%
```

`dropped 0` and `missed 0` alongside nonzero `errors` means genuine frame/CRC
corruption, not ring-buffer overrun.

Identify the link and its far end:

```bash
ssh root@morpheus 'ethtool -m eth10 | grep -iE "Identifier|Connector|Transceiver|Vendor|Length"
                   lldpcli show neighbors ports eth10 details'
```

Ours: 1 m passive SFP+ DAC (`OEM CAB-10GSFP-P1M`) → `Core`
(USW-Enterprise-24-PoE) port 26 / `SFP_ 2`.

### 6. Isolate cage vs cable vs far-end port

Move **one variable at a time**. We moved the DAC to a different UDM cage
(`eth10` → `eth9`), keeping the same cable and the same Core port 26:

```
BEFORE (eth10):  2,940 retrans over 1.38 GB @ 1.98 Gbit/s
AFTER  (eth9):       1 retrans over 2.83 GB @ 2.43 Gbit/s
                 rx_errors 0 across 365,731 packets
```

Verdict: the **UDM's `eth10` cage** was at fault. The DAC and the switch port
were both fine. Had errors followed the cable, the next step would have been
Core port 26 → 25.

## Result

| Measurement | Before | After |
| --- | --- | --- |
| vault upload | 15-26 Mbit/s | **166-214 Mbit/s** |
| k8s pod upload | 29 Mbit/s | **130 Mbit/s** |
| k8s pod loss | 0.191% | **0.005%** |
| vault → router LAN | 1.98 Gbit/s, 2940 retr | 2.43 Gbit/s, **1 retr** |

Forwarded hosts now match or beat the router. Do not use `eth10` until the
cage is known good; treat that port as suspect hardware.

## Verification after any future reseat

```bash
ssh root@morpheus 'for i in 1 2 3; do \
  ip -s link show eth9 | awk "/RX:/{getline; print \"err=\"\$3\" pkt=\"\$2}"; sleep 10; done'
```

Errors must not increment. Then re-run step 4 and confirm retransmits stay
near zero.

## Link capacity — measured, before adding any

Taken 2026-09-15 from Thanos (`unpoller_device_port_*_bytes_total`). Peak of a
10-minute average sampled hourly over 30 days, so short bursts are invisible
and true instantaneous peaks are higher.

| Core port | Link | Peak RX | Peak TX | Utilisation |
| --- | --- | --- | --- | --- |
| 17 (vault bond leg) | 2.5G | **2,387 Mbit/s** | 1,452 Mbit/s | **95%** |
| 18 (vault bond leg) | 2.5G | 1,540 Mbit/s | 1,351 Mbit/s | 62% |
| 4 "Office" | 1G | 611 Mbit/s | 298 Mbit/s | 61% |
| 26 "SFP+ 2" → UDM | 10G | 395 Mbit/s | 545 Mbit/s | **5.4%** |

**The UDM uplink is not a bottleneck and does not want a second DAC.** Even a
10x underestimate leaves it loafing. Two further reasons not to LAG it:

- 802.3ad hashes **per flow**, so a single flow is still capped at 10G. A LAG
  buys aggregate capacity and redundancy, never single-flow speed. (Same
  mechanism that pinned vault's uploads to one bond leg during this
  investigation.)
- `eth10`'s cage is suspect hardware. LAG `eth9`+`eth10` and roughly half the
  flows hash onto the bad cage, reintroducing the loss **intermittently** —
  far harder to diagnose than the consistent version. Do not use `eth10` until
  it is proven clean on something low-stakes.

The tightest link in the fabric is **port 17 at 95% of 2.5G**, not the office.
Ports 17/18 are vault's `enp9s0`/`enp10s0` LACP pair; because LACP pins a flow
to one leg, a single heavy transfer can saturate one 2.5G leg while the bond
as a whole still looks half idle.

### Acceptance test for any new high-speed link

Do **not** qualify a link with a speed test. The fault in this runbook trained
at 10G and passed every throughput test while corrupting 0.2% of frames.

```bash
iperf3 -c <other end> -t 30     # read the Retr column, NOT Gbits/sec
ip -s link show <iface>         # rx_errors must stay flat at 0
```

Retr in single digits and `rx_errors` not incrementing = good. Retr in the
thousands while the bitrate still looks great = the same failure mode.

Cable guidance for a 10GBASE-T run: Cat6 is rated to 55 m, Cat6a to 100 m.
Cat5e is not rated for 10G but often works under ~10 m — qualify it with the
test above rather than assuming, in either direction.

## Dead ends — do not re-investigate these

All were ruled out **with evidence**. Four were confident wrong turns.

| Suspect | How it was killed |
| --- | --- |
| Cluster / Cilium / Tailscale | vault, a plain LAN host, showed the identical cap |
| LAN bandwidth | vault → router ran 1.98 Gbit/s; pod → pod 2.2 Gbit/s |
| WAN link or ISP bandwidth | router pushed 200+ Mbit/s over the same WAN |
| **HTB shaper / QoS default class** | Called it the smoking gun. Then traced which class the router's *fast* traffic used: the same `1:2` (`rate 64bit prio 7`), at 199 Mbit/s. The 157M `overlimits` are just HTB borrowing accounting for a zero-rate default class — **`overlimits` is not `dropped`** |
| fq_codel drops | 510 → 510 across a full slow upload, zero ECN marks |
| **DPI / traffic prioritization** | Rules left the datapath mid-session; vault stayed pinned at 19-21 Mbit/s. Turning DPI off does **not** help |
| CPU / IPS | All 4 cores 50-58% idle; Intrusion Prevention was already off |
| Dual-WAN load balancing | vault, pods and router all egress `66.219.1.132` (eth8) |
| Congestion control | router, vault and k8s nodes are all `cubic` |
| **`Auto-negotiation: OFF` on the SFP+ link** | Normal for a passive DAC. `ethtool` reporting `Port: Twisted Pair` is the `al_eth` driver misreporting a DAC — not evidence of copper |
| Bad cable at the NAS | Both vault bond legs showed zero CRC/TX errors; a second host on different cables showed the same loss |

### Two traps in the tooling

- **Mongo's `device.port_table` is configuration, not statistics.** It has no
  `rx_errors`/packet fields at all, so `p.rx_errors || 0` silently yields 0 for
  every port on every device — which reads exactly like a clean network and is
  how this investigation initially, and wrongly, concluded the far end of the
  failing link was healthy. The stats live in the live controller API, and
  **they are accurate**: unpoller polls it and had the correct figure
  (`unpoller_device_port_receive_errors_total{port_id="Morpheus Port 11"}` =
  4,803,210) in Prometheus the entire time. Query the metrics, or read the
  host directly with `ip -s link` sampled twice — never mongo's port_table.
- **`db.device.find()` output is long.** Piping it through `tail` silently
  drops devices — `Core` was #10 of 25 and vanished from an early dump, which
  led to a wrong conclusion that it was third-party. Also note `port_table`
  entries have `up: undefined`, so filtering on `p.up` matches nothing.

## Still outstanding: ISP first-hop jitter

Unrelated to the above and **not** fixed by the cage swap. Both WAN links —
which share one fibre modem through a dumb switch — show identical latency
instability one hop out:

```
eth8 gw 66.219.0.1    min 1.88  max 146.10  mdev 20.67 ms
eth7 gw 64.235.64.1   min 2.22  max 157.46  mdev 26.08 ms
```

0% ICMP loss, so this is queueing/scheduling, not a broken link.

### ICMP badly overstates it — measure the data plane

**This is the correction that matters.** The numbers above are ICMP, and ISP
routers routinely deprioritise and rate-limit control-plane ICMP. Measuring
the actual data path tells a far milder story:

| Method | Result |
| --- | --- |
| ICMP ping | max 220-328 ms, mdev 20-65 ms — looks like constant chaos |
| TCP handshake, 30 samples to 1.1.1.1 | median **11.2 ms**, p90 **13.8 ms**, one outlier at 158 ms |
| TCP socket during a real bulk transfer | `rtt:11.17/0.873` — mdev under **1 ms** |

Real latency is ~11 ms with roughly **1 connection in 30** taking a ~150 ms
hit. Annoying, worth reporting, but not the crippling instability ICMP
implies — and never what capped uploads. The cage was.

```bash
# the right probe: TCP handshake, not ping
for i in $(seq 30); do curl -4 -o /dev/null -s -w "%{time_connect}\n" https://1.1.1.1/; done
```

### It is not the 500 Mbit rate limit

A shaper queueing your own traffic would make jitter scale with load. It does
not — the spikes are fully present at idle:

| Phase | max | mdev |
| --- | --- | --- |
| Idle | 267 ms | 34.9 |
| Upload saturated, 8 streams | 254 ms | 41.1 |
| Download saturated, 8 streams | 253 ms | 40.8 |

So a higher tier buys headroom for a problem that is not headroom-related.

**Local hardware is ruled out — do not re-test this.** The normal topology is
fibre modem → dumb gigabit switch → two cables → UDM (two WAN ports, two
public IPs). On 2026-09-15 we bypassed that entirely and ran a single cable
from the modem straight into the UDM:

| Path | → ISP gw (max / mdev) | → 1.1.1.1 (max / mdev) |
| --- | --- | --- |
| Through switch (earlier) | 146 ms / 20.7 | 275 ms / 40.4 |
| Direct to modem, run 1 | 246 ms / 41.4 | 220 ms / 34.7 |
| Direct to modem, run 2 | 318 ms / 48.6 | 328 ms / 64.8 |
| Through switch (paired, +4 min) | 185 ms / 18.5 | 241 ms / 34.9 |

The two direct runs are the **same configuration measured twice** — max 246 vs
318 ms, mdev 41.4 vs 48.6 — so this metric carries roughly ±30% run-to-run
noise and a single pair of samples proves nothing. Going direct did not help;
the switched path actually measured marginally better on the gateway hop. The
jitter is plainly present in every topology tested. Router upload stayed in
the same 75-188 Mbit/s swing throughout, and `eth8` shows `rx_err=0` across
751M packets in both configurations.

While direct, only one WAN reaches the ISP (`eth7` keeps link to the switch
but has no route out), so that is a diagnostic state, not one to leave
running. Restored config: both WAN ports up, `66.219.1.132` and
`64.235.64.92`.

So the switch, both WAN cables, and both UDM WAN ports are all exonerated.
What remains upstream is the modem, the fibre, and GVTel's access equipment.
The complaint to GVTel is: *both public IPs, and a direct modem-to-router
connection bypassing all customer switching and cabling, show the same
occasional latency excursion — roughly 1 TCP connection in 30 taking ~150 ms
against a ~11 ms median — with 0% packet loss.* Lead with the TCP figures,
not the ICMP ones; the ICMP numbers invite being dismissed as ping
deprioritisation, which is largely what they are.

## Is the WAN tier the constraint? (measured, 2026-09-15)

Peak of a 10-minute average over 30 days: **364 Mbit/s down, 518 Mbit/s up**.
A peak alone says nothing about need, so here is the distribution — 7 days at
full 5-minute coverage, 2016 samples:

| Direction | >50 Mbit/s | >100 | >250 | >400 |
| --- | --- | --- | --- | --- |
| Upload | 2.33% | 0.60% | 0.10% | **0.00%** |
| Download | 2.83% | 0.79% | 0.10% | 0.05% |

**Upload never once exceeded 400 Mbit/s in a week, and sits under 50 Mbit/s
for 97.7% of it.** The 518 Mbit/s figure was a single 10-minute window in 30
days. On this evidence a 1 Gbit tier would buy capacity used ~0.1% of the
time, and would not touch the latency excursions above.

Two honest caveats before deciding:

- The upload side of this window is **contaminated by the very bug this
  runbook documents** — every LAN host was capped near 20 Mbit/s for most of
  it, so upload demand is suppressed by an unknown amount. Re-measure a week
  after the cage fix.
- 5-minute averages cannot see short bursts (see collection limits below).

### Collection: what exists, and its ceiling

WAN throughput **is** collected: `unpoller` → Prometheus → Thanos
(`unpoller_device_wan_{transmit,receive}_bytes_total{name="Morpheus"}`).
It does **not** go to InfluxDB — `UP_INFLUXDB_DISABLE: true` in the
HelmRelease; Influx here carries Home Assistant data, not network telemetry.

Retention and resolution: Prometheus 2d, Thanos raw 14d / 5m 30d / 1h 60d.

The real ceiling is the **2-minute scrape interval**, and it is not a tuning
mistake — UniFi's own API only refreshes every 2 minutes
(`kubernetes/apps/observability/unpoller/app/helmrelease.yaml`). So sub-minute
bursts are invisible no matter how the query is written, and a 1h-resolution
query beyond 30d smooths peaks away almost entirely.

If finer WAN resolution is ever actually needed, the path is **not** to tune
unpoller. Enable SNMP on the UDM (currently off) and scrape it with
`snmp_exporter` at 30s, reading the interface counters directly and bypassing
the UniFi API. Worth doing only if a decision hinges on burst behaviour — the
utilisation numbers above are decisive without it.
