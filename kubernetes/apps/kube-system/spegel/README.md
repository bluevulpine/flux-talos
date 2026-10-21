# Spegel

[Spegel](https://github.com/spegel-org/spegel) is a stateless, peer-to-peer OCI registry mirror. Each node can serve image layers it has already pulled to other nodes in the cluster, avoiding redundant downloads from upstream.

## Mirror Chain

This cluster has a Nexus pull-through cache configured in the Talos node registries. Spegel is deployed with `prependExisting: true`, which inserts itself in front of the existing Nexus mirror configuration. The result is a three-tier chain:

```
Pull request → Spegel (local cluster peers) → Nexus (pull-through cache) → Upstream registry
```

This means a layer only leaves the cluster network if no peer has it *and* Nexus doesn't have it cached.

**The chain only exists for registries listed in `spegel.mirroredRegistries`.** `prependExisting` merges Spegel's hosts with the Talos-written Nexus `hosts.toml` one registry at a time. With an empty list (the chart default) Spegel writes a single `_default/hosts.toml` and moves the Talos files to `/etc/cri/conf.d/hosts/_backup/`, where containerd never reads them. That ran unnoticed until 2026-10-20: every pull went Spegel → upstream, and the Nexus hosts' broken TLS (no `*.nexus.` SAN, fixed in #2213) never surfaced. When a workload starts pulling from a new registry, add it to the list. Check a node with `talosctl -n <ip> read /etc/cri/conf.d/hosts/ghcr.io/hosts.toml`, which should show the Spegel NodePort followed by the Nexus host.

Spegel only backs up the Talos files on its first run (when `_backup/` does not exist yet). If the Talos mirror patch changes later, the backup is stale until `_backup/` is removed and the Spegel pods restart.

Registries without a Nexus repository (`oci.element.io`, `cr.fluentbit.io`, `mirror.gcr.io`, the Gitea registry) are listed too, so they at least get peer-to-peer sharing. Spegel serves any cached layer to anything that can reach its NodePort, including layers of private Gitea images.

## Dashboard

Chart 0.8.0 no longer ships a Grafana dashboard. `app/spegel-dashboard.json` is the 0.7.4 chart's dashboard, adapted to 0.8's metrics: `spegel_advertised_keys` replaced `spegel_advertised_{content,image}_digests`, and the registry variable now comes from `spegel_mirror_requests_total`. The grafana.com dashboard 18089 that Grafana also loaded was removed, because it only ever had revision 1 and queried metrics Spegel no longer exports.

## Why not just Nexus?

Nexus reduces upstream bandwidth but still requires a round-trip to the Nexus host for every node that needs an image. Spegel allows nodes to serve each other directly over the node subnet, which is useful during rolling restarts or upgrades where many nodes pull the same image in a short window.
