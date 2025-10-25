# Flux Operator Deployment Strategy

## The Challenge

You have a GitOps repo where Flux automatically applies changes. But we're replacing Flux itself, which creates a chicken-and-egg problem:

1. **Option A (Manual)**: Manually apply Flux Operator/FluxInstance, then commit
   - Breaks GitOps workflow temporarily
   - Manual intervention required
   - Risk of drift

2. **Option B (GitOps)**: Commit first, let Flux apply it
   - Maintains GitOps workflow
   - But old Flux doesn't know about new Flux files
   - New Flux won't start until old Flux applies it

3. **Option C (Hybrid)**: Commit, let old Flux apply, then transition
   - Best of both worlds
   - Maintains GitOps principles
   - Controlled transition

## Current Flux Configuration

Your current setup:
```
kubernetes/flux/config/cluster.yaml
  ├── GitRepository: home-kubernetes (main branch)
  ├── Kustomization: cluster (syncs kubernetes/flux)
  └── Kustomization: cluster-apps (syncs kubernetes/apps)
```

**Key insight**: The `cluster` Kustomization syncs `kubernetes/flux` directory, which includes `config/` subdirectory.

## Recommended Strategy: Option C (Hybrid GitOps)

### Phase 1: Commit New Configuration (GitOps)
1. Commit all Flux Operator and FluxInstance files to git
2. Push to main branch
3. Old Flux automatically detects and applies the new files
4. New Flux Operator and FluxInstance start up

### Phase 2: Verify New Flux (Manual Verification)
1. Monitor logs to ensure new Flux is working
2. Verify FluxInstance is reconciling
3. Confirm all Flux controllers are running

### Phase 3: Disable Old Flux (GitOps)
1. Remove old `kubernetes/flux/config/flux.yaml` from git
2. Commit and push
3. Old Flux prunes itself (because of `prune: true`)
4. New Flux takes over completely

### Phase 4: Cleanup (GitOps)
1. Remove old bootstrap kustomization references
2. Update documentation
3. Commit and push

## Step-by-Step Execution

### Step 1: Commit New Flux Configuration

```bash
# Stage all new files
git add kubernetes/apps/flux-system/flux-operator/
git add kubernetes/apps/flux-system/flux-instance/
git add kubernetes/flux/cluster/
git add kubernetes/apps/flux-system/kustomization.yaml
git add bootstrap/helmfile.d/01-apps.yaml

# Commit
git commit -m "feat: add Flux Operator and FluxInstance configuration

- Add Flux Operator HelmRelease (v0.32.0)
- Add FluxInstance HelmRelease (v0.32.0) with all patches
- Add kubernetes/flux/cluster/ks.yaml for cluster sync
- Update bootstrap helmfile to v0.32.0
- Flux will automatically deploy new components alongside existing Flux"

# Push to main
git push origin main
```

### Step 2: Monitor Old Flux Applying New Configuration

```bash
# Watch the cluster Kustomization
kubectl describe kustomization cluster -n flux-system

# Watch for new resources being created
kubectl get helmrelease -n flux-system -w
kubectl get fluxinstance -n flux-system -w

# Watch Flux Operator pod starting
kubectl get pods -n flux-system -l app=flux-operator -w

# Check logs
kubectl logs -f -n flux-system -l app=flux-operator
```

**Expected timeline**: 5-10 minutes for old Flux to detect, apply, and new Flux to start

### Step 3: Verify New Flux is Working

```bash
# Check FluxInstance status
kubectl get fluxinstance -n flux-system
kubectl describe fluxinstance -n flux-system

# Check Flux controllers
kubectl get pods -n flux-system | grep -E "source|helm|kustomize|notification"

# Check that new Flux is syncing
kubectl get gitrepository -n flux-system
kubectl get kustomization -n flux-system | head -20

# Verify no errors
kubectl logs -n flux-system -l app=flux-operator
kubectl logs -n flux-system -l app=source-controller
```

