# Plan: move the control plane onto a single VM on vault

**Status: PROPOSED — the leading option, not executed.** Written 2026-09-22.
Supersedes [`controlplane-migration-to-brokkr.md`](controlplane-migration-to-brokkr.md)
as the primary path. That document's diagnosis still stands and is not repeated here;
its brokkr and x86 mini-PC options remain the alternatives if this one is rejected.

## Why now

The three Pi control planes are failing on a clock that has shortened sharply.
On 2026-09-22 all three went `Ready` within 14 minutes of each other (14:28,
14:36, 14:42Z). Within ~3 hours of that boot:

| node | Talos `OOM controller triggered` since boot |
| --- | --- |
| jormungandr1 | 50 |
| jormungandr2 | 180 |
| jormungandr3 | 35 |

`kube-controller-manager` sat at 41/65/80 restarts and `kube-scheduler` at 42/59/91.
Node memory went 80% → 89% over 12h. Another session had to do a CP recovery the same
afternoon, and four VolSync movers wedged over the preceding week — one of them
(`timescaledb-local`) minutes after the churn began.

The cause is the one the brokkr runbook measured: `kube-apiserver` alone is 3.1–4.4 GB
on a 7.8 GB node. It oscillates rather than leaks, and it tracks object count, which only
grows. A reboot no longer buys weeks.

## The decision: one control plane, not three

**The Pis' HA does not protect against the failure that actually happens.** Quorum
protects against *independent* failures. Three identical boards under identical load hit
the same memory ceiling on the same clock, so they fail together — 2026-09-22 was one
event across all three nodes, not three events. Replacing three correlated sick nodes with
one healthy one is expected to be *more* available in practice. That is a judgement, not
a measurement, but the correlation above is measured.

**Never run two.** Quorum on two members needs both alive, which is strictly worse than
one. The choices are one or three.

**It is not a one-way door.** Going from one CP to three later means joining new CP
nodes; the first is never wiped. Adding two more (brokkr, mini-PCs, or anything else)
stays available.

### What one CP gives up

- **Protection against that host dying** — disk, PSU, board. This is the real loss, and it
  is what the backup conditions below exist for.
- **Rolling CP upgrades.** A Talos or Kubernetes upgrade of the one CP node is a brief API
  outage (the reboot), because there is no peer to fail over to.

### What "CP down" actually means

A frozen cluster, not a dead one. Running pods keep running, Cilium keeps forwarding, and
CoreDNS answers from its cache. What stops is everything that needs the API: scheduling,
rollouts, Flux, ESO refreshes, cert renewals, leader-elected operators, and backups
(VolSync and kopiur both need the API to launch movers). Hours of that are survivable. The
genuinely bad combination is CP down *and* a worker failing, because nothing reschedules.

## Why vault

- **It is already a hard dependency.** Garage S3 (VolSync `*-local`, CNPG, Thanos, etcd
  backups) and every NFS / tns-csi mount die with vault today. The Longhorn-backed apps live
  on brokkr and survive a vault outage — and with the CP on vault they *still* keep running,
  just frozen. So the added blast radius is "API-dependent things stop while vault is down",
  and most of those have already stopped because their storage is gone.
- **Boot order improves.** vault boots → storage up → VM autostarts → API. Today the CP can
  come up before the storage it depends on.
- **It is free and oversized for the job.** TrueNAS 25.10.7, 24 threads, 503 GB RAM (~66 GB
  available with ARC holding the rest; ARC shrinks to make room). libvirt is active and
  nested KVM is on.
- **The Pis become proven fallback hardware.** If vault dies outright, restore the etcd
  snapshot onto a Pi. They ran the control plane for a year; they are fine for days.

## Measured: etcd will be fine on the `apps` pool

etcd is fsync-bound and wants **p99 `fdatasync` < 10 ms**. The VM disk goes on `apps`, a
mirror of two Samsung 870 EVO 2TB — consumer SATA SSDs, **no power-loss protection**, no
SLOG, `sync=standard`. etcd's own recommended benchmark, run on a dataset on that pool
(2026-09-22):

```
sudo fio --name=etcd-bench --directory=/mnt/apps/etcd-bench \
  --rw=write --ioengine=sync --fdatasync=1 --size=22m --bs=2300

fdatasync  p50 2.77 ms   p95 3.65 ms   p99 6.00 ms   p99.9 22.2 ms   max 46.4 ms
```

