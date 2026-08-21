# Handoff: rackpanel Phase 3 — alerts

**Date:** 2026-08-21
**Status:** Handoff brief. Read this, then the spec, then start.
**Spec:** `docs/superpowers/specs/2026-08-18-rackpanel-design.md` (alert tiers, line ~289)
**Previous brief:** `docs/briefs/2026-08-20-rackpanel-phase1-remaining-scenes.md`
**Source repo:** `~/Repositories/rackpanel` (Gitea, Drone-built). Manifests live in `flux-talos`.

## Where the project actually is

**Phases 1 and 2 are complete.** Four Pis, four panels, sub-millisecond sync, and
all **eight** base scenes the spec designed are live in rotation:

| Order | Scene | Order | Scene |
| --- | --- | --- | --- |
| 10 | `IDENTITY` | 50 | `NETWORK` |
| 20 | `CLOCK` | 60 | `GITOPS` |
| 30 | `FLEET` | 70 | `WORKLOADS` |
| 40 | `STORAGE` | 80 | `TRIVIA` |

Orders leave gaps of 10 so a new scene slots in without renumbering. 233 tests.
Running image at time of writing: `rackpanel:11-2b495c72`.

Phase 3 is the alert work: an `alertmanager` provider, an `ALERTS` scene,
selector pin/demote logic, and severity palette overrides.

## ⚠️ Read this before designing anything

**A `critical` alert is firing 96.7% of the time.** Measured over 30 days at
10-minute resolution: 4178 of 4321 samples had at least one critical firing.
Warnings: 88.8%. Excluding the noisy Kia collector alerts changes it to 96.4%,
so it is not one bad rule.

This breaks the spec's central premise about conditional scenes:

> "scenes that appear only when something is happening stay interesting for
> years, and are the reason a glance becomes a stop"

Something is *always* happening. Implemented literally, `ALERTS` becomes a
permanent ninth scene and `INCIDENT` pins the rack forever.

**The spec's "critical pins until resolved" is therefore unimplementable as
written**, and the operator override recorded in the previous brief (pin ~10
minutes, then demote into rotation) was the right call. But note the *reason*
given there was wrong — see Corrections below.

What the 30-day estate actually looks like:

| % of 30d firing | severity | alertname |
| --- | --- | --- |
| 54.7% | critical | `ZfsUnexpectedPoolState` |
| 40.8% | critical | `VolSyncVolumeOutOfSync` |
| 40.8% | warning | `ContainerMemoryNearLimit` |
| 38.1% | warning | `VolSyncMoverStuck` |
| 37.5% | warning | `KubeContainerWaiting` |
| 33.0% | warning | `KubeStatefulSetUpdateNotRolledOut` |
| 28.5% | warning | `KubeJobNotCompleted` |
| 26.4% | critical | `BootstrapRateLimitRisk` |
| 22.9% | warning | `NodeSystemdServiceFailed` |

11 distinct critical alertnames fired in 30 days, 20 warning, 2 `none`, 1 `info`.

**Do not conclude "chronic == false positive".** `ZfsUnexpectedPoolState`, the
single biggest contributor, was a **genuinely degraded pool**: `pinas` pool
`apps` sat in `degraded` from **2026-07-31 to 2026-08-16**, 16 continuous days,
and has since cleared. That is exactly what you *want* on a wall panel. The
design problem is not "filter out the noise", it is "distinguish a 16-day real
incident from a rule that never clears" — and both look identical to a
predicate that only asks "is anything firing right now".

The open design question this leaves, which is genuinely undecided:
**what earns a pin?** Candidates worth weighing rather than assuming:
- alerts whose `startsAt` is recent (new since the last poll) — treats change as
  the signal rather than state
- an explicit acknowledged/expected set in config, which has to be maintained
- rank by recency and show the newest N, never pinning at all

Pick one, write the reasoning in a comment, and say so in the commit.

## Data availability — surveyed live 2026-08-21, do not re-derive

**Endpoint:** `kube-prometheus-stack-alertmanager.observability.svc:9093`,
`/api/v2/alerts`. Port-forward with
`kubectl port-forward -n observability svc/kube-prometheus-stack-alertmanager 9093:9093`.

Per-alert JSON keys: `annotations`, `endsAt`, `fingerprint`, `generatorURL`,
`labels`, `receivers`, `startsAt`, `status`, `updatedAt`.
Label keys present: `alertname`, `cluster`, `instance`, `job`, `prometheus`, `severity`.

Two things in that payload will bite if ignored:

1. **`status` is an object, not a string:**
   `{"state": "active", "silencedBy": [], "inhibitedBy": [], "mutedBy": []}`.
   A silenced or inhibited alert still appears in the response. If the scene
   does not check those arrays, silencing an alert in the UI will not stop it
   pinning the rack — which is precisely what someone silencing it is trying to
   achieve.

