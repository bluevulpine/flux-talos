I have, unfortunately, more than once brought the control plane etcd out of quorum. Usually by deleting too many CP nodes at once. 6 => 3 was an issue, as I should have let it re-establish voting state with 4 before downsizing to 3.

Talos' disaster recovery guide has helped fix it by extracting an etcd database clone from the leaderless cluster, blowing away etcd and standing it back up. It's able to self repair from there but it's not a proper snapshot, and in worse cases, may not be restorable.

This cronJob will instead have a properly snapshotted etcd image uploaded away from the cluster. Retention is 30 days, which should be plenty of time to realize an issue and restore the cluster control plane.

## Retention is enforced by this job, not by the bucket

The snapshot runs every 6 hours (4/day), and a second container in the same Job prunes to the **120 most recent** objects — 30 days' worth. If you change `spec.schedule`, change the `tail -n +121` in `cronjob.yaml` to match (`keep + 1`).

This used to be a bucket-side S3 lifecycle rule, and on 2026-08-27 it was found never to have worked after the backend moved from R2 to Garage: **no lifecycle configuration existed on any Garage bucket**, so every snapshot ever taken was still there — 975 objects / 443 GiB back to 2025-12-27, none ever deleted. Garage v2.3.0 does support lifecycle rules, so a bucket rule would work; it is deliberately not used, because bucket-side state is invisible to git and that is exactly how this regressed unnoticed for eight months. Garage also exposes no per-bucket object-count metric, so there is nothing to alert on — a job that fails loudly is the only detectable option.

**Verification:** after any change here, confirm the object count actually falls.

```bash
aws --endpoint-url http://vault.funb.us:30188 --region us-east-1   s3 ls s3://talos/backups/ | wc -l   # expect <= 120
```

