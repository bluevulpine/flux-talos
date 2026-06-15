# Helium Archiver

A small, **temporary** MQTT→storage logger. It subscribes to `helium/#` on the
[Mosquitto](../mosquitto/README.MD) broker (Helium Console relays per-device
LoRaWAN uplinks to `helium/<device-uuid>/rx`) and persists **every** message —
decoded JSON plus the original raw string — so the decoded payload schema can be
checked for drift across devices and over time before decoders are rewritten on
ChirpStack.

It is built to be removable: delete this one directory and revoke one OpenBao
key (`helium-archiver`) when the migration is done.

## Storage decision

Payloads from many devices under `helium/#` won't share a rigid relational
schema, so the backend needs to handle schemaless JSON well. Options actually
available in this cluster:

| Option | Fit for schemaless JSON | Query ergonomics for drift | New infra / ops burden | Backup & retention |
| --- | --- | --- | --- | --- |
| **Postgres `postgres16` + JSONB** | Strong — `jsonb` column, no schema needed | **Best** — `?` / `?&` / `->` / `#>` + GIN index make "which devices are missing key X" trivial in SQL | **None** — cluster already runs; one DB + one table | Covered by existing CNPG backups; `DROP DATABASE` to clean up |
| **CouchDB** (deployed) | Native document store, very natural | Mango selectors / map-reduce views; weaker than SQL for ad-hoc cross-cutting drift queries, needs view design | Low — already deployed, but adds a second datastore to the data path | Separate backup story |
| **Garage S3** (`~10.0.10.11`) | Fine as opaque object archive (NDJSON rollups) | **Weakest** — no ad-hoc query; need Athena-style tooling or download+grep | Low write path, but querying is the whole point here | Cheapest write-once archival |
| **MongoDB** | Strong | Good aggregation pipeline | **Highest** — not in cluster; would need a new StatefulSet or external Atlas | New backup story |

**Recommendation: Postgres `postgres16` with a JSONB column.** It adds no new
infrastructure, and the whole purpose of this tool — *detecting schema drift* —
is exactly what `jsonb` operators + a GIN index are good at. MongoDB isn't worth
standing up for a throwaway tool; Garage is great for cold archival but poor for
the ad-hoc querying we need; CouchDB is a reasonable fit but adds a second
datastore for no real gain over the Postgres we already run.

The backend is **easy to swap**: the subscriber writes through a tiny `Sink`
interface (`src/storage.py`). To switch, add a new `Sink` implementation and set
`STORAGE_BACKEND` in the HelmRelease — no changes to `main.py`.

### Example drift queries

```sql
-- Distinct top-level key sets seen per device
SELECT device_uuid, jsonb_object_keys(payload) AS key, count(*)
FROM helium_messages GROUP BY 1, 2 ORDER BY 1, 2;

-- Messages whose decoded body is missing the `decoded` key
SELECT id, topic, received_at FROM helium_messages
WHERE payload IS NOT NULL AND NOT (payload ?& array['decoded']);

-- Non-JSON / unparseable payloads
SELECT id, topic, raw_payload FROM helium_messages WHERE payload IS NULL;
```

## Schema (DDL)

Applied idempotently by the subscriber on startup (`src/schema.sql`); the
`postgres-init` init container creates the database/role first (the repo-wide
bootstrap convention is documented in the root [`CLAUDE.md`](../../../../CLAUDE.md)).

```sql
CREATE TABLE IF NOT EXISTS helium_messages (
    id          bigserial   PRIMARY KEY,
    received_at timestamptz NOT NULL DEFAULT now(),
    topic       text        NOT NULL,
    device_uuid text,
    payload     jsonb,
    raw_payload text        NOT NULL,
    qos         int         NOT NULL,
    retain      boolean     NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS helium_messages_payload_gin   ON helium_messages USING gin (payload);
CREATE INDEX IF NOT EXISTS helium_messages_device_idx    ON helium_messages (device_uuid);
CREATE INDEX IF NOT EXISTS helium_messages_received_idx  ON helium_messages (received_at);
```

## The subscriber

`src/` is a minimal first-party Python consumer (`paho-mqtt` + `psycopg` 3):

- Subscribes `helium/#` at **QoS 1** with a **persistent session**
  (`clean_session=false`, stable `MQTT_CLIENT_ID`) so the broker queues messages
  across restarts — uplinks aren't dropped. Auto-reconnect with backoff.
- One row per message; decoded JSON → `payload` (jsonb), original string always
  kept in `raw_payload`. `device_uuid` is parsed from the topic.
- Never crashes on malformed/non-JSON payloads — logs and stores raw.
- Runs as non-root, drops ALL caps, read-only root filesystem (only `/tmp`).

### Building the image

This is a **first-party image** built automatically by Drone CI (Kaniko) on
every push to `main` of the source repo:
[gitea.derekjacobs.dev/bluevulpine/helium-archiver](https://gitea.derekjacobs.dev/bluevulpine/helium-archiver)

It is pushed as `gitea.derekjacobs.dev/bluevulpine/helium-archiver:latest`
(and tagged with the short commit SHA). The HelmRelease tracks `latest`.

## OpenBao secrets to create first

Create these in OpenBao **before** the ExternalSecrets sync. Field naming is
PascalCase double-underscore, matching the rest of the repo.

**1. Key `helium-archiver`** (new — this app's own key):

| Field | Purpose |
| --- | --- |
| `HeliumArchiver__Mqtt__User` | MQTT username (client side) |
| `HeliumArchiver__Mqtt__Password` | MQTT password (client side) |
| `HeliumArchiver__Postgres__User` | Postgres app role for `helium_archive` |
| `HeliumArchiver__Postgres__Password` | Postgres app role password |

**2. Key `mosquitto`** (existing — broker side). The broker reads its users and
ACLs straight from this OpenBao key (fields `passwd.conf` / `acl.conf`; see
[mosquitto/README.MD](../mosquitto/README.MD)). Add the archiver as a read-only
consumer by appending to those two fields — the password **must match**
`HeliumArchiver__Mqtt__Password` above:

```
# add to the `passwd.conf` field (helmrelease hashes it on next sync):
helium-archiver:<same password as HeliumArchiver__Mqtt__Password>

# add to the `acl.conf` field:
user helium-archiver
topic read helium/#
```

**3. Key `cloudnative-pg`** (existing — *reused, nothing to add*):

| Field | Purpose |
| --- | --- |
| `Postgres__SuperPassword` | superuser pass for `postgres-init` bootstrap |

The app's ExternalSecret pulls from both `helium-archiver` and `cloudnative-pg`
(two `dataFrom.extract` blocks) so the super password is never duplicated.

## Removal

When the ChirpStack migration is finished:

1. Delete `kubernetes/apps/home/helium-archiver/` and its line in
   `kubernetes/apps/home/kustomization.yaml`.
2. Remove the `helium-archiver` lines from the `passwd.conf` and `acl.conf`
   fields of the OpenBao `mosquitto` key.
3. Revoke the OpenBao `helium-archiver` key.
4. `DROP DATABASE helium_archive;` on `postgres16` once the data is exported.
