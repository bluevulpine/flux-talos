# Quick Reference Guide

## Essential Commands (Linux Environment)

### Environment Setup
```bash
# Always run this first for kubectl access
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
```

### Common Debugging Commands
```bash
# Check HelmRelease status
kubectl get helmrelease -A
kubectl describe helmrelease <name> -n <namespace>

# Check pod status and logs
kubectl get pods -n <namespace> -l app.kubernetes.io/instance=<name>
kubectl logs -n <namespace> <pod-name> -c <container-name>
kubectl describe pod <pod-name> -n <namespace>

# Force reconciliation
kubectl annotate helmrelease <name> -n <namespace> reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# Check Flux system health
flux check
flux get all
```

### Schema Validation URLs
```bash
# App-template v4.4.0
curl -s https://raw.githubusercontent.com/bjw-s-labs/helm-charts/common-4.4.0/charts/library/common/values.schema.json

# HelmRelease schema
curl -s https://raw.githubusercontent.com/bjw-s/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2beta2.schema.json

# Kubernetes schemas
# https://kubernetes-schemas.pages.dev/
```

## Troubleshooting Checklist

### HelmRelease Failures
- [ ] Check HelmRelease status: `kubectl get helmrelease <name> -n <namespace>`
- [ ] Get error details: `kubectl describe helmrelease <name> -n <namespace>`
- [ ] Verify schema format against official sources
- [ ] Check for working examples in repository
- [ ] Validate YAML syntax: `yamllint <file>`
- [ ] Check for immutable field conflicts
- [ ] Verify RBAC permissions if ServiceAccount is used

### Pod Issues
- [ ] Check pod status: `kubectl get pods -n <namespace>`
- [ ] Review pod events: `kubectl describe pod <name> -n <namespace>`
- [ ] Check container logs: `kubectl logs <pod> -c <container> -n <namespace>`
- [ ] Verify image availability and pull secrets
- [ ] Check resource limits and requests
- [ ] Validate storage mounts and PVC status

### Storage Problems
- [ ] Check PVC status: `kubectl get pvc -n <namespace>`
- [ ] Verify storage class: `kubectl get storageclass`
- [ ] Check available space: `kubectl exec <pod> -- df -h`
- [ ] Review backup configurations and schedules
- [ ] Validate volume expansion settings

### Network Issues
- [ ] Check service status: `kubectl get service -n <namespace>`
- [ ] Verify ingress/route configuration
- [ ] Test internal connectivity: `kubectl exec <pod> -- nslookup <service>`
- [ ] Check external DNS resolution
- [ ] Validate load balancer IP assignment

## Common Fixes

### App-Template v4.4.0 Migration
```yaml
# OLD (broken)
serviceAccount:
  create: true
  name: myapp

# NEW (correct)
serviceAccount:
  myapp:
    enabled: true

# Also add controller type
controllers:
  myapp:
    type: deployment  # Required!
```

### Force Resource Recreation
```bash
# Delete stuck deployment
kubectl delete deployment <name> -n <namespace>

# Force HelmRelease reconciliation
kubectl annotate helmrelease <name> -n <namespace> reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

### Storage Expansion
```bash
# Check if storage class supports expansion
kubectl get storageclass <class-name> -o yaml | grep allowVolumeExpansion

# Expand PVC
kubectl patch pvc <pvc-name> -n <namespace> -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'

# Restart pod to trigger expansion
kubectl delete pod <pod-name> -n <namespace>
```

## Emergency Procedures

### Cluster Issues
1. Check Flux system: `kubectl get pods -n flux-system`
2. Check storage system: `kubectl get pods -n longhorn-system`
3. Check networking: `kubectl get pods -n kube-system -l k8s-app=cilium`
4. Check DNS: `kubectl get pods -n kube-system -l k8s-app=kube-dns`

### Application Recovery
1. Suspend HelmRelease: `kubectl patch helmrelease <name> -n <namespace> --type='merge' -p='{"spec":{"suspend":true}}'`
2. Manual cleanup if needed
3. Resume HelmRelease: `kubectl patch helmrelease <name> -n <namespace> --type='merge' -p='{"spec":{"suspend":false}}'`

### Git Rollback
```bash
# Revert last commit
git revert HEAD
git push origin main

# Revert specific commit
git revert <commit-hash>
git push origin main
```

## Key Repository Patterns

### Working Examples to Reference
- **Simple web app**: `kubernetes/apps/home/homepage/`
- **Game server**: `kubernetes/apps/games/valheim/`
- **Monitoring app**: `kubernetes/apps/observability/gatus/`
- **Media server**: `kubernetes/apps/media/plex/`

### Template Locations
- **VolSync backup**: `kubernetes/components/volsync/`
- **Gatus monitoring**: `kubernetes/components/gatus-guarded/`
- **Common templates**: `kubernetes/templates/`

### Schema Sources
- **App-template**: Check `kubernetes/apps/*/app/ocirepository.yaml` for current version
- **Flux**: `https://kubernetes-schemas.pages.dev/`
- **Kubernetes**: `https://kubernetes.io/docs/reference/`

---

**Quick Win Strategy**: When troubleshooting, always start by finding a working example of a similar application in this repository, then compare configurations to identify differences.
