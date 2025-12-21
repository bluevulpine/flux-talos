# Democratic-CSI Technical Analysis

**Date**: December 21, 2025

---

## Implementation Patterns

### 1. Flux Kustomization Pattern
The `ks.yaml` demonstrates proper Flux integration:
- **Dependency Management**: Correctly depends on `external-secrets-stores`
- **Substitution**: Uses `cluster-settings` and `cluster-secrets` ConfigMaps
- **Namespace Isolation**: Targets `storage` namespace
- **Wait Strategy**: Enabled for proper ordering

### 2. Secret Management Flow
```
Bitwarden Secret (democratic-csi)
    ↓
ExternalSecret (watches Bitwarden)
    ↓
Kubernetes Secret (democratic-csi-secret)
    ↓
HelmRelease (injects as DEMOCRATIC_CSI_API_KEY)
    ↓
Democratic-CSI Pod (uses API key)
```

### 3. Storage Class Strategy
Two StorageClasses provide protocol flexibility:
- **truenas-nfs**: NFS protocol, noatime + nfsvers=3
- **truenas-iscsi**: iSCSI protocol, ext4 filesystem

Both support volume expansion and snapshots.

---

## Configuration Analysis

### HelmRelease Values
**Driver Configuration**:
- Instance ID: `truenas-nfs` (for NFS provisioner)
- HTTP Connection: HTTPS to TrueNAS
- API Key: Injected from ExternalSecret
- ZFS Datasets: Organized by protocol

**Resource Allocation**:
- Controller: 50m CPU / 128Mi memory (requests)
- Node: 50m CPU / 128Mi memory (requests)
- Conservative approach suitable for home lab

**Volume Snapshot Classes**:
- Detached snapshots enabled for both protocols
- Allows snapshot independence from volumes

---

## Operational Considerations

### Deployment Prerequisites
1. **TrueNAS Scale**:
   - REST API enabled
   - ZFS datasets created
   - NFS/iSCSI services configured

2. **Kubernetes Cluster**:
   - External Secrets Operator deployed
   - Bitwarden Secrets Manager configured
   - Nodes with NFS/iSCSI tools

3. **Network**:
   - Cluster can reach TrueNAS HTTPS (port 443)
   - iSCSI nodes can reach TrueNAS (port 3260)

### Monitoring Gaps
- No PrometheusRule for CSI driver health
- No alerts for PVC provisioning failures
- No metrics collection configured

**Recommendation**: Add monitoring for:
- CSI driver pod restarts
- PVC provisioning latency
- TrueNAS API connectivity

---

## Security Assessment

### Strengths
✅ API key stored in Bitwarden (not in Git)  
✅ HTTPS communication with TrueNAS  
✅ ExternalSecret with 15-second refresh  
✅ No hardcoded credentials  

### Considerations
- API key has full TrueNAS access (consider scoping)
- No RBAC restrictions on StorageClass usage
- No network policies limiting CSI driver access

**Recommendation**: Document API key scope and consider RBAC policies.

---

## Comparison with csi-driver-nfs

The repository also includes `csi-driver-nfs` (separate NFS CSI driver).

**Democratic-CSI Advantages**:
- TrueNAS-native provisioning
- Automatic dataset creation
- Snapshot support
- iSCSI support

**csi-driver-nfs Advantages**:
- Simpler, lightweight
- No external API dependency
- Suitable for static NFS shares

**Use Case**: Democratic-CSI for dynamic provisioning, csi-driver-nfs for static shares.

---

## Integration with Existing Infrastructure

### Namespace Sharing
Storage namespace hosts:
- democratic-csi (CSI driver)
- seaweedfs (object storage)
- seaweedfs-jobs (batch operations)

**Consideration**: Shared namespace simplifies management but couples components.

### Volsync Integration
Recent commits show volsync using S3 (Garage) instead of NFS. Democratic-CSI can:
- Provision volumes for Kopia repository
- Support backup PVCs
- Enable snapshot-based backups

---

## Deployment Readiness Checklist

- [ ] Bitwarden secret created with API key
- [ ] TrueNAS ZFS datasets prepared
- [ ] NFS shares configured (if using NFS)
- [ ] iSCSI portals/initiators configured (if using iSCSI)
- [ ] Kubernetes nodes have NFS/iSCSI tools
- [ ] External Secrets Operator running
- [ ] Bitwarden Secrets Manager accessible
- [ ] Git changes committed and pushed
- [ ] Flux reconciliation verified
- [ ] Test PVC created and verified

---

## Potential Enhancements

1. **Multi-Pool Support**: Add StorageClasses for different TrueNAS pools
2. **Quota Management**: Implement PVC quota enforcement
3. **Backup Integration**: Automated snapshot-based backups
4. **Monitoring**: PrometheusRule for CSI driver health
5. **RBAC**: Namespace-specific StorageClass access
6. **Documentation**: Add runbook for common operations

---

## Conclusion

The implementation demonstrates **production-grade infrastructure-as-code practices**. The combination of proper Flux patterns, secure secret management, and comprehensive documentation makes this a model implementation for CSI driver deployment in Kubernetes.

**Technical Debt**: Minimal. Monitoring and RBAC are optional enhancements, not critical gaps.

