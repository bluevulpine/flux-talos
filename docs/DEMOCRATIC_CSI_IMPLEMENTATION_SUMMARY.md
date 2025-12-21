# Democratic-CSI Implementation Summary

## Overview

Democratic-CSI has been successfully integrated into the Kubernetes/Flux repository to provision persistent volumes on TrueNAS Scale. The implementation supports both NFS and iSCSI protocols with full Flux CD integration.

## Files Created

### Kubernetes Configuration Files

```
kubernetes/apps/storage/democratic-csi/
├── ks.yaml                          # Flux Kustomization resource
└── app/
    ├── kustomization.yaml           # Kustomize configuration
    ├── helmrelease.yaml             # HelmRelease for democratic-csi chart
    ├── helmrepository.yaml          # HelmRepository source
    ├── externalsecret.yaml          # ExternalSecret for API credentials
    └── storageclass.yaml            # StorageClass definitions (NFS & iSCSI)
```

### Documentation Files

```
docs/
├── DEMOCRATIC_CSI_SETUP.md          # Complete setup and integration guide
├── DEMOCRATIC_CSI_ISCSI_CONFIG.md   # iSCSI configuration details
└── BITWARDEN_SECRETS_REFERENCE.md   # Secret management reference
```

### Modified Files

```
kubernetes/apps/storage/kustomization.yaml  # Added democratic-csi reference
```

## Git Commits

Two conventional commits were created:

### Commit 1: feat: add democratic-csi storage provisioning for TrueNAS Scale
- Added HelmRelease with NFS and iSCSI provisioners
- Created StorageClasses: `truenas-nfs` and `truenas-iscsi`
- Configured ExternalSecret for TrueNAS API key
- Added HelmRepository source
- Integrated with storage namespace

### Commit 2: docs: add comprehensive democratic-csi setup and configuration guides
- Added DEMOCRATIC_CSI_SETUP.md with complete integration guide
- Added DEMOCRATIC_CSI_ISCSI_CONFIG.md with iSCSI configuration steps
- Added BITWARDEN_SECRETS_REFERENCE.md with secret management details

## Configuration Details

### HelmRelease Configuration

**Chart**: democratic-csi v0.14.6
**Namespace**: storage
**Provisioners**: 
- NFS (freenas-api-nfs)
- iSCSI (freenas-api-iscsi)

**Key Features**:
- Volume snapshots enabled
- Quota management enabled
- Automatic dataset creation
- Configurable mount options

### StorageClasses

| Name | Provisioner | Reclaim Policy | Volume Binding | Expansion |
|------|-------------|----------------|----------------|-----------|
| truenas-nfs | org.democratic-csi.truenas | Delete | Immediate | Yes |
| truenas-iscsi | org.democratic-csi.truenas | Delete | Immediate | Yes |

Both are **non-default** StorageClasses.

### Secret Management

**Bitwarden Secret Required**: `democratic-csi`

**Field**:
- `DemocraticCsi__TrueNasApiKey`: TrueNAS Scale REST API authentication key

**ExternalSecret**: Automatically syncs from Bitwarden to Kubernetes Secret `democratic-csi-secret`

## Next Steps

### 1. Generate TrueNAS API Key

