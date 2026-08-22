# Handoff: minnkota-collector — archive utility demand-response state

**Date:** 2026-08-21
**Status:** Scoping brief. Reconnaissance done, nothing built. Read this, then start.
**Source repo:** `git@gitea.derekjacobs.dev:bluevulpine/minnkota-collector.git` (empty; created for this work)
**Closest reference implementation:** `~/Repositories/beestat-collector` + `kubernetes/apps/home/beestat-collector/`
**Related brief:** none. Related memory: `project-beestat-collector`, `reference-beestat-api`.

## Why this matters

The utility (Red Lake Electric, on the Minnkota demand-response programme) remotely
**disables the heat pump** during load-management events. When it does, the house
falls back to the **propane furnace** — the `auxiliary_heat_1` series already being
archived by `beestat-collector`.

That means today's `beestat` archive shows propane running with **no recorded reason**.
The `Balance point` panel on the *Beestat — Long-term Analysis* dashboard currently
reads aux runtime at 35–40 °F as if it were a thermostat lockout setting. Some of it
may instead be the utility having switched the heat pump off. **Without this data the
existing balance-point analysis is not just incomplete, it is potentially wrong.**

The user has never seen the heat pump disabled in cooling months; it starts once
temperatures drop. There is **no historical data** — the site only exposes a rolling
window — so every day not collected is lost permanently, exactly like the beestat
room-sensor problem.

## What the site actually is (verified 2026-08-21, do not re-derive)

`https://redlake.minnkotadr.com` is a **React SPA**. All three routes (`/`, `/detail`,
`/log`) return an identical 728-byte shell — there is nothing to scrape from the HTML.
The user's earlier scraper predates this rewrite and should be treated as dead.

The backing API is **`https://api.minnkotadr.com`**, discovered in
`/static/js/main.1b282323.js`. Endpoints found:

| Endpoint | Params | Notes |
| --- | --- | --- |
| `/api/Ripple/list` | `area`, `startDate=YYYY-MM-DD` | **the log** — one row per state change |
| `/api/Ripple/lastonoff` | `area`, `loadgroup` | per-DO `lastOn` / `lastOff` / `currentStatus` |
| `/api/Ripple/last` | `area` | single most recent row |
| `/api/Ripple/status` | — | plain text, returned `Ready` |
| `/api/Schedule/list` | — | Yellow/Red Zone shed schedule, `status`, `enabled` |
| `/api/Plan/list` | — | human-readable daily forecast message |
| `/api/SystemCondition` | — | `percentage` + `enabled` events |
| `/api/SystemCondition/weekwindow` | — | not probed |
| `/api/Coop/list` | — | co-op directory; **Red Lake is `coopId: 9`** |
| `/api/Status/list` | `area` | not probed |

**There is no authentication.** Every endpoint above returned HTTP 200 with no token,
cookie, or API key. It is an ASP.NET Core backend and returns RFC 9110 `ProblemDetails`
on validation errors, which conveniently **names the missing parameters** — use a
deliberate 400 to discover any endpoint's required params.

Valid `area` values are the subdomain slugs, listed verbatim in the bundle:
`cass, cavalier, cp, nodak, northstar, pkm, redlake, redriver, roseau, wildrice, nmpa`.

### `/api/Ripple/list` row shape

```json
{ "ac": "ALL", "coop": "Red River", "datetime": "260820T000000",
  "do": ["ON","---","---","---","---","---","---","ON","---","---","---","---","---","---","---","---"],
  "err": 0, "lg": "2.06", "name": "Ada" }
```

- `datetime` is **`YYMMDDTHHMMSS`**, not ISO 8601. Timezone is unstated — assume
  America/Chicago and **verify against a known switching event** before trusting it.
- `do` is a 16-element array mapping to **DO09..DO24**, values `ON` / `OFF` / `---`
  (`---` = not controlled for that load group).
- `lg` = load group (e.g. `2.06`), `name` = substation, `coop` = co-op name.
- A full day returned only **35 rows** — this is event-driven, not sampled. Volume is
  trivial; the whole problem is *not missing an event*.

## Which load groups are the user's — RESOLVED

The user's controlled loads, confirmed against live API state on 2026-08-21:

| Load group | DO | What it is | Evidence |
| --- | --- | --- | --- |
| **2.06** | **DO09** | **EVSE** | `currentStatus: OFF`, `lastOn 2026-08-21T00:00`, `lastOff 2026-08-21T10:01` — a nightly on/morning-off cycle is an off-peak charging window |
| **3.09** | **DO13** | **Heat pump** | `currentStatus: ON`, last cycled `2026-05-12` (end of heating season) and ON ever since — matches "never seen it disabled in cooling months" |

The user predicted, before these were queried, that the EVSE would read OFF and the
heat pump ON at that moment. Both matched. **These two series are the point of the
collector**; archive everything else if convenient, but these are what must not be missed.

Note `2.06 / DO16` moves in lockstep with `DO09` (identical on/off timestamps), so the
group has more than one controlled output. Do not assume one DO per group.

### About the `area` parameter — a red herring, but know why

`area=redlake` returns **byte-identical data to `area=cp`**, and every row is labelled
`"coop": "Red River"`, substation `"Ada"`. That looks alarming, as though the wrong
co-op's data is being fetched.

It is not a problem: **load groups are globally unique across the Minnkota ripple
system**, and 2.06/DO09 and 3.09/DO13 demonstrably reflect this house's own devices.
The `coop` and `name` fields evidently describe the transmitting substation rather than
the member being served.

