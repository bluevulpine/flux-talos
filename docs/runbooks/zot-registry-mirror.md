# zot registry mirror (TrueNAS `vault`)

The cluster's pull-through image cache. Every node pulls through
**Spegel (peers) → zot on the NAS → upstream**. zot replaced the in-cluster Nexus on 2026-11-13.

| | |
|---|---|
| Endpoint | `http://10.0.10.11:5000/v2/<upstream>` (plain HTTP, anonymous read-only) |
| App | TrueNAS custom app `zot` ("Install via YAML"), defined in [`zot/compose.yaml`](zot/compose.yaml) |
| Storage | dataset `home/zot`, refquota 200 GiB, excluded from the recursive `home` snapshot task |
| Upstreams | docker.io, ghcr.io, quay.io, lscr.io, gcr.io, registry.k8s.io, public.ecr.aws, cgr.dev |
| Node config | `talos/patches/all/12-registry-mirrors.yaml.tpl` (`RegistryMirrorConfig` documents) |
| Metrics | ScrapeConfig `zot` (kube-prometheus-stack); `BootstrapRateLimitRisk` fires when it is absent |

## Why it is shaped this way

- **Why the NAS, not the cluster:** Nexus filled its PVC. Its blob-store compaction never ran
  (`Compacting [null]` on every run), cleanup removed nothing for 31 days, and 3.98 goes
  read-only after 30 days without telemetry. The mirror also has to serve while the cluster is
  down. A cold bootstrap is when Docker Hub's anonymous rate limit bites, and the old route needed
  the in-cluster gateway and its certificate.
- **Why plain HTTP to an IP:** nothing to resolve or renew during a bootstrap. zot allows anonymous
  `read` only, so nobody can push an image under a mirrored name, and containerd checks every blob
  against its digest.
- **Why no `skipFallback`:** if the NAS is down, nodes pull straight from the upstream.
  `BootstrapRateLimitRisk` is the signal that this is happening.
- **Why `home`, not the `tardis` pool:** `tardis` carries Time Machine's 11.5T quota on its
  root dataset, so a zot dataset there would eat into Time Machine's headroom. `home`'s 64K special
  vdev holds only small blobs (manifests and configs, ~184 MB at most); layers stay on HDD.
- **Why `http.compat: ["docker2s2"]`:** without it zot converts Docker images to OCI, which changes
  their digests, so every `@sha256:` pin in this repo would miss. `preserveDigest` is ignored in
  v2.1.x.
- **Why retention keeps the 3 most recently pulled tags and digests per repo, not just a 30-day
  window:** nodes keep running images and Spegel serves them, so a stable app may not touch zot for
  months. A pure age window would expire exactly what a cold bootstrap needs. `keepUntagged` matters
  because digest-only pulls cache untagged manifests.
- **Why `public.ecr.aws` has `reqPerSec: 1`:** ECR Public answered zot's anonymous request pattern
  with `429 TOOMANYREQUESTS`, so cold syncs stalled 20–40s or failed with 503 (2026-11-13).

## Changing the config

Edit [`zot/compose.yaml`](zot/compose.yaml) here first. Validate it, then paste it into
**Apps → zot → Edit**:

```bash
yq -r '.configs.zot-config.content' docs/runbooks/zot/compose.yaml > /tmp/zot.json
container run --rm -v /tmp:/cfg ghcr.io/project-zot/zot:<tag> verify /cfg/zot.json
```

The image is pinned by digest, and Renovate does not see this file. To bump it, take the release
from <https://github.com/project-zot/zot/releases>; the index digest comes from
`skopeo inspect --raw docker://ghcr.io/project-zot/zot:<tag> | sha256sum`.

## Verifying

```bash
curl -s http://10.0.10.11:5000/v2/ -o /dev/null -w '%{http_code}\n'          # 200
# A pull went through zot only if zot's per-repo counter for it moved:
curl -s http://10.0.10.11:5000/metrics | grep '^zot_http_repo_latency_seconds_count' | grep <repo>
# On a node, the merged chain: Spegel NodePort first, then zot with override_path = true
talosctl -n <ip> read /etc/cri/conf.d/hosts/docker.io/hosts.toml
```

A pull that *succeeds* proves nothing about zot: Spegel or the upstream fallback may have served
it. Test with an image no node has, and check zot's counter.

## Changing the node mirror list

Talos regenerates `/etc/cri/conf.d/hosts` on a live config change, wiping Spegel's merged files
and its `_backup/` (observed 2026-11-13, Talos 1.13.11). After an apply (`--mode no-reboot`
works; the dry run says "Applied configuration without a reboot"), nodes pull containerd → zot
directly until Spegel restarts:

```bash
just talos apply-all --mode no-reboot
kubectl --context admin@home-kubernetes -n kube-system rollout restart ds/spegel
```

Spegel only takes `_backup/` on first run and re-merges from it on every later restart. So if a
node ever shows a stale `_backup/` (old endpoints come back after a Spegel restart), the hosts
directory was not regenerated: re-apply that node's config, then restart its Spegel pod.

A registry must be in both the template and `spegel.mirroredRegistries`. A registry Spegel does not
list loses its zot entry when Spegel moves the Talos files into `_backup/`.

## Retention follow-up

The config ships with `retention.dryRun: true`. After a gc pass (`gcInterval` 6h), read zot's
retention log lines. Nothing pulled in the last 30 days should be listed for removal; in
particular, no digest-pinned untagged manifest. Then set `dryRun: false`, paste the file again,
and update this section.

`keepUntagged` needs zot's metadata DB. If it is missing, zot silently falls back to deleting
untagged manifests after `delay`. That alone is reason to keep the dry run until the log has been
read.
