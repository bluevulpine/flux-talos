# Longhorn

Longhorn provides replicated block storage for workloads that need data to survive a node failure. It replicates PVC data across multiple nodes.

## When to use Longhorn vs OpenEBS vs TrueNAS

| Storage Class        | Driver    | Replicated  | Access Mode | Use When                                     |
|----------------------|-----------|-------------|-------------|----------------------------------------------|
| `longhorn`           | Longhorn  | Yes         | RWO         | Stateful apps that need HA (databases, auth) |
| `longhorn-1-replica` | Longhorn  | 1 replica   | RWO         | VolSync caches, low-priority block storage   |
| `openebs-hostpath`   | OpenEBS   | No          | RWO         | Non-critical or dev workloads (fast, local)  |
| `tns-csi-nfs`        | tns-csi   | No (NFS)    | RWX         | Shared access, media libraries               |
| `tns-csi-iscsi`      | tns-csi   | No (block)  | RWO         | High-throughput block workloads, game saves  |
| `tns-csi-nvmeof`     | tns-csi   | No (block)  | RWO         | High-performance block (NVMe-oF/TCP)         |

Longhorn is the choice for anything where losing a node shouldn't lose the data: Vaultwarden, Authentik, CouchDB, InfluxDB, Grocy, etc.
