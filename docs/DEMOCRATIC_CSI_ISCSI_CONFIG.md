# Democratic-CSI iSCSI Configuration Guide

This guide provides detailed instructions for configuring iSCSI support in democratic-csi with TrueNAS Scale.

## Overview

iSCSI (Internet Small Computer Systems Interface) provides block-level storage access over the network. Democratic-CSI can provision iSCSI volumes directly from TrueNAS Scale.

## Prerequisites

### TrueNAS Scale Setup
- iSCSI service enabled
- Portal configured
- Initiator group created
- Target group configured

### Kubernetes Nodes
All nodes must have iSCSI tools installed:

```bash
# Debian/Ubuntu
sudo apt-get install -y open-iscsi multipath-tools scsitools lsscsi

# RHEL/CentOS
sudo dnf install -y lsscsi iscsi-initiator-utils sg3_utils device-mapper-multipath
```

## Step 1: Find TrueNAS iSCSI Configuration

### 1.1 Find Portal ID

**Via Web UI:**
1. Navigate to **Sharing → iSCSI → Portals**
2. Note the **ID** column value (e.g., 8)

**Via CLI:**
```bash
# SSH into TrueNAS Scale
ssh root@fangtooth

# Query portals
cli -c "sharing iscsi portal query"
```

**Example Output:**
```
+----+-----+---------+--------+----------------------+---------------------+
| id | tag | comment | listen | discovery_authmethod | discovery_authgroup |
+----+-----+---------+--------+----------------------+---------------------+
| 8  | 1   | iscsi   | <list> | NONE                 | <null>              |
+----+-----+---------+--------+----------------------+---------------------+
```

**Your Portal ID: `8`**

### 1.2 Find Initiator Group ID

**Via Web UI:**
1. Navigate to **Sharing → iSCSI → Initiator Groups**
2. Note the **ID** column value (e.g., 14)
3. Verify it contains your Kubernetes nodes' iSCSI IQNs

**Via CLI:**
```bash
cli -c "sharing iscsi initiator query"
```

**Example Output:**
```
+----+-----+-----+-----+
| id | tag | ini | cmt |
+----+-----+-----+-----+
| 14 | 1   | ALL | k8s |
+----+-----+-----+-----+
```

**Your Initiator Group ID: `14`**

### 1.3 Find Target Group Configuration

**Via Web UI:**
1. Navigate to **Sharing → iSCSI → Target Groups**
2. Note the configuration:
   - **Portal Group**: Links to your portal ID (e.g., 8)
   - **Initiator Group**: Links to your initiator group ID (e.g., 14)
   - **Auth Type**: Usually "None" for internal networks

**Via CLI:**
```bash
cli -c "sharing iscsi targetgroup query"
```

**Example Output:**
```
+----+-----+-----+-----+-----+-----+
| id | tag | tpg | ipg | iag | ath |
+----+-----+-----+-----+-----+-----+
| 1  | 1   | 8   | 14  | 0   | 0   |
+----+-----+-----+-----+-----+-----+
```

**Your Target Group Portal Group: `8`**
**Your Target Group Initiator Group: `14`**

## Step 2: Update HelmRelease Configuration

The iSCSI configuration is in `kubernetes/apps/storage/democratic-csi/app/helmrelease.yaml`.

### Current Placeholder Values

The HelmRelease currently has placeholder values that need to be replaced:

```yaml
iscsi:
  targetPortal: "10.10.20.100:3260"  # Replace with fangtooth IP
  targetPortals: []
  interface:
  namePrefix: csi-
  nameSuffix: "-clustera"
  targetGroups:
    - targetGroupPortalGroup: 8      # REPLACE with your portal group ID
      targetGroupInitiatorGroup: 14  # REPLACE with your initiator group ID
      targetGroupAuthType: None
      targetGroupAuthGroup:
  extentInsecureTpc: true
  extentXenCompat: false
  extentDisablePhysicalBlocksize: true
  extentBlocksize: 512
  extentRpm: "SSD"
  extentAvailThreshold: 0
```

### Update Steps

