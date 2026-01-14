# qBittorrent VPN Options

This document covers VPN options for qBittorrent torrenting with kill switch protection.

## Current Setup: Gluetun Sidecar

The current configuration uses **Gluetun** as a sidecar container with Mullvad WireGuard.

**Pros:**
- Built-in kill switch via iptables/nftables rules
- Mature, well-tested solution
- Supports port forwarding (provider-dependent)
- Easy configuration via environment variables

**Cons:**
- Requires active Mullvad subscription (~$5/month)
- Mullvad credentials stored in secrets

**Files:**
- `app/helmrelease.yaml` - Gluetun sidecar configuration
- `app/externalsecret.yaml` - Mullvad WireGuard credentials

---

## Alternative: Tailscale with Mullvad Exit Nodes

Tailscale offers Mullvad VPN servers as exit nodes for ~$5/month addon. This was evaluated as a potential Gluetun replacement.

### Kill Switch Testing Results (2026-01-14)

| Scenario | Result |
|----------|--------|
| Exit node explicitly removed (`tailscale set --exit-node=`) | ❌ **LEAK** - Traffic immediately falls back to direct |
| Exit node goes offline (unreachable) | ✅ **BLOCKED** - Traffic times out, no leak |
| Custom nftables kill switch | ⚠️ Conflicts with Tailscale's own nftables rules |

**Key Finding:** Tailscale has NO built-in kill switch when the exit node setting is cleared. However, if the exit node becomes unreachable while still configured, traffic is blocked (natural kill switch behavior).

### Technical Requirements for Tailscale on Talos/Kubernetes

1. **Kernel networking mode** - Userspace networking doesn't route traffic properly
2. **`/dev/net/tun` access** - Via smarter-device-manager:
   ```yaml
   resources:
     requests:
       smarter-devices/net_tun: "1"
     limits:
       smarter-devices/net_tun: "1"
   ```
3. **nftables mode** - Talos uses nftables, not iptables:
   ```yaml
   env:
     TS_DEBUG_FIREWALL_MODE: nftables
   ```
4. **NET_ADMIN capability** - Required for network configuration

### Proposed Tailscale Sidecar Configuration

Replace Gluetun with Tailscale sidecar and bind qBittorrent to `tailscale0` interface:

```yaml
containers:
  tailscale:
    image:
      repository: ghcr.io/tailscale/tailscale
      tag: latest
    envFrom:
      - secretRef:
          name: qbittorrent-secret  # Contains TS_AUTHKEY
    env:
      TS_USERSPACE: "false"
      TS_DEBUG_FIREWALL_MODE: nftables
      TS_HOSTNAME: qbittorrent
      TS_STATE_DIR: /var/lib/tailscale
      # Set Mullvad exit node
      TS_EXTRA_ARGS: --exit-node=us-lax-wg-101.mullvad.ts.net --exit-node-allow-lan-access=true
    securityContext:
      capabilities:
        add: ["NET_ADMIN"]
      runAsUser: 0
    resources:
      requests:
        smarter-devices/net_tun: "1"
      limits:
        smarter-devices/net_tun: "1"
```

qBittorrent config to bind to Tailscale interface (acts as kill switch):
```yaml
env:
  QBT_Preferences__Connection__Interface: tailscale0
```

### Secret Requirements

```yaml
# externalsecret.yaml
data:
  TS_AUTHKEY: "{{ .Tailscale__QbittorrentAuthKey }}"
```

Auth key requirements:
- Reusable (pod restarts)
- Pre-authorized
- Tagged (e.g., `tag:qbittorrent`)
- Tag must have Mullvad access in Tailscale ACLs

### Trade-offs vs Gluetun

| Aspect | Gluetun | Tailscale |
|--------|---------|-----------|
| Kill switch | ✅ Built-in iptables | ⚠️ Relies on interface binding |
| Port forwarding | ✅ Supported | ❌ Not with Mullvad |
| Setup complexity | Simple | Moderate (auth key, ACLs) |
| Cost | Mullvad sub | Tailscale + Mullvad addon |
| Integration | Standalone | Part of Tailscale network |

### Considerations

1. **No port forwarding** - Mullvad exit nodes don't support inbound connections, affecting seeding
2. **Interface binding reliability** - Depends on qBittorrent respecting the setting
3. **State persistence** - Should persist `/var/lib/tailscale` to avoid re-auth on restarts
4. **Init container** - Need to wait for `tailscale0` interface before qBittorrent starts

---

## Related Resources

- Tailscale operator config: `kubernetes/apps/network/tailscale/`
- ProxyClass with tun access: `kubernetes/apps/network/tailscale/resources/proxyclass.yaml`
- Tailscale Mullvad docs: https://tailscale.com/kb/1258/mullvad-exit-nodes

