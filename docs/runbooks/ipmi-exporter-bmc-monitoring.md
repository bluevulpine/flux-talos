# Runbook: BMC power & sensor monitoring (ipmi_exporter → vault)

Scrapes the vault NAS's IPMI 2.0 BMC (Supermicro X9DR3-F, 10.0.10.2) for
system power, temperatures, fans, voltages, and chassis state. Fills a real
gap: `truenas-exporter` collects pools/ARC/errors but no power or thermals,
and vault is not on a metered PDU outlet.

Motivating number (2026-09-18): `ipmitool dcmi power reading` reported **263 W
average over a 42-day sampling window** — ~$271/yr at $0.1177/kWh, larger than
the entire rest of the rack's metered PDU draw combined.

## Architecture

`prometheuscommunity/ipmi-exporter` in **remote/RMCP mode**: the exporter runs
in-cluster (observability ns) and opens an IPMI session to the BMC over the
network. Prometheus uses the **multi-target** pattern — it scrapes the
exporter's `/ipmi` endpoint (port 9290) with `?target=10.0.10.2&module=default`,
relabeled from a ScrapeConfig. This is the same shape as blackbox/snmp exporter.

The BMC password cannot be passed as an env var — it lives inside the
exporter's `config.yml`. So the **entire config file is rendered from OpenBao**
via ExternalSecret and mounted read-only; the password never touches git.

Manifests: `kubernetes/apps/observability/ipmi-exporter/`.

## Prerequisites (do these BEFORE the manifests reconcile)

The manifests reference an OpenBao key `ipmi` and a BMC account that do not
exist yet. Create both first, or the ExternalSecret fails and the pod has no
config.

### 1. Create a dedicated, least-privilege BMC account

Run on vault (in-band KCS needs no BMC creds), or remotely with the current
ADMIN creds. First find a free user slot on the **LAN channel** (X9 LAN is
channel 1):

```bash
ipmitool user list 1          # find an unused slot id, e.g. 3
ipmitool user set name 3 prometheus
ipmitool user set password 3 '<generated-password>'
# privilege 2 = USER (read-only-ish, cannot power-cycle) — try this FIRST
ipmitool channel setaccess 1 3 callin=on ipmi=on link=on privilege=2
ipmitool user enable 3
```

**The privilege reality on this board (measured 2026-09-21):** system watts
require **ADMINISTRATOR** (privilege 4), full stop. DCMI returns "insufficient
privilege (d4)" at OPERATOR, and the X9DR3-F's SDR exposes **no power sensor at
any level** (only temps/fans/voltages/chassis), so there is no lower-privilege
route to the number. `externalsecret.yaml` therefore sets `privilege: "admin"`.

```bash
ipmitool -I lanplus -H 10.0.10.2 -U ADMIN -P '<adminpass>'   channel setaccess 1 3 privilege=4        # 4 = ADMINISTRATOR
```

freeipmi/ipmitool privilege numbers: 2=USER, 3=OPERATOR, 4=ADMINISTRATOR.

This is more privilege than a scraper ideally holds — an ADMIN BMC account can
power off vault and reconfigure the BMC. Accepted here because (a) the power
number is the whole motivation and there is no other path to it on this board,
(b) the account is dedicated, (c) its password lives only in OpenBao, and (d)
the mgmt IP is LAN-only. If you only want environmental data, set the account
to OPERATOR, change `privilege: "admin"` → `"operator"`, and drop the `dcmi`
collector — you keep temps/fans/voltages/chassis and lose watts.

**Two X9 credential gotchas that cost real time here:**
- **Passwords must be ≤ 16 characters.** A 20-char password set cleanly but
  failed RMCP+ auth with "Unable to establish IPMI v2 / RMCP+ session" — the
  ATEN BMC stores 16-byte passwords and the longer one never matched.
- `Set Session Privilege Level to ADMINISTRATOR failed (0x80)` with no `-L` is
  harmless noise: ipmitool defaults to requesting ADMIN, which a non-ADMIN
  account cannot be granted. It is not the error to chase.

### 2. Close the default-credential hole

`ADMIN/ADMIN` currently works on this BMC over the LAN — an X9-era IPMI stack
with factory creds on a routable management IP. Change it in the same session:

```bash
ipmitool user list 1                      # find the ADMIN slot (usually 2)
ipmitool user set password 2 '<new-admin-password>'
```

Store the new ADMIN password somewhere durable (it is the break-glass account).

### 3. Put the scraper creds in OpenBao

```bash
bao kv put secret/ipmi \
  Ipmi__Vault__User=prometheus \
  Ipmi__Vault__Pass='<generated-password>'
```

Field names are PascalCase double-underscore per repo convention; the
ExternalSecret templates `{{ .Ipmi__Vault__User }}` / `{{ .Ipmi__Vault__Pass }}`.

### 4. Then commit the manifests

Only after 1–3 exist. Push, let the webhook reconcile, and verify:

```bash
kubectl -n observability logs deploy/ipmi-exporter | tail
# through Thanos/Prometheus:
#   ipmi_dcmi_power_consumption_watts{instance="vault-ipmi"}
#   ipmi_temperature_celsius, ipmi_fan_speed_rpm, ipmi_voltage_volts
```