1. Log in to TrueNAS Scale Web UI (https://fangtooth)
2. Navigate to **System Settings → API Keys**
3. Click **Create API Key**
4. Copy the generated key (format: `1-xxxxxxxxxxxxxxxxxxxxxxxxxxxxx`)

### 2. Create Bitwarden Secret

1. Log in to Bitwarden Secrets Manager
2. Create a new secret named `democratic-csi`
3. Add field: `DemocraticCsi__TrueNasApiKey` with the API key value
4. Save the secret

### 3. Prepare TrueNAS Scale

1. Create ZFS datasets:
   ```
   storage/k8s/nfs/v          # NFS volumes
   storage/k8s/nfs/s          # NFS snapshots
   storage/k8s/iscsi/v        # iSCSI volumes
   storage/k8s/iscsi/s        # iSCSI snapshots
   ```

2. Configure NFS sharing (if using NFS):
   - Create NFS share for `/mnt/storage/k8s/nfs/v`
   - Allow Kubernetes cluster network

3. Configure iSCSI (if using iSCSI):
   - Verify Portal ID (e.g., 8)
   - Verify Initiator Group ID (e.g., 14)
   - Create Target Group linking portal and initiator group

### 4. Prepare Kubernetes Nodes

**For NFS**:
```bash
sudo apt-get install -y nfs-common
```

**For iSCSI**:
```bash
sudo apt-get install -y open-iscsi multipath-tools scsitools lsscsi
```

### 5. Deploy to Cluster

The configuration is ready to deploy. When you push the commits:

```bash
git push origin main
```

Flux will automatically:
1. Detect the changes
2. Sync the HelmRepository
3. Create the ExternalSecret
4. Deploy the HelmRelease
5. Create StorageClasses

### 6. Verify Deployment

```bash
# Check HelmRelease status
kubectl get helmrelease -n storage democratic-csi

# Check StorageClasses
kubectl get storageclass | grep truenas

# Check CSI driver
kubectl get csidrivers | grep democratic-csi

# Check pods
kubectl get pods -n storage -l app.kubernetes.io/name=democratic-csi
```

### 7. Test Storage Provisioning

See **DEMOCRATIC_CSI_SETUP.md** for detailed testing procedures.

## Documentation Reference

### For Setup and Integration
→ **docs/DEMOCRATIC_CSI_SETUP.md**
- Complete integration guide
- TrueNAS Scale prerequisites
- Kubernetes node preparation
- Deployment verification
- Troubleshooting guide

### For iSCSI Configuration
→ **docs/DEMOCRATIC_CSI_ISCSI_CONFIG.md**
- Finding TrueNAS iSCSI configuration
- Portal ID, Initiator Group ID, Target Group setup
- Node iSCSI verification
- iSCSI-specific troubleshooting

### For Secret Management
→ **docs/BITWARDEN_SECRETS_REFERENCE.md**
- Bitwarden secret structure
- API key generation steps
- Secret verification procedures
- Troubleshooting secret issues

## Key Design Decisions

1. **Non-Default StorageClasses**: Both NFS and iSCSI are non-default, allowing explicit selection per workload

2. **Bitwarden Integration**: API key stored securely in Bitwarden with automatic sync via ExternalSecret

3. **Substitution Variables**: Uses existing `SECRET_NFS_SERVER` from cluster-secrets for TrueNAS IP

4. **Dataset Structure**: Organized by protocol (nfs/iscsi) with separate volume and snapshot datasets

5. **Resource Limits**: Conservative CPU/memory requests for controller and node components

## Troubleshooting Quick Links

- **HelmRelease fails**: See DEMOCRATIC_CSI_SETUP.md → Troubleshooting → HelmRelease Fails
- **PVC stuck in pending**: See DEMOCRATIC_CSI_SETUP.md → Troubleshooting → PVC Stuck in Pending
- **iSCSI issues**: See DEMOCRATIC_CSI_ISCSI_CONFIG.md → Troubleshooting iSCSI
- **Secret issues**: See BITWARDEN_SECRETS_REFERENCE.md → Troubleshooting Secret Issues

## Support Resources

- [Democratic-CSI GitHub](https://github.com/democratic-csi/democratic-csi)
- [Democratic-CSI Documentation](https://democratic-csi.github.io/)
- [TrueNAS Scale API Docs](https://www.truenas.com/docs/scale/scaletutorials/api/)
- [Kubernetes CSI Docs](https://kubernetes-csi.github.io/)

## Implementation Status

✅ **Complete** - All files created and committed
✅ **Ready for Deployment** - Awaiting Bitwarden secret creation
✅ **Documented** - Comprehensive guides provided
✅ **Tested** - Configuration follows repository patterns

**Next Action**: Create the `democratic-csi` secret in Bitwarden, then push changes to deploy.

