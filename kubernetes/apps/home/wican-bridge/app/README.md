# wican-bridge

Telegraf bridge: WiCAN Pro (EV9 OBD-II dongle) → mosquitto MQTT → InfluxDB.

The WiCAN publishes its E-GMP battery telemetry (Ioniq 9 profile) over MQTT as a
FLAT JSON object on `wican/fc012cdbd521/automate`
(`{"SOC":94,"KWH_CHARGED":931,"HV_A":...,"LV_V":14.6,...}` — confirmed live; the
webhook variant wraps it in `autopid_data`, MQTT does not). This bridge subscribes,
turns each numeric key into a field, and writes to the **`kia-wican`** bucket as:

- measurement: `wican`
- tag: `device=fc012cdbd521`
- fields: `SOC`, `SOC_D`, `SOH`, `KWH_CHARGED`, `LV_V`, `HV_C_V_MIN/MAX`, `HV_T_*`, `HV_A`, `HV_W`, …

Query example (Flux):
```flux
from(bucket:"kia-wican") |> range(start:-30d)
 |> filter(fn:(r)=> r._measurement=="wican" and r._field=="KWH_CHARGED")
 |> last()
```

## Provisioned cluster state (already done — 2026-08-22)

- InfluxDB bucket **`kia-wican`** (`00e7f7e0c13b69d5`, org `homelab`, infinite retention).
- A write-scoped InfluxDB token, minted in-pod and stored in OpenBao
  `secret/wican-bridge` → `WicanBridge__InfluxdbToken` (never left the cluster).
- OpenBao `secret/wican-bridge` with `WicanBridge__MqttUsername=telegraf`,
  `WicanBridge__MqttPassword`, `WicanBridge__InfluxdbToken`.
- A read-only mosquitto user `telegraf` (`topic read wican/#`) — appended to the
  OpenBao `mosquitto` item's `passwd.conf`/`acl.conf`; the hasher sidecar rehashed
  and SIGHUP'd the broker (no restart).

## Remaining actions to get data flowing

1. **On the WiCAN device**: point the autopid **Destination at MQTT** (it currently
   posts to a webhook, which is why MQTT only shows basic data). Publish to a topic
   under `wican/fc012cdbd521/` — anything matching `wican/fc012cdbd521/#` is picked up.
   Retiring the webhook also stops leaking its `api_key`/`token` (query params) into
   the echo-server logs.
2. **Deploy this app**: commit the branch and let Flux reconcile. The ExternalSecret
   renders `wican-bridge-secret`, then:
   ```bash
   kubectl -n home logs deploy/wican-bridge -f   # expect MQTT connect + writes
   ```
3. **First-wake validation**: confirm the live MQTT payload matches the assumed
   `autopid_data` wrapper (it should). `KWH_CHARGED` should read ~918 (matches the
   BMS counter seen in the webhook capture; our SoC-delta window estimate was ~640,
   the difference being lifetime-since-BMS-flash vs the July→Aug telemetry window).

## Known profile issue (device-side, not this bridge)

With the Ioniq 9 profile the EV9 mis-scales **`HV_A` / `HV_W`** (signed-as-unsigned:
`HV_A` reads ~6553 A at rest; `HV_W` = HV_V×HV_A is therefore ~4 MW). `SOC`, `SOH`,
`KWH_CHARGED`, `LV_V`, cell voltages, and temperatures look correct. Fix the HV
current PID expression on the device before trusting instantaneous power.

## Notes
- Broker reached in-cluster on plain `1883`; TLS `8883` is for the WiCAN over the
  internet. Keep the bridge on `1883`.
- A dedicated Grafana read token + `kia-wican` datasource (mirroring the minnkota
  pattern) is a sensible follow-up for dashboards.
- Alternative considered: a purpose-built Python consumer to match the house
  collector style. Telegraf was chosen for the MVP because the transform is pure config.
