# Static NAS name: storage that survives a Morpheus outage

The cluster reaches the NAS as `vault.funb.us`, and the only DNS server for that name is
Morpheus (10.0.10.1), which answers with TTL 0. Node↔NAS traffic is same-VLAN (10.0.10.0/24)
and never touches Morpheus, but the **name lookup** does: while Morpheus is down, mounts that
already exist keep working and any pod that starts or moves fails to mount with
`mount.nfs: Failed to resolve server vault.funb.us`. That happened for ~5 minutes on
2026-11-15 21:31–21:36Z (Morpheus shut down by mistake); CoreDNS's `serve_stale` cache hid
part of it.

So the name is pinned in two places, one per resolution path:

| Who mounts | Volumes | Resolves through | Fix |
|---|---|---|---|
| kubelet, on the host | 22 static NFS PVs (`spec.nfs.server`) | node `/etc/hosts`, then Talos hostDNS → Morpheus | `talos/patches/all/14-static-hosts.yaml` (`extraHostEntries`) |
| CSI node plugins in pods (`ClusterFirstWithHostNet`) | `tns-csi-nfs`, `tns-csi-nvmeof`, `vault-nfs`, and the tns-csi controller's API | CoreDNS → Talos hostDNS → Morpheus | `hosts` block in `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml` |

**Why both:** Talos hostDNS (127.0.0.53 / 169.254.116.108) does **not** answer from
`extraHostEntries`; it forwards. CoreDNS forwards to it, so a Talos-only fix never reaches
the CSI path. tns-csi v0.18.0 runs `nvme connect -a <hostname>` inside its plugin container
(`pkg/driver/node_nvmeof_device.go`), so NVMe-oF is on the CoreDNS path too.

**If the NAS IP changes:** update Morpheus's local DNS record, the Talos patch, and the CoreDNS
block together. `chronos.funb.us` (GPS NTP) is pinned in the Talos patch only; that entry is
untested.

## Test (no real DNS outage needed)

Use a name Morpheus does not know, so "unresolvable" is the cache-cold equivalent of Morpheus
being down. Mount a harmless share read-only, pinned to one node.

1. **Negative control.** Apply a pod with an inline `nfs` volume (`server: nas-dnstest.funb.us`,
   `path: /mnt/blockbuster/media`, `readOnly: true`) and a static `nfs.csi.k8s.io` PV + PVC with
   the same server, both `nodeName:` the test node. Both must fail with
   `Failed to resolve server nas-dnstest.funb.us`. The same inline pod with `server: 10.0.10.10`
   must succeed (rules out exports/permissions).
2. **Talos entry.** `talosctl -n <test node> patch mc --mode=no-reboot` with
   `machine.network.extraHostEntries` for the fake name. The inline pod now mounts; the CSI pod
   still fails. Confirm hostDNS ignores it: `nslookup nas-dnstest.funb.us 169.254.116.108` from a
   hostNetwork pod returns no address.
3. **CoreDNS entry.** `flux suspend hr coredns -n kube-system`, add
   `hosts { 10.0.10.10 nas-dnstest.funb.us; fallthrough }` to the `.` block of the `coredns`
   ConfigMap, wait for `Reloading complete` on both pods (~80 s), and query each CoreDNS pod IP
   directly. The CSI pod now mounts.
4. **Revert.** Patch the saved Corefile back and diff it, **then** `flux resume` (resuming alone
   may not rewrite the ConfigMap when the chart values did not change). Remove the Talos entry
   with a strategic patch: `machine: {network: {extraHostEntries: [{ip: ..., $patch: delete}]}}`
   (JSON6902 `remove` is rejected on multi-document configs), then `machine: {network:
   {$patch: delete}}` if that leaves an empty `network: {}`. `topf --nodes-filter '^<node>$'
   apply --dry-run` must report `no changes to apply`. Delete the test namespace and PV.

**Checking the live entries** (after rollout, or after a Talos or CoreDNS upgrade): the steps
above use a fake name because the real one also resolves upstream, so a plain lookup cannot
tell the static answer from Morpheus's. Check where each answer comes from instead:

- Talos: `talosctl -n <node> read /etc/hosts` lists `vault.funb.us` and `chronos.funb.us`.
- CoreDNS: `kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'` shows the
  `hosts` block in the `.` server block, and `nslookup vault.funb.us <pod IP>` against each
  CoreDNS pod returns `10.0.10.10` with TTL 3600 (the `hosts` plugin's default) rather than
  Morpheus's 0 (`dig +noall +answer`).
