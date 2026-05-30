-- helium-archiver: durable archive of every message under helium/#.
-- Applied idempotently by the subscriber on every start (see storage.py).
--
-- One wide row per MQTT message. The decoded JSON lands in `payload` (jsonb) so
-- schema-drift can be inspected with the jsonb operators (?| ? -> #>), while the
-- original on-the-wire string is always kept verbatim in `raw_payload` even when
-- the body is not valid JSON.

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

-- GIN index for key/containment queries used to detect decoded-schema drift,
-- e.g. find messages missing a key:  WHERE NOT (payload ?& array['decoded']);
CREATE INDEX IF NOT EXISTS helium_messages_payload_gin
    ON helium_messages USING gin (payload);

-- Per-device and time-window scans for cross-device / over-time comparisons.
CREATE INDEX IF NOT EXISTS helium_messages_device_idx
    ON helium_messages (device_uuid);
CREATE INDEX IF NOT EXISTS helium_messages_received_idx
    ON helium_messages (received_at);
