# Bitwarden Secrets Checklist - Democratic-CSI

This checklist provides a quick reference for all Bitwarden secrets required for democratic-csi integration.

## Required Bitwarden Secret

### ✅ Secret Name: `democratic-csi`

**Status**: ⚠️ **NOT YET CREATED** - Action required

**Purpose**: TrueNAS Scale API authentication for democratic-csi storage provisioning

**Location**: Bitwarden Secrets Manager (same project as other cluster secrets)

**Fields to Create**:

| Field Name | Value | Notes |
|-----------|-------|-------|
| `DemocraticCsi__TrueNasApiKey` | `1-xxxxxxxxxxxxxxxxxxxxxxxxxxxxx` | Generate from TrueNAS Scale System Settings → API Keys |

## Step-by-Step Creation

### 1. Generate TrueNAS API Key

```bash
# 1. Log in to TrueNAS Scale Web UI
# URL: https://fangtooth

# 2. Navigate to: System Settings → API Keys

# 3. Click "Create API Key"

# 4. Fill in:
#    - Description: "Kubernetes Democratic-CSI"
#    - Permissions: Full access (or minimal: Storage, Sharing)

# 5. Copy the generated key
#    Format: 1-IvCjJtMLUhEUseYourOwnrK1HKRIFWd1UFK5ay52HogLUrwC2UxjHNQWODCRGhe
```

### 2. Create Bitwarden Secret

```bash
# 1. Log in to Bitwarden Secrets Manager
# URL: https://vault.bitwarden.com

# 2. Navigate to your cluster project

# 3. Click "Create Secret"

# 4. Fill in:
#    - Name: democratic-csi
#    - Type: Custom

# 5. Add Field:
#    - Field Name: DemocraticCsi__TrueNasApiKey
#    - Field Value: <paste-your-api-key-here>

# 6. Click "Save"
```

### 3. Verify Secret Sync

```bash
# After creating the secret, verify it syncs to Kubernetes:

# Check ExternalSecret status
kubectl get externalsecret -n storage democratic-csi-secret

# Should show: SECRETSTORE   STATUS   REFRESHTIME
#              bitwarden...  Valid    <recent-time>

# Verify the Kubernetes secret was created
kubectl get secret -n storage democratic-csi-secret

# Should show: NAME                      TYPE     DATA   AGE
#              democratic-csi-secret     Opaque   1      <time>
```

## Verification Checklist

- [ ] TrueNAS API key generated
- [ ] Bitwarden secret `democratic-csi` created
- [ ] Field `DemocraticCsi__TrueNasApiKey` added with API key value
- [ ] ExternalSecret shows "Valid" status
- [ ] Kubernetes secret `democratic-csi-secret` exists in storage namespace
- [ ] HelmRelease deployment successful

## Troubleshooting

### Secret Not Syncing

**Check ExternalSecret status:**
```bash
kubectl describe externalsecret -n storage democratic-csi-secret
```

**Check external-secrets controller logs:**
```bash
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets -f
```

**Common issues:**
- Secret name doesn't match (should be `democratic-csi`)
- Field name doesn't match (should be `DemocraticCsi__TrueNasApiKey`)
- Bitwarden project not accessible
- API key format incorrect

### API Key Invalid

**If you get authentication errors:**

1. Verify the API key format (should start with `1-`)
2. Check TrueNAS Scale still has the key (not deleted)
3. Generate a new key if needed
4. Update Bitwarden secret
5. Force refresh:
   ```bash
   kubectl annotate externalsecret -n storage democratic-csi-secret \
     force-sync="$(date +%s)" --overwrite
   ```

## Related Documentation

- **Full Setup Guide**: See `docs/DEMOCRATIC_CSI_SETUP.md`
- **Secret Details**: See `docs/BITWARDEN_SECRETS_REFERENCE.md`
- **Implementation Summary**: See `DEMOCRATIC_CSI_IMPLEMENTATION_SUMMARY.md`

## Timeline

1. **Now**: Create Bitwarden secret
2. **After secret created**: Push changes to deploy democratic-csi
3. **After deployment**: Verify StorageClasses are available
4. **After verification**: Test with sample PVC

## Important Notes

⚠️ **Security**: The API key grants full access to TrueNAS Scale. Keep it secure.

⚠️ **Rotation**: Recommended to rotate the API key every 90 days.

⚠️ **Backup**: Store the API key securely before deleting from TrueNAS UI.

✅ **Status**: All Kubernetes configuration is ready. Only waiting for Bitwarden secret.

## Quick Reference

**Secret Name**: `democratic-csi`
**Field Name**: `DemocraticCsi__TrueNasApiKey`
**Field Value**: Your TrueNAS API key (starts with `1-`)
**Kubernetes Secret**: `democratic-csi-secret` (in storage namespace)
**ExternalSecret**: `democratic-csi-secret` (in storage namespace)