The practical consequence: **filter on `lg`, never on `area`, `coop`, or `name`.**
Passing `area` at all appears optional. Do not build a filter on fields that are inert
or that describe something other than what they seem to.

## The other thing that must not be guessed

**The DO → load-name mapping is per load group, not global.** The bundle contains
several different mapping dictionaries, e.g.

```
{9:"Grain Dryers",10:"Pk Ind Light",11:"Water Heaters", ... 17:"Space Heat", ...}
{9:"Slab Heat", ... 19:"Water Heaters", 21:"Thermal Storage Heat", ...}
```

and elsewhere `"Dual Heat"`, `"Commercial"`, `"Comm, Direct Control"`, `"Test"`.
**`Dual Heat` is almost certainly the heat-pump/propane dual-fuel control** — the
signal this whole collector exists to capture. Extract the correct dictionary for the
user's load group from the bundle and **pin it in config**, do not hardcode DO09 = a
guess. Mislabelling here silently attributes propane burn to the wrong cause.

Note the bundle hash (`main.1b282323.js`) will change when they redeploy the SPA. Treat
the mapping as configuration to be re-verified, not as a constant.

## Scope

Build `minnkota-collector` on the same shape as `beestat-collector`:

- Source in the Gitea repo above, built by Drone with kaniko
  (copy `.drone.yml`, `Dockerfile`, `.dockerignore` from `beestat-collector` verbatim).
- Manifests at `kubernetes/apps/home/minnkota-collector/` (`app/` + `ks.yaml`), plus
  Flux image automation at `kubernetes/apps/flux-system/minnkota-collector/`.
- New InfluxDB bucket `minnkota`, infinite retention, org `homelab`. Buckets are **not**
  GitOps-managed here — create by `kubectl -n database exec` into the influxdb pod using
  the in-pod `$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN`, then `bao kv put` the generated tokens
  so they never enter a transcript. Add a matching read-only Grafana datasource
  (`influxdb-minnkota`) to the grafana HelmRelease + an `INFLUXDB_MINNKOTA_TOKEN` line in
  its ExternalSecret.
- **No OpenBao Kubernetes auth role is needed** — there is no API key and no state to
  write back, so ESO alone suffices and the pod should set
  `automountServiceAccountToken: false`.
- CronJob, `concurrencyPolicy: Forbid`, `ttlSecondsAfterFinished`, non-root,
  `readOnlyRootFilesystem`, drop ALL caps, resource requests/limits.
- `prometheusrule.yaml` in the shape of `beestat-collector`'s: job-failed,
  ImagePullBackOff (never marks a Job failed — caused a 14h outage once), CronJob
  last-success staleness, **and a non-zero exit when the collector archives nothing**,
  which is what turns "silently green" into an alert.

### Cadence

Load-management decisions are made intraday and the log is event-driven. **Poll every
5–10 minutes**, not hourly — an event that starts and ends between polls is invisible,
and this is the data being collected precisely because it cannot be recovered later.

Avoid taken cron slots: `*/10` and `35 12` (kia-collector), `23 * * * *` and `53 4`
(beestat-collector), `0 3` (unifi), `0 */6` (openbao), `10 0/6` (talos-backup), `*/15`
(image-reflector-healer). `concurrencyPolicy: Forbid` does **not** apply across
CronJobs, so offsets must be chosen deliberately — e.g. `*/7` or `4-59/10`.

### Stateless watermark

Same pattern as `beestat-collector`: hold no state, recover the resume point by querying
the bucket's own max timestamp per series, and re-fetch a deliberate overlap window.
`/api/Ripple/list` takes `startDate`, so walk back from the watermark by whole days.
InfluxDB dedupes on `(measurement, tagset, field, timestamp)`, so overlap is free.

### Suggested schema

Model the DO state as one point per (load group, DO) transition:

- measurement `ripple_state` — tags `load_group` (`2.06`, `3.09`), `do` (`DO09`, `DO13`), `load_name`
  (from the pinned mapping), `substation`, `coop`; field `state` (boolean on/off) plus
  a string `state_text`. **Tag on the stable `do` index, not the human name**, so a
  mapping correction does not fork the series.
- measurement `dr_plan` — the `/api/Plan/list` message and `isDemandResponseExpected`.
- measurement `dr_schedule` — Yellow/Red Zone `status` / `enabled` / `probability`.
- measurement `system_condition` — `percentage`, `enabled`.

Beware the InfluxDB traps already documented in `reference-influxdb-write-traps`: do not
mix a boolean and a float in one measurement and then `group()` across fields, and keep
batches small when a single write spans years of history.

## The payoff, once collected

Join `ripple_state{load_name="Dual Heat"}` against the existing
`beestat` `runtime_thermostat.auxiliary_heat_1`. That answers a question the user
currently cannot: **what fraction of propane burn is the utility's choice rather than
the thermostat's?** It also lets the balance-point panel be split into
utility-curtailed and not, which is the difference between "my aux lockout is set too
high" and "my utility switched my heat pump off".

Both are actionable, and they have opposite fixes.

## Testing note

Every finding in this brief came from `curl` against the public API plus reading the JS
bundle. Do the same before writing code — and in particular, run each candidate query
against the live API and look at the actual rows, rather than trusting the field names
here. They were correct on 2026-08-21 and the API is unversioned.
