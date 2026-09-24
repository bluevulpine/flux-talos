# SolarEdge Production Collector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. The authoritative step-by-step template is `docs/superpowers/plans/2026-08-21-minnkota-collector.md`; this plan records where the SolarEdge collector **differs** from it and why.

**Goal:** Backfill SolarEdge site production at 15-minute resolution from commissioning (~2022) into InfluxDB, and keep capturing it going forward, independent of Home Assistant.

**Architecture:** A stateless Python CronJob in the minnkota/beestat shape. An hourly incremental job re-reads a trailing 3-day window. A daily audit reconciles SolarEdge monthly totals against the bucket and re-fetches only months that differ. On an empty bucket, that audit is the backfill. Writes are idempotent on `(measurement, tagset, field, timestamp)`.

**Tech Stack:** Python 3.12, `requests`, `influxdb-client`, InfluxDB 2 (Flux), Kubernetes CronJob, Flux CD + Drone/kaniko, Prometheus, Grafana.

**Review:** This plan was adversarially reviewed on 2026-09-24 and every finding is incorporated below. The SolarEdge API facts come from a Jan 2019 copy of the API doc (the official PDF blocks automated fetches), so confirm them with the curl calls in Prerequisites step 2 before writing code.

---


## Context

Real inverter output reaches Home Assistant through a HACS Modbus-over-IP
integration (user-reported entity IDs `sensor.solaredge_inverter_1_ac_power` and
`..._2_ac_power`). It only exists for as long as HA has been writing to the
`homeassistant` InfluxDB bucket, so nothing covers the time between
commissioning (~2022) and then. The Grafana "Solar now" / "Solar production"
panels (`kubernetes/apps/observability/grafana/app/ha-energy-dashboard.json:110,310`)
actually chart **Forecast.Solar's estimate** (`power_production_now*`).

The SolarEdge cloud still holds full 15-minute history. The goal is **one
continuous, HA-independent production series from install date onward**: fill in
history once, then keep capturing. The collector follows the **minnkota-collector**
pattern (an incremental CronJob plus a daily audit, idempotent writes, one bucket
per collector, Flux image automation). It differs from minnkota where SolarEdge's
hard daily quota and API key require it. Those differences are called out
below.

Decisions:
- **Collector, not a one-shot Job.** The first audit on an empty bucket does the backfill.
- **Production only.** There is no CT meter. Emporia and SmartHub are future work.
- **Own bucket `solaredge`**, following the per-collector convention.
- **Cloud API, not Modbus.** It doesn't interfere with HA's Modbus link.
- **Site-level production.** It sums both inverters. Per-inverter cloud history is out of scope.

### SolarEdge API facts (doc rev. Jan 2019 via GitHub copy; official PDF 403s)
- `energyDetails` at `QUARTER_OF_AN_HOUR` allows **one month per call**.
  `timeUnit=MONTH` has **no period limit**, so one call covers all history.
