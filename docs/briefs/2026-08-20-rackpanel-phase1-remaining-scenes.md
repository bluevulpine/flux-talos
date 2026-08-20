# Handoff: rackpanel Phase 1 — the five missing scenes

**Date:** 2026-08-20
**Status:** Handoff brief. Read this, then the spec, then start.
**Spec:** `docs/superpowers/specs/2026-08-18-rackpanel-design.md` (scene inventory)
**Source repo:** `~/Repositories/rackpanel` (Gitea, Drone-built). Manifests live in `flux-talos`.

## Where the project actually is

Phase 2 (the panel-agent) is complete and live: four Pis, four panels, sub-millisecond
sync, ~2.3 s full sweeps. **Phase 1 is not.** The spec designs **eight** base scenes;
three exist.

| Built | Missing — this brief |
| --- | --- |
| `FLEET`, `CLOCK`, `IDENTITY` | `STORAGE`, `NETWORK`, `GITOPS`, `WORKLOADS`, `TRIVIA` |

The rotation is currently a 3-scene loop where the design called for 8 base + 3
conditional. That short loop is also why `CLOCK`'s tiles 2–3 (`CLUSTER`, `RACK`) are
weak filler — `CLUSTER` duplicates `IDENTITY` tile 3 and `FLEET` tile 0, and `RACK` is
the hardcoded string `"4 pi · 3 amd64"`. **Both are fair game to repurpose** once real
scenes exist.

## Data availability — surveyed live 2026-08-20, do not re-derive

This is the part that would otherwise cost an hour. Two entries change the plan.

| Scene needs | Metric | Status |
| --- | --- | --- |
| Flux readiness | **`flux_resource_info{kind,ready}`** | ✅ **exists** — note the name is `flux_*`, **not** `gotk_*`. The `gotk_*` family is only controller internals (reconcile duration, HTTP, cache) and carries **no** readiness. Live: Kustomization 132 ready / 1 Unknown, HelmRelease 103 ready. |
| BGP to UniFi | **`cilium_bgp_control_plane_session_state`** | ✅ exists — 7 sessions, labels `node`, `neighbor` (`10.0.10.1:179`), `vrouter` (`65512`) |
| CoreDNS | `coredns_dns_requests_total`, `coredns_cache_served_stale_total`, `coredns_cache_{hits,misses}_total` | ✅ exists (served_stale is what the spec asks for) |
| UniFi throughput | `unpoller_device_*` (182 metrics) | ✅ exists |
| VolSync | `volsync_volume_out_of_sync`, `volsync_sync_duration_seconds`, `volsync_missed_intervals_total`, `volsync_kopia_snapshot_creation_{success,failure}_total` | ✅ exists. Live: **`sum(volsync_volume_out_of_sync) = 2`** |
| TrueNAS pool fill | `truenas_*` (827 metrics) | ✅ exists |
| Pods / restarts / age | `kube_pod_status_phase`, `kube_pod_container_status_restarts_total`, `kube_pod_start_time`, `kube_pod_created` | ✅ exists |
| **Longhorn used/degraded** | `longhorn_*` | ❌ **ZERO metrics. Not scraped at all.** |

### ⚠️ Longhorn is not scraped — decide before building STORAGE

The spec's `STORAGE` tile 1 is "Longhorn used/degraded" and that data does not exist in
Prometheus. Options, in the order I'd consider them:

1. **Enable Longhorn's ServiceMonitor** — longhorn-manager exposes `longhorn_volume_*`
   and `longhorn_node_*`; it just is not being scraped. Probably a small addition
   alongside the existing kube-prometheus-stack config. **Check this first** — it is
   likely a few lines, and it benefits more than the panel.
2. **Read Longhorn CRs via the Kubernetes API** in a provider, as the conductor already
   does for nodes.
3. **Drop Longhorn from `STORAGE`** and build the tile from TrueNAS + VolSync, which are
   both available today.

Do not silently pick (3) because it is easiest — enabling the scrape is the option that
also improves the cluster, and Longhorn health matters beyond this display.

## Architecture you need to know

```
src/rackpanel/
  providers/{clock,kube,thanos}.py   fetch() -> dict, polled on independent intervals
  scenes/{clock,fleet,identity}.py   render_tile(index, ctx) -> 160x80 PIL Image
  scenes/__init__.py                 Scene protocol, SceneContext, TILES_PER_SCENE = 4
  queries.py                         ALL_QUERIES + LABELLED_QUERIES (PromQL catalogue)
  render.py                          draw_label / draw_hero / draw_support / draw_bar / draw_sparkline
  palette.py                         DAY / NIGHT, select_palette(hour, severity)
  selector.py                        which scene is showing
  conductor.py                       one render pass -> 4 tiles -> ETag + display_at
```

A scene is `key`, `order`, `eligible(ctx) -> bool`, `render_tile(index, ctx) -> Image`.
Register it wherever `FleetScene`/`ClockScene`/`IdentityScene` are wired (`__main__.py`).
`order` controls rotation position; existing values are IDENTITY 10, CLOCK 20, FLEET 30,
so leave gaps.

`ctx.data("thanos")` / `ctx.data("kube")` / `ctx.data("clock")` return `{}` when a
provider has not reported — never `None`. `ctx.is_stale(provider)` drives the staleness
dot.

### Rules that are load-bearing

1. **Tile budget: one label, one hero number, one supporting line.** A tile is a playing
   card, not a dashboard panel. If a scene needs more than four facts, it is two scenes.
2. **Never blank a tile and never render an error string.** A failed provider renders the
   last known value plus a staleness dot (see `fleet.py` — it checks staleness against
   *the provider that tile actually reads*, not a blanket check).
