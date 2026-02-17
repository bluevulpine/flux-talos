# Authentik Outpost /dev/shm Cleanup Solutions

## Problem Description

Authentik outpost proxy deployments suffer from a known issue where session files accumulate in `/dev/shm` and are not automatically cleaned up, eventually causing "No space left on device" errors and pod crashes.

**Upstream Issue**: https://github.com/goauthentik/authentik/issues/12230

## Root Cause

The authentik proxy outpost stores session data in `/dev/shm` (shared memory tmpfs), but the session cleanup mechanism doesn't properly remove old session files. Over time, this fills up the default 64Mi `/dev/shm` allocation, causing the application to crash.

---

## ⭐ Solution 1: Native Authentik Configuration (RECOMMENDED)

**Method**: Configure via authentik Admin UI using `kubernetes_json_patches`  
**Status**: ✅ Official and fully supported by authentik  
**Documentation**: https://docs.goauthentik.io/docs/add-secure-apps/outposts#configuration

### Why This is the Best Solution

- **Official**: Uses authentik's native configuration system
- **Persistent**: Survives authentik upgrades and restarts
- **Declarative**: Configuration stored in authentik's database
- **No external dependencies**: No CronJobs or additional resources needed
- **Self-healing**: Authentik automatically applies patches to outpost deployments

### Implementation Steps

1. **Log in to authentik Admin interface**
   - Navigate to your authentik instance (e.g., `https://sso.yourdomain.com`)
   - Click on the Admin interface button

2. **Navigate to Outposts**
   - Go to **Applications** → **Outposts**
   - Find your proxy outpost (likely named "sso-proxy" or "embedded outpost")

3. **Edit the Outpost Configuration**
   - Click on the outpost name to edit
   - Scroll down to **Advanced settings**
   - In the **Configuration** field, add the following YAML:

```yaml
# Fix for /dev/shm session file accumulation
# Issue: https://github.com/goauthentik/authentik/issues/12230
#
# NOTE: The outpost deployment doesn't have 'volumes' or 'volumeMounts' arrays
# by default, so we create them with our values in a single operation.
kubernetes_json_patches:
  deployment:
    # Patch 1: Add volumes array with /dev/shm volume
    - op: add
      path: /spec/template/spec/volumes
      value:
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 256Mi

    # Patch 2: Add volumeMounts array to main container
    - op: add
      path: /spec/template/spec/containers/0/volumeMounts
      value:
        - name: dshm
          mountPath: /dev/shm

    # Patch 3: Add cleanup sidecar container
    - op: add
      path: /spec/template/spec/containers/-
      value:
        name: shm-cleanup
        image: busybox:latest
        command:
          - /bin/sh
          - -c
        args:
          - |
            while true; do
              echo "$(date): Cleaning /dev/shm..."
              # Remove session files older than 60 minutes
              find /dev/shm -type f -mmin +60 -delete 2>/dev/null || true
              # Remove empty directories
              find /dev/shm -type d -empty -delete 2>/dev/null || true
              echo "$(date): Cleanup complete. Next run in 1 hour."
              sleep 3600
            done
        volumeMounts:
          - name: dshm
            mountPath: /dev/shm
        resources:
          requests:
            cpu: 5m
            memory: 16Mi
          limits:
            cpu: 50m
            memory: 32Mi
        securityContext:
          runAsNonRoot: true
          runAsUser: 1000
          allowPrivilegeEscalation: false
          capabilities:
            drop:
              - ALL
          readOnlyRootFilesystem: true
```

4. **Save and Apply**
   - Click **Update** at the bottom of the form
   - Authentik will automatically update the outpost deployment
   - The outpost pods will be recreated with the new configuration

### What This Configuration Does

1. **Increases /dev/shm size**: From 64Mi to 256Mi (4x larger)
2. **Adds cleanup sidecar**: Lightweight busybox container that runs hourly
3. **Automatic cleanup**: Removes session files older than 60 minutes
4. **Minimal overhead**: Uses only 5m CPU and 16Mi memory

### Verification

After applying the configuration, verify it's working:

```bash
# 1. Check that the deployment has the new volume
kubectl get deployment -n identity -l app.kubernetes.io/name=authentik-proxy-outpost -o yaml | grep -A 5 dshm

# 2. Check that both containers are running
kubectl get pods -n identity -l app.kubernetes.io/name=authentik-proxy-outpost

# 3. Verify container names (should show: authentik-proxy shm-cleanup)
kubectl get pods -n identity -l app.kubernetes.io/name=authentik-proxy-outpost \
  -o jsonpath='{.items[0].spec.containers[*].name}'

# 4. Check /dev/shm size (should show 256Mi total)
POD=$(kubectl get pods -n identity -l app.kubernetes.io/name=authentik-proxy-outpost -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n identity $POD -c authentik-proxy -- df -h /dev/shm

# 5. View cleanup sidecar logs
kubectl logs -n identity $POD -c shm-cleanup --tail=20
```

Expected output for step 4:
```
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           256M  1.2M  255M   1% /dev/shm
```

### Customization Options

You can adjust the configuration to suit your needs:

