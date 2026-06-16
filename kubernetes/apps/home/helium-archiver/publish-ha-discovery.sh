#!/bin/bash
# Publishes MQTT discovery payloads for Helium devices to Home Assistant.
#
# Usage:
#   ./publish-ha-discovery.sh                 # publish NEW entities only (safe, no deletions)
#   ./publish-ha-discovery.sh --update-all    # tombstone + republish ALL (drops HA history!)
#   ./publish-ha-discovery.sh --update mailbox   # tombstone + republish one device by name
#
# Requires: kubectl access to the cluster with the home namespace visible.
#
# DC balance note: the homeassistant/sensor/helium_dc_balance entity below
# subscribes to helium/console/dc_balance — a rollup topic kept current by a
# HA automation that triggers on helium/+/rx and publishes dc.balance there.
# Create that automation in HA (Settings → Automations → Edit in YAML):
#
#   alias: "Helium: forward DC balance to rollup topic"
#   trigger:
#     - platform: mqtt
#       topic: "helium/+/rx"
#   action:
#     - service: mqtt.publish
#       data:
#         topic: "helium/console/dc_balance"
#         payload: "{{ trigger.payload_json.dc.balance }}"
#         retain: true
#   mode: queued
#   max: 5

set -euo pipefail

GOD_PASS=$(kubectl get secret mosquitto-secret -n home \
  -o jsonpath='{.data.passwd\.conf}' | base64 -d \
  | grep '^bluevulpine_god:' | cut -d: -f2)

del() {
  local topic="$1"
  kubectl exec -n home mosquitto-0 -c app \
    -- env PASS="$GOD_PASS" TOPIC="$topic" \
    sh -c 'mosquitto_pub -h localhost -p 1883 -u bluevulpine_god -P "$PASS" -r -t "$TOPIC" -n'
}

pub() {
  local topic="$1"
  local payload="$2"
  kubectl exec -n home mosquitto-0 -c app \
    -- env PASS="$GOD_PASS" TOPIC="$topic" PAYLOAD="$payload" \
    sh -c 'mosquitto_pub -h localhost -p 1883 -u bluevulpine_god -P "$PASS" -r -q 1 -t "$TOPIC" -m "$PAYLOAD"'
}

# ---------------------------------------------------------------------------
# Device: Mailbox Door Sensor — Dragino LDS02
# ---------------------------------------------------------------------------
MAILBOX_TOPIC="helium/85af3133-9c6e-4b6b-a245-44a72fa0883a/rx"
MAILBOX_ID="helium_85af3133"
MAILBOX_META='{"identifiers":["'"$MAILBOX_ID"'"],"name":"Mailbox Door Sensor (LDS02)","model":"LDS02","manufacturer":"Dragino"}'

tombstone_mailbox() {
  echo "Tombstoning mailbox door entities..."
  del "homeassistant/binary_sensor/mailbox_door/config"
  del "homeassistant/sensor/mailbox_door_open_count/config"
  del "homeassistant/sensor/mailbox_door_battery/config"
  sleep 5
}

publish_mailbox() {
  echo "Publishing mailbox door entities..."
  pub "homeassistant/binary_sensor/mailbox_door/config" \
    '{"name":"Mailbox Door","unique_id":"mailbox_door_status","state_topic":"'"$MAILBOX_TOPIC"'","value_template":"{{ value_json.decoded.payload.DOOR_OPEN_STATUS }}","payload_on":1,"payload_off":0,"device_class":"door","expire_after":7200,"device":'"$MAILBOX_META"'}'

  pub "homeassistant/sensor/mailbox_door_open_count/config" \
    '{"name":"Mailbox Door Open Count","unique_id":"mailbox_door_open_count","state_topic":"'"$MAILBOX_TOPIC"'","value_template":"{{ value_json.decoded.payload.DOOR_OPEN_TIMES }}","state_class":"total_increasing","device":{"identifiers":["'"$MAILBOX_ID"'"]}}'

  pub "homeassistant/sensor/mailbox_door_battery/config" \
    '{"name":"Mailbox Door Battery","unique_id":"mailbox_door_battery_v","state_topic":"'"$MAILBOX_TOPIC"'","value_template":"{{ value_json.decoded.payload.BAT_V }}","unit_of_measurement":"V","device_class":"voltage","state_class":"measurement","suggested_display_precision":3,"device":{"identifiers":["'"$MAILBOX_ID"'"]}}'
}

