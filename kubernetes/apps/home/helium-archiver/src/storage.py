"""Storage backends for the helium archiver.

The subscriber talks to a tiny `Sink` interface, so swapping Postgres for
another datastore (CouchDB, S3, ...) is a matter of writing a new class and
changing one line in ``build_sink``. Postgres JSONB is the default and only
implemented backend today — see README.MD for the comparison.
"""

from __future__ import annotations

import json
import logging
import pathlib
from typing import Optional, Protocol

import psycopg
from psycopg import sql

log = logging.getLogger("helium-archiver.storage")

SCHEMA_PATH = pathlib.Path(__file__).with_name("schema.sql")


class Sink(Protocol):
    """Minimal write interface every storage backend must implement."""

    def init(self) -> None:
        """Prepare the backend (apply migrations, create buckets, ...)."""

    def store(
        self,
        *,
        topic: str,
        device_uuid: Optional[str],
        payload: Optional[dict],
        raw_payload: str,
        qos: int,
        retain: bool,
    ) -> None:
        """Persist a single message. Must not raise on malformed payloads."""

    def close(self) -> None:
        ...


class PostgresSink:
    """Append-only writer into the ``helium_messages`` JSONB table."""

    def __init__(self, dsn: str) -> None:
        self._dsn = dsn
        # autocommit: each insert is its own tiny transaction; we never want a
        # poison message to roll back a batch (there are no batches).
        self._conn = psycopg.connect(dsn, autocommit=True)

    def init(self) -> None:
        ddl = SCHEMA_PATH.read_text(encoding="utf-8")
        with self._conn.cursor() as cur:
            cur.execute(ddl)
        log.info("schema applied (helium_messages ready)")

    def store(
        self,
        *,
        topic: str,
        device_uuid: Optional[str],
        payload: Optional[dict],
        raw_payload: str,
        qos: int,
        retain: bool,
    ) -> None:
        # psycopg adapts a python dict to jsonb via Json(); None -> SQL NULL.
        payload_param = psycopg.types.json.Jsonb(payload) if payload is not None else None
        with self._conn.cursor() as cur:
            cur.execute(
                sql.SQL(
                    """
                    INSERT INTO helium_messages
                        (topic, device_uuid, payload, raw_payload, qos, retain)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    """
                ),
                (topic, device_uuid, payload_param, raw_payload, qos, retain),
            )

    def close(self) -> None:
        try:
            self._conn.close()
        except Exception:  # noqa: BLE001 - best effort on shutdown
            pass


def build_sink(backend: str, *, dsn: str) -> Sink:
    """Factory: map the STORAGE_BACKEND env value to a concrete Sink."""
    backend = (backend or "postgres").lower()
    if backend == "postgres":
        return PostgresSink(dsn)
    raise ValueError(
        f"unsupported STORAGE_BACKEND={backend!r}; "
        "only 'postgres' is implemented (see storage.py to add another)"
    )


def try_parse_json(raw: str) -> Optional[dict]:
    """Return the decoded object, or None if the body is not a JSON object."""
    try:
        value = json.loads(raw)
    except (ValueError, TypeError):
        return None
    # Only objects/arrays are meaningful jsonb here; scalars get kept as raw only.
    if isinstance(value, (dict, list)):
        return value
    return None
