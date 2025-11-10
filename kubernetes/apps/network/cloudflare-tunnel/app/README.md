# Cloudflare Tunnel Configuration

This directory contains the Kubernetes manifests for deploying Cloudflare Tunnel (cloudflared) with both HTTP/2 and QUIC transport protocols.

## Overview

Cloudflare Tunnel provides secure access to internal services without exposing them directly to the internet. This setup includes:

- **HTTP/2 Transport**: Stable, production-ready tunnel using HTTP/2 protocol
- **QUIC Transport**: Modern HTTP/3 tunnel with post-quantum cryptography support

## Components

### Core Resources
- `helmrelease.yaml` - HTTP/2 tunnel deployment (production)
- `helmrelease-quic.yaml` - QUIC tunnel deployment (testing/future)
- `externalsecret.yaml` - Tunnel credentials from Bitwarden
- `dnsendpoint.yaml` - DNS records for tunnel endpoints
- `ocirepository.yaml` - Helm chart source
- `configs/config.yaml` - Tunnel ingress configuration

### Configuration Files
- `kustomization.yaml` - Kustomize configuration with ConfigMap generation

## QUIC Protocol Support

### Problem
QUIC (HTTP/3) uses UDP port 443 for transport, which can be blocked by stateful firewalls that don't properly handle UDP connection tracking.

### Symptoms
When QUIC is blocked, you'll see errors like:
```
Failed to dial a quic connection error="failed to dial to edge with quic: timeout: handshake did not complete in time"
```

### Solution: UniFi Firewall Rule

**Required UniFi Network Application Configuration:**

#### Navigation Path:
```
UniFi Network Application → Settings → Security → Firewall & Security → Traffic & Firewall Rules
```

#### Firewall Rule Configuration:
- **Name**: `Enable QUIC egress` (or similar)
- **Description**: `Allow QUIC/HTTP3 traffic from Kubernetes cluster`
- **Rule Applied**: `Before Predefined Rules`
- **Action**: `Accept`
- **Rule Index/Priority**: `9999` (high priority)

#### Traffic Matching:
- **Source**: 
  - **Type**: `Network/VLAN`
  - **Network**: `10 Servers Trusted` (Kubernetes network - 10.0.10.0/24)
- **Destination**: `Internet` or `Any`
- **Protocol**: `UDP`
- **Port**: `443`
- **Direction**: `LAN Out` (egress from LAN to WAN)

#### Advanced Settings:
- **Connection State**: `New` (disable stateful tracking for QUIC)
- **Logging**: `Enabled` (to monitor QUIC traffic)
- **IPv4/IPv6**: `Both`
- **Schedule**: `Always`

### Why This Works
1. **Explicit UDP 443 Rule**: Bypasses default firewall policies that may not handle QUIC properly
2. **Disabled Stateful Tracking**: Prevents UDP session tracking issues that interfere with QUIC handshakes
3. **High Priority**: Ensures the rule is processed before general "Allow All" rules

### Verification
After creating the rule, verify QUIC connectivity:
```bash
kubectl logs cloudflare-tunnel-quic-xxx -n network --since=2m | grep -E "(registered|handshake.*complete)"
```

Successful QUIC connections will show:
```
Registered tunnel connection connIndex=1 connection=xxx protocol=quic
```

## Performance Comparison

Based on testing, QUIC provides:
- **3.3% faster** average response times compared to HTTP/2
- **Post-quantum cryptography** for enhanced security
- **Better congestion control** and connection migration capabilities
- **0-RTT connection resumption** for subsequent connections

## Deployment Strategy

1. **Production**: HTTP/2 tunnel (stable, reliable)
2. **Testing**: QUIC tunnel (currently disabled due to backend connectivity issues)
3. **Future**: Gradual migration to QUIC as it matures

### Current Status
- **HTTP/2 Tunnel**: ✅ Active and stable (2 replicas)
- **QUIC Tunnel**: ❌ Disabled (0 replicas) - backend connectivity issues under investigation

## Troubleshooting

### QUIC Connection Issues
1. Verify UniFi firewall rule is active and properly configured
2. Check for ISP-level QUIC filtering
3. Ensure health check ports are correctly configured (8080)
4. Monitor tunnel logs for handshake timeouts

### Health Check Failures
Ensure the health check port in the HelmRelease matches the metrics port:
```yaml
TUNNEL_METRICS: 0.0.0.0:8080
# ... and in probes:
port: &port 8080
```

## Security Considerations

