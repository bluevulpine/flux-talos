# Bitwarden Secrets Reference - Democratic-CSI

This document lists all Bitwarden secrets required for democratic-csi integration.

## Secret: `democratic-csi`

**Purpose**: TrueNAS Scale API authentication for democratic-csi storage provisioning

**Location in Bitwarden**: 
- Project: Same project as other cluster secrets
- Name: `democratic-csi`

### Fields

| Field Name | Value Type | Description | Example |
|-----------|-----------|-------------|---------|
| `DemocraticCsi__TrueNasApiKey` | API Key | TrueNAS Scale REST API authentication key | `1-IvCjJtMLUhEUseYourOwnrK1HKRIFWd1UFK5ay52HogLUrwC2UxjHNQWODCRGhe` |

### How to Generate the API Key

1. Log in to TrueNAS Scale Web UI (https://fangtooth)
2. Navigate to **System Settings → API Keys**
3. Click **Create API Key**
4. Configure:
   - **Description**: "Kubernetes Democratic-CSI"
   - **Permissions**: Full access (or minimal: Storage, Sharing)
5. Copy the generated key (starts with `1-`)
6. Store in Bitwarden under the `democratic-csi` secret

### Security Notes

- **Sensitivity**: HIGH - This key grants full API access to TrueNAS
- **Rotation**: Recommended every 90 days
- **Scope**: Should be limited to API-only access if TrueNAS supports it
- **Backup**: Store the key securely before deleting from TrueNAS UI

### Usage in Kubernetes

The ExternalSecret at `kubernetes/apps/storage/democratic-csi/app/externalsecret.yaml` automatically:
1. Fetches this secret from Bitwarden
2. Creates a Kubernetes Secret named `democratic-csi-secret`
3. Injects the API key into the HelmRelease as `DEMOCRATIC_CSI_API_KEY`

### Verification

To verify the secret is properly synced:

```bash
# Check ExternalSecret status
kubectl get externalsecret -n storage democratic-csi-secret

# View the created Kubernetes secret (API key will be base64 encoded)
kubectl get secret -n storage democratic-csi-secret -o yaml

# Test API connectivity (from a pod in the cluster)
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl -k -H "Authorization: Bearer <API_KEY>" \
  https://fangtooth/api/v2.0/system/info
```

## Related Secrets

The following existing secrets are also used by democratic-csi:

| Secret | Field | Usage |
|--------|-------|-------|
| `cluster-secrets` | `SECRET_NFS_SERVER` | TrueNAS Scale IP address (fangtooth) |

## iSCSI Configuration Notes

The following iSCSI settings are **non-sensitive** and are configured directly in the HelmRelease:

- **Portal ID**: Placeholder value in helmrelease.yaml (find and replace with your portal ID)
- **Initiator Group ID**: Placeholder value in helmrelease.yaml (find and replace with your initiator group ID)
- **Target Group Portal Group**: Placeholder value in helmrelease.yaml (find and replace with your target group portal group ID)

These values should be obtained from TrueNAS Scale:
1. Navigate to **Sharing → iSCSI → Portals** (for Portal ID)
2. Navigate to **Sharing → iSCSI → Initiator Groups** (for Initiator Group ID)
3. Navigate to **Sharing → iSCSI → Target Groups** (for Target Group Portal Group ID)

## Troubleshooting Secret Issues

### ExternalSecret Not Syncing

```bash
# Check ExternalSecret status
kubectl describe externalsecret -n storage democratic-csi-secret

# Check external-secrets controller logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets -f
```

### API Key Invalid or Expired

1. Generate a new API key in TrueNAS Scale
2. Update the secret in Bitwarden
3. Force refresh:
   ```bash
   kubectl annotate externalsecret -n storage democratic-csi-secret \
     force-sync="$(date +%s)" --overwrite
   ```
4. Restart democratic-csi:
   ```bash
   kubectl rollout restart deployment -n storage -l app.kubernetes.io/name=democratic-csi
   ```

### Secret Not Appearing in Pod

```bash
# Check if the secret was created
kubectl get secret -n storage democratic-csi-secret

# Check HelmRelease for errors
kubectl describe helmrelease -n storage democratic-csi

# Check if the secret is mounted correctly
kubectl get pod -n storage -l app.kubernetes.io/name=democratic-csi -o yaml | grep -A 5 "env:"
```

