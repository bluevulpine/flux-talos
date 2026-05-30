"""helium-archiver — subscribe to helium/# and persist every message.

Temporary archival/format-verification tool used while migrating off Helium
Console onto ChirpStack. It keeps a complete, durable record of raw uplink
payloads (and their decoded JSON) so the decoded schema can be checked for
drift across devices and over time.

Design notes:
  * QoS 1 + a persistent session (clean_session=false, stable client id) so the
    broker queues messages while we're restarting — we don't drop uplinks.
  * Auto-reconnect with exponential backoff (handled by paho's reconnect loop).
  * Never crash on a bad payload: non-JSON bodies are logged and stored raw.
"""

from __future__ import annotations

import logging
import os
import signal
import sys
from typing import Optional

import paho.mqtt.client as mqtt

from storage import Sink, build_sink, try_parse_json


def _env(name: str, default: Optional[str] = None, *, required: bool = False) -> str:
    val = os.environ.get(name, default)
    if required and not val:
        print(f"FATAL: required env var {name} is not set", file=sys.stderr)
        sys.exit(1)
    return val or ""


LOG_LEVEL = _env("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("helium-archiver")


def device_uuid_from_topic(topic: str) -> Optional[str]:
    """helium/<device-uuid>/rx -> <device-uuid>. None if it doesn't match."""
    parts = topic.split("/")
    if len(parts) >= 2 and parts[0] == "helium":
        return parts[1] or None
    return None


class Archiver:
    def __init__(self) -> None:
        self.topic = _env("MQTT_TOPIC", "helium/#")
        self.qos = int(_env("MQTT_QOS", "1"))
        self.host = _env("MQTT_HOST", required=True)
        self.port = int(_env("MQTT_PORT", "1883"))
        self.client_id = _env("MQTT_CLIENT_ID", "helium-archiver")

        self.sink: Sink = build_sink(
            _env("STORAGE_BACKEND", "postgres"),
            dsn=_env("HELIUM_DB_URL", required=True),
        )

        # clean_session=False -> persistent session: the broker retains our
        # subscription and queues QoS-1 messages while we're disconnected.
        self.client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=self.client_id,
            clean_session=False,
            protocol=mqtt.MQTTv311,
        )
        self.client.username_pw_set(
            _env("HELIUM_MQTT_USER", required=True),
            _env("HELIUM_MQTT_PASSWORD", required=True),
        )
        # Exponential-ish backoff between 1s and 2m on connection loss.
        self.client.reconnect_delay_set(min_delay=1, max_delay=120)
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_message = self._on_message

    # --- callbacks -------------------------------------------------------
    def _on_connect(self, client, userdata, flags, reason_code, properties=None):
        if reason_code != 0:
            log.error("MQTT connect failed: %s", reason_code)
            return
        # Re-subscribe on every (re)connect. With a persistent session the
        # broker remembers it, but subscribing again is cheap and safe.
        client.subscribe(self.topic, qos=self.qos)
        log.info(
            "connected to %s:%s, subscribed to %s (qos=%d, session_present=%s)",
            self.host, self.port, self.topic, self.qos, flags.session_present,
        )

    def _on_disconnect(self, client, userdata, flags, reason_code, properties=None):
        log.warning("MQTT disconnected (%s); paho will auto-reconnect", reason_code)

    def _on_message(self, client, userdata, msg: mqtt.MQTTMessage):
        try:
            raw = msg.payload.decode("utf-8", errors="replace")
        except Exception:  # noqa: BLE001 - decode should not raise with replace
            raw = repr(msg.payload)

        payload = try_parse_json(raw)
        if payload is None and raw.strip():
            log.info("non-JSON payload on %s, storing raw", msg.topic)

        try:
            self.sink.store(
                topic=msg.topic,
                device_uuid=device_uuid_from_topic(msg.topic),
                payload=payload,
                raw_payload=raw,
                qos=msg.qos,
                retain=msg.retain,
            )
        except Exception:  # noqa: BLE001 - never crash the consumer on a write
            log.exception("failed to persist message on %s", msg.topic)

    # --- lifecycle -------------------------------------------------------
    def run(self) -> None:
        self.sink.init()
        log.info("connecting to MQTT %s:%s as %s", self.host, self.port, self.client_id)
        self.client.connect(self.host, self.port, keepalive=60)
        self.client.loop_forever(retry_first_connection=True)

    def stop(self, *_args) -> None:
        log.info("shutting down")
        try:
            self.client.disconnect()
        finally:
            self.sink.close()


def main() -> None:
    archiver = Archiver()
    signal.signal(signal.SIGTERM, archiver.stop)
    signal.signal(signal.SIGINT, archiver.stop)
    archiver.run()


if __name__ == "__main__":
    main()
