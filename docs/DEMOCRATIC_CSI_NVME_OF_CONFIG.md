# Democratic-CSI NVMe-over-Fabrics (NVMe-oF) Configuration Guide

**Last Updated**: December 22, 2025
**Status**: Experimental (TrueNAS Scale 24.10+ required)

---

## Overview

NVMe-over-Fabrics (NVMe-oF) provides high-performance block storage access over network fabrics, offering lower latency and higher throughput compared to iSCSI. Democratic-CSI supports NVMe-oF through the `zfs-generic-nvmeof` driver.

This guide provides instructions for configuring NVMe-oF with Democratic-CSI to replace iSCSI storage provisioning.

---

## Prerequisites

### TrueNAS Scale Requirements

1. **TrueNAS Scale 24.10 or later** (NVMe-oF support)
   - NVMe-oF was introduced in TrueNAS Scale 24.10
   - Verify with: `ssh root@truenas 'midclt call system.version'`

2. **Hardware Requirements**
   - NVMe devices attached to the TrueNAS system
   - Network infrastructure supporting RDMA or TCP transport

3. **NVMe-oF Service**
   - Enable NVMe-oF service in TrueNAS UI
   - Navigate to **Services → NVMe-oF** and start the service

### Kubernetes Node Requirements

1. **NVMe-oF Kernel Modules**
   ```bash
   # Load NVMe modules (persistent across reboots)
   cat <<EOF | sudo tee /etc/modules-load.d/nvme.conf
   nvme
   nvme-tcp
   nvme-fc
   nvme-rdma
   EOF

   # Load modules immediately
   sudo modprobe nvme
   sudo modprobe nvme-tcp
   ```

2. **NVMe CLI Tools (Optional but recommended)**
   ```bash
   sudo apt-get install -y nvme-cli  # Debian/Ubuntu
   sudo dnf install -y nvme-cli      # RHEL/CentOS
   ```

3. **Multipath Configuration**
   - NVMe has native multipath support
   - Configure via kernel parameter:
     ```bash
     # Check current setting
     cat /sys/module/nvme_core/parameters/multipath

     # Disable native multipath (use DM multipath instead)
     echo "options nvme_core multipath=N" | sudo tee /etc/modprobe.d/nvme.conf
     ```

---

## Step 1: Configure NVMe-oF on TrueNAS Scale

### 1.1 Create NVMe Targets

**Via Web UI:**
1. Navigate to **Sharing → Block (iSCSI/NVMe)**
2. Select **NVMe** tab
3. Click **Add** to create a new NVMe target
4. Configure:
   - **Name**: Unique identifier (e.g., `k8s-nvme-target`)
   - **Extents**: Add ZVOL extents (1GB minimum)
   - **Portals**: Configure TCP port (default: 4420)

**Via CLI:**
```bash
ssh root@truenas
midclt call sharing.nvme.target.create '{"name": "k8s-nvme-target"}'
midclt call sharing.nvme.extent.create '{"name": "k8s-extent-1", "type": "DISK", "disk": "/dev/zvol/pool/k8s/nvme1"}'
midclt call sharing.nvme.portal.create '{"name": "k8s-portal", "ip": "0.0.0.0", "port": 4420}'
midclt call sharing.nvme.target.extent.attach '{"target": "k8s-nvme-target", "extent": "k8s-extent-1"}'
midclt call sharing.nvme.target.portal.attach '{"target": "k8s-nvme-target", "portal": "k8s-portal"}'
```

### 1.2 Verify Configuration

```bash
# List NVMe targets
midclt call sharing.nvme.target.query

# List extents
midclt call sharing.nvme.extent.query

# List portals
midclt call sharing.nvme.portal.query
```

---

## Step 2: Update Democratic-CSI Configuration

### 2.1 Modify HelmRelease Values

Edit `kubernetes/apps/storage/democratic-csi/app/helmrelease.yaml`:

```yaml
driver:
  name: zfs-generic-nvmeof
  driverConfig:
    nvmeof:
      shareStrategy: nvmetCli
      nvmetCli:
        configIsImportedFilePath: /etc/nvmet/config.json
      shareStrategyNvmetCli:
        configIsImportedFilePath: /etc/nvmet/config.json
      shareStrategyNvmeadm:
        host: ${SECRET_NFS_SERVER}
        port: 4420
        insecureTpc: true
      shareStrategyNvmeadm:
        host: ${SECRET_NFS_SERVER}
        port: 4420
        insecureTpc: true
      shareStrategyNvmeofadm:
        host: ${SECRET_NFS_SERVER}
        port: 4420
      shareStrategyNvmeofadm:
        host: ${SECRET_NFS_SERVER}
        port: 4420
```

### 2.2 Create NVMe StorageClass

Create `kubernetes/apps/storage/democratic-csi/app/storageclass-nvme.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: truenas-nvme
provisioner: org.democratic-csi.truenas
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  type: nvmeof
  dataset: k8s/nvme
  compression: "lz4"
  sync: "standard"
```

---

## Step 3: Node Preparation for NVMe-oF

### 3.1 Install NVMe-oF Tools on Kubernetes Nodes

