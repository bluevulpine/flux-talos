# Flux Operator Migration Plan

## Overview

This plan outlines the step-by-step process to migrate from manual Flux installation (v2.6.4) to Flux Operator (v0.32.0) without disrupting the cluster.

## Pre-Migration Checklist

- [ ] Backup current cluster state
- [ ] Document current Flux configuration
- [ ] Ensure all HelmReleases are in a stable state
- [ ] Test migration in staging environment first
- [ ] Have rollback plan ready

## Migration Strategy

### Strategy: In-Place Upgrade with Parallel Running

We will:
1. Install Flux Operator alongside existing Flux
2. Configure FluxInstance to manage the same GitRepository
3. Verify FluxInstance is working correctly
4. Remove old Flux installation
5. Clean up old bootstrap configuration

This approach minimizes downtime and allows for easy rollback.

## Detailed Migration Steps

### Step 1: Create Directory Structure

Create the new Flux system directory structure:
```
kubernetes/apps/flux-system/
├── namespace.yaml
├── kustomization.yaml
├── flux-operator/
│   ├── app/
│   │   ├── helmrelease.yaml
│   │   ├── ocirepository.yaml
│   │   └── kustomization.yaml
│   └── ks.yaml
└── flux-instance/
    ├── app/
    │   ├── helmrelease.yaml
    │   ├── ocirepository.yaml
    │   ├── kustomization.yaml
    │   └── [other monitoring files]
    └── ks.yaml
```

### Step 2: Create Flux Operator HelmRelease

File: `kubernetes/apps/flux-system/flux-operator/app/helmrelease.yaml`
- Chart: oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator
- Version: 0.32.0
- Namespace: flux-system
- Enable ServiceMonitor for Prometheus

### Step 3: Create FluxInstance HelmRelease

File: `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml`
- Chart: oci://ghcr.io/controlplaneio-fluxcd/charts/flux-instance
- Version: 0.32.0
- Configure all patches from current flux.yaml
- Point to existing GitRepository
- Disable NetworkPolicy (networkPolicy: false)

### Step 4: Create OCI Repositories

Create OCIRepository resources for both Flux Operator and FluxInstance charts.

### Step 5: Create Bootstrap Helmfile

Create `bootstrap/helmfile.d/` structure:
- `00-crds.yaml`: Extract CRDs from charts
- `01-apps.yaml`: Install Flux Operator and FluxInstance
- `templates/values.yaml.gotmpl`: Template for reading HelmRelease values

### Step 6: Update Bootstrap Process

Modify bootstrap to:
1. Install prerequisites (if needed)
2. Run Helmfile to install Flux Operator
3. Wait for Flux Operator to be ready
4. Run Helmfile to install FluxInstance
5. Verify FluxInstance is managing Flux components

### Step 7: Verification

After deployment, verify:
- [ ] Flux Operator pod is running
- [ ] FluxInstance is created and reconciling
- [ ] All Flux controllers are running (source, helm, kustomize, notification)
- [ ] GitRepository is syncing
- [ ] HelmReleases are being reconciled
- [ ] No errors in logs

### Step 8: Cleanup

Once verified:
1. Remove old `kubernetes/bootstrap/flux/` directory
2. Remove old `kubernetes/flux/config/flux.yaml`
3. Update `kubernetes/flux/config/kustomization.yaml` if needed
4. Remove old bootstrap kustomization references
5. Update documentation

## Rollback Plan

If issues occur:

1. **Before removing old Flux**:
   - Delete FluxInstance HelmRelease
   - Delete Flux Operator HelmRelease
   - Old Flux will continue managing the cluster
   - No data loss

2. **If old Flux is already removed**:
   - Reapply old bootstrap kustomization
   - Restore old flux.yaml configuration
   - Flux will resume managing the cluster

## Configuration Mapping

### Current Patches → FluxInstance Patches

Your current `kubernetes/flux/config/flux.yaml` patches:

1. **NetworkPolicy Removal**
   - Already handled: `networkPolicy: false` in FluxInstance

2. **Concurrent Workers**
   - Current: `--concurrent=8`
   - New: Add to `instance.kustomize.patches`

3. **API QPS/Burst**
   - Current: `--kube-api-qps=500`, `--kube-api-burst=1000`
   - New: Add to `instance.kustomize.patches`

4. **Memory Limits**
   - Current: `2Gi`
   - New: Add to `instance.kustomize.patches`

5. **Helm OOM Detection**
   - Current: `--feature-gates=OOMWatch=true`
   - New: Add to `instance.kustomize.patches`

6. **Requeue Dependency**
   - Current: `--requeue-dependency=5s`
   - New: Add to `instance.kustomize.patches`

## Timeline

- **Day 1**: Create directory structure and files
- **Day 2**: Deploy Flux Operator and FluxInstance
- **Day 3**: Verify and monitor
- **Day 4**: Cleanup old configuration
- **Day 5**: Update documentation

## Success Criteria

- [ ] Flux Operator is running and healthy
- [ ] FluxInstance is reconciling successfully
- [ ] All Flux controllers are running
- [ ] All HelmReleases are reconciling
- [ ] No increase in reconciliation errors
- [ ] Cluster stability maintained
- [ ] Old Flux configuration removed
- [ ] Documentation updated

## Risks & Mitigation

| Risk | Mitigation |
|------|-----------|
| Flux components stop managing cluster | Keep old Flux running until verified |
| Configuration not properly migrated | Test patches thoroughly before cleanup |
| GitRepository sync issues | Verify GitRepository is accessible |
| Operator pod crashes | Check logs and resource limits |
| Network policies block traffic | Disable NetworkPolicy in FluxInstance |

## Support & Troubleshooting

If issues occur:
1. Check Flux Operator logs: `kubectl logs -n flux-system -l app=flux-operator`
2. Check FluxInstance status: `kubectl describe fluxinstance -n flux-system`
3. Check Flux controller logs: `kubectl logs -n flux-system -l app=<controller>`
4. Review FluxInstance events: `kubectl get events -n flux-system`

