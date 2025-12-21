# Democratic-CSI Integration with TrueNAS Scale

This document provides comprehensive guidance for setting up and managing democratic-csi in this Kubernetes cluster with TrueNAS Scale as the storage backend.

## Overview

Democratic-CSI is a CSI (Container Storage Interface) driver that enables Kubernetes to provision persistent volumes directly from TrueNAS Scale using its REST API. This integration supports both NFS and iSCSI protocols.

### Current Configuration
- **TrueNAS Server**: fangtooth (via `SECRET_NFS_SERVER`)
- **Connection Protocol**: HTTPS (port 443)
- **Provisioners**: NFS and iSCSI
- **Storage Classes**: `truenas-nfs` and `truenas-iscsi` (both non-default)

## Prerequisites

### Cluster Requirements
- Kubernetes cluster with Flux CD deployed
- External Secrets Operator configured with Bitwarden Secrets Manager
- For iSCSI: All nodes must have `open-iscsi` and `multipath-tools` installed

### TrueNAS Scale Requirements
- TrueNAS Scale instance accessible via HTTPS
- ZFS datasets created for volume storage
- API key generated for authentication

## Step 1: Prepare TrueNAS Scale

### 1.1 Generate API Key

1. Log in to TrueNAS Scale Web UI
2. Navigate to **System Settings → API Keys**
3. Click **Create API Key**
4. Set appropriate permissions (recommend full access for initial setup)
5. Copy the generated API key (format: `1-xxxxxxxxxxxxxxxxxxxxxxxxxxxxx`)
6. Store this securely - you'll need it for Bitwarden

### 1.2 Create ZFS Datasets

Democratic-CSI requires ZFS datasets for volume storage. Create the following structure:

**For NFS Provisioning:**
```
storage/k8s/nfs/v          # Volume datasets
storage/k8s/nfs/s          # Snapshot datasets
```

**For iSCSI Provisioning:**
```
storage/k8s/iscsi/v        # Volume datasets
storage/k8s/iscsi/s        # Snapshot datasets
```

**Optional: Multi-tier Storage**

For different storage tiers, create additional datasets:
```
# SSD pool (fast storage)
ssd-pool/k8s/nfs/v
ssd-pool/k8s/iscsi/v

# HDD pool (bulk storage)
hdd-pool/k8s/nfs/v
hdd-pool/k8s/iscsi/v
```

### 1.3 Configure NFS Sharing (if using NFS)

1. Navigate to **Sharing → NFS**
2. Create NFS shares for each dataset:
   - Path: `/mnt/storage/k8s/nfs/v`
   - Allowed networks: Your Kubernetes cluster network
   - Map root user: root
   - Map root group: root

### 1.4 Configure iSCSI (if using iSCSI)

**Portal Configuration:**
1. Navigate to **Sharing → iSCSI → Portals**
2. Note the Portal ID (e.g., 8) - you'll need this
3. Verify the portal is listening on the correct IP

**Initiator Group Configuration:**
1. Navigate to **Sharing → iSCSI → Initiator Groups**
2. Create or note the Initiator Group ID (e.g., 14)
3. Add your Kubernetes nodes' iSCSI IQNs

**Target Group Configuration:**
1. Navigate to **Sharing → iSCSI → Target Groups**
2. Create a target group linking:
   - Portal Group: Your portal ID
   - Initiator Group: Your initiator group ID
   - Authentication: None (or configure as needed)

## Step 2: Configure Bitwarden Secrets

Add the following secret to Bitwarden Secrets Manager under the project used by this cluster:

### Secret Name: `democratic-csi`

**Fields:**
```
DemocraticCsi__TrueNasApiKey: <your-api-key-from-step-1.1>
```

**Example:**
```
DemocraticCsi__TrueNasApiKey: 1-IvCjJtMLUhEUseYourOwnrK1HKRIFWd1UFK5ay52HogLUrwC2UxjHNQWODCRGhe
```

## Step 3: Configure Kubernetes Nodes

### For NFS Support
```bash
# On all Kubernetes nodes
sudo apt-get install -y nfs-common
```

### For iSCSI Support
```bash
# On all Kubernetes nodes
sudo apt-get install -y open-iscsi multipath-tools scsitools lsscsi

# Configure multipath
sudo tee /etc/multipath.conf > /dev/null <<EOF
defaults {
    user_friendly_names yes
    find_multipaths yes
}
EOF

# Restart multipath
sudo systemctl restart multipathd
```

## Step 4: Deploy Democratic-CSI

The democratic-csi HelmRelease is configured in `kubernetes/apps/storage/democratic-csi/`.

