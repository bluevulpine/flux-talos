# Cluster IPv6 (dual-stack) — feasibility and staged plan

Status: **not started / planning only.** Written 2026-07-31 after establishing the
facts below, so a future session starts from evidence instead of rediscovery.

## Should we even do this?

Be honest about the payoff before spending the risk budget: **public IPv6 is
already solved at the edge.**

- Pangolin VPS (Traefik) terminates IPv6 and speaks IPv4 inward to the Newt
  connector — every service migrated to the `external-pangolin` gateway is
  already reachable over IPv6 (see `pangolin-vps-setup.md`).
- Cloudflare does the same for everything still on the `external` (tunnel) door.

So in-cluster dual-stack buys only:

1. **IPv6 for LAN clients → internal services** (the `internal` gateway currently
   publishes A records only).
2. **IPv6 pod egress** (reaching v6-only upstreams from inside the cluster).
3. Removing a latent gap: the cluster can't currently *test* anything over IPv6 —
   which already caused a misdiagnosis (`curl -6` from a pod fails regardless of
   the remote end, because the cluster has no v6 egress).

That is a real but modest return against a control-plane-level change. **Do not
treat this as cleanup work.** Do it when there is a driver, and preferably fold
step 3 into a planned cluster rebuild.

## Current state (verified 2026-07-31)

### The prerequisite is already met — nodes have global IPv6

This was initially mis-assessed. `kubectl get nodes` reports IPv4-only
`InternalIP` **because the cluster is SingleStack**, not because the hosts lack
IPv6. `talosctl get addresses` shows otherwise:

```
jormungandr1  end0      2604:8500:b20b:1:e65f:1ff:fefe:9f06/64
brokkr01      bond0     2604:8500:b20b:1:8647:9ff:fe33:6c1f/64
              bond0.30  2604:8500:b20b:2:8647:9ff:fe33:6c1f/64
              bond0.50  2604:8500:b20b:4:8647:9ff:fe33:6c1f/64
```

Every node has SLAAC GUAs with working `::/0` routes. The home ISP is **Garden
Valley**, and UniFi is handing out a **distinct /64 per VLAN** (`b20b:1` native,
`b20b:2` VLAN 30, `b20b:4` VLAN 50) — implying a delegated prefix of at least a
/60, i.e. **spare /64s may be available to route to pods** rather than being
forced onto ULA + NAT66. Confirm the actual PD size in UniFi before planning
addressing (see Open questions).

### Cluster is single-stack IPv4

| Thing | Value | Where |
| --- | --- | --- |
| Pod CIDR | `10.69.0.0/16` | `talos/talconfig.yaml` → `clusterPodNets` |
| Service CIDR | `10.96.0.0/16` | `talos/talconfig.yaml` → `clusterSvcNets` |
| `kubernetes` Service | `ipFamilies: [IPv4]`, `ipFamilyPolicy: SingleStack` | live |
| CNI | Cilium (Talos `cniConfig.name: none`) | |

### Cilium

- `ipam.mode: kubernetes` — pod CIDRs come from kube-controller-manager, so pod
  IPv6 follows automatically once the control plane hands out v6 CIDRs.
- `routingMode: native` + `autoDirectNodeRoutes: true`,
  `ipv4NativeRoutingCIDR: 10.69.0.0/16` — a v6 equivalent is required.
- `kubeProxyReplacement: true`, `bpf.masquerade: true`.

### LoadBalancers are BGP, not L2 — this is the good news

`l2announcements.enabled: true` is set in the HelmRelease but **no
CiliumL2AnnouncementPolicy exists**, so it is unused. LB addresses are advertised
by **BGP**:

- `CiliumBGPClusterConfig/l3-bgp-cluster-config`: local ASN **65512**, peer
  **unifi** ASN **65510** at **10.0.10.1**
- `CiliumLoadBalancerIPPool/pool`: `172.16.8.0/24`
- `CiliumBGPAdvertisement` + `CiliumBGPPeerConfig` in
  `kubernetes/apps/kube-system/cilium/app/networking.yaml`

This matters: **L2 announcements are ARP-based and IPv4-only**, so an L2-based
cluster would have needed a BGP migration first. This one does not — the v6 path
is "add a v6 pool + advertisement + address family", not "re-architect the LB".

## Staged plan

Each stage is independently useful and independently revertable. Do not start a
later stage until the previous one is verified.

### Stage 0 — decide pod/service addressing (design, no changes)

- **Pods:** prefer a **routed GUA /64** from the delegated prefix if UniFi can
  hand one out that is *not* used for a VLAN — gives real end-to-end IPv6 with no
  NAT. Otherwise **ULA `fd00::/48`** + `enableIPv6Masquerade` (works, but NAT66).
