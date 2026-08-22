# Handoff: minnkota-collector — archive utility demand-response state

**Date:** 2026-08-21
**Status:** Scoping brief. Reconnaissance done, nothing built. Read this, then start.
**Revised:** 2026-08-21 — a second recon pass corrected two load-bearing premises. See
**Corrections** immediately below; they override anything later in this document.
**Source repo:** `git@gitea.derekjacobs.dev:bluevulpine/minnkota-collector.git` (empty; created for this work)
**Closest reference implementation:** `~/Repositories/beestat-collector` + `kubernetes/apps/home/beestat-collector/`
**Related brief:** none. Related memory: `project-beestat-collector`, `reference-beestat-api`.

---

## Corrections (verified live 2026-08-21, second pass)

These override the original text below. Each was measured against the live API,
not inferred.

### 1. History EXISTS — the "rolling window" premise was wrong

The original brief says *"there is no historical data — the site only exposes a
rolling window — so every day not collected is lost permanently."* **False.**

`/api/Ripple/list` serves history back to **2025-09-13** (bisected; 2025-09-12
returns 0 rows, 2025-09-13 returns 19). That is the whole 2025-26 heating season,
**342 days**, reachable in ~172 calls.

Consequence: this is not a race against data expiry. **Backfill the full range on
first run.** The balance-point question can be answered immediately rather than
after another winter. Confirmed shed events already visible in that history:

| Date | Shed (local) | Duration |
| --- | --- | --- |
| 2025-11-07 | 07:21 → 13:43 | 6 h 22 m |
| 2025-11-12 | 07:47 → 13:24 | 5 h 37 m |
| 2025-11-12 | 15:30 → 22:02 | 6 h 32 m |
| 2025-12-08 | 07:16 → 10:48 | 3 h 32 m |

Morning-peak and evening-peak sheds — exactly the hours the balance-point panel
currently attributes to thermostat lockout.

### 2. `startDate=X` returns a TWO-day window (X and X+1)

Not one day. Verified: `startDate=2026-08-18` returns rows dated `260818` and
`260819`. There is no `endDate` parameter. Walk history at a **2-day stride**
(or 1-day for deliberate overlap — writes are idempotent, so overlap is free).

`area` is a **required** parameter (a deliberate 400 says so) even though its
value does not change the response.

### 3. The DO → load-name mapping is RESOLVED — extract it, do not guess

The full table is object `UP` in the SPA bundle, keyed by load group. The two
that matter:

```
2.06: {9:"Battery Storage", 16:"Battery Storage"}
3.09: {9..16:"Dual Heat", 17:"Misc Heat 3", 18:"Misc Heat 3", 24:"Ind. Contr Loads 3"}
```

- **3.09 / DO13 = "Dual Heat"** — confirms the brief's hypothesis. This is the
  heat-pump/propane control and the whole point of the collector.
- **2.06 / DO09 + DO16 = "Battery Storage"** — the brief called this "EVSE".
  The utility's own label is *Battery Storage*. The behaviour is still an
  off-peak charging window; only the name was wrong. Tag on the `do` index so
  the label can be corrected later without forking the series.

Load-group *tier* names come from a second dict (`WP`), keyed on the integer
prefix: `1` = Short-Term (water heaters), `2` = Intermediate-Term (storage heat),
`3` = Long-Term (dual heating furnaces, back-up generators), `6` = Summer-Only.

Both tables are pinned into `configmap.yaml` as JSON. Bundle hash
`main.1b282323.js` was unchanged between both recon passes.

### 4. `---` does NOT mean "not controlled" — rows are PARTIAL

This is the correction most likely to produce silently wrong data.

The original brief says `---` = "not controlled for that load group". That is only
half true. A row is **one command addressed to a subset of DOs**; every DO the
command did not address reads `---`, including DOs that are controlled and
currently hold a state. Observed:

```
251203T071900  lg=3.09  OFF=DO09,DO10,DO11,DO12            (all others '---')
251203T072200  lg=3.09  OFF=DO09..DO18,DO24                (3 minutes later)
```

