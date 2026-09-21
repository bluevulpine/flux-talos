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

## Home Assistant energy dashboard (secondary goal — NOT YET BUILT)

HA cannot pull Prometheus, so ipmi_exporter alone does not reach HA. The
conducive path is MQTT, which is this repo's established HA mechanism
(discovery to `homeassistant/<type>/<id>/config`; see
`kubernetes/apps/home/helium-archiver/publish-ha-discovery.sh`).

The energy dashboard specifically wants an **energy** sensor (kWh,
`state_class: total_increasing`), but the BMC gives instantaneous **power** (W).
Two ways to bridge:

- **Publish power (W), integrate in HA (recommended).** A small in-cluster
  publisher reads `dcmi power reading` and publishes W to MQTT with
  `device_class: power`, `state_class: measurement`. In HA, a Riemann-sum
  integration helper converts W → kWh for the dashboard. Robust across
  restarts; HA owns the accumulation. One HA-side helper to create.
- **Publish energy (kWh) directly.** The publisher maintains a persistent
  running kWh total and publishes `total_increasing`. No HA-side helper, but
  the publisher must persist state and handle resets carefully. More fragile.

Either needs mosquitto creds in the observability namespace (mosquitto is a
LoadBalancer in the `home` ns, 172.16.8.8:1883) via an ExternalSecret. This
half is proposed, not built.

## Scope of what this account can do

The scraper account is LAN-channel, USER or OPERATOR privilege, password in
OpenBao only. It can read all sensors and (at OPERATOR) power-control the
chassis, but cannot alter BMC users, network, or config. The break-glass ADMIN
account is separate and should no longer be on default credentials.