**Pass**, and essentially the same as the Pis today (2.66–2.90 ms mean). The ~2.7 ms floor
also suggests the drives honor FLUSH rather than lying about it (a lying drive returns in
tens of microseconds) — an inference, not a vendor claim. Treat these as a best case: the
VM adds virtio and a zvol on top. The p99.9 tail is the thing to watch, via
`etcd_disk_wal_fsync_duration_seconds`, which is already scraped.

### Do not do these

- **`sync=disabled` on the zvol.** It makes fsync lie. One power loss on vault then corrupts
  etcd. If latency ever needs fixing, fix the device, not the promise.
- **Host etcd on blockbuster's special vdev** (by raising `special_small_blocks`). It
  couples the CP to the 72.8 TB HDD pool — a suspended blockbuster takes the API down — and
  it eats the special vdev's headroom (112 GB partition holding *all* of blockbuster's
  metadata: 10.6 GB used, 47% fragmented; overflow spills metadata onto the HDDs). It may not
  help anyway: sync latency is decided by where the ZIL lands, and with no SLOG it is not
  established that it would land on the special class.
- **Spend the free space on sdb/sdd.** Those are Intel D3-S4510 480 GB (enterprise, PLP).
  Only the 112 GB special-vdev partition is used on each; the ~335 GB beyond it is
  **deliberate over-provisioning slack for longevity**, not spare capacity.

**The fallback if the tail degrades in production:** a small (~16 GB) mirrored **SLOG on
`apps`** carved from that slack — PLP-backed sync writes, ~320 GB of slack left intact, and
the one ZFS change that can be undone live (`zpool remove apps <log-vdev>`). Its real cost
is write volume, not space: every sync write on `apps` would pass through it, not only
etcd's. Re-run the fio above before and after. Not needed today.

## The CPU: Ivy Bridge, and what that means

vault is a dual **Intel Xeon E5-2620 v2** (Ivy Bridge-EP, 2013). It supports x86-64-v2
but **not x86-64-v3** — no AVX2, BMI or FMA. Talos and the control-plane components are
built for baseline amd64 and are fine. The risk is **DaemonSets that tolerate the
control-plane taint**: any image compiled for v3 exits on the VM with an illegal
instruction (SIGILL, exit code 132). Phase 3 gates on every DaemonSet pod on the VM
reaching `Running`.

Per-core it is slower than a modern x86 box but comfortably faster than the Pis' Cortex
cores. Four vCPUs is ample for a CP.

---

## Phase 0 — backups first (its own PR, before any VM exists)

**This is the precondition, not a nice-to-have.** Today's etcd snapshots
(`kubernetes/apps/kube-system/talos-backup`) go to the Garage `talos` bucket — *on vault*.
With the CP on vault, the backup would share fate with the thing it backs up.

1. **Hourly snapshots.** `schedule: "10 0/6 * * *"` → hourly.
   **⚠️ Retention is count-based**: the prune container keeps the 120 most recent snapshots,
   which is 30 days at 4/day. Changing only the schedule silently shrinks the window to
   **5 days**. Decide the retention deliberately and change the count in the same commit —
   e.g. keep 168 (7 days hourly) locally and let the offsite copy below hold the long tail.
   Snapshots are ~260 MB; Garage dedupes near-identical ones heavily.
2. **An off-vault copy.**
   - **pinas (hourly, local, fast restore)** once it is set up.
   - **Daily offsite** to **R2** or **Storj** (Derek is both a Storj customer and a node
     operator). Wasabi is cancelled — do not use it.
   - Until the pinas is ready, send the hourly copy to R2 so there is an off-box copy from day
     one. A second `talos-backup` CronJob with its own ExternalSecret pointing at the other
     S3 endpoint is the smallest change; the existing job's prune logic can be reused as-is.
3. **Prove a restore is possible** before relying on it: pull the newest snapshot from the
   off-vault location and check it with `etcdutl snapshot status <file>`.

## Phase 1 — pre-flight

```bash
# etcd healthy, alarms clear, one leader, indices in sync
talosctl -n 10.0.10.31,10.0.10.32,10.0.10.33 etcd status
talosctl -n 10.0.10.31,10.0.10.32,10.0.10.33 etcd alarm list    # must be empty

# A fresh snapshot, taken by hand, stored OFF vault
talosctl -n <healthiest-pi> etcd snapshot ./etcd-pre-vault-vm.snap

# Who is leader, and who holds the VIP? Both matter for removal order (Phase 4).
talosctl -n 10.0.10.31,10.0.10.32,10.0.10.33 etcd status        # LEADER column
talosctl -n 10.0.10.31,10.0.10.32,10.0.10.33 get addresses | grep 10.0.10.30
```

