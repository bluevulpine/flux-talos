I have, unfortunately, more than once brought the control plane etcd out of quorum. Usually by deleting too many CP nodes at once. 6 => 3 was an issue, as I should have let it re-establish voting state with 4 before downsizing to 3.

Talos' disaster recovery guide has helped fix it by extracting an etcd database clone from the leaderless cluster, blowing away etcd and standing it back up. It's able to self repair from there but it's not a proper snapshot, and in worse cases, may not be restorable.

This cronJob will instead have a properly snapshotted etcd image uploaded away from the cluster. Snapshots are taken hourly and kept in two places:

| where | job | retention |
| --- | --- | --- |
| Garage `talos/backups` (on vault) | `talos-s3-backup` | 168 hourly = 7 days |
| R2 `talos-etcd/hourly` (off vault) | `talos-offsite` | 48 hourly = 2 days |
| R2 `talos-etcd/daily` (off vault) | `talos-offsite` | 30 daily = 30 days |

The R2 copy exists because the control plane is moving onto a VM on vault (`docs/runbooks/controlplane-migration-to-vault-vm.md`): a backup on the same host as the thing it backs up is no backup. `talos-offsite` copies the already-encrypted objects rather than taking a second snapshot. Once the pinas is up, the hourly off-vault copy moves there and R2 keeps the dailies.

## Retention is enforced by this job, not by the bucket

The snapshot runs hourly, and a second container in the same Job prunes to the **168 most recent** objects — 7 days' worth. If you change `spec.schedule`, change the `tail -n +169` in `cronjob.yaml` to match (`keep + 1`). This bit once already in planning: the schedule used to be 6-hourly with a count of 120, and changing the schedule alone would have silently cut 30 days to 5.

`talos-offsite` prunes R2 the same way (`tail -n +49` / `+31` in `offsite-cronjob.yaml`).

This used to be a bucket-side S3 lifecycle rule, and on 2026-08-27 it was found never to have worked after the backend moved from R2 to Garage: **no lifecycle configuration existed on any Garage bucket**, so every snapshot ever taken was still there — 975 objects / 443 GiB back to 2025-12-27, none ever deleted. Garage v2.3.0 does support lifecycle rules, so a bucket rule would work; it is deliberately not used, because bucket-side state is invisible to git and that is exactly how this regressed unnoticed for eight months. Garage also exposes no per-bucket object-count metric, so there is nothing to alert on — a job that fails loudly is the only detectable option.

**Verification:** after any change here, confirm the object count actually falls.

```bash
aws --endpoint-url http://vault.funb.us:30188 --region us-east-1   s3 ls s3://talos/backups/ | wc -l   # expect <= 168
```


## Restoring from the off-vault copy

Snapshots are age-encrypted to the repo's sops key (`age.key`, recipient `age1ww3u…9t5dem`).

```bash
rclone copyto r2:talos-etcd/hourly/<newest>.snap.age ./etcd.snap.age   # or daily/
age -d -i age.key -o etcd.snap etcd.snap.age
etcdutl snapshot status etcd.snap -w table                            # hash, revision, keys, size
talosctl -n <cp-ip> bootstrap --recover-from=./etcd.snap
```
