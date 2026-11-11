# vinyl-bridge

A fake UPnP speaker named **Vinyl** that the Victrola Stream Onyx turntable autoplays to. It
plays nothing. When the Victrola starts a record, the bridge calls a Home Assistant webhook with
the stream URL, and HA has Music Assistant play that URL on the speakers it picks. When the record
ends, the bridge calls the webhook again with `stop`. The HA side is `packages/vinyl.yaml` in
esphome-hass.

## Why a bridge

- The Victrola's autoplay sends a record to exactly one default speaker, either a Sonos group or
  a UPnP renderer, with `SetAVTransportURI` + `Play`. Nothing else learns that a record started.
- It finds UPnP renderers only on its own VLAN (30), because SSDP does not cross VLANs and UniFi
  relays mDNS only. Music Assistant runs on HA, which is on VLAN 50.
- Its lossless stream (Ogg FLAC, 48 kHz, 24-bit) is offered only to UPnP renderers. In Sonos
  mode it serves 320 kbps MP3 and AAC HLS.
- It never sends `Stop`: none arrived in 3.7 h of testing on 2026-11-10. With the needle parked,
  the stream carries digital silence instead.
- Music Assistant's own DLNA Receiver, upstream PR music-assistant/server#3611, would replace
  this. A weekly routine watches that PR.

## Behaviour

| Victrola does | Bridge does |
|---|---|
| `SetAVTransportURI` FLAC URL + `Play` (twice) | `start` webhook once, then reads the stream continuously |
| ~100 s later, `SetAVTransportURI` MP3 URL + `Play` | Ignores it while the FLAC stream still flows; logged as `ignoring mp3 URI` |
| Needle parked (FLAC drops below `SILENCE_BPS` for `SILENCE_SECONDS`) | `stop` webhook; keeps reading |
| Next side (byte rate back up) | `start` webhook again |
| FLAC stream dies (5 retries) | `stop` webhook; a new URI + `Play` starts over |
| `Stop` (never observed) | `stop` webhook |

The MP3 fallback was most likely triggered by the 2026-11-10 test renderer reading 64 KB and then
going quiet. This bridge reads the stream the whole time, so the fallback may never happen. That
is unverified until it runs.

On MP3 the bitrate is constant, so silence cannot be detected and no automatic stop is sent.

## Networking

- **`net1`, the Multus `vlan-30` macvlan:** carries SSDP, the UPnP control server the Victrola
  talks to, and the stream fetch. The IP and MAC are static, like scrypted's, so a UniFi DHCP
  reservation can hold them.
- **`eth0`, the cluster network:** carries the webhook. It goes to `homeassistant.funb.us` by
  name, so HA can change VLAN or address without touching this app.
- **Probes:** the HTTP server listens on all interfaces, so the kubelet can probe `/healthz` on
  the pod IP. A node cannot reach its own macvlan children.

## Before it lands

1. **The VLAN 30 address and MAC** are `192.168.30.13` and `de:ad:be:ef:30:13`, with a UniFi
   fixed-IP reservation (2026-11-11), because the DHCP range covers .6-254. To change them,
   change the annotation, `BIND_IP` and the reservation together.
2. **The webhook id** (minted 2026-11-11) is in OpenBao in two places that must match:
   - `secret/vinyl-bridge` `VinylBridge__HaWebhookId`, read by the ExternalSecret.
   - `secret/esphome` `vinyl_bridge_webhook_id`, which `scripts/secrets-from-bao.sh` writes
     into esphome-hass `secrets.yaml` so HA's `!secret` resolves.
   - To rotate it, `bao kv patch` both (never `put` on `secret/esphome`), then rerun the
     script with `-f`.
3. **Land the HA package and reload automations and scripts.** `packages/vinyl.yaml` must be
   loaded before the Victrola is pointed at Vinyl.
4. **Point the Victrola at Vinyl.** In the Victrola app, set the output to UPnP and select
   **Vinyl**. It is remembered by UDN, which is derived from `UDN_SEED`, so it survives
   restarts. Changing `UDN_SEED` means selecting Vinyl again.

## Tuning

- `SILENCE_BPS` (default 64 kbit/s): music FLAC runs about 1 Mbit/s, and parked-needle silence
  is close to zero.
- `SILENCE_SECONDS` (default 45): long enough for a quiet passage or the lead-in groove.
- Check both against the logs after the first few records.

```bash
kubectl --context admin@home-kubernetes -n home logs deploy/vinyl-bridge -f
```