**Power-cycle the Pis first**, one at a time, so they are at their healthiest for the
membership changes. A graceful reboot has been observed to no-op on these boards; use
`talosctl reboot --mode powercycle` (or PoE) and verify with uptime / boot ID, not with
`Ready` — a flapping node reports a stale `Ready`.

Pick the VM's hostname and a free address on VLAN 10, and create a **DHCP reservation**
in UniFi against the VM's MAC (the Pis are DHCP with reservations too). In use today:
`.30` (VIP), `.31–.34` (Pis), `.38–.40` (brokkr). The steps below write `<cp-vm>` and
`<cp-ip>` for these.

## Phase 2 — build the VM on vault

**Talos image.** Build an amd64 schematic at the Image Factory: the same `extraKernelArgs`
as the Pi and brokkr schematics minus the IOMMU pair, with these extensions:

- `siderolabs/qemu-guest-agent` — lets TrueNAS shut the VM down cleanly when vault
  shuts down
- `siderolabs/tailscale` — every node runs the tailscale extension service
- `siderolabs/util-linux-tools`

No microcode extension: that is the host's job for a VM. Download the **v1.13.9** metal ISO
for that schematic.

**TrueNAS → Virtualization → add VM:**

| setting | value | why |
| --- | --- | --- |
| boot | UEFI | Talos supports it; matches the rest of the fleet |
| vCPUs | 4, CPU mode **host-passthrough** | host-passthrough exposes the real CPU flags; CP needs ~2 cores |
| memory | **32 GiB**, fixed (no ballooning) | apiserver is 3.1–4.4 GB and grows with object count; 32 gives years of headroom |
| disk | **40 GiB zvol on `apps`**, virtio, `sync=standard` | see "Measured" above; never `sync=disabled` |
| NIC | virtio, attached to **`br1`** | br1 carries 10.0.10.10/.11 on VLAN 10 untagged (MTU 9000); note the MAC for the DHCP reservation |
| autostart | **on** | this is what makes the boot order storage → API |
| NUMA | optional: pin to one socket | dual socket; keeps memory access local |

## Phase 3 — join the VM as a fourth control plane

In `talos/talconfig.yaml`, add the node alongside the Pis:

```yaml
  - hostname: "<cp-vm>"
    ipAddress: "<cp-ip>"
    installDisk: "/dev/vda"
    controlPlane: true
    networkInterfaces:
      - deviceSelector:
          hardwareAddr: "<vm-mac>"
        dhcp: true
        mtu: 1500
        vip:
          ip: "10.0.10.30"
    schematic: &vmschematic
      customization:
        extraKernelArgs: [...]   # as above
        systemExtensions:
          officialExtensions:
            - siderolabs/qemu-guest-agent
            - siderolabs/tailscale
            - siderolabs/util-linux-tools
    extensionServices: *extensionServices
```

Leave `allowSchedulingOnMasters: false`. Unlike the brokkr plan, this node should stay
**CP-only**: isolation from workload memory pressure is the property being bought.

```bash
just talos gen-config            # never hand-edit talos/clusterconfig/
# boot the VM from the ISO into maintenance mode, then:
talosctl apply-config --insecure --nodes <cp-ip> \
  --file talos/clusterconfig/home-kubernetes-<cp-vm>.yaml
```

**Gate — do not continue until all of these hold:**

```bash
talosctl -n <cp-ip> etcd status                          # member present, raft index caught up
talosctl -n 10.0.10.31,10.0.10.32,10.0.10.33,<cp-ip> etcd status   # 4 members, indices converged
talosctl -n <cp-ip> etcd alarm list                      # empty
kubectl get node <cp-vm>                                 # Ready, control-plane role
kubectl get pods -A -o wide --field-selector spec.nodeName=<cp-vm>
#   every DaemonSet pod Running. Any CrashLoopBackOff with exit code 132 (SIGILL)
#   is an x86-64-v3 image — see "The CPU" above. Resolve before removing any Pi.
```

At four members quorum is three, so one can be lost. Do not linger here.

## Phase 4 — remove the Pis, 4 → 3 → 2 → 1

