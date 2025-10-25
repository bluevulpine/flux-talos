# Flux Operator Migration - Execution Guide

## Current Configuration Analysis

### What We Have
1. **Manual Flux Installation** (v2.6.4)
   - Installed via `kubernetes/bootstrap/flux/kustomization.yaml`
   - Managed by `kubernetes/flux/config/flux.yaml` (OCIRepository + Kustomization)
   - Patches applied to customize controllers

2. **GitRepository Configuration**
   - `kubernetes/flux/config/cluster.yaml` defines the main GitRepository
   - Points to: https://github.com/bluevulpine/flux-talos.git
   - Syncs: kubernetes/flux directory
   - Uses SOPS decryption with age key

3. **Cluster Kustomization**
   - `kubernetes/flux/config/cluster.yaml` defines cluster Kustomization
   - Syncs: kubernetes/flux directory
   - Uses SOPS decryption
   - Substitutes from ConfigMap and Secret

### What We're Creating
1. **Flux Operator** (v0.32.0)
   - Installed via Helmfile during bootstrap
   - Manages the lifecycle of Flux components

2. **FluxInstance** (v0.32.0)
   - Installed via Helmfile during bootstrap
   - Defines all Flux component patches
   - Manages sync configuration
   - Points to: kubernetes/flux/cluster directory

## Migration Steps

### Step 1: Verify New Configuration Files Exist

The following files have been created:
- ✅ `kubernetes/apps/flux-system/flux-operator/app/helmrelease.yaml`
- ✅ `kubernetes/apps/flux-system/flux-operator/app/ocirepository.yaml`
- ✅ `kubernetes/apps/flux-system/flux-operator/app/kustomization.yaml`
- ✅ `kubernetes/apps/flux-system/flux-operator/ks.yaml`
- ✅ `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml`
- ✅ `kubernetes/apps/flux-system/flux-instance/app/ocirepository.yaml`
- ✅ `kubernetes/apps/flux-system/flux-instance/app/kustomization.yaml`
- ✅ `kubernetes/apps/flux-system/flux-instance/ks.yaml`
- ✅ `kubernetes/apps/flux-system/kustomization.yaml` (updated)
- ✅ `bootstrap/helmfile.d/01-apps.yaml` (updated to v0.32.0)

### Step 2: Create kubernetes/flux/cluster Directory

The FluxInstance syncs from `kubernetes/flux/cluster` directory. We need to create this:

```bash
mkdir -p kubernetes/flux/cluster
```

This directory should contain the Kustomization that manages all cluster apps.

### Step 3: Create kubernetes/flux/cluster/ks.yaml

This is the main Kustomization that FluxInstance will sync. It should:
- Point to kubernetes/apps directory
- Apply SOPS decryption
- Apply patches to HelmReleases

### Step 4: Update GitRepository Configuration

The FluxInstance will create its own GitRepository internally. However, we need to ensure:
- The GitRepository secret (github-deploy-key) exists in flux-system namespace
- The SOPS age secret exists in flux-system namespace

### Step 5: Disable Old Flux Configuration

Once FluxInstance is running and managing Flux components:
1. Remove `kubernetes/flux/config/flux.yaml` from kustomization
2. Keep `kubernetes/flux/config/cluster.yaml` for reference (but it won't be used)
3. Eventually remove the old bootstrap kustomization

### Step 6: Verify Migration

Check that:
- Flux Operator pod is running
- FluxInstance is created and reconciling
- All Flux controllers are running
- HelmReleases are being reconciled
- No duplicate Flux components

## Key Differences in Configuration

### Old Approach (flux.yaml)
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: flux-manifests
spec:
  url: oci://ghcr.io/fluxcd/flux-manifests
  ref:
    tag: v2.6.4
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux
spec:
  sourceRef:
    kind: OCIRepository
    name: flux-manifests
  patches: [...]
```

### New Approach (FluxInstance)
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: flux-instance
spec:
  values:
    instance:
      distribution:
        artifact: oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests:v0.32.0
      sync:
        kind: GitRepository
        url: https://github.com/bluevulpine/flux-talos
        path: kubernetes/flux/cluster
      kustomize:
        patches: [...]
```

## Important Notes

1. **GitRepository URL**: The FluxInstance uses the full GitHub URL, not a local path
2. **Sync Path**: Changed from `kubernetes/flux` to `kubernetes/flux/cluster`
3. **Patches**: All patches are now in FluxInstance.spec.values.instance.kustomize.patches
4. **SOPS**: FluxInstance handles SOPS decryption internally
5. **Network Policy**: Disabled in FluxInstance (networkPolicy: false)

## Next Steps

1. Create `kubernetes/flux/cluster/ks.yaml` with proper configuration
2. Test the migration in a staging environment
3. Monitor logs during transition
4. Verify all HelmReleases are reconciling
5. Clean up old configuration files