3. **Validate every query against live Thanos before committing.** This module's stated
   standard, and it has caught real bugs. Port-forward
   `svc/thanos-query-frontend -n observability 10902:10902`.
4. **A bare `max()` / `sum()` in PromQL discards every label.** This shipped as a real bug:
   the HOTTEST tile could only say "node_hwmon max" because the node name was aggregated
   away. If a tile needs to name something, use `topk(1, max by (label) (...))` and put the
   query in `LABELLED_QUERIES` — the provider emits both `<key>` and `<key>_<label>`.
   See `queries.py` for the worked example.
5. **PromQL string literals need doubled backslashes** in Python source (`\\.` not `\.`).
   Single-backslash survived review once; shell testing hides it. See `CLUSTER_ONLY`.
6. **`CLUSTER_ONLY` exists because `job="node-exporter"` also scrapes `chronos` and
   `pinas`, which are NOT cluster nodes.** Without it, "cluster CPU" silently included a
   NAS.

### Golden-image tests

`tests/conftest.py` provides `assert_golden(img, name)`. On mismatch it writes
`<name>.actual.png` next to the reference.

```bash
.venv/bin/pytest -q                              # verify
RACKPANEL_UPDATE_GOLDEN=1 .venv/bin/pytest -q    # regenerate, AFTER eyeballing the diff
```

**Look at the render before regenerating.** Compose a contact sheet and actually view it —
scale 3x with `Image.NEAREST`. Golden tests that get blind-regenerated are worse than no
tests.

⚠️ **Do not unpin the font layout engine.** `render.py` pins `ImageFont.Layout.BASIC`
because Pillow silently uses Raqm when libraqm is present and falls back to BASIC when it
is not — macOS wheels ship Raqm, manylinux wheels do not. Identical code rendered to
different pixels, and every golden failed in CI while passing locally.

## The five scenes (spec tile definitions)

| Scene | Four tiles |
| --- | --- |
| `STORAGE` | Longhorn used/degraded · TrueNAS pool fill · VolSync last run · 14 d capacity trend |
| `NETWORK` | BGP sessions to UniFi · cluster throughput · CoreDNS QPS + served_stale · WAN up/down |
| `GITOPS` | Kustomizations ready · HelmReleases ready · last commit author + subject · open Renovate PRs |
| `WORKLOADS` | pods by phase · restarts (1 h) · pending/crashloop · top CPU consumer |
| `TRIVIA` | days since last incident · longest-lived pod · most-restarted pod this week |

Notes on the harder tiles:

- **`GITOPS` last commit / open Renovate PRs** are not metrics. Either extend the kube
  provider to read the Flux `GitRepository` status (it carries the last-fetched revision)
  or query the GitHub API. The spec's provider table lists a `flux` provider at 30 s.
  Renovate PR count needs the GitHub API — consider deferring that tile rather than
  adding a credentialed dependency for one number.
- **`STORAGE` 14 d capacity trend** wants `draw_sparkline`, which exists and is untested
  against real range data. Thanos serves 14 d comfortably (raw 14 d / 5 m 30 d / 1 h 60 d).
  **Query Thanos, never Prometheus — Prometheus retains 2 days and truncates silently.**
- **`TRIVIA` days since last incident** needs a definition. Suggest: time since the last
  `critical` alert resolved, from `ALERTS`. Pick one and write it in a comment.
- **`NETWORK` WAN up/down** — check `unpoller_*` for a WAN/uplink series before assuming.

## After Phase 1 — a decision, not an instruction

When the five scenes are done, **stop and decide** rather than rolling straight on:

**Phase 3 (alerts)** is the next phase. Its design is settled and recorded — do not
re-litigate it:

- `critical` newly firing → **pins all four panels, red border, ~10 minutes**, then
  demotes into rotation as a recurring `ALERTS` scene. Pin state keys on the alert's
  `startsAt`, so a conductor restart does not re-pin an old alert.
- `warning` → `ALERTS` scene injected into rotation, amber accent.
- `info` → accent colour only.

The spec as written says a critical pins **until resolved**; that was **overridden by the
operator** on 2026-08-20 for a concrete reason: `VolSyncVolumeOutOfSync` has been critical
continuously since at least 2026-08-16, so "pin until resolved" would have frozen the rack
for days. `sum(volsync_volume_out_of_sync)` is still **2** as of this writing.

Phase 3 also needs a new `alertmanager` provider (`/api/v2/alerts`, 10 s), an `alerts`
scene, selector pin/demote logic, and severity palette overrides.

**Judge honestly whether to continue in the same context.** Five scenes is already a
substantial session. If context is heavy by then, say so and recommend a clean start
rather than producing weaker work on Phase 3 — that is what happened to *this* session,
and calling it early is cheaper than recovering from it. A fresh session for Phase 3 costs
one handoff brief; a degraded one costs a rewrite.

## Working notes

- Push to `main` in the rackpanel repo → Drone builds → Flux image automation bumps the
  conductor → Deployment rolls. Roughly 4–8 minutes end to end.
- **Do not verify during the rollout.** The old pod serves until the new one is Ready, and
  reading tiles mid-roll shows stale layout. Confirm the pod's image first.
- Verify tiles by port-forwarding `svc/rackpanel-app -n observability` (note: `-app`, the
  Service name is derived by app-template and is **not** `rackpanel`) and fetching
  `/tile/<node>.png`.
- `/status` returns compact JSON — `{"scene":"FLEET"}` with no space. Parse it, do not grep
  for `"scene": "FLEET"`.
- The rack is in a basement on the way to the laundry. The bar is: looks good, answers
  "is anything broken?" in two seconds, occasionally interesting enough to stop and read.
