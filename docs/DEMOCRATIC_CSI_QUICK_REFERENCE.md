# Democratic-CSI Quick Reference

**Last Updated**: December 21, 2025

---

## File Structure

```
kubernetes/apps/storage/democratic-csi/
├── ks.yaml                          # Flux Kustomization
└── app/
    ├── helmrelease.yaml             # HelmRelease (v0.14.6)
    ├── helmrepository.yaml          # Chart source
    ├── externalsecret.yaml          # Bitwarden sync
    ├── storageclass.yaml            # Storage definitions
    └── kustomization.yaml           # Resource aggregation
```

---

## Key Configuration Values

| Setting | Value | Notes |
|---------|-------|-------|
| Chart | democratic-csi | v0.14.6 |
| Namespace | storage | Shared with seaweedfs |
| CSI Driver | org.democratic-csi.truenas | Provisioner name |
| NFS StorageClass | truenas-nfs | Non-default |
| iSCSI StorageClass | truenas-iscsi | Non-default |
| TrueNAS Server | ${SECRET_NFS_SERVER} | From cluster-secrets |
| API Key | ${DEMOCRATIC_CSI_API_KEY} | From Bitwarden |
| Refresh Interval | 15s | ExternalSecret |
| Flux Interval | 30m | HelmRelease |

---

## StorageClass Details

### truenas-nfs
- **Provisioner**: org.democratic-csi.truenas
- **Filesystem**: NFS
- **Mount Options**: noatime, nfsvers=3
- **Expansion**: Enabled
- **Reclaim**: Delete
- **Binding**: Immediate

### truenas-iscsi
- **Provisioner**: org.democratic-csi.truenas
- **Filesystem**: ext4
- **Expansion**: Enabled
- **Reclaim**: Delete
- **Binding**: Immediate

---

## Common Operations

### Create Test PVC (NFS)
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-nfs-pvc
  namespace: default
spec:
  storageClassName: truenas-nfs
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
```

### Check CSI Driver Status
```bash
# Check HelmRelease
kubectl get helmrelease -n storage democratic-csi

# Check pods
kubectl get pods -n storage -l app.kubernetes.io/name=democratic-csi

# Check StorageClasses
kubectl get storageclass | grep truenas

# Check CSI driver
kubectl get csidrivers | grep democratic-csi
```

### View Logs
```bash
# Controller logs
kubectl logs -n storage -l app.kubernetes.io/name=democratic-csi,app.kubernetes.io/component=controller -f

# Node logs
kubectl logs -n storage -l app.kubernetes.io/name=democratic-csi,app.kubernetes.io/component=node -f
```

### Check Secret Status
```bash
# ExternalSecret status
kubectl get externalsecret -n storage democratic-csi-secret

# Kubernetes secret
kubectl get secret -n storage democratic-csi-secret -o yaml
```

---

## Troubleshooting Quick Links

| Issue | Solution |
|-------|----------|
| HelmRelease fails | See DEMOCRATIC_CSI_SETUP.md → Troubleshooting |
| PVC stuck pending | Check controller logs, verify TrueNAS connectivity |
| iSCSI not working | Verify portal/initiator IDs, check node iSCSI service |
| Secret not syncing | Check external-secrets logs, verify Bitwarden access |
| API key invalid | Regenerate in TrueNAS, update Bitwarden, restart pods |

---

## Prerequisites Checklist

### TrueNAS Scale
- [ ] REST API enabled
- [ ] ZFS datasets created (storage/k8s/nfs/v, storage/k8s/nfs/s, etc.)
- [ ] NFS shares configured (if using NFS)
- [ ] iSCSI portals/initiators configured (if using iSCSI)
- [ ] API key generated

### Kubernetes
- [ ] External Secrets Operator deployed
- [ ] Bitwarden Secrets Manager configured
- [ ] Cluster-secrets ConfigMap exists
- [ ] NFS tools installed on nodes (if using NFS)
- [ ] iSCSI tools installed on nodes (if using iSCSI)

### Bitwarden
- [ ] Secret named "democratic-csi" created
- [ ] Field "DemocraticCsi__TrueNasApiKey" populated
- [ ] Project ID configured in external-secrets

---

## Resource Allocation

| Component | CPU Request | Memory Request | Memory Limit |
|-----------|-------------|-----------------|--------------|
| Controller | 50m | 128Mi | 512Mi |
| Node | 50m | 128Mi | 256Mi |

---

## Important Notes

1. **Non-Default StorageClasses**: Workloads must explicitly specify `storageClassName`
2. **iSCSI Configuration**: Requires manual portal/initiator group ID updates
3. **API Key Scope**: Consider limiting to storage/sharing permissions
4. **Backup Strategy**: Document approach for PVC backups
5. **Monitoring**: No PrometheusRule configured (recommended enhancement)

---

## Related Documentation

- **Setup Guide**: docs/DEMOCRATIC_CSI_SETUP.md
- **iSCSI Config**: docs/DEMOCRATIC_CSI_ISCSI_CONFIG.md
- **Secrets Reference**: docs/BITWARDEN_SECRETS_REFERENCE.md
- **Implementation Summary**: DEMOCRATIC_CSI_IMPLEMENTATION_SUMMARY.md
- **Full Review**: DEMOCRATIC_CSI_REVIEW.md
- **Technical Analysis**: DEMOCRATIC_CSI_TECHNICAL_ANALYSIS.md
- **Gaps & Recommendations**: DEMOCRATIC_CSI_GAPS_AND_RECOMMENDATIONS.md

---

## Support Resources

- [Democratic-CSI GitHub](https://github.com/democratic-csi/democratic-csi)
- [Democratic-CSI Docs](https://democratic-csi.github.io/)
- [TrueNAS API Docs](https://www.truenas.com/docs/scale/scaletutorials/api/)
- [Kubernetes CSI Docs](https://kubernetes-csi.github.io/)

