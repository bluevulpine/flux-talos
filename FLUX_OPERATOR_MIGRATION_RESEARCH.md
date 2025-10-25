# Flux Operator Migration Research & Analysis

## Executive Summary

This document outlines the research findings from examining the onedr0p/home-ops repository's Flux Operator implementation and provides a detailed migration plan for transitioning from manual Flux installation (v2.6.4) to the Flux Operator approach.

## Current State Analysis

### Your Repository (flux-talos)
- **Flux Installation Method**: Manual via bootstrap kustomization
- **Flux Version**: v2.6.4
- **Bootstrap Process**: 
  - `kubernetes/bootstrap/flux/kustomization.yaml` pulls from `github.com/fluxcd/flux2/manifests/install?ref=v2.6.4`
  - Applies patches to customize deployments
  - Managed via `kubernetes/flux/config/flux.yaml` (OCIRepository + Kustomization)
- **Key Patches Applied**:
  - Remove NetworkPolicy resources
  - Increase concurrent workers (--concurrent=8)
  - Increase API QPS/burst limits
  - Increase memory limits (2Gi)
  - Enable Helm OOM detection
  - Set requeue-dependency=5s

### Reference Repository (onedr0p/home-ops)
- **Flux Installation Method**: Flux Operator + FluxInstance
- **Flux Operator Version**: 0.32.0
- **Bootstrap Process**:
  - Uses Helmfile for bootstrap (not Kustomization)
  - Installs Flux Operator via Helm chart
  - Installs FluxInstance via Helm chart
  - FluxInstance manages the actual Flux components
- **Key Components**:
  - `flux-operator` HelmRelease (v0.32.0)
  - `flux-instance` HelmRelease (v0.32.0)
  - Both use OCI repositories for charts
  - FluxInstance defines all Flux component patches and configurations

## Key Differences: Manual Flux vs Flux Operator

### Architecture
| Aspect | Manual Flux | Flux Operator |
|--------|------------|---------------|
| Installation | Direct manifests from GitHub | Helm charts (OCI) |
| Management | Kustomization patches | FluxInstance CRD |
| Lifecycle | Manual updates | Operator-managed |
| Configuration | Scattered patches | Centralized in FluxInstance |
| Bootstrap | Kustomization-based | Helmfile-based |

### Configuration Management
**Manual Flux**:
- Patches applied via `kubernetes/flux/config/flux.yaml`
- Patches target individual Deployments
- Configuration spread across multiple files

**Flux Operator**:
- All configuration in `FluxInstance.spec.kustomize.patches`
- Centralized, declarative configuration
- Easier to version and track changes

### Bootstrap Differences
**Manual Flux**:
1. Bootstrap kustomization pulls manifests
2. Patches are applied
3. Flux components start managing the cluster

**Flux Operator**:
1. Helmfile installs prerequisites (Cilium, CoreDNS, Cert-Manager)
2. Helmfile installs Flux Operator
3. Helmfile installs FluxInstance
4. Operator reconciles FluxInstance and manages Flux components

## Reference Implementation Details

### Bootstrap Helmfile Structure
```
bootstrap/helmfile.d/
├── 00-crds.yaml          # Extract CRDs from Helm charts
├── 01-apps.yaml          # Install Flux Operator & FluxInstance
└── templates/
    └── values.yaml.gotmpl # Template that reads HelmRelease values
```

### FluxInstance Configuration (Key Sections)
```yaml
instance:
  distribution:
    artifact: oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests:v0.32.0
    version: 2.x
  cluster:
    networkPolicy: false
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
  sync:
    kind: GitRepository
    url: https://github.com/onedr0p/home-ops
    ref: refs/heads/main
    path: kubernetes/flux/cluster
    interval: 1h
  kustomize:
    patches: [...]  # All controller patches defined here
```

### OCI Repository Pattern
Both Flux Operator and FluxInstance use OCI repositories:
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: flux-operator
spec:
  interval: 15m
  url: oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator
  ref:
    tag: 0.32.0
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
```

## Configurations to Preserve

Your current patches should be migrated to FluxInstance:
1. NetworkPolicy removal
2. Concurrent worker settings (--concurrent=8)
3. API QPS/burst limits
4. Memory limits (2Gi)
5. Helm OOM detection
6. Requeue dependency settings

## Migration Path

### Phase 1: Preparation
- Create Flux Operator and FluxInstance HelmRelease files
- Create OCI repository definitions
- Create bootstrap Helmfile structure

### Phase 2: Bootstrap Update
- Update bootstrap process to use Helmfile
- Ensure prerequisites are installed first
- Test Flux Operator installation

### Phase 3: Transition
- Deploy Flux Operator and FluxInstance
- Verify Flux components are running
- Monitor for any issues

### Phase 4: Cleanup
- Remove old bootstrap kustomization
- Remove old flux.yaml configuration
- Update documentation

## Critical Considerations

1. **Bootstrap Timing**: Flux Operator must be installed before FluxInstance
2. **GitRepository**: FluxInstance needs GitRepository to sync from
3. **Network Policies**: Reference repo disables them (networkPolicy: false)
4. **Patches**: All patches must be moved to FluxInstance.spec.kustomize.patches
5. **Helmfile**: Bootstrap requires Helmfile tool (not standard Kustomization)

## Next Steps

1. Create `kubernetes/apps/flux-system/` directory structure
2. Create Flux Operator HelmRelease and OCI repository
3. Create FluxInstance HelmRelease with all patches
4. Create bootstrap Helmfile configuration
5. Test migration in non-production environment first