- **Missing data leaves the `value` key out entirely.** It is not sent as `null`
  (the doc's sample is `{"date": "..."}`). Values mix JSON ints (`0`, `2953`)
  and floats.
- Timestamps are site-local wall-clock time. The doc's samples suggest intervals
  are labelled by their start, but this is unconfirmed (see Verification 4).
- Limit: **300 requests/day per account token, and 300 per site ID per source
  IP.** Any client on the home IP querying this site shares the site budget,
  including HA's core cloud SolarEdge integration if that's ever enabled. ≤3
  concurrent.
- `/site/{id}/overview` returns `lastUpdateTime` and `lifeTimeData.energy`.
  `/dataPeriod` returns the install start.

## Where the work lives
- **Repo A (Gitea, new): `bluevulpine/solaredge-collector`.** App source, built
  and pushed locally via Drone → `gitea.derekjacobs.dev/bluevulpine/solaredge-collector:<n>-<sha8>`.
  It isn't reachable from this cloud session.
- **Repo B: flux-talos (this branch).** Manifests, image automation, Grafana.
- **Manual:** bucket, tokens, OpenBao items, first image.

Authoritative template for both repos:
`docs/superpowers/plans/2026-08-21-minnkota-collector.md`. Use its File
Structure, Task 6 (Dockerfile / .dockerignore / .drone.yml), and Tasks 7–10. The
live manifests are in `kubernetes/apps/{home,flux-system}/minnkota-collector/`.
Copy `influx_archive.py` from the beestat/minnkota repos.

---

## A. Collector app (Repo A)

| Module | Responsibility |
| --- | --- |
| `solaredge_api.py` | HTTP client (`requests`). Month windows `[YYYY-MM-01 00:00:00, last-day 23:59:59]`. Sequential calls. In-process retry with backoff for 5xx and timeouts **per window only**. A hard `MAX_CALLS_PER_RUN`. **Logs status, path and window, never URLs or exception text** (`api_key` is a query param and pod logs ship to victoria-logs). Scrubs `api_key=[^&]+` defensively. |
| `production.py` | Pure logic. Parses entries with `v.get("value")`: **missing key or None means no data, skip it** (never write 0). **Coerces every value to `float()`** (an int would write `0i` and cause a 422 field-type conflict). Converts local time to UTC with `zoneinfo`, and **explicitly drops spring-forward nonexistent times**. |
| `influx_archive.py` | Batched idempotent writes (`WRITE_BATCH_SIZE`). Per-local-month `sum(energy_wh)` reads for reconciliation. Adapted from beestat/minnkota. |
| `collector.py` | Config, run modes, exit codes. |
| `tests/` | Window boundaries (31-day months, Feb, leap years). Both DST transitions. A **real saved `energyDetails` fixture** (night intervals with no `value` key, mixed int/float). Line protocol never contains an `i` suffix. The API key never appears in captured logs. 429 → exit 7. |

**Run modes**
- **Incremental** (hourly): fetches `now − LOOKBACK_DAYS(3)` → now. That's 1
  call, or 2 across a month boundary. It overwrites the still-accumulating
  current interval and any late uploads.
- **Audit** (daily): **reconciliation, not a full re-walk.** A full walk would
  be ~45 calls/day and grow 12/yr against a hard quota. Minnkota can afford one
  only because its API is unlimited.
  1. `/overview` (1 call). If `lastUpdateTime` is more than `COMMS_STALE_DAYS=7`
     old, **exit 4**. This catches the inverter losing internet while Modbus/HA
     still look fine, which is the one failure that creates permanent gaps. It's
     lenient enough to allow for snow.
  2. `energy?timeUnit=MONTH` over the whole history (1 call). Compare each
     month's total with the bucket's per-local-month sum. **Re-fetch at 15-min
     resolution only the months that differ by more than 0.5%**, plus the
     current and previous month.
  3. On an empty bucket every month differs, so **this is the backfill** (~45
     calls). It's also **resumable**: months finished before a failure match the
     next time and are skipped.
  - `FULL_WALK=true` is an escape hatch for manual runs only.
- Checks that `SOURCE_TZ` matches `/site/details`. If it doesn't, the run fails
  loudly (exit 2).

**Schema (`solaredge` bucket):** measurement `energy`, tags `site_id` and
`meter=production`, float field `energy_wh`, UTC timestamps. Points are
idempotent on `(measurement, tagset, field, time)`.

**Exit codes** (minnkota numbering, extended). Code 6 is deliberately unused:
minnkota uses it for MQTT errors, and this collector has no MQTT. Reusing it with
a different meaning would make the two collectors' codes look interchangeable
when they aren't.

| Code | Meaning | Retry? |
| --- | --- | --- |
| 2 | Config/tz mismatch | No |
| 3 | SolarEdge transient error, in-process retries exhausted | Pod-level retry |
| 4 | Cloud comms stale | No |
| 5 | InfluxDB error | Pod-level retry |
| 7 | **429 quota / 403 window or auth** | **No** (deterministic) |

**Budget, worst case:** incremental is 24 × 3 attempts × 2 calls = 144.
Steady-state audit is ≈4 calls × 2 attempts = 8. The backfill is ~47 calls and
retries only cost the remaining months, since it resumes. Backfill day totals
≈ 200 and steady state ≈ 150, under 300 even if both run on the same day.

## B. flux-talos manifests (this branch)

**`kubernetes/apps/home/solaredge-collector/`**
- `ks.yaml`: copy minnkota's. `dependsOn: external-secrets-openbao-store`.
  (An `influxdb` Kustomization does exist in `database`. Following
  minnkota/beestat precedent it's left out, because the CronJob just retries.)
- `app/kustomization.yaml`: resources plus the dashboard `configMapGenerator`.
  Keep minnkota's comment: **no `${…}` in the JSON** (postBuild envsubst),
  otherwise escape as `$${`.
- `app/configmap.yaml`: `INFLUXDB_URL`, `INFLUXDB_ORG=homelab`,
  `INFLUXDB_BUCKET=solaredge`, `SOLAREDGE_BASE_URL`, `SOURCE_TZ=America/Chicago`,
  `BACKFILL_START_DATE` (from `dataPeriod`), `LOOKBACK_DAYS=3`,
  `MAX_CALLS_PER_RUN=80`, `MISMATCH_TOLERANCE=0.005`, `COMMS_STALE_DAYS=7`,
  `WRITE_BATCH_SIZE=2000`. Each value gets a comment explaining it, as in minnkota.
- `app/externalsecret.yaml`: OpenBao key `solaredge-collector`:
  `Solaredge__ApiKey`, `Solaredge__SiteId`, and `Solaredge__InfluxdbToken`, which
  is **read+write**, like minnkota's (reconciliation reads the bucket).
- `app/serviceaccount.yaml`: identity only. `automountServiceAccountToken: false`.
- `app/cronjob.yaml`: minnkota's securityContext, `/tmp` emptyDir,
  `concurrencyPolicy: Forbid`, `imagePullPolicy: Always`, and the image marker
  `# {"$imagepolicy": "flux-system:solaredge-collector"}` (**no `:tag`**).
  **Unlike minnkota:** `restartPolicy: Never` plus a `podFailurePolicy` of
  `FailJob` on exit codes `[2, 4, 7]`, so deterministic failures don't burn quota.
  - `solaredge-collector`: `41 * * * *`, `backoffLimit: 2`, `ttlSecondsAfterFinished: 3600`.
  - `solaredge-collector-audit`: `29 2 * * *`, `AUDIT_MODE=true`, `backoffLimit: 1`,
    `ttlSecondsAfterFinished: 21600`, 256Mi (streamed per month).
  - Carry over minnkota's collision-rule comment and extend it. 41 isn't ≡ 2
    (mod 5) and isn't a multiple of 10 or 15. It avoids :23 (beestat), :47
    (kia-trip) and :10 (talos-backup). **These slots are free of other
    CronJobs**; VolSync R2 movers do share hour 2 and :41, but that doesn't
    matter because the collector has no volume.
- `app/prometheusrule.yaml`: minnkota's four rules, renamed. **Stale is 6h**
  (warnings still page via Pushover, so a brief SolarEdge outage shouldn't
  notify). AuditStale is 48h. Both stale rules add `or absent(...)` so a CronJob
  that has never succeeded still alerts. JobFailed and ImagePullFailing regexes
  are `solaredge-collector.*`. Severity is **warning**.
- `app/solaredge-dashboard.json`: daily and monthly kWh, year-over-year by month,
  15-min detail, and lifetime cumulative. **Every daily/monthly aggregate uses
  `import "timezone"` + `location: timezone.location(name: "America/Chicago")`**
  (precedent: beestat-longterm, chargepoint-flex). The lifetime panel uses a
  fixed `range(start: <install date>)`.
- Register it in `kubernetes/apps/home/kustomization.yaml`.

**`kubernetes/apps/flux-system/solaredge-collector/`**: copy minnkota's `ks.yaml`
and `app/{kustomization,imagerepository,imagepolicy,imageupdateautomation}.yaml`.
Set `update.path: ./kubernetes/apps/home/solaredge-collector`. Register it in
`kubernetes/apps/flux-system/kustomization.yaml`.

**Grafana** (`kubernetes/apps/observability/grafana/app/`): in `helmrelease.yaml`,
add `InfluxDB-SolarEdge` (copying the `InfluxDB-Minnkota` block). In
`externalsecret.yaml`, add
`INFLUXDB_SOLAREDGE_TOKEN: '{{ .Grafana__InfluxdbSolaredgeToken | default "" | nospace }}'`.

**Separate commit, adjacent fix: `ha-energy-dashboard.json` solar panels.**
First confirm the real entity IDs and unit with `schema.tagValues` on the
`homeassistant` bucket. They may be `solaredge_i1_ac_power` and/or `kW`. Then:
- **"Solar now":** sum the inverters with `last() |> group() |> sum()`.
- **"Solar production":** add an actual total series **overlaid on** the
  Forecast.Solar line, rather than replacing it, to keep the forecast-vs-actual
  comparison.

## C. Prerequisites (ordered, manual)
1. SolarEdge portal → site-level API key and site ID.
2. Run curl against `dataPeriod` (→ `BACKFILL_START_DATE`), `details` (tz), and
   `overview`. Also fetch **one real `energyDetails` 15-min day that includes a
   night**, saved as a test fixture. Then check **one full 31-day month** with
   the chosen window format to confirm it doesn't 403.
3. Create the bucket with
   `influx bucket create --name solaredge --org homelab --retention 0 --shard-group-duration 52w`.
   That gives ~5 shards instead of ~200; see the beestat ~430-shard timeout and
   InfluxDB's 1Gi→4Gi memory bump.
4. Create tokens against the **bucket ID**, following minnkota Task 7: a
   read+write token for `Solaredge__InfluxdbToken`, and a read-only token for
   `Grafana__InfluxdbSolaredgeToken` in the OpenBao `grafana` item.
5. Store the OpenBao `solaredge-collector` item.
6. Build and push the first image (Repo A) **before** merging B.

## Verification
1. Repo A: `pytest` (see the tests row above).
2. Repo B: `lefthook run pre-commit`, then `flux-local test`.
3. After merge (webhook; no `flux reconcile`), start the backfill now:
   `kubectl -n home create job --from=cronjob/solaredge-collector-audit solaredge-collector-backfill`.
   The name keeps it inside the alert regexes. Logs should show ~45 month
   fetches and ≤ `MAX_CALLS_PER_RUN`.
4. **Cross-check against HA Modbus data:** on a recent sunny day, compare 15-min
   integrals of inverter 1 and 2 AC power from `homeassistant` with `energy_wh`.
   Totals should match within a few percent. This also settles whether intervals
   are labelled by start or end, and confirms tz handling (peak around 13:00 CDT).
5. **Completeness:** the bucket's lifetime `sum(energy_wh)` should be close to
   `/overview` `lifeTimeData.energy`. Re-run the audit: it should re-fetch only
   the current and previous month, and the totals shouldn't change
   (idempotency).
6. Grafana: run `kubectl -n observability exec deploy/grafana -- printenv INFLUXDB_SOLAREDGE_TOKEN | wc -c`
   and check it's > 1. If not, `rollout restart`, since there's no reloader. Then
   check the datasource is healthy and that daily bars line up with local
   midnight.
7. The next hourly run succeeds, and the alerts stay quiet.

## Future (out of scope)
- An Emporia Vue collector (`pyemvue`: hourly/daily kept for the device's lifetime, 15-min ~1 yr).
- SmartHub/Green Button consumption (no official API).
- Per-inverter cloud history.
