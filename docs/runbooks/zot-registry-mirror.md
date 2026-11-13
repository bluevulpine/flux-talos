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
  with `429 TOOMANYREQUESTS`, so cold syncs stalled 20–40s or failed with 503 (2026-11-13). With
  the cap, 4 cold ECR syncs took 2–3s with no 429 logged; a small sample, not a load test.

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

## Retention

Retention is live (`dryRun: false`) from 2026-11-13, after one dry-run gc pass. Its log lines
(`"module":"retention"`) evaluated both the tagged and the untagged policy on the repos that
pass reached (`cgr.dev/chainguard/static`, `docker.io/alpine/socat`) and decided `keep`,
"retained by pushedWithin". The untagged policy only evaluates with zot's metadata DB, and
without that DB zot would delete untagged manifests after `delay` regardless of
`keepUntagged`, so those lines are the evidence the DB works.

What the dry run could not show: the clauses that keep old images, `pulledWithin` and
`mostRecentlyPulledCount`. Both rely on zot recording pull timestamps, which is untested here
(the search extension that exposes them over GraphQL is not enabled). Until about 2026-12-13
nothing is older than 30 days, so `pushedWithin` protects everything and turning deletion on
early is harmless. After that date, read the retention log and check that removals are only
images nobody has pulled in 30 days and outside their repo's 3 most recently pulled.

A wrong removal costs an upstream fetch on the next pull. That matters most in a cold bootstrap,
when it becomes the rate-limited pull this mirror exists to prevent, and a digest that upstream
has since pruned cannot be fetched again.

Warnings "skipping missing manifest blob" (sync and GC) are expected: on-demand sync stores an
image index without its per-platform manifests, which sync on first request.