**Success criteria**:
- ✅ Flux Operator pod running
- ✅ FluxInstance created and reconciling
- ✅ All Flux controllers running
- ✅ GitRepository syncing
- ✅ Kustomizations reconciling

### Step 4: Remove Old Flux Configuration

Once new Flux is verified working:

```bash
# Remove old flux.yaml from git
git rm kubernetes/flux/config/flux.yaml

# Update kustomization.yaml to remove flux.yaml reference
# (if needed - check if it's still referenced)

# Commit
git commit -m "feat: remove old manual Flux configuration

- Remove kubernetes/flux/config/flux.yaml
- Flux Operator now manages Flux components
- Old Flux will prune this resource automatically"

# Push
git push origin main
```

**What happens**:
1. Old Flux detects the removal
2. Old Flux's Kustomization (named "flux") gets pruned
3. Old Flux components stop being managed by the old Kustomization
4. New Flux (FluxInstance) is already managing them
5. Seamless transition!

### Step 5: Verify Transition Complete

```bash
# Check that old "flux" Kustomization is gone
kubectl get kustomization flux -n flux-system
# Should return: Error from server (NotFound)

# Check that FluxInstance is managing Flux
kubectl get fluxinstance -n flux-system
# Should show: flux-instance reconciling

# Verify all Flux controllers still running
kubectl get pods -n flux-system
# Should show all controllers running

# Verify cluster is still reconciling
kubectl get kustomization -n flux-system | head -20
# Should show all Kustomizations Ready
```

### Step 6: Cleanup Bootstrap (Optional)

Later, you can remove the old bootstrap kustomization:

```bash
# Remove old bootstrap kustomization
git rm kubernetes/bootstrap/flux/

# Commit
git commit -m "chore: remove old Flux bootstrap kustomization

- Old bootstrap no longer needed
- Flux Operator installed via Helmfile
- Flux components managed by FluxInstance"

# Push
git push origin main
```

## Timeline

| Step | Action | Time | GitOps? |
|------|--------|------|---------|
| 1 | Commit new Flux config | 5 min | ✅ Yes |
| 2 | Old Flux applies it | 5-10 min | ✅ Yes |
| 3 | Verify new Flux working | 5 min | Manual |
| 4 | Remove old flux.yaml | 5 min | ✅ Yes |
| 5 | Verify transition | 5 min | Manual |
| 6 | Cleanup bootstrap | Later | ✅ Yes |

**Total time: 25-35 minutes**

## Risk Mitigation

### During Transition
- **Both Flux versions running**: Old Flux and new Flux coexist
- **No service interruption**: Applications continue running
- **Easy rollback**: If issues, just revert commits

### If Issues Occur
```bash
# Revert the commits
git revert HEAD~1  # Remove old flux.yaml removal
git revert HEAD~2  # Remove new Flux config
git push origin main

# Old Flux will reapply itself
# New Flux will be pruned
```

## Why This Strategy Works

1. **Maintains GitOps**: Everything is in git, Flux applies it
2. **No manual kubectl apply**: Flux does the work
3. **Controlled transition**: You control the pace
4. **Easy rollback**: Git history is your safety net
5. **Verifiable**: You can check each step before proceeding
6. **Automatic cleanup**: Old Flux prunes itself when config is removed

## Key Insight: The Kustomization Prune

Your current `kubernetes/flux/config/flux.yaml` Kustomization has:
```yaml
spec:
  prune: true
```

This means when you remove `flux.yaml` from git, the old Kustomization will:
1. Detect the removal
2. Automatically delete all resources it created
3. Clean itself up

This is the magic that makes the transition seamless!

## Recommended Approach

**Use Option C (Hybrid GitOps)**:
1. Commit all new Flux Operator/FluxInstance files
2. Push to main
3. Let old Flux apply them automatically
4. Verify new Flux is working
5. Remove old flux.yaml
6. Push to main
7. Let old Flux prune itself
8. Done!

This maintains your GitOps workflow while safely transitioning to Flux Operator.

