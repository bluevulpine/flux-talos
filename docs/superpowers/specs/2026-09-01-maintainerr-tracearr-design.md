# Maintainerr + Tracearr + TimescaleDB — design

**Status:** approved for implementation, not yet built
**Date:** 2026-09-01
**Requested by:** Derek (`@bluevulpine`)
**Research:** Pollen and Fizz, every upstream claim read in source twice

## Summary

Add [Maintainerr](https://maintainerr.info/) to clean up unwatched media, backed by
[Tracearr](https://github.com/connorgallopo/Tracearr) for watch history, backed by a
dedicated TimescaleDB instance.

Three components, in a forced order. Maintainerr is the only one Derek asked for; the
other two are its dependency chain, and each was chosen because the obvious alternative
does not work.

## Why three components

**Maintainerr needs watch history to decide "unwatched."** Its media-server-native
properties only cover the one server it is pointed at, and its two stats companions are
hard-bound in `rule-application-availability.helper.ts`:

```ts
MEDIA_SERVER_BY_APPLICATION = {
  TAUTULLI:     PLEX,        // unavailable unless media server is Plex
  STREAMYSTATS: JELLYFIN,    // unavailable unless media server is Jellyfin
}
```

Derek runs both Plex and Jellyfin. Tautulli cannot see Jellyfin; Streamystats cannot see
Plex. **Tracearr is the only watch-history source Maintainerr does not bind to a media
server type** — it is absent from that map, gated only on its own URL and API key.

**Tracearr covers all three servers** (`services/mediaServer/{plex,jellyfin,emby}/`) and
**imports existing Tautulli history** (`services/tautulli.ts`, `importHistory()` at :536),
so Derek's Plex history carries over rather than restarting from zero.

**Tracearr requires TimescaleDB Community edition.** It creates five continuous aggregates
and a compression policy on every startup. Those are TSL features, absent from the Apache-2
build — see "Database choice" below, which is the least obvious decision here.

## Decisions

| Decision | Choice | Who / why |
|---|---|---|
| Media server | **Plex** | **Derek, 2026-09-01**, after establishing what the choice actually controls. Not watch history — Tracearr supplies that for both. It selects the **rule vocabulary**: Plex exposes 49 properties to Jellyfin's 47, sharing 41. The eight Plex-only ones include `Is Watchlisted`, `Watchlisted by (username)` and `Labels`; Jellyfin's six include `Favorited by (username)` and `Tags`. For a tool that deletes things, the highest-value rule is an exemption, and the "keep this" flag lives in whichever server the household marks things in. **Not free to change later** (see Risks). |
| Collection | **Visible, named "Leaving Soon"** | Derek, 2026-09-01. The collection in Plex *is* the dry-run report. |
| `arrAction` | **`DO_NOTHING` (4)** for the trial | Fizz/Pollen; Maintainerr has no dry-run mode, so this is the substitute. |
| `deleteAfterDays` | **30**, explicitly | Not a safety margin — under `DO_NOTHING` nothing acts regardless. The deletion calendar *skips null entirely*, so a real value is what makes the trial legible. |
| Database | **(a) dedicated TimescaleDB StatefulSet** | Derek, 2026-09-01, after asking for evidence on the CNPG alternative. |
| Telemetry | **`TELEMETRY: "off"`** | New installs are seeded `true` and **never prompted**. The manifest is the only place this can be decided. |

## Database choice — why not CloudNativePG

This cluster runs CNPG 1.30.0 and PG 18.2 on k8s v1.36.2 with containerd 2.2.7, which
**passes every prerequisite** for CNPG's ImageVolume extensions (needs CNPG 1.29+, k8s
1.33+, PG 18, containerd 2.1.0+). There is a first-party
[Tiger Data guide](https://www.tigerdata.com/docs/integrate/configuration-deployment/cloudnativepg)
and an official image, `ghcr.io/cloudnative-pg/timescaledb-oss:2.27.2-18-trixie`.

**The `-oss` suffix is disqualifying.** TimescaleDB's Apache-2 edition excludes continuous
aggregates and compression; both are TSL/Community features. Tracearr requires exactly
those, at every boot:

```sql
CREATE MATERIALIZED VIEW … WITH (timescaledb.continuous, timescaledb.materialized_only = false)
  × 5: daily_content_engagement, user_media_plays_daily, daily_bandwidth_by_user,
       library_stats_daily, content_quality_daily
SELECT add_continuous_aggregate_policy(…)
```

The official image would deploy cleanly and fail at application startup — the worst place
to discover it. TSL is free to self-host (it only bars offering a managed service); it is
simply not the build CNPG publishes.

A third-party Community-edition CNPG image (`clevyr/docker-cloudnativepg-timescale`, 43★)
would work but trades "outside CNPG" for "inside CNPG, depending on a third party to
rebuild for every PG and Timescale release." For a database holding watch history, the
boring StatefulSet wins.

## Components

### A. TimescaleDB

- **Image:** `timescale/timescaledb-ha:pg18.4-ts2.29.1` — pinned exactly as upstream's
  compose does. Tracearr rewrites its aggregate schema on startup and version-drifts badly.
- **Namespace:** `database`
- **Storage:** `longhorn-1-replica`, RWO. Size TBD at implementation — start 20Gi.
- **Requires:** `shm_size` equivalent (`emptyDir` medium `Memory` at `/dev/shm`, 512Mi) and
  a raised `nofile` limit; upstream notes chunks need many file descriptors.
- **Credentials:** ExternalSecret from openbao, following the existing `database/` pattern.
- **Not** under CNPG, so **not** covered by the barman-cloud plugin.

### B. Tracearr

**Corrected 2026-09-01 against upstream's own Helm chart** (`docker/helm/tracearr/` in the
repo), which contradicted this section in three places. The original was inferred from
`.env.example`; the chart is authoritative.

- **Image:** `ghcr.io/connorgallopo/tracearr`, pin **`2.2.3`** — not `latest`, and **not**
  `supervised` (those bundle Postgres *and* Redis into the app container). Version tags are
  not on the first page of the GHCR tag list; there are 1048 tags across 11 pages.
- **Namespace:** `media`
- **Port:** 3000
- **Runs as 1001:1001** (`tracearr:nodejs`) — *not* the 1000 TimescaleDB uses.
- **Singleton.** Upstream pins `replicaCount: 1`, "singleton poller — only 1 supported", so
  the Deployment needs `strategy: Recreate`.
- **Redis is required.** `REDIS_URL` is set unconditionally in upstream's deployment; it
  coordinates the connection-pool budget across instances. **This dependency was missing
  from the first draft.** No new component: the existing `dragonfly` in `database/` already
  serves authentik, immich, nextcloud and thanos. Set `REDIS_PREFIX` — upstream offers it
  for exactly the shared-instance case.
- **Config:** `DATABASE_URL` and two auth secrets — `JWT_SECRET` and `COOKIE_SECRET`,
  32 bytes each — from an ExternalSecret. **The auth secrets were also missing.** Assemble
  `DATABASE_URL` from two openbao extracts rather than copying the database password under
  the `tracearr` key, so rotation cannot drift between two copies.
- **Storage: two PVCs, not zero.**

  | claim | path | backed up |
  |---|---|---|
  | volsync claim | `/data/backup` | yes |
  | plain PVC | `/app/data/image-cache` | no — rebuildable poster cache |

  **Mount the subdirectories, never `/app/data`.** The image ships `basemap.pmtiles` and
  `BASEMAP_NOTICE.txt` there; mounting the parent shadows both and silently breaks the
  stream map.
- **Probes: one endpoint, three budgets.** `/health` **always returns HTTP 200** — state is
  reported in the JSON body (`ok | degraded | maintenance`) from in-memory caches, with no
  `reply.code()` in the handler. So liveness cannot be tripped by a database outage (the
  jellyfin failure mode is unreachable here), and **readiness cannot shift traffic on
  degradation either** — a broken server still answers 200. Readiness is informational;
  upstream builds for this, rendering a maintenance banner client-side and 503-ing `/api/*`
  until ready. The only real detection is a wedged event loop, so liveness gets a long
  budget and a 10s timeout: a slow answer from a synchronous handler is event-loop lag,
  which must not cause a restart.
- **Post-deploy, manual:** connect Plex *and* Jellyfin, then run the Tautulli import.
- **Note:** Jellyfin/Emby real-time sessions need Tracearr's SSE plugin; without it they
  poll. Polling is sufficient for watch history — the plugin is a latency nicety.

### C. Maintainerr

- **Image:** `ghcr.io/maintainerr/maintainerr`, pin `v3.9.0`.
- **Namespace:** `media`
- **Port:** 6246 (`UI_PORT`)
- **Env:** `TELEMETRY: "off"`, `TZ: "${TIMEZONE}"`, `BASE_PATH` only if path-routed.
- **Storage:** `/opt/data`, **RWO on `longhorn-1-replica`** — `better-sqlite3`, one file.
  Also holds `logs/` (unbounded in source) and a UI bundle rewritten on every boot.
- **Probes — split, using upstream's own endpoints.** Do **not** share one spec via a YAML
  anchor the way `jellyseerr` does:

  | probe | path | touches DB |
  |---|---|---|
  | liveness | `/api/health/live` | no — "no restarts on transient DB blips" |
  | readiness | `/api/health/ready` | yes — 503 when DB unreachable |

  This is the same split we applied to jellyfin on 2026-08-31, except upstream already
  built the endpoints for it.
- **Credentials are manual.** No `process.env` path exists for Plex/Jellyfin/*arr keys —
  all are entered in-app and stored in SQLite. **There is no ExternalSecret to write.**

## Safety model

Full detail in `RESEARCH/MAINTAINERR_SAFETY_MODEL.md` (Fizz's workspace). The load-bearing
points:

**There is no dry-run mode.** Safety is a time delay, not a confirmation. Rules add media
to a collection; a worker deletes members once the window expires. Nobody approves anything.

**Every default is the permissive one.** `isActive` true, `arrAction` 0 (= `DELETE`),
`deleteAfterDays` null — and null resolves to *now*, deliberately:

```
getCollectionDangerDate: now - (deleteAfterDays ?? 0)
  /** An unset window resolves to `now` - no window means everything is immediately due. */
```

`RuleGroupDto` is a plain class with **zero validation decorators**, and all three fields
are optional or absent, so an API create that omits them lands on active + DELETE + zero-day.
**Always set `arrAction` and `deleteAfterDays` explicitly.**

**Omitting the *arrs does NOT make it safer — it makes it worse.** With no *arr configured,
a delete action falls through to deleting via the media server directly:

```ts
if (!radarrSettingsId && !sonarrSettingsId && !sportarrSettingsId) {
  if (arrAction !== UNMONITOR && … && … ) {
    await mediaServer.deleteFromDisk(media.mediaServerId);   // real deletion
```

**Radarr and Sonarr are therefore a safety requirement, not a convenience.**

**Under `DO_NOTHING`:** files, *arr state and artwork are all untouched (overlays are gated
to deleting actions). The media-server collection **is still created** — that is intentional
and is the dry-run output.

## Rollout

Order is forced: Maintainerr's rules must be written against Tracearr properties from day
one, or they get rewritten later.

1. **TimescaleDB.** Gate: `SELECT extversion FROM pg_extension WHERE extname='timescaledb'`
   returns a Community build, and `CREATE MATERIALIZED VIEW … WITH (timescaledb.continuous)`
   succeeds. **Prove this before deploying Tracearr** — it is the whole reason for option (a).
2. **Tracearr.** Gate: connects to both Plex and Jellyfin; Tautulli import completes; the
   five continuous aggregates exist.
3. **Maintainerr.** Gate: `/api/health/ready` returns 200; Tracearr appears as an available
   rule application in the editor (it will not, if its URL/key/server-id are unset).
4. **First rule, `DO_NOTHING` + 30 days.** Gate: "Leaving Soon" appears in Plex and its
   membership is defensible.
5. **Review for several weeks before changing `arrAction` to anything that deletes.**

## Backup

- **Maintainerr** — standard volsync component, `longhorn-1-replica` / RWO /
  `longhorn-snapclass`, matching the jellyseerr pattern. **Its PVC contains Plex, Jellyfin
  and *arr API keys**, so the backup contains credentials.
- **TimescaleDB** — **reversed on 2026-09-01: volsync, with `VOLSYNC_COPYMETHOD: Snapshot`.**
  The original objection stands as a *limit*, not a disqualification: a single-volume atomic
  snapshot is exactly what WAL replay is built to recover, which is not true across two
  volumes. What it cannot give you is per-table or point-in-time restore, and a corrupt page
  is copied faithfully into every retained snapshot.

  **`COPYMETHOD` must be set alongside `VOLSYNC_ACCESSMODES`, never on its own.** The
  component defaults to `Direct`, which has kopia walk a live `PGDATA` while Postgres writes
  to it. It does not fail loudly — VolSync co-schedules the mover onto the node already
  holding the volume, and RWO is per-*node*, so the backup completes. **Green
  ReplicationSources and a restore that may not start.** Caught in review of #1711.

  The logical-dump layer this paragraph originally called for is supplied by Tracearr, below.
- **Tracearr** — has state, and it closes the gap above. Its own backup subsystem
  (`services/backup.ts`, `jobs/backupQueue.ts`) writes scheduled **logical** database dumps
  to `/data/backup`. Putting the volsync claim there — rather than on the rebuildable poster
  cache — makes those dumps the replicated artifact, which is the logically-consistent layer
  a live-volume snapshot structurally cannot provide. **No separate `pg_dump` CronJob is
  needed.** Left on ephemeral storage the feature is worse than absent: backups that vanish
  on every restart.

## Keeper signals — what can and cannot be read

**There is no way to read both servers' keep-flags.** Verified against the rule constants:

| source | keeper properties | available when media server is |
|---|---|---|
| Plex | `Is Watchlisted`, `Watchlisted by (username)`, `Labels` | Plex only |
| Jellyfin | `Favorited by (username)`, `Tags` | Jellyfin only |
| Streamystats | `Is in a watchlist`, `In watchlist of (username)` | **Jellyfin only** (hard-bound) |
| Tautulli | none — 13 properties, all watch history | Plex only (hard-bound) |
| Tracearr | **none** — 12 properties, all watch history | either |
| **Seerr** | **`Requested by user (Jellyfin, Emby, Plex or local username)`**, `Requested in Seerr`, `Request date`, `Amount of requests` | **either** |

**Seerr is the only cross-server signal**, and its own property name declares it. `jellyseerr`
is configured against Plex ("Talos", 3 of 4 libraries enabled, `mediaServerType: 1`), so it
works today.

**But a request is not a keep.** "Someone asked for this once" is weaker than "someone flagged
this to keep." Use Seerr as a supplementary exemption, not as a replacement for the watchlist.

**Consequence of choosing Plex:** anything the household marks as a *Jellyfin favourite* is
invisible to Maintainerr. If Jellyfin use grows, either move keep-flagging to the Plex
watchlist or to Seerr requests.

## Risks and open questions

1. **Media server choice is not cheaply reversible.** Switching clears collections,
   collection media, **exclusions** and collection logs, and migrates rules with
   incompatible ones skipped. Exclusions are the never-touch-this list. Additionally,
   property ids do not align across servers — id 39 is `collectionsIncludingSmart` on Plex
   and `favoritedBy` on Jellyfin — so an unmigrated rule silently reads a different field.
2. **TimescaleDB sits outside CNPG.** No operator-managed failover or barman backups. This
   is the accepted cost of option (a).
3. **`/opt/data/logs` is unbounded** in Maintainerr's source. Watch volume growth.
4. **Not verified:** whether Maintainerr's *UI* can create a null-window deleting collection
   (the API demonstrably can); whether the media-server switch flow forces you to view
   `previewSwitch` before it clears. Both need a running instance.
5. **Tracearr is young.** ★2548 and actively developed, but newer than the tools it replaces.
   The Tautulli import means adopting it is reversible in the sense that Tautulli can stay.