2. **`Watchdog` fires permanently, with `severity: none`.** It is the
   dead-man's switch and firing is its healthy state. The spec's tier table
   only covers `critical`/`warning`/`info`, so `none` is an unhandled case.
   Filter Watchdog explicitly, or `ALERTS` is eligible 100% of the time before
   you even reach the 96.7% problem.

Live sample at the time of writing (4 alerts):

```
warning   KubeClientCertificateExpiration     active  since 2026-08-20T16:21:53
critical  ChargepointPasswordLoginBlocked     active  since 2026-08-21T04:23:20
none      Watchdog                            active  since 2026-08-16T05:14:46
warning   KubeStatefulSetUpdateNotRolledOut   active  since 2026-08-20T16:30:48
```

`KubeClientCertificateExpiration` is a known ~6-month self-renewing cert that
fires for about a week every cycle — see the memory of the same name, and do not
treat it as a fault.

The `ALERTS` PromQL series in Thanos is a usable cross-check for history
(`ALERTS{alertstate="firing"}`), but Alertmanager is the source of truth for
silences, which the metric does not carry.

## Corrections to the previous brief

The Phase 1 brief justified the pin override like this:

> `VolSyncVolumeOutOfSync` has been critical continuously since at least
> 2026-08-16, so "pin until resolved" would have frozen the rack for days.
> `sum(volsync_volume_out_of_sync)` is still **2** as of this writing.

**The conclusion was right; the evidence was wrong.** Verified 2026-08-21:

- The Syncthing exclusion has been in the alert rule since commit `0904f74d`
  (`volsync_volume_out_of_sync{method!="syncthing"} == 1`), so Syncthing was
  never the cause of those firings.
- The actual 7-day firings were `method="kopia"` — `games/valheim-local` and
  `productivity/mealie-local`, both **real faults**.
- `valheim-local` was wedged from 2026-08-18 by the tns-csi non-idempotent
  `CreateVolume` bug: the dataset `apps/tns-csi/nvmeof/pvc-902dcdef-…` had been
  destroyed while the PV was still `Bound`, so the mount timed out
  (`MountVolume.MountDevice … DeadlineExceeded`). Cleared 2026-08-20; a full
  scheduled cycle since then ran clean in 1m19s.
- Both are now resolved. `sum(volsync_volume_out_of_sync{method!="syncthing"})`
  is **0** across 117 kopia volumes.

So the override should be re-decided on the 96.7% figure above, which is a much
stronger argument, rather than inherited from a fixed bug.

Operator ruling recorded 2026-08-21, worth keeping: Syncthing movers
"will never be 'finished' because syncthing is a perpetual task like dropbox…
should be resolved as expected, and probably treated by alerting as normal
instead of exceptional."

## Architecture you need to know

```
src/rackpanel/
  providers/{clock,kube,thanos}.py   fetch() -> dict, polled on independent intervals
  scenes/*.py                        render_tile(index, ctx) -> 160x80 PIL Image
  scenes/__init__.py                 Scene protocol, SceneContext, TILES_PER_SCENE = 4
  queries.py                         ALL_QUERIES + LABELLED_QUERIES + RANGE_QUERIES
  render.py                          draw_label/hero/support/bar/sparkline, fit()
  palette.py                         DAY / NIGHT, select_palette(hour, severity)
  selector.py                        rotation, dwell, newly-eligible queue jumping
  conductor.py                       one render pass -> 4 tiles -> ETag + display_at
```

A provider is `name`, `interval`, `fetch() -> dict`. Register it in
`__main__.py:build_conductor`. `ctx.data("<name>")` returns `{}` when a provider
has not reported — never `None` — and `ctx.is_stale(name)` drives the staleness
dot.

`select_palette(hour, severity)` **already accepts a severity override** and
already implements "critical outranks the clock". Phase 3 wires it up; it does
not need writing.

`SceneSelector` already has the newly-eligible queue-jump the spec asked for
(`_pending`), and already rejects duplicate scene keys. Pin/demote is the new
part. Note `seconds_until_next()` is an estimate against a fixed epoch grid and
a queue-jumping scene can change sooner — fine for the rackview diagnostic line,
but do not build pin timing on it.

### Rules that are load-bearing

1. **Tile budget: one label, one hero number, one supporting line.** If a scene
   needs more than four facts, it is two scenes.
2. **Never blank a tile and never render an error string.** A failed provider
   renders the last known value plus a staleness dot, checked against *the
   provider that tile actually reads*.
3. **Validate every query against live Thanos before committing** — by importing
   `ALL_QUERIES`/`LABELLED_QUERIES` and firing those exact strings, not by
   retyping them into a shell. That is how a single-backslash regex survived
   review once.
