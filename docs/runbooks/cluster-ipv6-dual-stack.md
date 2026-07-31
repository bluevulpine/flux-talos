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
Valley**, which delegates a **/48** (`2604:8500:b20b::/48`). UniFi currently
carves a /64 per VLAN out of it (`b20b:1` native, `b20b:2` VLAN 30, `b20b:4`
VLAN 50), leaving **65,000+ unused /64s**.

That is the single most important fact here: there is no addressing constraint.
Pods and LoadBalancers can each get **routed global /64s** — no ULA, no NAT66,
no prefix-squeezing. This removes the ugliest part of most homelab IPv6 designs.

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

### Stage 0 — addressing (design, no changes)

With a /48 in hand, carve dedicated ranges well clear of the VLAN /64s already in
use (`b20b:1`, `:2`, `:4`). Suggested layout:

| Purpose | Prefix | Notes |
| --- | --- | --- |
| Pods | `2604:8500:b20b:1000::/56` | 256 × /64, one per node (k8s default `node-cidr-mask-size-ipv6` is /64) |
| Services | `fd00:96::/108` | ULA — never routed off-cluster; k8s caps the v6 service CIDR at /108 |
| LoadBalancers | `2604:8500:b20b:ff00::/64` | advertised via BGP (Stage 3) |

- **Pods get routed GUAs, not ULA.** No `enableIPv6Masquerade` needed, no NAT66,
  and pod egress uses a real address. The pod CIDR must be *shorter* than the
  per-node mask so each node gets its own /64 — hence /56 for the cluster.
- **Services stay ULA.** They are cluster-internal by definition; there is no
  reason to spend routable space, and ULA makes it obvious they are not external.
- Keep **IPv4 as the primary family**. It cannot be changed later without a
  rebuild, and every existing Service stays IPv4-only regardless.

> **Security: routable now means reachable.** Today every LoadBalancer lives on
> `172.16.8.0/24` (RFC1918) and every pod on `10.69.0.0/16` — the internet cannot
> reach them even if a firewall rule is wrong, because the addresses are not
> routable. GUA pods and GUA LoadBalancers **are** globally routable, so the
> firewall becomes the only thing standing between the internet and every
> internal service. Before Stage 3, confirm UniFi's WAN policy **denies inbound
> IPv6 to the pod and LB prefixes by default**, and only allow what is
> deliberately published. This is the one genuinely new risk dual-stack
> introduces, and it does not exist in the IPv4 setup.

### Stage 1 — Talos control plane (the risky one)

Append the v6 CIDRs in `talos/talconfig.yaml`:

```yaml
clusterPodNets:
  - "10.69.0.0/16"
  - "2604:8500:b20b:1000::/56"
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
ipv6NativeRoutingCIDR: "2604:8500:b20b:1000::/56"
# enableIPv6Masquerade: NOT needed -- pods have routed GUAs, so no NAT66.
```

`ipam.mode: kubernetes` means pod v6 CIDRs arrive from Stage 1 automatically.
Verify `autoDirectNodeRoutes` installs v6 node routes; if node-to-node v6 routing
misbehaves, that is the first thing to check.

### Stage 3 — LoadBalancer / BGP

- Add `2604:8500:b20b:ff00::/64` as a v6 block on `CiliumLoadBalancerIPPool`.
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

1. ~~What prefix size does Garden Valley delegate?~~ **Answered: a /48**
   (`2604:8500:b20b::/48`). Addressing is a non-issue; see Stage 0.
2. Is the /48 **stable**, or can it change on a lease/CPE swap? If it can rotate,
   the pod/LB prefixes rotate with it — which is disruptive in a way ULA is not.
   Worth confirming with Garden Valley before committing pods to GUAs.
3. Will UniFi's BGP accept an advertised v6 prefix from ASN 65512, and does it
   need a separate v6 peering session or just the v6 AFI on the existing one?
4. Does UniFi's WAN firewall default-deny inbound IPv6 to the pod/LB prefixes?
   (See the security note in Stage 0 — this is the new risk.)
5. Convert in place or fold into a rebuild? (Leaning rebuild — see Stage 1.)
6. Is there a concrete driver beyond completeness? If not, this stays parked.

## Related

- `docs/runbooks/pangolin-vps-setup.md` — the edge already does IPv6 today
- `kubernetes/apps/kube-system/cilium/app/networking.yaml` — BGP + LB pool
- `talos/talconfig.yaml` — `clusterPodNets` / `clusterSvcNets`
