# Bootstrap Process Documentation

## Overview

The bootstrap process installs Flux Operator and FluxInstance using Helmfile, which then manages all Flux components and cluster applications.

## Prerequisites

### Required Tools
- `kubectl` - Kubernetes CLI
- `helmfile` - Helm templating tool
- `helm` - Kubernetes package manager
- `yq` - YAML processor
- `talosctl` - Talos CLI (for Talos-specific operations)

### Required Secrets
Before running bootstrap, ensure these secrets exist in flux-system namespace:
- `github-deploy-key` - SSH key for GitHub repository access
- `sops-age` - Age key for SOPS encryption/decryption

### Required ConfigMaps
- `cluster-settings` - Cluster configuration variables
- `cluster-secrets` - Encrypted cluster secrets (created by bootstrap)

## Bootstrap Stages

### Stage 1: Talos Installation
```bash
just bootstrap talos
```
Applies Talos configuration to all nodes.

### Stage 2: Kubernetes Bootstrap
```bash
just bootstrap k8s
```
Bootstraps Kubernetes cluster.

### Stage 3: Fetch Kubeconfig
```bash
just bootstrap kubeconfig
```
Retrieves kubeconfig from Talos.

### Stage 4: Wait for Nodes
```bash
just bootstrap wait
```
Waits for all nodes to be ready.

### Stage 5: Apply Namespaces
```bash
just bootstrap namespaces
```
Creates all required namespaces from kubernetes/apps directories.

### Stage 6: Apply Resources
```bash
just bootstrap resources
```
Applies bootstrap resources (secrets, ConfigMaps) from bootstrap/resources.yaml.j2.

### Stage 7: Apply CRDs
```bash
just bootstrap crds
```
Extracts and applies CRDs from Helm charts using helmfile.

### Stage 8: Apply Apps (Flux Operator & FluxInstance)
```bash
just bootstrap apps
```
Installs Flux Operator and FluxInstance using helmfile.

## Helmfile Structure

### bootstrap/helmfile.d/00-crds.yaml
Extracts CRDs from Helm charts:
- external-dns
- external-secrets
- envoy-gateway
- grafana-operator
- keda
- kube-prometheus-stack

### bootstrap/helmfile.d/01-apps.yaml
Installs applications in order:
1. **cilium** - Container networking
2. **coredns** - DNS
3. **spegel** - Image registry
4. **cert-manager** - Certificate management
5. **flux-operator** - Flux Operator (v0.32.0)
6. **flux-instance** - FluxInstance (v0.32.0)

Each release depends on the previous one (needs: field).

### bootstrap/helmfile.d/templates/values.yaml.gotmpl
Template that reads HelmRelease values from kubernetes/apps:
```
{{ (fromYaml (readFile (printf "../../../kubernetes/apps/%s/%s/app/helmrelease.yaml" .Release.Namespace .Release.Name))).spec.values | toYaml }}
```

This allows helmfile to use the same values defined in HelmRelease files.

## Flux Operator & FluxInstance

### Flux Operator (v0.32.0)
- Manages the lifecycle of Flux components
- Installed via HelmRelease in kubernetes/apps/flux-system/flux-operator/
- Enables ServiceMonitor for Prometheus monitoring

### FluxInstance (v0.32.0)
- Defines Flux component configuration
- Installed via HelmRelease in kubernetes/apps/flux-system/flux-instance/
- Manages sync from GitRepository
- Applies all patches to Flux controllers

### FluxInstance Configuration
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
    url: https://github.com/bluevulpine/flux-talos
    ref: refs/heads/main
    path: kubernetes/flux/cluster
    interval: 1h
  kustomize:
    patches: [...]
```

## Cluster Sync Path

After FluxInstance is deployed, Flux syncs from:
- **Repository**: https://github.com/bluevulpine/flux-talos
- **Branch**: main
- **Path**: kubernetes/flux/cluster

The kubernetes/flux/cluster/ks.yaml Kustomization:
- Points to kubernetes/apps directory
- Applies SOPS decryption
- Applies patches to all Kustomizations and HelmReleases
- Substitutes variables from cluster-settings and cluster-secrets

## Manual Bootstrap Steps

If using helmfile directly:

```bash
# 1. Create namespaces
kubectl apply -f kubernetes/apps/*/namespace.yaml

# 2. Apply bootstrap resources
kubectl apply -f bootstrap/resources.yaml.j2

# 3. Extract and apply CRDs
helmfile -f bootstrap/helmfile.d/00-crds.yaml template -q | kubectl apply -f -

# 4. Install Flux Operator and FluxInstance
helmfile -f bootstrap/helmfile.d/01-apps.yaml sync

# 5. Wait for Flux Operator to be ready
kubectl wait --for=condition=ready pod -l app=flux-operator -n flux-system --timeout=300s

# 6. Wait for FluxInstance to be ready
kubectl wait --for=condition=ready fluxinstance -n flux-system --timeout=300s
```

## Verification

After bootstrap completes:

```bash
# Check Flux Operator
kubectl get pods -n flux-system -l app=flux-operator

# Check FluxInstance
kubectl get fluxinstance -n flux-system

# Check Flux controllers
kubectl get pods -n flux-system -l app.kubernetes.io/part-of=flux

# Check GitRepository
kubectl get gitrepository -n flux-system

# Check Kustomizations
kubectl get kustomization -n flux-system

# Check HelmReleases
kubectl get helmrelease -A
```

## Troubleshooting

### Flux Operator not starting
```bash
kubectl logs -n flux-system -l app=flux-operator
kubectl describe pod -n flux-system -l app=flux-operator
```

### FluxInstance not reconciling
```bash
kubectl describe fluxinstance -n flux-system
kubectl get events -n flux-system
```

### GitRepository not syncing
```bash
kubectl describe gitrepository flux-system -n flux-system
kubectl logs -n flux-system -l app=source-controller
```

### SOPS decryption failing
```bash
# Verify sops-age secret exists
kubectl get secret sops-age -n flux-system

# Check kustomize-controller logs
kubectl logs -n flux-system -l app=kustomize-controller
```

## Rollback

If issues occur:

1. Delete FluxInstance HelmRelease
2. Delete Flux Operator HelmRelease
3. Old Flux will continue managing the cluster
4. Investigate and fix issues
5. Redeploy Flux Operator and FluxInstance

## Files Modified/Created

### Created
- kubernetes/apps/flux-system/flux-operator/app/helmrelease.yaml
- kubernetes/apps/flux-system/flux-operator/app/ocirepository.yaml
- kubernetes/apps/flux-system/flux-operator/app/kustomization.yaml
- kubernetes/apps/flux-system/flux-operator/ks.yaml
- kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml
- kubernetes/apps/flux-system/flux-instance/app/ocirepository.yaml
- kubernetes/apps/flux-system/flux-instance/app/kustomization.yaml
- kubernetes/apps/flux-system/flux-instance/ks.yaml
- kubernetes/flux/cluster/ks.yaml

### Modified
- kubernetes/apps/flux-system/kustomization.yaml
- bootstrap/helmfile.d/01-apps.yaml (version update to 0.32.0)

### To Be Removed (after migration)
- kubernetes/bootstrap/flux/kustomization.yaml
- kubernetes/flux/config/flux.yaml