# ---------------------------------------------------------------------------
# Device: Soil Moisture Sensor — soilmoisture-2133A0023
# ---------------------------------------------------------------------------
SOIL_TOPIC="helium/f8543681-e422-42fb-9c41-e24220d6a2a8/rx"
SOIL_ID="helium_f8543681"
SOIL_META='{"identifiers":["'"$SOIL_ID"'"],"name":"Soil Moisture Sensor (2133A0023)"}'

tombstone_soil() {
  echo "Tombstoning soil sensor entities..."
  del "homeassistant/sensor/soil_moisture/config"
  del "homeassistant/sensor/soil_temp/config"
  del "homeassistant/sensor/soil_ambient_temp/config"
  del "homeassistant/sensor/soil_ambient_humidity/config"
  del "homeassistant/sensor/soil_ambient_light/config"
  sleep 5
}

publish_soil() {
  echo "Publishing soil sensor entities..."

  pub "homeassistant/sensor/soil_moisture/config" \
    '{"name":"Soil Moisture","unique_id":"soil_moisture_gwc","state_topic":"'"$SOIL_TOPIC"'","value_template":"{{ (value_json.decoded.payload.soil_gwc * 100) | round(1) }}","unit_of_measurement":"%","icon":"mdi:water-percent","state_class":"measurement","expire_after":3600,"device":'"$SOIL_META"'}'

  pub "homeassistant/sensor/soil_temp/config" \
    '{"name":"Soil Temperature","unique_id":"soil_temp_c","state_topic":"'"$SOIL_TOPIC"'","value_template":"{{ value_json.decoded.payload.soil_temp | round(2) }}","unit_of_measurement":"°C","device_class":"temperature","state_class":"measurement","suggested_display_precision":2,"expire_after":3600,"device":{"identifiers":["'"$SOIL_ID"'"]}}'

  pub "homeassistant/sensor/soil_ambient_temp/config" \
    '{"name":"Soil Sensor Ambient Temperature","unique_id":"soil_ambient_temp_c","state_topic":"'"$SOIL_TOPIC"'","value_template":"{{ value_json.decoded.payload.ambient_temp | round(1) }}","unit_of_measurement":"°C","device_class":"temperature","state_class":"measurement","suggested_display_precision":1,"expire_after":3600,"device":{"identifiers":["'"$SOIL_ID"'"]}}'

  pub "homeassistant/sensor/soil_ambient_humidity/config" \
    '{"name":"Soil Sensor Ambient Humidity","unique_id":"soil_ambient_humidity","state_topic":"'"$SOIL_TOPIC"'","value_template":"{{ value_json.decoded.payload.ambient_humidity | round(1) }}","unit_of_measurement":"%","device_class":"humidity","state_class":"measurement","suggested_display_precision":1,"expire_after":3600,"device":{"identifiers":["'"$SOIL_ID"'"]}}'

  pub "homeassistant/sensor/soil_ambient_light/config" \
    '{"name":"Soil Sensor Ambient Light","unique_id":"soil_ambient_light","state_topic":"'"$SOIL_TOPIC"'","value_template":"{{ value_json.decoded.payload.ambient_light }}","unit_of_measurement":"lx","device_class":"illuminance","state_class":"measurement","expire_after":3600,"device":{"identifiers":["'"$SOIL_ID"'"]}}'
}

# ---------------------------------------------------------------------------
# Helium Console account — DC balance (device-independent rollup topic)
# ---------------------------------------------------------------------------
tombstone_console() {
  echo "Tombstoning Helium Console entities..."
  del "homeassistant/sensor/helium_dc_balance/config"
  sleep 5
}

publish_console() {
  echo "Publishing Helium Console entities..."
  pub "homeassistant/sensor/helium_dc_balance/config" \
    '{"name":"Helium DC Balance","unique_id":"helium_dc_balance","state_topic":"helium/console/dc_balance","state_class":"measurement","icon":"mdi:database"}'
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
MODE="${1:-new}"
TARGET="${2:-}"

case "$MODE" in
  --update-all)
    tombstone_mailbox
    tombstone_soil
    tombstone_console
    publish_mailbox
    publish_soil
    publish_console
    ;;
  --update)
    case "$TARGET" in
      mailbox)  tombstone_mailbox;  publish_mailbox  ;;
      soil)     tombstone_soil;     publish_soil     ;;
      console)  tombstone_console;  publish_console  ;;
      *) echo "Unknown target '$TARGET'. Use: mailbox, soil, console" && exit 1 ;;
    esac
    ;;
  new|"")
    publish_mailbox
    publish_soil
    publish_console
    ;;
  *)
    echo "Usage: $0 [--update-all | --update <mailbox|soil|console>]"
    exit 1
    ;;
esac

echo "Done. Entities appear in HA within a few seconds; states populate on next uplink."
