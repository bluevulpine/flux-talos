# Flux Operator GitOps Execution Guide

## Quick Summary

**Don't manually apply anything.** Just commit and push. Old Flux will apply the new Flux Operator and FluxInstance automatically. Then we remove the old config and let Flux clean itself up.

## Step 1: Commit New Flux Configuration

```bash
# Navigate to repo
cd /Users/bluevulpine/Repositories/flux-talos

# Stage new files
git add kubernetes/apps/flux-system/flux-operator/
git add kubernetes/apps/flux-system/flux-instance/
git add kubernetes/flux/cluster/
git add kubernetes/apps/flux-system/kustomization.yaml
git add bootstrap/helmfile.d/01-apps.yaml

# Verify what you're committing
git status

# Commit with descriptive message
git commit -m "feat: add Flux Operator and FluxInstance configuration

- Add Flux Operator HelmRelease (v0.32.0) with OCI repository
- Add FluxInstance HelmRelease (v0.32.0) with all current patches
- Add kubernetes/flux/cluster/ks.yaml for cluster sync configuration
- Update bootstrap helmfile to Flux Operator v0.32.0
- Flux will automatically deploy new components alongside existing Flux
- Old Flux will be removed in next commit after verification"

# Push to main
git push origin main
```

## Step 2: Monitor Old Flux Applying New Configuration

Old Flux will detect the new files and apply them. Monitor the process:

```bash
# Terminal 1: Watch Flux Operator pod starting
kubectl get pods -n flux-system -l app=flux-operator -w

# Terminal 2: Watch FluxInstance being created
kubectl get fluxinstance -n flux-system -w

# Terminal 3: Watch events
kubectl get events -n flux-system -w --sort-by='.lastTimestamp'

# Terminal 4: Check logs
kubectl logs -f -n flux-system -l app=flux-operator
```

**Expected sequence**:
1. Old Flux detects new files (1-2 min)
2. Old Flux applies HelmRelease files (1-2 min)
3. Helmfile installs Flux Operator (2-3 min)
4. Flux Operator pod starts (1-2 min)
5. Flux Operator creates FluxInstance (1-2 min)
6. FluxInstance starts managing Flux components (2-3 min)

**Total: 8-15 minutes**

## Step 3: Verify New Flux is Working

Once you see Flux Operator pod running, verify everything:

```bash
# Check Flux Operator
kubectl get pods -n flux-system -l app=flux-operator
# Expected: 1/1 Running

# Check FluxInstance
kubectl get fluxinstance -n flux-system
# Expected: flux-instance reconciling

# Check Flux controllers (should see both old and new)
kubectl get pods -n flux-system | grep -E "source|helm|kustomize|notification"
# Expected: Multiple pods for each controller

# Check GitRepository
kubectl get gitrepository -n flux-system
# Expected: flux-system syncing

# Check Kustomizations
kubectl get kustomization -n flux-system | head -20
# Expected: All Ready

# Check for errors
kubectl logs -n flux-system -l app=flux-operator | tail -20
# Expected: No errors, reconciliation messages

# Check HelmReleases
kubectl get helmrelease -n flux-system
# Expected: flux-operator and flux-instance Ready
```

**Success criteria**:
- ✅ Flux Operator pod running
- ✅ FluxInstance created and reconciling
- ✅ All Flux controllers running
- ✅ GitRepository syncing
- ✅ All Kustomizations Ready
- ✅ No errors in logs

## Step 4: Remove Old Flux Configuration

Once verified, remove the old flux.yaml:

```bash
# Remove old flux.yaml
git rm kubernetes/flux/config/flux.yaml

# Verify removal
git status
# Should show: deleted: kubernetes/flux/config/flux.yaml

# Commit
git commit -m "feat: remove old manual Flux configuration

- Remove kubernetes/flux/config/flux.yaml
- Flux Operator now manages Flux components
- Old Flux Kustomization will be pruned automatically
- FluxInstance takes over complete management"

# Push
git push origin main
```

## Step 5: Monitor Old Flux Pruning Itself

Old Flux will detect the removal and clean up:

```bash
# Watch the old "flux" Kustomization being deleted
kubectl get kustomization flux -n flux-system -w

# Watch events
kubectl get events -n flux-system -w --sort-by='.lastTimestamp'

# Check logs
kubectl logs -f -n flux-system -l app=kustomize-controller | grep -i flux
```

**Expected sequence**:
1. Old Flux detects removal (1-2 min)
2. Old Flux's Kustomization (named "flux") gets pruned (1-2 min)
3. Old Kustomization disappears (1 min)

**Total: 3-5 minutes**

## Step 6: Final Verification

Verify the transition is complete:

```bash
# Verify old "flux" Kustomization is gone
kubectl get kustomization flux -n flux-system
# Expected: Error from server (NotFound)

# Verify FluxInstance is managing Flux
kubectl get fluxinstance -n flux-system
# Expected: flux-instance reconciling

# Verify all Flux controllers still running
kubectl get pods -n flux-system
# Expected: All controllers running

# Verify cluster is still reconciling
kubectl get kustomization -n flux-system | head -20
# Expected: All Kustomizations Ready

# Verify HelmReleases still working
kubectl get helmrelease -A | head -20
# Expected: All reconciling
```

## Step 7: Optional - Cleanup Bootstrap (Later)

After everything is stable, you can remove the old bootstrap kustomization:

```bash
# Remove old bootstrap
git rm kubernetes/bootstrap/flux/

# Commit
git commit -m "chore: remove old Flux bootstrap kustomization

- Old bootstrap no longer needed
- Flux Operator installed via Helmfile
- Flux components managed by FluxInstance"

# Push
git push origin main
```

## Rollback (If Needed)

If anything goes wrong:

```bash
# Revert the commits (in reverse order)
git revert HEAD~1  # Revert removal of flux.yaml
git revert HEAD~2  # Revert addition of new Flux config
git push origin main

# Old Flux will reapply itself
# New Flux will be pruned
# Wait 5-10 minutes for reconciliation
```

## Timeline

| Step | Action | Time | GitOps? |
|------|--------|------|---------|
| 1 | Commit new Flux config | 5 min | ✅ Yes |
| 2 | Old Flux applies it | 8-15 min | ✅ Yes |
| 3 | Verify new Flux | 5 min | Manual |
| 4 | Remove old flux.yaml | 5 min | ✅ Yes |
| 5 | Old Flux prunes itself | 3-5 min | ✅ Yes |
| 6 | Final verification | 5 min | Manual |

**Total: 30-40 minutes**

## Key Points

1. **No manual kubectl apply** - Flux does everything
2. **Everything in git** - Full GitOps workflow
3. **Easy rollback** - Just revert commits
4. **Automatic cleanup** - Old Flux prunes itself
5. **Zero downtime** - Applications keep running
6. **Verifiable** - Check each step before proceeding

## Ready?

When you're ready to start:

```bash
cd /Users/bluevulpine/Repositories/flux-talos
git add kubernetes/apps/flux-system/flux-operator/
git add kubernetes/apps/flux-system/flux-instance/
git add kubernetes/flux/cluster/
git add kubernetes/apps/flux-system/kustomization.yaml
git add bootstrap/helmfile.d/01-apps.yaml
git commit -m "feat: add Flux Operator and FluxInstance configuration"
git push origin main
```

Then monitor with:
```bash
kubectl get pods -n flux-system -l app=flux-operator -w
```

Good luck! 🚀

