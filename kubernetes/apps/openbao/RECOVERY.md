# OpenBao Disaster Recovery

## Prerequisites for Recovery

You must have all four of the following:

| Item | Where it lives |
|------|---------------|
| Git repo | GitHub — contains all config and SOPS-encrypted secrets |
| Age private key | Stored securely outside the cluster (e.g. Bitwarden) |
| Recovery keys (5 shares, threshold 3) | Stored securely (e.g. Bitwarden) — generated at first `bao operator init` |
| R2 bucket `openbao-snapshots` | Cloudflare — contains Raft snapshots uploaded every 6 hours |

> **The static seal key never needs to be backed up separately.** It lives in
> `openbao-unseal.sops.yaml` in the git repo, decrypted by the age key Flux
> already uses for all other SOPS secrets.

---

## Full Cluster Loss — Restore from Snapshot

### 1. Bootstrap Flux on the new cluster

Follow your standard cluster bootstrap procedure. Flux will deploy OpenBao
automatically. The pods will start but remain uninitialized.

### 2. Initialize OpenBao

OpenBao must be initialized before a snapshot can be restored. These recovery
keys will be discarded after the restore — use your **original** recovery keys
afterward.

```bash
kubectl exec -n openbao openbao-0 -- bao operator init
```

The cluster auto-unseals via the static seal key (mounted from the SOPS secret
by Flux). Pods 1 and 2 join the Raft cluster automatically via `retry_join`.

### 3. Download the latest snapshot from R2

```bash
# List snapshots newest-first
aws s3 ls s3://openbao-snapshots/snapshots/ \
  --endpoint-url "https://<CLOUDFLARE_ACCOUNT_ID>.r2.cloudflarestorage.com" \
  | sort -r | head -5

# Download the latest one
aws s3 cp \
  s3://openbao-snapshots/snapshots/<snapshot-file>.snap \
  ./openbao.snap \
  --endpoint-url "https://<CLOUDFLARE_ACCOUNT_ID>.r2.cloudflarestorage.com"
```

You need R2 credentials (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) from
Bitwarden (same `r2` entry the CronJob uses).

### 4. Copy the snapshot into the pod and restore

```bash
kubectl cp ./openbao.snap openbao/openbao-0:/tmp/openbao.snap

kubectl exec -n openbao openbao-0 -- \
  env BAO_TOKEN=<root-token-from-step-2> \
  bao operator raft snapshot restore -force /tmp/openbao.snap
```

The cluster restarts and loads data from the snapshot. It auto-unseals via the
static seal key (unchanged — same SOPS secret in git).

### 5. Verify with original recovery keys

The snapshot restore replaces all cluster data, including the root of trust.
The root token from step 2 is now invalid. Use your **original recovery keys**
to generate a new root token if needed:

```bash
kubectl exec -n openbao openbao-0 -- bao operator generate-root -init
# Then provide 3 of 5 original recovery keys, decode the result
```

---

## Partial Loss — Pod or Node Failure

No action required. The Raft cluster tolerates losing 1 of 3 nodes. When the
failed pod reschedules, it rejoins the Raft cluster via `retry_join` and
replicates data from the leader. Auto-unseal handles unsealing on restart.

If a pod comes back sealed (shouldn't happen with static seal but can occur
transiently), check that the `openbao-unseal` secret is present and the file
`/openbao/userconfig/openbao-unseal/current_key` is mounted in the pod.

---

## Seal Key Rotation

To rotate the static unseal key without downtime:

1. Generate a new key: `openssl rand -base64 32`
2. Edit `openbao-unseal.sops.yaml` — add `previous_key_id` / `previous_key`
   alongside the new `current_key_id` / `current_key`
3. Update `helmrelease.yaml` seal stanza with both key IDs
4. Re-encrypt: `sops -e -i kubernetes/apps/openbao/openbao/app/openbao-unseal.sops.yaml`
5. Push — Flux deploys the new secret and HelmRelease
6. Once all data is re-encrypted under the new key, remove the `previous_key`
   entries from both files
