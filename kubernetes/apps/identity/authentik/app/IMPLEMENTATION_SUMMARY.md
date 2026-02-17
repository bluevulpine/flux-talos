# Authentik Outpost /dev/shm Fix - Implementation Summary

## Overview

This implementation provides solutions for the authentik outpost proxy `/dev/shm` session file accumulation issue (https://github.com/goauthentik/authentik/issues/12230).

## Files Created/Modified

### Documentation
- **OUTPOST_SHM_CLEANUP.md** - Comprehensive guide covering all solutions
- **outpost-patch-config.yaml** - Ready-to-paste configuration for authentik UI
- **IMPLEMENTATION_SUMMARY.md** - This file

### Fallback Resources (Optional)
- **outpost-cleanup-rbac.yaml** - RBAC for CronJob approach
- **outpost-cleanup-cronjob.yaml** - CronJob that cleans /dev/shm hourly
- **outpost-config-patch.yaml** - ConfigMap with patch script (deprecated)
- **outpost-patch-job.yaml** - Job to apply patch (deprecated)

### Modified Files
- **helmrelease.yaml** - Added comments about outpost configuration
- **kustomization.yaml** - Added references to cleanup resources (commented out)

## Recommended Implementation Path

### ⭐ RECOMMENDED: Solution 1 - Native Authentik Configuration

**This is the official, supported method.**

1. **Open the configuration file**:
   ```bash
   cat kubernetes/apps/identity/authentik/app/outpost-patch-config.yaml
   ```

2. **Copy the YAML configuration** (lines starting with `kubernetes_json_patches:`)

3. **Apply via authentik Admin UI**:
   - Log in to authentik Admin interface
   - Navigate to **Applications** → **Outposts**
   - Click on your proxy outpost
   - Scroll to **Advanced settings**
   - Paste the configuration into the **Configuration** field
   - Click **Update**

4. **Verify the deployment**:
   ```bash
   # Check that the outpost pods have been recreated
   kubectl get pods -n identity -l app.kubernetes.io/name=authentik-proxy-outpost
   
   # Verify /dev/shm size
   POD=$(kubectl get pods -n identity -l app.kubernetes.io/name=authentik-proxy-outpost -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n identity $POD -c authentik-proxy -- df -h /dev/shm
   
   # Should show: tmpfs 256M (instead of 64M)
   ```

5. **Monitor cleanup sidecar**:
   ```bash
   kubectl logs -n identity $POD -c shm-cleanup --tail=20 -f
   ```

### Alternative: Solution 2 - CronJob Fallback

**Only use if Solution 1 doesn't work for some reason.**

1. **Uncomment resources in kustomization.yaml**:
   ```yaml
   # Change from:
   # - ./outpost-cleanup-rbac.yaml
   # - ./outpost-cleanup-cronjob.yaml
   
   # To:
   - ./outpost-cleanup-rbac.yaml
   - ./outpost-cleanup-cronjob.yaml
   ```

2. **Commit and push** (FluxCD will deploy automatically)

3. **Verify CronJob is running**:
   ```bash
   kubectl get cronjob -n identity authentik-outpost-shm-cleanup
   kubectl get jobs -n identity -l app.kubernetes.io/name=authentik-outpost-shm-cleanup
   ```

## What Gets Deployed

### Solution 1 (Recommended)
- **No Kubernetes resources** - configuration is stored in authentik's database
- Authentik automatically patches the outpost deployment with:
  - Larger /dev/shm volume (256Mi)
  - Cleanup sidecar container (busybox)
  - Hourly cleanup of files older than 60 minutes

### Solution 2 (Fallback)
- **ServiceAccount**: `authentik-outpost-cleanup`
- **Role**: Permissions to list pods and exec into them
- **RoleBinding**: Grants permissions to ServiceAccount
- **CronJob**: Runs hourly to clean /dev/shm in all outpost pods

## Benefits of Solution 1

✅ **Official and supported** by authentik  
✅ **Persistent** - survives authentik upgrades  
✅ **Declarative** - configuration stored in authentik's database  
✅ **No external dependencies** - no CronJobs needed  
✅ **Self-healing** - authentik automatically applies patches  
✅ **GitOps friendly** - can be exported/imported via blueprints  

## Testing and Validation

### Before Applying Fix

```bash
# Check current /dev/shm usage
POD=$(kubectl get pods -n identity -l app.kubernetes.io/name=authentik-proxy-outpost -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n identity $POD -- df -h /dev/shm

# Count session files
kubectl exec -n identity $POD -- sh -c 'find /dev/shm -type f | wc -l'
```

### After Applying Fix

```bash
# Verify /dev/shm size increased
kubectl exec -n identity $POD -c authentik-proxy -- df -h /dev/shm
# Should show: tmpfs 256M (was 64M)

# Verify cleanup sidecar is running
kubectl get pods -n identity $POD -o jsonpath='{.spec.containers[*].name}'
# Should show: authentik-proxy shm-cleanup

# Check cleanup logs
kubectl logs -n identity $POD -c shm-cleanup
```

## Monitoring

### Set up alerts for:
- `/dev/shm` usage > 80%
- Cleanup sidecar failures
- Number of session files exceeding threshold

### Prometheus metrics:
The outpost exposes metrics at `:9300/metrics` which can be scraped for monitoring.

## Rollback

### Solution 1
1. Log in to authentik Admin UI
2. Navigate to Applications → Outposts
3. Edit the outpost
4. Remove the `kubernetes_json_patches` configuration
5. Click Update

### Solution 2
1. Comment out the resources in `kustomization.yaml`
2. Commit and push
3. FluxCD will remove the CronJob

## Future Improvements

1. **Monitor upstream issue** for official fixes
2. **Add Prometheus metrics** for /dev/shm usage
3. **Consider Redis backend** for session storage instead of filesystem
4. **Implement alerts** for /dev/shm usage thresholds

## References

- **Upstream Issue**: https://github.com/goauthentik/authentik/issues/12230
- **Authentik Outpost Docs**: https://docs.goauthentik.io/docs/add-secure-apps/outposts#configuration
- **Kubernetes JSON Patch**: https://github.com/kubernetes-sigs/kustomize/blob/master/examples/jsonpatch.md

## Support

For questions or issues:
1. Check `OUTPOST_SHM_CLEANUP.md` for detailed troubleshooting
2. Review the upstream GitHub issue for updates
3. Check authentik documentation for configuration changes

