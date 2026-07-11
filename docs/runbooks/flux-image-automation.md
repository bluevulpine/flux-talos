# Reference: Flux image automation (the working pattern)

How this repo auto-updates first-party (Drone-built, Gitea-hosted) image tags,
and the two mistakes that silently break it. Born from a 14h `kia-collector`
outage on 2026-07-11.

## The three objects (one set per app, all in `kubernetes/apps/flux-system/<app>/app/`)

| Object | Job |
| --- | --- |
| `ImageRepository` | scans the registry for tags (`interval: 5m`), auth via `gitea-registry-creds` |
| `ImagePolicy` | picks the "latest" tag. Drone tags are `<build>-<sha8>`; we extract the build number and sort numerically: `pattern: '^(?P<num>[0-9]+)-[0-9a-f]{8}$'`, `extract: '$num'` |
| `ImageUpdateAutomation` | writes the selected tag back into the manifest (via a `$imagepolicy` marker) and pushes to `main` |

The app manifest carries the marker comment; Flux edits the marked node in place.

## Gotcha 1 — the marker suffix must match the node it sits on

Flux's `Setters` strategy replaces the **value of the node the marker is on** with
whatever the marker names:

- `{"$imagepolicy": "flux-system:<app>"}` → writes the **full `name:tag`** ref.
- `{"$imagepolicy": "flux-system:<app>:tag"}` → writes **only the tag**.

So the suffix depends on the YAML shape:

```yaml
# Combined scalar → NO :tag suffix (marker writes the whole ref)
image: gitea.derekjacobs.dev/bluevulpine/kia-collector:7-d604471f # {"$imagepolicy": "flux-system:kia-collector"}

# Dedicated tag: field → :tag suffix (marker writes just the tag)
image:
  repository: gitea.derekjacobs.dev/bluevulpine/helium-archiver
  tag: 2-c8294d3e # {"$imagepolicy": "flux-system:helium-archiver:tag"}
```

**The failure mode:** `:tag` on a *combined* `image: repo:tag` scalar overwrites
the entire scalar with the bare tag (`6-ad58c5df`). The kubelet then resolves it
as `docker.io/library/6-ad58c5df` → `ImagePullBackOff`. This is silent for hours
(see Gotcha 3).

## Gotcha 2 — scope each automation's `update.path` to its own app

`Setters` rewrites **every** `$imagepolicy` marker found under `update.path`. An
automation with `update.path: ./kubernetes` (the whole repo) therefore drives
*all* apps' markers, not just its own — which is how the blog automation kept
re-mangling kia's broken marker even before kia had an automation of its own.

**Rule: one `ImageUpdateAutomation` per app, `update.path` scoped to that app's
directory.** No overlap, explicit ownership.

```yaml
update:
  path: ./kubernetes/apps/home/kia-collector   # this app only
  strategy: Setters
```

## Gotcha 3 — `ImagePullBackOff` does not fire the job/pod failure alert

A CronJob whose image can't be pulled never *runs*, so `kube_job_status_failed`
stays `0` — a plain job-failure alert misses it entirely. `kia-collector` now
also has `KiaCollectorImagePullFailing`
(`kube_pod_container_status_waiting_reason{...reason="ImagePullBackOff"}`) and a
`KiaCollectorStale` catch-all. Copy that pattern for any automated workload.

## Gotcha 4 — Grafana/JSON `${...}` vs Flux postBuild envsubst

If a ConfigMap containing `${...}` (e.g. a Grafana dashboard's `${vin}`) lives in
a Kustomization with `postBuild.substitute*` in **strict** mode, Flux reads those
as unset variables and fails the whole apply. Escape them as `$$` in the file so
Flux emits a literal `$` (or store the JSON outside an envsubst-enabled path).

## Diagnose

```bash
# What tag did the policy pick, and is it applied?
flux get image policy <app> -n flux-system
kubectl get cronjob/<app> -n home -o jsonpath='{..containers[0].image}'

# Did an automation push a bad revert? Look for chore(images) commits.
git log --oneline -5 -- kubernetes/apps/<ns>/<app>

# Coverage audit: every marker should have exactly one owning automation.
grep -rn '$imagepolicy' kubernetes/
grep -rl 'kind: ImageUpdateAutomation' kubernetes/ | xargs grep -H 'path:'
```

## Reference implementations

- **Combined `image:` scalar** (no `:tag`): `kubernetes/apps/home/kia-collector/`
- **Dedicated `tag:` field** (`:tag`): `kubernetes/apps/default/bluevulpine-blog/`,
  `kubernetes/apps/home/helium-archiver/`