- **Services:** ULA is fine and preferable (cluster-internal only), e.g.
  `fd00:96::/108`. Note Kubernetes requires the IPv6 service CIDR to be **/108 or
  larger prefix length** (it rejects huge service CIDRs).
- Keep **IPv4 as the primary family**. It cannot be changed later without a
  rebuild, and every existing Service stays IPv4-only regardless.

### Stage 1 — Talos control plane (the risky one)

Append the v6 CIDRs in `talos/talconfig.yaml`:

```yaml
clusterPodNets:
  - "10.69.0.0/16"
  - "<pod-v6>/64"      # or fd00::/48
clusterSvcNets:
  - "10.96.0.0/16"
  - "fd00:96::/108"
```

Then `just talos gen-config` and apply. This changes kube-apiserver
(`--service-cluster-ip-range`), kube-controller-manager (`--cluster-cidr`,
`--node-cidr-mask-size-ipv6`) and kubelet.

**Risk:** Kubernetes documents converting an existing single-stack cluster to
dual-stack, but (a) existing Services remain single-stack forever, (b) the
primary family is immutable, and (c) on Talos these values are bootstrap-time
inputs — changing them on a live cluster is not a well-trodden path.
**Recommendation: do this as part of a planned rebuild**, not in place, unless
you accept the possibility of a rebuild anyway.

### Stage 2 — Cilium

```yaml
ipv6:
  enabled: true
ipv6NativeRoutingCIDR: "<pod-v6-cidr>"
enableIPv6Masquerade: true   # only if pods use ULA
```

`ipam.mode: kubernetes` means pod v6 CIDRs arrive from Stage 1 automatically.
Verify `autoDirectNodeRoutes` installs v6 node routes; if node-to-node v6 routing
misbehaves, that is the first thing to check.

### Stage 3 — LoadBalancer / BGP

- Add a v6 block to `CiliumLoadBalancerIPPool` (a routed GUA /64, or ULA if the
  router will carry it).
- Add/extend `CiliumBGPAdvertisement` for the v6 family and ensure the
  `CiliumBGPPeerConfig` negotiates the **IPv6 unicast AFI/SAFI** — either over the
  existing IPv4 session (multiprotocol BGP) or via a second peer over v6.
- UniFi (ASN 65510) must accept and route the advertised v6 prefix. Check the
  router config alongside `kubernetes/apps/kube-system/cilium/app/morpheus.bgpd`.

### Stage 4 — Gateways and DNS

- Give the `internal` Gateway a v6 address from the pool; Services become
  `ipFamilyPolicy: PreferDualStack` where wanted (**new** Services only — existing
  ones stay IPv4).
- `external-dns-unifi` then needs to publish **AAAA** for internal hostnames.
- The `external-pangolin` gateway needs nothing: it is ClusterIP-only and reached
  by Newt over IPv4; public IPv6 is already handled by the VPS entry hosts.

## Verification

```bash
# nodes actually have v6 (already true today)
talosctl -n <node> get addresses | grep -v fe80 | grep 2604:

# after Stage 1: node gets a v6 podCIDR
kubectl get node <node> -o jsonpath='{.spec.podCIDRs}'

# after Stage 2: pod egress over v6 (fails today — no v6 in cluster)
kubectl run v6 --rm -i --restart=Never --image=curlimages/curl -- \
  curl -6 -sS -o /dev/null -w '%{http_code}\n' https://ifconfig.co

# after Stage 3: LB service gets a v6 address and the router learns it
kubectl get svc -A -o wide | grep -i ':'
```

## Rollback

Stages 2–4 are ordinary GitOps reverts. **Stage 1 is not** — reverting
pod/service CIDRs on a running cluster is at least as disruptive as applying
them. Treat Stage 1 as the point of no return and have a rebuild path ready.

## Open questions

1. **What prefix size does Garden Valley actually delegate** (UniFi → Internet →
   IPv6 → prefix delegation)? A /56 or /60 means a spare routed /64 for pods; a
   single /64 forces ULA + NAT66.
2. Will UniFi's BGP accept an advertised v6 prefix from ASN 65512, and does it
   need a separate v6 peering session?
3. Convert in place or fold into a rebuild? (Leaning rebuild — see Stage 1.)
4. Is there a concrete driver beyond completeness? If not, this stays parked.

## Related

- `docs/runbooks/pangolin-vps-setup.md` — the edge already does IPv6 today
- `kubernetes/apps/kube-system/cilium/app/networking.yaml` — BGP + LB pool
- `talos/talconfig.yaml` — `clusterPodNets` / `clusterSvcNets`