**Change cleanup frequency:**
```yaml
sleep 3600  # Change to 1800 for 30 minutes, 7200 for 2 hours, etc.
```

**Change file age threshold:**
```yaml
find /dev/shm -type f -mmin +60  # Change +60 to +30 for 30 minutes, +120 for 2 hours, etc.
```

**Increase /dev/shm size further:**
```yaml
sizeLimit: 512Mi  # Or 1Gi if you have very high session volume
```

---

## Solution 2: CronJob-Based Cleanup (Fallback Option)

**Files**: `outpost-cleanup-cronjob.yaml`, `outpost-cleanup-rbac.yaml`
**Status**: ⚠️ Fallback if Solution 1 doesn't work

A Kubernetes CronJob that runs hourly to clean up old session files from all authentik outpost proxy pods.

### When to Use This

- If you cannot access the authentik Admin UI
- If the native configuration method fails for some reason
- As a temporary measure while waiting for upstream fixes

### Deployment

The CronJob is already defined in this repository but **commented out** in `kustomization.yaml`.

To enable it:
1. Edit `kustomization.yaml`
2. Uncomment the CronJob resources
3. Commit and push (FluxCD will deploy automatically)

### How It Works

1. Runs every hour via CronJob
2. Finds all authentik outpost proxy pods
3. Executes cleanup commands to remove session files older than 1 hour
4. Reports /dev/shm usage before and after cleanup

---

## Solution 3: Manual Deployment Patch (Advanced)

**Files**: `outpost-config-patch.yaml`, `outpost-patch-job.yaml`
**Status**: ⚠️ Not recommended - use Solution 1 instead

This was the original approach before we discovered the native `kubernetes_json_patches` configuration.

**Do not use this method** - it's superseded by Solution 1 which is official and better supported.

---

## Troubleshooting

### Common Issues

#### Error: "member 'volumes' not found"

If you see an error like:
```
member 'volumes' not found in {'containers': [...]}
```

This means the outpost deployment doesn't have a `volumes` array yet. The updated configuration (above) handles this by creating the entire array in one operation instead of trying to append to a non-existent array.

**Solution**: Use the updated configuration that creates the `volumes` and `volumeMounts` arrays with the `add` operation and a complete value (not using `/-` to append).

#### Configuration Not Applied

If the configuration doesn't seem to apply:

1. **Check authentik logs**:
   ```bash
   kubectl logs -n identity -l app.kubernetes.io/name=authentik-server --tail=100
   ```

2. **Verify outpost is managed by Kubernetes integration**:
   - In authentik Admin UI, go to System → Integrations
   - Ensure there's a Kubernetes integration
   - Check that the outpost is using this integration

3. **Force outpost recreation**:
   - Delete the outpost deployment manually
   - Authentik will recreate it with the new configuration
   ```bash
   kubectl delete deployment -n identity -l app.kubernetes.io/name=authentik-proxy-outpost
   ```

## Monitoring and Troubleshooting

### Check /dev/shm Usage

```bash
# Find outpost pods
kubectl get pods -n identity -l app.kubernetes.io/name=authentik-proxy-outpost

# Check /dev/shm usage in a pod
POD=$(kubectl get pods -n identity -l app.kubernetes.io/name=authentik-proxy-outpost -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n identity $POD -c authentik-proxy -- df -h /dev/shm

# List session files
kubectl exec -n identity $POD -c authentik-proxy -- ls -lah /dev/shm/

# Count session files
kubectl exec -n identity $POD -c authentik-proxy -- sh -c 'find /dev/shm -type f | wc -l'
```

### Monitor Cleanup Sidecar

```bash
# View cleanup sidecar logs
kubectl logs -n identity $POD -c shm-cleanup --tail=50 -f

# Check sidecar resource usage
kubectl top pod -n identity $POD --containers
```

### Alerts and Metrics

Consider setting up monitoring for:
- `/dev/shm` usage > 80%
- Number of session files > threshold
- Cleanup sidecar failures

---

## Manual Cleanup (Emergency)

If /dev/shm fills up and causes immediate issues:

```bash
# Get the outpost pod name
POD=$(kubectl get pods -n identity -l app.kubernetes.io/name=authentik-proxy-outpost -o jsonpath='{.items[0].metadata.name}')

# Clean up all files in /dev/shm (CAUTION: Will log out all users)
kubectl exec -n identity $POD -c authentik-proxy -- sh -c 'rm -rf /dev/shm/*'

# Or clean up only old session files (safer)
kubectl exec -n identity $POD -c authentik-proxy -- sh -c 'find /dev/shm -type f -mmin +30 -delete'
```

---

## References

- **Upstream Issue**: https://github.com/goauthentik/authentik/issues/12230
- **Authentik Outpost Configuration**: https://docs.goauthentik.io/docs/add-secure-apps/outposts#configuration
- **Kubernetes JSON Patch**: https://github.com/kubernetes-sigs/kustomize/blob/master/examples/jsonpatch.md
- **Kubernetes emptyDir Volumes**: https://kubernetes.io/docs/concepts/storage/volumes/#emptydir