If power is missing but temps/fans are present, it is the privilege gotcha
(step 1). If everything is missing, check the exporter log for RMCP auth
failures (wrong channel, account not enabled, or wrong privilege).

## Home Assistant energy dashboard (built)

HA cannot pull Prometheus, so ipmi-exporter alone does not reach HA. A small
publisher (`kubernetes/apps/home/vault-power-mqtt/`) bridges it over MQTT, the
repo's established HA path.

**How it works.** An `eclipse-mosquitto` pod (which ships both `mosquitto_pub`
and BusyBox `wget`/`awk`) reads the **already-running exporter's** endpoint —
`http://ipmi-exporter.observability.svc:9290/ipmi?target=10.0.10.2&module=default`
— every 30s, greps `ipmi_dcmi_power_consumption_watts`, and publishes it to
`homeassistant/sensor/vault_power/state`. So there is still exactly one BMC
poller (the exporter) and no BMC credential in this pod. A retained MQTT
discovery message creates the HA entity (`device_class: power`,
`state_class: measurement`, `expire_after: 150`).

**Setup — provision a dedicated, ACL-scoped broker user.** This follows the
repo convention (`minnkota-collector`, `telegraf` each have their own scoped
user, not the shared `mqtt_publisher`). mosquitto users live as **plaintext
`user:password` in the OpenBao `mosquitto` key's `passwd.conf` field**; a hasher
sidecar runs `mosquitto_passwd -U` and SIGHUPs the broker — no restart.

Two gotchas, both bite silently:
- `passwd.conf` has **no trailing newline** — append with a leading `\n` or you
  merge into the previous user's line and break their login too.
- After editing the `mosquitto` key you **must force the mosquitto
  ExternalSecret to resync** or the hasher never sees the new user.

Run locally (bao authenticated as root), keeping the password out of any
transcript:

```bash
PW=$(openssl rand -base64 18)          # no shell-special chars in the pw

# Rebuild passwd.conf: existing content (command substitution strips ANY
# trailing newlines) + exactly one newline + the new user. This is robust
# whether or not `bao ... -field` emits a trailing newline.
OLD_PASSWD=$(bao kv get -field=passwd.conf secret/mosquitto)
printf '%s\nvault-power:%s\n' "$OLD_PASSWD" "$PW" > /tmp/passwd.conf

OLD_ACL=$(bao kv get -field=acl.conf secret/mosquitto)
printf '%s\n\nuser vault-power\ntopic write homeassistant/sensor/vault_power/#\n' \
  "$OLD_ACL" > /tmp/acl.conf

# VERIFY before writing — the last lines should be the new user, no merged line
tail -3 /tmp/passwd.conf; echo '---'; tail -4 /tmp/acl.conf

bao kv patch secret/mosquitto passwd.conf=@/tmp/passwd.conf acl.conf=@/tmp/acl.conf
rm -f /tmp/passwd.conf /tmp/acl.conf

# the app's own key the ExternalSecret reads
bao kv put secret/vault-power-mqtt \
  VaultPower__Mqtt__User=vault-power \
  VaultPower__Mqtt__Password="$PW"

# force the broker to pick up the new user (hasher rehashes + SIGHUPs, no restart)
kubectl -n home annotate externalsecret mosquitto-secret \
  force-sync="$(date +%s)" --overwrite
```

Sanity-check the broker accepted it (no restart needed):

```bash
kubectl -n home get secret mosquitto-secret \
  -o jsonpath='{.data.passwd\.conf}' | base64 -d | cut -d: -f1 | grep -x vault-power
```

Until `secret/vault-power-mqtt` exists the publisher's ExternalSecret stays
unsynced and its pod has no MQTT password (same staged pattern as the exporter).

**The one HA-side step (only you can do this).** The Energy dashboard consumes
**energy** (kWh, `state_class: total_increasing`), but the BMC gives
instantaneous **power** (W). Convert in HA with a Riemann-sum integration
helper on the `sensor.vault_power` entity:

  Settings → Devices & Services → Helpers → Create Helper →
  Integration - Riemann sum integral
    Input sensor: sensor.vault_power
    Metric prefix: k (kilo), Time unit: h (hours), Method: Left/Trapezoidal

That yields `sensor.vault_power_integral` in kWh, which the Energy dashboard
accepts as an "Individual device". HA owns the accumulation, so it survives
publisher restarts.

**Changing the discovery config later:** publish an empty retained message to
`homeassistant/sensor/vault_power/config` first (tombstone), wait ~5s, then let
the pod republish — HA ignores an updated payload for an existing unique_id
otherwise (drops history for that entity; see the ha-mqtt-discovery note).

## Scope of what this account can do

The scraper account is LAN-channel, USER or OPERATOR privilege, password in
OpenBao only. It can read all sensors and (at OPERATOR) power-control the
chassis, but cannot alter BMC users, network, or config. The break-glass ADMIN
account is separate and should no longer be on default credentials.