1. **Get your TrueNAS IP** (from `SECRET_NFS_SERVER`):
   ```bash
   # This should be fangtooth
   echo $SECRET_NFS_SERVER
   ```

2. **Update the HelmRelease** with your values:
   ```bash
   # Edit the file
   vim kubernetes/apps/storage/democratic-csi/app/helmrelease.yaml
   ```

3. **Replace these values:**
   - `targetPortal`: Use your TrueNAS IP (fangtooth)
   - `targetGroupPortalGroup`: Your portal ID (from Step 1.1)
   - `targetGroupInitiatorGroup`: Your initiator group ID (from Step 1.2)

## Step 3: Verify iSCSI on Kubernetes Nodes

### 3.1 Check iSCSI Service

```bash
# On each Kubernetes node
sudo systemctl status iscsid
sudo systemctl status open-iscsi

# Should show "active (running)"
```

### 3.2 Discover iSCSI Targets

```bash
# On a Kubernetes node
sudo iscsiadm -m discovery -t sendtargets -p fangtooth:3260

# Should list available targets
```

### 3.3 Check Multipath Configuration

```bash
# On a Kubernetes node
sudo multipath -ll

# Should show configured paths
```

## Step 4: Test iSCSI Provisioning

### Create Test PVC

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
      storage: 5Gi
EOF
```

### Monitor Creation

```bash
# Watch PVC status
kubectl get pvc test-iscsi-pvc -w

# Check democratic-csi controller logs
kubectl logs -n storage -l app.kubernetes.io/name=democratic-csi,app.kubernetes.io/component=controller -f

# Check TrueNAS for created extent
# Navigate to Sharing → iSCSI → Extents
```

### Verify on TrueNAS

```bash
# SSH into TrueNAS
ssh root@fangtooth

# List iSCSI extents
cli -c "sharing iscsi extent query"

# Should show your new extent
```

### Cleanup

```bash
kubectl delete pvc test-iscsi-pvc
```

## Troubleshooting iSCSI

### PVC Stuck in Pending

**Check controller logs:**
```bash
kubectl logs -n storage -l app.kubernetes.io/name=democratic-csi,app.kubernetes.io/component=controller -f | grep -i iscsi
```

**Common issues:**
- Portal ID incorrect
- Initiator group ID incorrect
- iSCSI service not running on nodes
- Firewall blocking port 3260

### Volume Not Mounting

**Check node logs:**
```bash
kubectl logs -n storage -l app.kubernetes.io/name=democratic-csi,app.kubernetes.io/component=node -f
```

**Verify iSCSI discovery:**
```bash
# On the node where pod is scheduled
sudo iscsiadm -m discovery -t sendtargets -p fangtooth:3260
sudo iscsiadm -m node -L all
```

### Multipath Issues

```bash
# Check multipath status
sudo multipath -ll

# Reload multipath configuration
sudo systemctl restart multipathd

# Verify configuration
sudo cat /etc/multipath.conf
```

## Reference Configuration

### Complete iSCSI Section (Example)

```yaml
iscsi:
  targetPortal: "10.10.20.100:3260"
  targetPortals: []
  interface:
  namePrefix: csi-
  nameSuffix: "-clustera"
  targetGroups:
    - targetGroupPortalGroup: 8
      targetGroupInitiatorGroup: 14
      targetGroupAuthType: None
      targetGroupAuthGroup:
  extentInsecureTpc: true
  extentXenCompat: false
  extentDisablePhysicalBlocksize: true
  extentBlocksize: 512
  extentRpm: "SSD"
  extentAvailThreshold: 0
```

## References

- [Democratic-CSI iSCSI Documentation](https://github.com/democratic-csi/democratic-csi/blob/master/examples/freenas-api-iscsi.yaml)
- [TrueNAS iSCSI Configuration](https://www.truenas.com/docs/scale/scaletutorials/sharing/iscsi/)
- [Linux iSCSI Initiator](https://github.com/open-iscsi/open-iscsi)
- [Device Mapper Multipath](https://linux.die.net/man/8/multipath)

