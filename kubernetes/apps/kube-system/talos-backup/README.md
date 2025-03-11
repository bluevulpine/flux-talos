I have, unfortunately, more than once brought the control plane etcd out of quorum. Usually by deleting too many CP nodes at once. 6 => 3 was an issue, as I should have let it re-establish voting state with 4 before downsizing to 3.

Talos' disaster recovery guide has helped fix it by extracting an etcd database clone from the leaderless cluster, blowing away etcd and standing it back up. It's able to self repair from there but it's not a proper snapshot, and in worse cases, may not be restorable.

This cronJob will instead have a properly snapshotted etcd image uploaded away from the cluster. The bucket has a retention of 7 days which in theory should be plenty of time to realize an issue and restore the cluster control plane.
