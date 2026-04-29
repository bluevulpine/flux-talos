# Spegel

[Spegel](https://github.com/spegel-org/spegel) is a stateless, peer-to-peer OCI registry mirror. Each node can serve image layers it has already pulled to other nodes in the cluster, avoiding redundant downloads from upstream.

## Mirror Chain

This cluster has a Nexus pull-through cache configured in the Talos node registries. Spegel is deployed with `prependExisting: true`, which inserts itself in front of the existing Nexus mirror configuration. The result is a three-tier chain:

```
Pull request → Spegel (local cluster peers) → Nexus (pull-through cache) → Upstream registry
```

This means a layer only leaves the cluster network if no peer has it *and* Nexus doesn't have it cached.

## Why not just Nexus?

Nexus reduces upstream bandwidth but still requires a round-trip to the Nexus host for every node that needs an image. Spegel allows nodes to serve each other directly over the node subnet, which is useful during rolling restarts or upgrades where many nodes pull the same image in a short window.
