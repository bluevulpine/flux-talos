# Phase 1 Deployment Checklist

## Pre-Deployment Verification

### Configuration Files
- [x] Flux Operator HelmRelease created
- [x] Flux Operator OCI repository created
- [x] FluxInstance HelmRelease created (with all patches)
- [x] FluxInstance OCI repository created
- [x] kubernetes/flux/cluster/ks.yaml created
- [x] kubernetes/apps/flux-system/kustomization.yaml updated
- [x] bootstrap/helmfile.d/01-apps.yaml updated to v0.32.0

### Configuration Review
- [x] FluxInstance patches verified against current flux.yaml
- [x] NetworkPolicy removal analyzed and commented
- [x] GitRepository URL correct (https://github.com/bluevulpine/flux-talos)
- [x] Sync path correct (kubernetes/flux/cluster)
- [x] All required secrets present (github-deploy-key, sops-age)
- [x] All required ConfigMaps present (cluster-settings, cluster-secrets)

### Documentation
- [x] PHASE_1_FINAL_REPORT.md created
- [x] FLUX_OPERATOR_MIGRATION_RESEARCH.md created
- [x] FLUX_OPERATOR_CLUSTER_STATE.md created
- [x] BOOTSTRAP_PROCESS_DOCUMENTATION.md created
- [x] NETWORKPOLICY_ANALYSIS.md created
- [x] QUICK_REFERENCE.md created

## Pre-Deployment Cluster Checks

### Current Flux Status
```bash
$ flux version
flux: v2.7.2
distribution: flux-v2.6.4
```
Status: ✅ Healthy

### Flux Components
```bash
$ kubectl get pods -n flux-system
```
Status: ✅ All running

### GitRepositories
```bash
$ kubectl get gitrepository -n flux-system
```
Status: ✅ All syncing

### Kustomizations
```bash
$ kubectl get kustomization -n flux-system | wc -l
```
Status: ✅ 80+ active

### Secrets
```bash
$ kubectl get secrets -n flux-system
```
Status: ✅ github-deploy-key present
Status: ✅ sops-age present

### ConfigMaps
```bash
$ kubectl get configmaps -n flux-system
```
Status: ✅ cluster-settings present
Status: ✅ cluster-secrets present

## Deployment Steps

### Step 1: Dry Run
```bash
kubectl apply --dry-run=client -f kubernetes/apps/flux-system/
```
Expected: No errors

### Step 2: Deploy Flux Operator and FluxInstance
```bash
helmfile -f bootstrap/helmfile.d/01-apps.yaml sync
```
Expected: Both charts installed successfully

### Step 3: Wait for Flux Operator
```bash
kubectl wait --for=condition=ready pod -l app=flux-operator -n flux-system --timeout=300s
```
Expected: Pod becomes ready

### Step 4: Verify FluxInstance
```bash
kubectl get fluxinstance -n flux-system
```
Expected: FluxInstance created and reconciling

### Step 5: Check Flux Controllers
```bash
kubectl get pods -n flux-system -l app.kubernetes.io/part-of=flux
```
Expected: All controllers running

## Post-Deployment Verification

### Flux Operator Status
```bash
kubectl get pods -n flux-system -l app=flux-operator
kubectl logs -n flux-system -l app=flux-operator
```
Expected: Pod running, no errors in logs

### FluxInstance Status
```bash
kubectl describe fluxinstance -n flux-system
kubectl get events -n flux-system --sort-by='.lastTimestamp'
```
Expected: Reconciling successfully, no errors

### Flux Controllers Status
```bash
kubectl get deployments -n flux-system
kubectl get pods -n flux-system
```
Expected: All controllers running (source, helm, kustomize, notification)

### GitRepository Sync
```bash
kubectl describe gitrepository flux-system -n flux-system
```
Expected: Syncing successfully

### Kustomizations
```bash
kubectl get kustomization -n flux-system | head -20
```
Expected: All Ready

### HelmReleases
```bash
kubectl get helmrelease -A | head -20
```
Expected: All reconciling

## Rollback Procedure (if needed)

### Quick Rollback
```bash
# Delete FluxInstance
kubectl delete helmrelease flux-instance -n flux-system

# Delete Flux Operator
kubectl delete helmrelease flux-operator -n flux-system

# Old Flux will continue managing cluster
```

### Full Rollback
```bash
# If old Flux was removed, reapply bootstrap
kubectl apply -k kubernetes/bootstrap/flux/

# Verify old Flux is managing cluster
kubectl get kustomization flux -n flux-system
```

## Success Criteria

After deployment, verify:
- [ ] Flux Operator pod running and healthy
- [ ] FluxInstance created and reconciling
- [ ] All Flux controllers running (source, helm, kustomize, notification)
- [ ] GitRepository syncing successfully
- [ ] All Kustomizations Ready
- [ ] All HelmReleases reconciling
- [ ] No errors in Flux logs
- [ ] Cluster stability maintained
- [ ] No duplicate Flux components
- [ ] All applications still running

## Monitoring During Deployment

### Watch Flux Operator
```bash
kubectl logs -f -n flux-system -l app=flux-operator
```

### Watch Flux Controllers
```bash
kubectl logs -f -n flux-system -l app=source-controller
kubectl logs -f -n flux-system -l app=kustomize-controller
kubectl logs -f -n flux-system -l app=helm-controller
```

### Watch Events
```bash
kubectl get events -n flux-system -w
```

## Estimated Timeline

- Dry run: 1-2 minutes
- Helmfile sync: 3-5 minutes
- Flux Operator startup: 2-3 minutes
- FluxInstance reconciliation: 2-3 minutes
- Full stabilization: 5-10 minutes

**Total estimated time: 15-25 minutes**

## Important Notes

1. **No Breaking Changes**: Old Flux runs alongside new Flux during transition
2. **Easy Rollback**: Can revert quickly if issues occur
3. **All Secrets Present**: No additional setup needed
4. **Patches Preserved**: All optimizations migrated
5. **NetworkPolicy**: Harmless legacy configuration (see NETWORKPOLICY_ANALYSIS.md)

## Questions Before Deployment?

Refer to:
- PHASE_1_FINAL_REPORT.md - Complete summary
- BOOTSTRAP_PROCESS_DOCUMENTATION.md - Bootstrap details
- NETWORKPOLICY_ANALYSIS.md - NetworkPolicy explanation
- QUICK_REFERENCE.md - Quick commands

## Ready to Deploy?

When you're ready, proceed with:
```bash
helmfile -f bootstrap/helmfile.d/01-apps.yaml sync
```

Good luck! 🚀