### Deployment
```bash
# Flux will automatically deploy when you push changes
git add -A
git commit -m "feat: add democratic-csi storage provisioning"
git push

# Monitor deployment
kubectl get pods -n storage -l app.kubernetes.io/name=democratic-csi -w
```

### Verify Installation
```bash
# Check HelmRelease status
kubectl get helmrelease -n storage democratic-csi

# Check StorageClasses
kubectl get storageclass | grep truenas

# Check CSI driver
kubectl get csidrivers | grep democratic-csi
```

## Step 5: Test Storage Provisioning

### Test NFS StorageClass
```bash
cat <<EOF | kubectl apply -f -
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

# Verify PVC is bound
kubectl get pvc test-nfs-pvc
```

### Test iSCSI StorageClass
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-iscsi-pvc
  namespace: default
spec:
  storageClassName: truenas-iscsi
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

# Verify PVC is bound
kubectl get pvc test-iscsi-pvc
```

### Cleanup Test PVCs
```bash
kubectl delete pvc test-nfs-pvc test-iscsi-pvc
```

## Troubleshooting

### HelmRelease Fails to Deploy

**Check HelmRelease status:**
```bash
kubectl describe helmrelease -n storage democratic-csi
```

**Common issues:**
- API key not set in Bitwarden
- ExternalSecret not syncing (check external-secrets logs)
- HelmRepository not accessible

### PVC Stuck in Pending

**Check controller logs:**
```bash
kubectl logs -n storage -l app.kubernetes.io/name=democratic-csi,app.kubernetes.io/component=controller -f
```

**Common issues:**
- ZFS datasets don't exist
- API key has insufficient permissions
- TrueNAS server unreachable

### iSCSI Volumes Not Mounting

**Check node logs:**
```bash
kubectl logs -n storage -l app.kubernetes.io/name=democratic-csi,app.kubernetes.io/component=node -f
```

**Verify iSCSI on nodes:**
```bash
# On a Kubernetes node
sudo iscsiadm -m discovery -t sendtargets -p <truenas-ip>:3260
sudo iscsiadm -m node -L all
```

### API Key Expired or Invalid

**Regenerate API key:**
1. Follow Step 1.1 to generate a new API key
2. Update the secret in Bitwarden
3. Force ExternalSecret refresh:
   ```bash
   kubectl annotate externalsecret -n storage democratic-csi-secret \
     force-sync="$(date +%s)" --overwrite
   ```
4. Restart democratic-csi pods:
   ```bash
   kubectl rollout restart deployment -n storage -l app.kubernetes.io/name=democratic-csi
   ```

## Advanced Configuration

### Multi-Tier Storage

To support different storage tiers, create additional StorageClasses by modifying the HelmRelease values:

```yaml
storageClasses:
  - name: truenas-nfs-ssd
    parameters:
      # Points to ssd-pool/k8s/nfs/v
  - name: truenas-nfs-hdd
    parameters:
      # Points to hdd-pool/k8s/nfs/v
```

Then update the driver config to support multiple instances or use dataset parameters.

### Snapshot Support

Democratic-CSI supports volume snapshots. To use snapshots:

```bash
# Create a snapshot
kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: my-snapshot
spec:
  volumeSnapshotClassName: truenas-nfs
  source:
    persistentVolumeClaimName: my-pvc
EOF
```

## Recovery and Restart

### Restart Democratic-CSI

```bash
# Restart all democratic-csi pods
kubectl rollout restart deployment -n storage -l app.kubernetes.io/name=democratic-csi
kubectl rollout restart daemonset -n storage -l app.kubernetes.io/name=democratic-csi
```

### Reset Democratic-CSI

If you need to completely reset democratic-csi:

```bash
# Suspend the HelmRelease
kubectl patch helmrelease -n storage democratic-csi --type merge -p '{"spec":{"suspend":true}}'

# Delete the HelmRelease (this will delete all resources)
kubectl delete helmrelease -n storage democratic-csi

# Delete any orphaned PVs/PVCs if needed
kubectl delete pv <pv-name>

# Resume by pushing changes or manually unsuspending
kubectl patch helmrelease -n storage democratic-csi --type merge -p '{"spec":{"suspend":false}}'
```

## References

- [Democratic-CSI GitHub](https://github.com/democratic-csi/democratic-csi)
- [Democratic-CSI Documentation](https://democratic-csi.github.io/)
- [TrueNAS Scale API Documentation](https://www.truenas.com/docs/scale/scaletutorials/api/)
- [Kubernetes CSI Documentation](https://kubernetes-csi.github.io/)