4. **PromQL string literals need doubled backslashes** in Python source (`\\.`).
5. **`CLUSTER_ONLY` exists because `job="node-exporter"` also scrapes `chronos`
   and `pinas`, which are NOT cluster nodes.**

### Query traps this module keeps re-learning

All four shipped as real bugs. The fourth was found *after* deploying, by
looking at the panel:

- A bare `max()`/`sum()` **drops every label**, so a tile that names something
  needs `topk(1, max by (label) (...))` and a `LABELLED_QUERIES` entry.
- `topk(1, ...)` over an **all-zero series still returns a series**, so "most
  restarted pod" names an innocent pod on a healthy cluster. Filter `> 0`.
- `p.crit if x else p.ok` collapses **`None` into the OK branch**, painting a
  no-data `--` in the "all good" colour. Unknown is a *third* state. This
  matters more in Phase 3 than anywhere else: an alert provider that fails must
  not render as "no alerts".
- **Label churn inflates counts.** `flux_resource_info` carries `revision`,
  `ready` and `reason` as labels, so a reconcile emits a new series while the
  old sits in the staleness window and `count()` adds both. The panel showed
  `128/154 Kustomizations, 27 NOT READY` against a clean `kubectl` 134/134;
  `ks_total` hit exactly 268 (2 × 134). Fix is `count(count by (uid) (...))`.
  **Alertmanager has the same shape** — `fingerprint` is the stable identity;
  `status`, `updatedAt` and `endsAt` all churn.

### Golden-image tests

`tests/conftest.py` provides `assert_golden(img, name)`. On mismatch it writes
`<name>.actual.png` beside the reference.

```bash
.venv/bin/pytest -q                              # verify
RACKPANEL_UPDATE_GOLDEN=1 .venv/bin/pytest -q    # regenerate, AFTER eyeballing
```

**Look at the render before regenerating.** Compose a contact sheet at 3× with
`Image.NEAREST` and actually view it. Five defects shipped past a green suite in
the Phase 1 session and **not one was findable by testing** — two text
overflows past the tile edge, two unknown-painted-as-healthy, and the count
inflation above. Three were caught by eyeballing goldens, one only by looking at
the deployed panel.

`render.fit(text, max_width)` exists for truncation and measures with the same
layout-pinned font used for drawing — use it for alert names, which are long.
Measure hero widths rather than guessing: at `HERO_SIZE` bold, 8 characters
render 167px against 148px of usable tile.

⚠️ **Do not unpin the font layout engine.** `render.py` pins
`ImageFont.Layout.BASIC` because Pillow silently uses Raqm when libraqm is
present and BASIC when not — macOS wheels ship Raqm, manylinux wheels do not.
Identical code rendered different pixels and every golden failed in CI while
passing locally.

## Phase 3 scope

- `alertmanager` provider — `/api/v2/alerts`, 10 s interval per the spec's
  provider table. Respect `silencedBy`/`inhibitedBy`/`mutedBy`. Exclude
  `Watchdog`. Handle `severity: none`.
- `ALERTS` scene — conditional. Free orders are 90+, or 40-gaps if it should
  interleave.
- Selector pin/demote — pin state keys on the alert's `startsAt`, so a conductor
  restart does not re-pin an old alert.
- Severity palette overrides — `select_palette` already supports this.
- Red border for a pinned critical. There is no border primitive in `render.py`
  yet; it needs adding, and it is the one piece of chrome that breaks the
  one-label-one-hero-one-support budget by design.

## Working notes

- Push to `main` in the rackpanel repo → Drone builds → Flux image automation
  bumps the conductor → Deployment rolls. **4–8 minutes end to end**, measured
  repeatedly.
- **Do not verify during the rollout.** Confirm the pod's image first; the old
  pod serves until the new one is Ready.
- Verify tiles by port-forwarding `svc/rackpanel-app` (note `-app`; the Service
  name is derived by app-template and is **not** `rackpanel`) and fetching
  `/tile/<node>.png`. Capturing the real PNGs from the running conductor is what
  caught the count-inflation bug — do it.
- `/status` returns compact JSON — `{"scene":"FLEET"}` with no space. Parse it,
  do not grep.
- Pushing to `flux-talos` often needs a rebase first: Flux image automation
  writes `chore(images): update …` commits to `main`.
- Sparklines on `STORAGE` reach a full 14-day window on **2026-09-03**; below
  `MIN_TREND_POINTS` those tiles render a text fact instead and upgrade
  themselves. Both states are pinned as goldens.
- The rack is in a basement on the way to the laundry. The bar is: looks good,
  answers "is anything broken?" in two seconds, occasionally interesting enough
  to stop and read.