- Tunnel credentials are stored in Bitwarden and accessed via ExternalSecrets
- QUIC tunnel includes post-quantum cryptography support
- Both tunnels use read-only root filesystems and drop all capabilities
- Non-root user execution (UID 1000)

## Network Architecture

```
Internet → Cloudflare Edge → Tunnel → Kubernetes Cluster
                                   ↓
                            Cilium Gateway (kube-system)
                                   ↓
                            Backend Services
```

### Tunnel Configuration
The tunnel routes traffic based on hostname:
- `hello.${SECRET_DOMAIN}` → hello_world service
- `${SECRET_DOMAIN}` → Cilium Gateway (HTTPS)
- `*.${SECRET_DOMAIN}` → Cilium Gateway (HTTPS)

## Common Issues and Solutions

### Issue: QUIC Handshake Timeouts
**Symptoms:**
```
timeout: handshake did not complete in time
failed to dial to edge with quic
```

**Solution:**
1. Create the UniFi firewall rule as documented above
2. Verify rule is active: Check UniFi logs for UDP 443 traffic
3. Test with curl: `curl -v https://hello.${SECRET_DOMAIN}`

### Issue: Health Check Failures
**Symptoms:**
```
Pod status: CrashLoopBackOff
Readiness probe failed
```

**Solution:**
Ensure health check port matches metrics port in both HelmReleases.

### Issue: DNS Resolution
**Symptoms:**
```
no such host
DNS resolution failed
```

**Solution:**
Verify DNSEndpoint is created and external-dns is processing it:
```bash
kubectl get dnsendpoint -n network
kubectl logs -n network deploy/external-dns-cloudflare
```

## Monitoring and Observability

### Metrics
Both tunnels expose metrics on port 8080:
- Connection status
- Request counts
- Latency metrics
- Protocol-specific metrics (QUIC vs HTTP/2)

### Logs
Monitor tunnel status:
```bash
# HTTP/2 tunnel
kubectl logs -n network deploy/cloudflare-tunnel -f

# QUIC tunnel
kubectl logs -n network deploy/cloudflare-tunnel-quic -f
```

### ServiceMonitor
Prometheus metrics are automatically scraped via ServiceMonitor configuration.

## QUIC vs Internal Infrastructure

### Protocol Translation Architecture
```
Internet → Cloudflare Edge → QUIC Tunnel → cloudflared Pod → HTTP/2 → Cilium Gateway → Backend
```

### Key Technical Points

#### **QUIC Support NOT Required in Cilium/Envoy**
- **cloudflared handles protocol translation**: QUIC terminates at the cloudflared pod
- **Internal communication uses HTTP/2**: As configured via `http2Origin: true`
- **Cilium Gateway API**: Currently only supports HTTP/1.1, HTTP/2, HTTPS
- **Envoy Proxy**: Has HTTP/3 support but not exposed through Cilium's Gateway API

#### **Current Cilium HTTP/3 Status**
- **Not Supported**: [GitHub Issue #28497](https://github.com/cilium/cilium/issues/28497) tracks HTTP/3 support
- **Workaround**: cloudflared performs protocol translation (QUIC → HTTP/2)
- **Future**: End-to-end QUIC may be possible when Cilium adds HTTP/3 Gateway API support

#### **QUIC Troubleshooting Focus Areas**
Since internal infrastructure doesn't need QUIC support, issues are typically:
1. **Backend Connectivity**: cloudflared → Cilium Gateway communication
2. **TLS Certificate Validation**: `originServerName` must match Gateway certificate
3. **Resource Conflicts**: Multiple tunnel deployments competing for resources
4. **Health Check Configuration**: Port conflicts between HTTP/2 and QUIC deployments

#### **Testing Backend Connectivity**
```bash
# Test direct connection from cloudflared pod to Cilium Gateway
kubectl exec -n network deploy/cloudflare-tunnel-quic -- curl -v -k \
  https://cilium-gateway-external.kube-system.svc.cluster.local:443

# Verify TLS certificate matches originServerName
kubectl exec -n network deploy/cloudflare-tunnel-quic -- openssl s_client \
  -connect cilium-gateway-external.kube-system.svc.cluster.local:443 \
  -servername external.${SECRET_DOMAIN}
```

## References

- [Cloudflare Tunnel Documentation](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)
- [QUIC Protocol Specification](https://datatracker.ietf.org/doc/html/rfc9000)
- [UniFi Network Application](https://ui.com/consoles)
- [Post-Quantum Cryptography](https://blog.cloudflare.com/post-quantum-for-all/)
- [Cilium HTTP/3 Support Issue](https://github.com/cilium/cilium/issues/28497)