**Order:** the Pis that are neither leader nor VIP holder first; the leader / VIP holder
last. Move leadership explicitly rather than letting a removal force an election.

```bash
# for each Pi in turn:
talosctl -n <pi-ip> etcd forfeit-leadership      # if it is the leader
talosctl -n <pi-ip> etcd leave                   # graceful self-removal
talosctl -n <cp-ip> etcd status                  # confirm membership shrank, indices in sync
```

**The fragile moment is two members** — between the second and third removal. Quorum on
two needs both, so either failing breaks the cluster. Do the last two removals back to back,
with both nodes verified healthy immediately before. With one member left, the VIP
necessarily lives on the VM.

Then, for each Pi: set `controlPlane: false` in `talconfig.yaml`, give it the same
`node.kubernetes.io/low-power` taint and patches as jormungandr4, regenerate, and
`talosctl reset` + `apply-config` it as a **worker**. It holds no data, so the reset is
cheap. The Pis keep driving the rack LCD via `rackpanel-agent`.

## Phase 5 — follow-through (easy to miss)

Things that hard-code the Pi control plane and will quietly break:

| where | what | change |
| --- | --- | --- |
| `kubernetes/apps/kube-system/etcd-defrag/app/cronjob.yaml` | three per-Pi containers (`defrag-jormungandr1..3`, IPs `.31–.33`) | one container against `<cp-ip>`. Note defrag blocks the *only* member while it runs; at ~360 MB that is seconds, and it already runs Sunday 03:30 |
| `kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml` `kubeEtcd.endpoints` | `10.0.10.31–33` | `<cp-ip>`. Without this, etcd metrics — including the fsync histogram this plan relies on — go dark |
| `docs/runbooks/vault-nas-maintenance.md` | vault restart procedure | **a vault restart is now an API outage.** Shutdown: quiesce workloads, then the VM (guest agent / ACPI). Startup: the VM autostarts after the pools import |
| `.serena/memories/core.md` | node table lists jormungandr1–3 as control-plane | update the topology |
| `talosconfig` | endpoints | regenerated by `just talos gen-config`; confirm `talosctl` talks to `<cp-ip>` |

Unchanged, because the VM holds the VIP: `talconfig.yaml` `endpoint`,
`additionalApiServerCertSans`, and the Tailscale exit-node route to `10.0.10.30/32`.

**tuppr upgrades** now take the API down for the CP reboot. That is expected; plan
upgrades for a quiet window rather than letting them surprise anyone.

## If vault dies

1. Pick a Pi (they are workers now). Set it back to `controlPlane: true` in `talconfig.yaml`,
   regenerate, `talosctl reset` it, and apply the CP config.
2. `talosctl -n <pi-ip> bootstrap --recover-from=./<snapshot>.snap`, using the newest
   off-vault snapshot (pinas, else the offsite copy).
3. It is the Pi problem again, on a clock: days, not weeks. Rebuild the VM when vault
   returns and migrate back the same way as Phase 3–4.

**Up to one hour of cluster state is lost** at hourly snapshots. In a GitOps cluster most of
it regenerates. The sharp edge is **Longhorn**: volume metadata lives in etcd CRs, so a volume
created inside the loss window comes back with replicas on disk and no CR describing them.
Likewise PV bindings. Hourly snapshots are what keep that window small.

## Rollback points

| stage | if it fails | recovery |
| --- | --- | --- |
| Phase 0–2 | anything | nothing in the cluster has changed; delete the VM |
| Phase 3, VM won't join or sync | config, network, disk | `talosctl -n <cp-ip> etcd leave` (or `remove-member` from a Pi), delete the VM. The three Pis are untouched |
| Phase 3, SIGILL DaemonSets | x86-64-v3 images | fix or pin those images first, or abandon: remove the VM from etcd as above |
| Phase 4, after the first Pi leaves | etcd trouble at 3 members | re-add a Pi as CP (reset + apply CP config); restore from the Phase 1 snapshot only if the cluster is damaged |
| Phase 4, at 2 members | a member fails | quorum lost — restore from the Phase 1 snapshot onto the VM with `bootstrap --recover-from` |

## Honest cost

No hardware. About an afternoon: a VM, one config regeneration, four etcd membership
changes, and three Pi resets that hold no data. The risk is concentrated in two places:
the two-member window in Phase 4, and discovering a v3-only DaemonSet in Phase 3 —
which is why Phase 3 gates on it before anything is removed.
