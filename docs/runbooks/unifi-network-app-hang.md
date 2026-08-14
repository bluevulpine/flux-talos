# UniFi Network application hangs on Morpheus (UDM-SE)

**Symptom you will actually see:** `KubePodNotReady` for
`external-dns-unifi-*` in namespace `network`. The pod sits at `1/2` in
`CrashLoopBackOff` with a fast-climbing restart count (112 in ~9h on
2026-08-13).

That alert blames the cluster. The fault is on the gateway.

## Confirm in 60 seconds

The decisive test is that **authenticated** calls hang while UniFi OS stays
healthy. Do not use an unauthenticated probe — while the gateway was wedged,
an unauthenticated GET to the same path still returned `401` in 240 ms,
because UniFi OS rejects before proxying to the Network app.

```bash
kubectl run unifi-check -n network --rm -it --restart=Never \
  --image=nicolaka/netshoot:latest \
  --overrides='{"spec":{"securityContext":{"runAsUser":1000,"runAsNonRoot":true}}}' \
  --env-from=secret/external-dns-secret-unifi -- sh -c '
    curl -sk -c /tmp/c -o /dev/null -w "login  http=%{http_code} t=%{time_total}\n" \
      --max-time 20 -X POST -H "Content-Type: application/json" \
      -d "{\"username\":\"$EXTERNAL_DNS_UNIFI_USER\",\"password\":\"$EXTERNAL_DNS_UNIFI_PASS\"}" \
      https://10.0.10.1/api/auth/login
    curl -sk -b /tmp/c -o /dev/null -w "health http=%{http_code} t=%{time_total}\n" \
      --max-time 20 https://10.0.10.1/proxy/network/api/s/default/stat/health'
```

| login | health | meaning |
|---|---|---|
| 200 fast | 200 fast | Network app fine — look elsewhere |
| **200 fast** | **hangs / `http=000`** | **this runbook** |
| hangs | hangs | whole box down — check power/link |
| 401 | — | credentials rotated; check OpenBao key `unifi` |

## Root cause

The UDM-SE has 3.9 GB of RAM and runs both the Network stack (~960 MB across
`unifi` + `mongod`) and the Protect stack (~950 MB across ~24 processes:
`unifi-protect`, `msr`, `mst`, `ms`, `msp`, and ~19 postgres backends), plus
`unifi-core` at ~450 MB. When it runs out, it thrashes:

- swap-out sustained at 1.5–2.7 MB/s
- free memory falling 354 → 81 MB in 6 seconds
- run queue 8–10 on 4 cores, 76k context switches/s
- `mongod` with 217 MB paged out

Every Network API call then has to fault mongo pages back from swap on an
IO-saturated box, exceeding every client timeout. UniFi OS auth and Protect
stay responsive because their hot paths remain resident — which is exactly why
the failure looks so selective.

The Network app self-reports this. Check it:

```bash
ssh root@morpheus.funb.us 'systemctl status unifi --no-pager | grep -o "\"pressures\":\[[^]]*\]"'
# → "pressures":["low_memory","refault_rate_increasing","cpu_pressure"]
```

`refault_rate_increasing` means pages are swapped out and immediately faulted
back in. Note this field is **cached, not live** — its `updatedAt` does not
advance on every poll, so treat a stale value with suspicion.

## Fix

```bash
ssh root@morpheus.funb.us 'systemctl restart unifi'
```

It is a native systemd unit on UniFi OS 5.x — *not* inside `unifi-os shell`.

Expect `/proxy/network/*` to answer within 60–90 s. external-dns exits backoff
on its own within 5 minutes; no cluster action needed. Routing and Protect are
unaffected (the dataplane is independent of the controller).

Expected recovery, measured 2026-08-13:

| | before | after |
|---|---|---|
| `/proxy/network/*` | hang → timeout | 30–70 ms |
| load avg (1/5/15) | 13.79 / 14.16 / 14.67 | 3.54 / 3.92 / 6.91 |
| available memory | 375 MB | 728 MB |
| swap-out | 1.5–2.7 MB/s | ~0 |
| `unifi.service` | 844 MB | 466 MB |