Between 07:19 and 07:22, DO13 was still **ON** — it simply was not addressed by
the 07:19 command. A collector that treats `---` as "no state" leaves holes; one
that treats it as OFF invents sheds that never happened.

**Therefore: carry state forward per `(load_group, do)`.** Write a point only for
the DOs a row actually addresses, and let queries use last-value-carried-forward.

Related: the log is **not** strictly one-row-per-change. Rows repeat the same
state periodically (2.06 emitted identical ON rows at 00:00, 00:56 and 01:31 on
2026-08-21). Deduplicate on timestamp; never infer a transition merely from the
arrival of a new row.

### 5. Timestamps are LOCAL wall-clock (America/Chicago), including DST

`datetime` is `YYMMDDTHHMMSS` with no zone. It is **local wall-clock time**, and
it follows DST rather than sitting at a fixed offset.

Evidence: through Nov 2025, load group 2.06 sheds at exactly `07:10` and `17:10`
every single day — across the 2025-11-02 DST boundary, with no one-hour shift.
A UTC or fixed-offset reading would place that shed at 01:10/11:10 local, which
is not a peak period under any tariff.

Parse with `ZoneInfo("America/Chicago")`, then convert to UTC for InfluxDB.
Getting this wrong shifts every event by 5–6 hours and silently destroys the
join against beestat runtime.

### 6. New requirement: live signal into Home Assistant

Beyond archiving, the collector must publish the **current** curtailment state so
a Home Assistant automation can flip the ecobee to *aux heat only* the moment the
utility disables the heat pump — rather than waiting for indoor temperature to
droop far enough for the thermostat to stage up on its own.

Delivery is **retained MQTT with Home Assistant discovery**, on the existing
`mosquitto` broker in the `home` namespace. Runtime shape confirmed with the user:
**CronJob every 5 minutes** (`2-59/5`), matching the sibling collectors — not a
long-running Deployment.

### 7. `/api/Status/list?area=<slug>` is a useful current-state snapshot

Not probed in the first pass. Returns one row per load group with the last-change
timestamp and all DOs as named fields (`dO9`..`dO25` — note `dO25` exists here and
not in the 16-element `do` array). Timestamps are `MM/DD/YYYY hh:mm:ss AM/PM`.
Useful as a cheap cross-check that carried-forward state has not drifted.

---

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
temperatures drop. ~~There is **no historical data** — the site only exposes a rolling
window — so every day not collected is lost permanently, exactly like the beestat
room-sensor problem.~~ **Superseded — see Correction 1: history reaches back to
2025-09-13 and must be backfilled.**

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
- `do` is a 16-element array mapping to **DO09..DO24**, values `ON` / `OFF` / `---`.
  ~~(`---` = not controlled for that load group)~~ **Superseded — see Correction 4:
  `---` means "not addressed by this command"; state must be carried forward.**
- `lg` = load group (e.g. `2.06`), `name` = substation, `coop` = co-op name.
- A full day returned only **35 rows** — this is event-driven, not sampled. Volume is
  trivial; the whole problem is *not missing an event*.

## Which load groups are the user's — RESOLVED

The user's controlled loads, confirmed against live API state on 2026-08-21:

| Load group | DO | What it is | Evidence |
| --- | --- | --- | --- |
| **2.06** | **DO09** | **EVSE** — utility label is **"Battery Storage"** (Corr. 3) | `currentStatus: OFF`, `lastOn 2026-08-21T00:00`, `lastOff 2026-08-21T10:01` — a nightly on/morning-off cycle is an off-peak charging window |
| **3.09** | **DO13** | **Heat pump** — utility label **"Dual Heat"**, confirmed (Corr. 3) | `currentStatus: ON`, last cycled `2026-05-12` (end of heating season) and ON ever since — matches "never seen it disabled in cooling months" |

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
signal this whole collector exists to capture. **Now confirmed — see Correction 3.** Extract the correct dictionary for the
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
`/api/Ripple/list` takes `startDate`, so walk back from the watermark by whole days
(**2-day stride — see Correction 2**). InfluxDB dedupes on
`(measurement, tagset, field, timestamp)`, so overlap is free.

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
