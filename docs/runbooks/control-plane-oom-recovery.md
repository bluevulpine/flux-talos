# Control-plane OOM: recognising it and recovering

> **Historical since 2026-09-22.** The control plane moved off the Pis onto the
> `freyja01` VM (32 GiB) on vault, which is the structural fix for this failure;
> see [controlplane-migration-to-vault-vm.md](controlplane-migration-to-vault-vm.md).
> The recognition steps still apply if a Pi is ever made a control plane again,
> for example in the "if vault dies" recovery. The rolling-reboot procedure does
> not: with one control-plane node, a reboot is an API outage.

The jormungandr Pi control-plane nodes leak memory. Far enough along, the leak
starves etcd and the cluster API becomes unusable. This is how to recognise that
specific failure and recover it without making it worse.

Recovered this way 2026-09-22.

## Recognising it

The first symptom is **not** an alert. It is `kubectl` getting slow, then
returning `InternalError`, then timing out entirely. The API server says why:

```bash
kubectl get --raw='/healthz' --request-timeout=20s
```

```
[+]ping ok
[+]log ok
[-]etcd failed: reason withheld     <- everything else is [+]ok
healthz check failed
```

**etcd is not dead — it is slow.** Confirm by asking Talos, which does not depend
on the Kubernetes API:

```bash
talosctl -n 10.0.10.31 -e 10.0.10.31 service etcd
```

```
STATE    Running
HEALTH   Fail
LAST HEALTH MESSAGE   context deadline exceeded
EVENTS   [Running]: Health check failed: context deadline exceeded (11m42s ago)
         [Running]: Health check successful (12m11s ago)     <- alternating
```

Alternating success/failure over tens of minutes is the signature. A genuinely
broken etcd fails consistently; a starved one flaps.

Then confirm the cause rather than assuming it:

```bash
for n in 10.0.10.31 10.0.10.32 10.0.10.33; do
  printf '%s ' "$n"
  talosctl -n "$n" -e "$n" memory 2>/dev/null | awk 'NR==2{print "avail="$NF"MB"}'
done
```

Under ~500 MB available is where etcd starts stalling. Under ~250 MB the node
stops being able to help itself. Talos says so directly in `dmesg`:

```
[talos] OOM controller triggered
```

## The two things that will waste your time

**1. Graceful reboot silently no-ops.** `talosctl reboot` returns
`reboot sequence completed` and the node **stays up** — it cannot finish the
shutdown sequence without memory. Use `--mode powercycle`.

**2. Powercycle takes ~90 seconds to actually drop the node.** It looks like
another no-op. It is not. Wait before reissuing; on 2026-09-22 the reboot was
sent three unnecessary times because the delay was read as failure.

```bash
talosctl -n <ip> -e <ip> reboot --mode powercycle &
for i in $(seq 1 30); do
  ping -c1 -W1000 <ip> >/dev/null 2>&1 || { echo "down after ~$((i*5))s"; break; }
  sleep 5
done
```

**Past a certain point neither works.** A sufficiently starved node cannot
complete a TLS handshake, and every talosctl call — including reboot — fails
with:

```
transport: authentication handshake failed: context deadline exceeded
```

That node needs a **physical or PoE power cycle**. There is no software path
back. Note the API may answer `version` intermittently while still failing
everything else; one successful call does not mean it has recovered.

## Recovery order

Restart **one at a time**, worst first, verifying etcd rejoins before the next.

With three members, one down leaves two — quorum holds. Restarting a second
before the first has rejoined loses quorum and stops the cluster.

1. Check the two you are NOT restarting both report `HEALTH OK` first.
2. Powercycle the node with the least available memory.
3. Wait for it to return AND for `service etcd` to report `HEALTH OK`.
4. Repeat for the next worst. Healthiest node last.

A node comes back with 5–7 GB available, then settles to ~2–3 GB as pods
reschedule onto it. **That settling is not the leak** — it is a one-time cost,
and mistaking it for runaway leakage sends you chasing a second problem that
does not exist.

## The actual leak rate

`~85 MB/day` was the recorded figure and it is **too low**. Measured 2026-09-22
from Thanos, from each node's last boot (this matters — averaging across a
reboot flattens the slope and understates it badly):

| node | window | decay | rate |
| --- | --- | --- | --- |
| jormungandr1 | 7.2d | 2.54 → 1.63 GB | **126 MB/day** |
| jormungandr3 | 7.2d | 4.43 → 1.94 GB | **348 MB/day** |

It is **load dependent** — j3 leaks nearly 3× j1 — so there is no single number.
Thanos also showed 3 and 6 reboots per node in 45 days, i.e. these nodes cycle
far more often than anyone had recorded.

Practically: from ~5 GB, expect **2–5 weeks**, not the ~45 days previously
assumed. Check with:

```
min by (instance) (node_memory_MemAvailable_bytes{instance=~"10.0.10.3[123].*"})
```

Query **Thanos**, not Prometheus — Prometheus keeps 2 days and will show a
truncated series that looks like "no history".

## Worth doing, not yet done

- An alert on control-plane `MemAvailable` below ~1 GB. Today the first warning
  is kubectl breaking, which is far too late and gives no clue where to look.
- Root-cause the leak rather than rebooting on a cadence. The load dependence is
  the strongest clue available.