The JVM will likely miss the 30 s stop timeout and get SIGKILLed
(`code=killed, status=9/KILL`) — expected on a thrashing box, and it restarts
clean. It does mean mongo takes an unclean shutdown each time, which is one
reason not to schedule these blindly.

## Blast radius

**Limited.** external-dns fails at the *read* step, so it never reaches the
sync/delete phase and no DNS records are removed. Verified during the incident:
all of `gitea` / `nexus` / `drone` / `influxdb.derekjacobs.dev` continued to
resolve to `172.16.8.2`, and all 192 static-DNS records were intact afterwards.

Only **new or changed** internal hostnames fail to publish while it is down.

## Predicting it

`unpoller_device_memory_utilization_ratio{name="Morpheus"}` is a sawtooth over
60 days of Thanos history: it climbs, a restart or reboot resets it, it climbs
again. Daily averages:

```
normal band ....... 68–78%
07-14 / 07-15 ..... 80%   → mini-episode 07-16 (+10 restarts)
08-09 ............. 80%   → outage 08-13
08-10 → 08-13 ..... 82 → 84%  (wedged)
```

Alerts `UnifiGatewayMemoryPressure` (>0.80) and `UnifiGatewayMemoryCritical`
(>0.83) in `kube-prometheus-stack/app/prometheusrule.yaml` fire on this.
Backtested over 60 days they fire on 11 days, and every cluster of firings
precedes a real episode — with ~6 days of lead time before 08-13.

**The metric is only useful at the multi-day scale.** Within the incident it
stayed flat at 0.82–0.89 and told us nothing. Do not use it to decide whether
the gateway is wedged *right now* — use the curl check at the top.

Also do not trust `unpoller_device_load_average_5` during an incident: it
reported an identical `4.95` for four consecutive samples while the kernel
showed 13–14. unpoller serves cached values when the controller is unresponsive.

## The durable fix

Restarting the Network app is symptomatic. Two structural problems drive the
floor upward:

1. **Protect postgres connection leak** — 19 backends, 9 of them idle for over
   a day (oldest ~18 days). Cleared by restarting Protect.
2. **`/dev/md3` at 99%** (122 G of 11 T). A fixed-size recording ring *must*
   purge — that is normal. What matters is whether purging is steady-state or
   thrashing against the ceiling; check IO wait before treating it as a fault.

**Service restarts do not reset the floor — only a reboot does.** Measured
end-to-end on 2026-08-13:

| stage | mem ratio | swap used | pressures |
| --- | --- | --- | --- |
| wedged | 84% | 1300 MB | low_memory, refault_rate_increasing, cpu_pressure |
| after `systemctl restart unifi` | 79–80% | 1189 MB | (unchanged) |
| after `systemctl restart unifi-protect` | 78–80% | 1166 MB | (unchanged) |
| **after full reboot** | **69–72%** | **97 MB** | **cpu_pressure only** |

The residue is swap. It sat at 1166–1300 MB across *both* service restarts —
pages evicted days earlier never fault back in and get freed, so the app
restarts reclaim heap but not the underlying pressure. The reboot took 164 s
and cleared it outright, and `low_memory` / `refault_rate_increasing` both
dropped off the degradation list.

So: restart the Network app to end an active outage quickly, but **reboot to
reset the clock**. If you only ever do service restarts the floor ratchets up
(63–68% in June/July → 78–80% by 2026-08-13) and the interval between hangs
shrinks.

Restarting Protect is still worth doing for its own reason — it clears the
postgres connection leak (9 backends idle >1d → 0) — but it bought only ~73 MB
and did not move the memory ratio.

Reboot cost: ~3 minutes of full internet and inter-VLAN outage, plus a
recording gap. The Kubernetes cluster is unaffected — all nodes sit on
`10.0.10.x` behind the Core switch, so etcd/Cilium traffic is switched rather
than routed through the UDM. external-dns-unifi will add a few restarts during
the window and recover on its own.

Moving Protect off the UDM-SE entirely (e.g. a dedicated NVR) removes ~950 MB
and the AI/transcode CPU load, and is the only change that fixes this class of
failure rather than deferring it.