```bash
# For Talos Linux (add to machine config)
machine:
  install:
    extensions:
      - image: ghcr.io/siderolabs/nvme-tools:v0.1.0

# For traditional Linux distributions
sudo apt-get install -y nvme-cli linux-generic
```

### 3.2 Verify NVMe-oF Connectivity

```bash
# Discover NVMe targets
sudo nvme discover -t tcp -a ${SECRET_NFS_SERVER} -s 4420

# Connect to target
sudo nvme connect -t tcp -a ${SECRET_NFS_SERVER} -s 4420

# List connected devices
sudo nvme list
```

---

## Step 4: Test NVMe-oF Provisioning

### Create Test PVC

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-nvme-pvc
  namespace: default
spec:
  storageClassName: truenas-nvme
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
kubectl get pvc test-nvme-pvc -w

# Check democratic-csi controller logs
kubectl logs -n storage -l app.kubernetes.io/name=democratic-csi,app.kubernetes.io/component=controller -f | grep -i nvme

# Verify on TrueNAS
ssh root@truenas 'midclt call sharing.nvme.extent.query'
```

---

## Step 5: Migrate from iSCSI to NVMe-oF

### 5.1 Phase Migration Strategy

1. **Create new StorageClass** for NVMe-oF
2. **Deploy test workloads** with NVMe storage
3. **Benchmark performance** (compare with iSCSI)
4. **Gradually migrate** existing workloads
5. **Decommission iSCSI** after validation

### 5.2 Performance Comparison

| Metric               | iSCSI          | NVMe-oF (TCP)  |
|----------------------|----------------|----------------|
| Latency              | ~100-200μs     | ~50-100μs      |
| Throughput           | ~1Gbps         | ~6-8Gbps       |
| CPU Overhead         | Moderate       | Low            |
| Multipath Support    | Yes (DM)       | Native         |

---

## Troubleshooting

### PVC Stuck in Pending

**Check controller logs:**
```bash
kubectl logs -n storage -l app.kubernetes.io/name=democratic-csi,app.kubernetes.io/component=controller -f | grep -i nvme
```

**Common issues:**
- NVMe-oF service not running on TrueNAS
- Firewall blocking port 4420
- Incorrect target configuration
- Missing NVMe kernel modules on nodes

### Volume Not Mounting

**Check node logs:**
```bash
kubectl logs -n storage -l app.kubernetes.io/name=democratic-csi,app.kubernetes.io/component=node -f
```

**Verify NVMe discovery:**
```bash
# On the node where pod is scheduled
sudo nvme discover -t tcp -a ${SECRET_NFS_SERVER} -s 4420
sudo nvme connect-all
```

### Multipath Issues

```bash
# Check NVMe multipath status
sudo nvme list -o json | jq '.[] | select(.subsystems[].paths | length > 1)'

# Reload NVMe configuration
sudo systemctl restart nvme-tcp.service  # if applicable
```

---

## References

- [Democratic-CSI NVMe-oF Documentation](https://github.com/democratic-csi/democratic-csi/tree/master/examples/zfs-generic-nvmeof.yaml)
- [TrueNAS NVMe-oF Configuration](https://www.truenas.com/docs/scale/scaletutorials/sharing/nvme/)
- [Linux NVMe-oF Documentation](https://www.kernel.org/doc/html/latest/staging/nvmet.html)
- [NVMe over Fabrics Specification](https://nvmexpress.org/developers/nvme-of-specification/)

---

## Known Limitations

1. **TrueNAS Scale Version**: Requires 24.10 or later
2. **Transport Protocols**: TCP only (RDMA requires additional configuration)
3. **Volume Size**: Minimum 1GB (TrueNAS API limitation)
4. **Multipath**: Native NVMe multipath may require kernel parameter tuning
5. **Snapshot Support**: Limited compared to iSCSI

---

## Migration Checklist

- [ ] Verify TrueNAS Scale version ≥ 24.10
- [ ] Enable NVMe-oF service on TrueNAS
- [ ] Configure NVMe targets and extents
- [ ] Install NVMe tools on Kubernetes nodes
- [ ] Update Democratic-CSI HelmRelease with NVMe configuration
- [ ] Create NVMe StorageClass
- [ ] Test provisioning with small PVCs
- [ ] Benchmark performance vs iSCSI
- [ ] Migrate workloads gradually
- [ ] Decommission iSCSI after validation

---

## Performance Optimization

### TrueNAS Configuration
- Use SSD/NVMe-backed ZFS pools
- Enable compression (lz4 recommended)
- Configure appropriate recordsize (128K for databases, 8K for general use)

### Kubernetes Configuration
- Set appropriate resource requests/limits for NVMe workloads
- Consider using `ReadWriteOnce` access mode for best performance
- Monitor NVMe device metrics with Prometheus

### Network Configuration
- Use dedicated network for storage traffic
- Consider RDMA (RoCE/iWARP) for lowest latency
- Ensure MTU consistency across network path

---

## Support Resources

- [Democratic-CSI GitHub Issues](https://github.com/democratic-csi/democratic-csi/issues)
- [TrueNAS Community Forums](https://www.truenas.com/community/)
- [NVMe-oF Linux Documentation](https://www.kernel.org/doc/html/latest/staging/nvmet.html)
- [Kubernetes CSI Documentation](https://kubernetes-csi.github.io/docs/)