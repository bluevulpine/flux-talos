# rackpanel — coordinated cluster display across the four Pi front panels

**Date:** 2026-08-18
**Status:** Design — accepted. Phase 0 hardware probe complete and passing.
**Goal:** Turn the four UCTRONICS RM0004 front panels in the Pi Rack Pro into a
single coordinated display of *cluster-wide* state, plus an internal web mirror
at `rackview.${SECRET_DOMAIN}`.

## Motivation

Four of the seven nodes (`jormungandr1`–`4`) are Raspberry Pi 4s in a UCTRONICS
Pi Rack Pro, each with a front-panel LCD. They have shown the vendor's default
boot image since installation — lit, bright, and conveying nothing.

The rack lives in the basement, on the path to the laundry and the ice machine.
The realistic value is therefore, in order: it should **look good**, it should
answer *"is anything broken?"* on a two-second walk-past, and it should
occasionally be interesting enough to stop and read. It is explicitly **not** a
break-glass diagnostic tool — that frees the design to depend on the API server,
Prometheus, Thanos and Alertmanager, which removes the ugliest possible
constraint.

The other three workers (`brokkr01`–`03`) are amd64 and have no panels. So the
four displays must describe the *whole* cluster, not the node each is bolted to.

## Hardware facts

Established by reading `github.com/UCTRONICS/SKU_RM0004` (cloned at
`~/Repositories/pirackpro`), not assumed:

- The panel is **not an OLED**. It is an **ST7735 160×80 RGB565 TFT LCD**
  (`hardware/st7735/st7735.h`).
- The Pi does not drive the panel directly. An **MCU at I²C address `0x18`**
  accepts register writes — coordinates (`0x2A`/`0x2B`), pixel data (`0x2C`),
  burst (`0x01`), sync (`0x03`), scan direction (`0x36`) — and relays to the
  ST7735.
- Bursts are capped at **160 bytes** (`BURST_MAX_LENGTH`).
- A full frame is **160 × 80 × 2 = 25,600 bytes**.
- **There is no brightness, backlight or display-off command** in the protocol,
  in the C API, or in the Python wrapper. The backlight is presumed hardwired on.
- `lcd_begin()` performs **no init sequence** — it only opens the bus and sets
  the slave address. The MCU initialises the ST7735 itself, which is also why the
  vendor boot image persists until something overwrites it.

### Two protocol details that are load-bearing

Both were established the hard way in Phase 0 and must not be dropped:

1. **The 700 µs delay after every 160-byte burst chunk is mandatory.** Without
   it the MCU silently drops bytes; the write pointer falls progressively
   further behind across rows and the un-written pixels retain the *previous*
   frame's content, tracing a diagonal artefact. Commands additionally take a
   10 µs delay, per the vendor driver.
2. **The MCU never stretches the clock.** Measured across three full-screen
   fills: zero stretch events. Clock-stretch handling was implemented, proven
   unnecessary, and costs ~30 % throughput — the agent should omit it. Recorded
   here because "the diagonal was clock stretching" is a plausible-sounding
   conclusion that the instrument contradicted.

### Consequence: the wear question mostly dissolves

The original framing assumed OLED wear-levelling (inverting every 24 h, pixel
shifting). That does not apply here. A transmissive TFT has no per-pixel emitter
to degrade; one shared backlight lights every pixel and ages identically
regardless of content. Since the backlight also cannot be dimmed or switched
off, *no* scheduling strategy saves any hours.

The one genuine risk on a cheap TFT is **transient image retention** from a
high-contrast static image left for months — precisely what has been happening.
Content that changes every twenty seconds eliminates it completely and may
relax what is already there. **The rotation is the wear mitigation.** Nothing
further is needed.

One unverified possibility: `i2c_write_command()` is a generic passthrough, so
the MCU *might* forward a raw `ST7735_DISPOFF` (`0x28`). That would blank the
pixels but not the LED backlight. Probed in Phase 0; not relied upon.

## The controlling constraint: there is no I²C bus

The Pis run Talos v1.13.x. The kernel has everything needed — but no adapter is
instantiated. Established by probing `jormungandr4` (and `jormungandr1`):

| Probe | Result |
| --- | --- |
| `/sys/class/i2c-dev` | exists → `i2c-dev` built in |
| `/sys/bus/platform/drivers` | contains `i2c-bcm2835` → driver built in |
| `/sys/bus/i2c/devices` | **empty** |
| `/dev/i2c-*` | **absent** |
| `/proc/iomem` | `fe200000.gpio` present, **no BSC at `fe804000`** |
| `/lib/modules/.../i2c/busses` | only `i2c-i801.ko` (Intel) — nothing to load |

The drivers are present; the device tree simply has `i2c_arm` off.

### Why the documented fix does not apply here

The standard remedy is `dtparam=i2c_arm=on` in `config.txt`, supplied through
the `rpi_generic` overlay's `configTxtAppend` in the Image Factory schematic.
**That is the wrong path for this cluster.** Established by probing:

| Probe | Result | Consequence |
| --- | --- | --- |
| Factory schematic `a6c707bf…` | `customization` only, **no `overlay:`** | not an SBC/u-boot install |
| `/boot` | contains only `EFI/` | no `config.txt`, no u-boot, no DTBs |
| `/sys/firmware` | `efi`, `dmi` | EDK2 UEFI, not u-boot |
| `sda` partitions | EFI / BIOS / BOOT / META / STATE / EPHEMERAL | stock Talos, no firmware partition |
| block devices | **no `mmcblk*`** | no SD card → firmware is in SPI EEPROM |

These Pis boot **pftf/RPi4 EDK2 UEFI from SPI EEPROM**, with Talos on a USB SSD.
There is no `config.txt` on any accessible medium, and Talos never reads one.

> **Do not add an `overlay:` block to the Pi schematic in `talconfig.yaml`.**
> It instructs the installer to write u-boot and `config.txt` to the boot media
> of a machine whose firmware boots UEFI from SPI. Best case the files are
> ignored; worst case the node does not boot and needs physical recovery.

Two further escapes were checked and are also closed:

- `/sys/kernel/config` has **no `device-tree`** entry → runtime DT overlays are
  not compiled into the Talos kernel.
- **`/dev/mem` is absent** → peripheral registers cannot be mmap'd, so a
  userspace driver for the BSC block is not possible either.

### The way through: bit-bang I²C over GPIO

`/dev/gpiochip0` is present and is `pinctrl-bcm2711` (58 lines). GPIO 2 (SDA1)
and GPIO 3 (SCL1) — the exact pins the RM0004 uses — are lines 2 and 3 on it.
A **userspace I²C master via libgpiod** therefore needs no firmware change, no
physical access, no reinstall, and carries no risk to a running node.

This is sound rather than merely clever because **I²C has no minimum clock
rate**. The master drives the clock, so scheduling jitter on a busy Kubernetes
node makes a transfer slower, never incorrect. (The same trick would be reckless
for SPI or WS2812, which have timing floors.)

**Throughput profile, measured on `jormungandr4`** (Python, three ioctls per
bit, vendor delays in place):

| Operation | Bytes | Time |
| --- | --- | --- |
| raw `GPIO_V2_LINE_SET_VALUES` ioctl | — | **5.19 µs** |
| full frame (160×80) | 26,335 | **4.40 s** |
| one eighth (160×8) | ~2,600 | 434 ms |
| one row (160×1) | ~330 | **59 ms** |

Cost is **purely proportional to bytes** — the band and row figures sit exactly
on the 80 × 55 ms line, so there is no fixed overhead worth optimising. The
pre-probe estimate of 100–250 kbit/s was optimistic; actual is ~64 kbit/s
ceiling in Python.

**The 5.19 µs ioctl is the entire bottleneck.** A raw `ioctl` syscall on arm64
costs roughly 1 µs; the remainder is interpreter overhead. A compiled agent
should therefore reach ~1–1.5 µs, i.e. **a full frame near 1.2 s**. *(Projection
from the syscall floor, not a measurement.)*

This makes the agent's language a **requirement, not a preference**:

- Routine diffed updates are fine even in Python — a scene where a few numbers
  change touches 10–20 rows, so 0.6–1.1 s now, 0.2–0.3 s compiled.
- **Scene transitions are what force it.** A full repaint at 4.4 s against a 20 s
  dwell spends 22 % of the cycle wiping. At ~1.2 s the banded wipe reads as
  deliberate. **The panel-agent must be Go or Rust.**

Note the conductor has no such constraint — it is not latency-bound and can use
Python/Pillow if that gives better rendering. That argues for two images rather
than the one multi-arch image assumed under Deployment; the implementation plan
should settle it.

Fallbacks, all requiring physical access and all deferred until after
measurement: reflash the SPI EEPROM with firmware that enables `i2c_arm`; move
UEFI to an SD card so `config.txt` becomes editable; or check whether the pftf
setup menu exposes an I²C toggle (needs HDMI and a keyboard at the rack).

## Design

### Ensemble model: scenes

The four panels behave as **one dashboard showing one topic at a time**. All
four display different facets of the same scene, then all four change topic
together. The user learns the rhythm, not the positions.

Rejected alternatives: fixed per-panel domains (predictable but static); a
640×80 video wall (dramatic on the walk-past, poor when you stop, and the bezel
gaps fight it); a persistent header stripe (costs ~15 px of 80 on every panel).

### Panel orientation: identity, confirmed

Phase 0 drew corner markers and they landed exactly where the driver's
coordinate space says they should: `(0,0)` is the **top-left** physical pixel,
x runs left-to-right along the 160 axis, y runs top-to-bottom along the 80 axis.
With `XSTART=0`, `YSTART=24` and the `MY|MV|BGR` rotation constant, **the
renderer needs no transform** — render 160×80 landscape and send it. RGB565
byte order (high byte first) is also confirmed correct.

### Tile budget

**A tile is 160×80.** With the driver's fonts that is 22×8 characters at 7×10,
14×4 at 11×18, or 10×3 at 16×26. In practice a tile holds **one label, one hero
number, and one supporting line or sparkline**. It is a playing card, not a
dashboard panel. Any scene needing more than four facts is really two scenes.

### Components

- **conductor** — Deployment on the amd64 workers. Collects data, selects the
  scene, renders all four tiles, serves them and the web mirror.
- **panel-agent** — DaemonSet on the four Pis. Fetches its tile, diffs against
  the last frame, writes changed rows over bit-banged I²C. Knows nothing about
  Kubernetes, metrics or scenes.
- **rackview** — the web mirror, served by the conductor from the same render
  pass, so it cannot drift from what the panels show.

Rendering centrally is what makes visual iteration possible without touching a
Pi, allows real TTF text and antialiasing, and guarantees the four tiles are
mutually consistent because they come from one render pass.

### Conductor internals

**Providers** implement one interface, `fetch() -> dict`, polled on independent
intervals and cached with a staleness timestamp:

| Provider | Source | Interval |
| --- | --- | --- |
| `thanos` | `thanos-query-frontend.observability.svc:10902` | 15 s |
| `kube` | API server — nodes, pods | 30 s |
| `flux` | Kustomization + HelmRelease CRs | 30 s |
| `alertmanager` | `/api/v2/alerts` | 10 s |
| `clock` | local | 1 s |

Thanos rather than Prometheus, per `CLAUDE.md`: Prometheus retains 2 days, so
any sparkline longer than 48 h silently truncates.

**Scene selection** is `eligible[floor(unix / dwell) % len(eligible)]`, where
`eligible` is the base scenes plus any conditional scene whose predicate is
currently true.

> One subtlety, called out because it is otherwise a silent bug: when a
> conditional scene becomes eligible or stops being eligible, the modulo
> re-indexes and the rotation appears to skip a scene. The design requires a
> **stable scene ordering** plus an explicit rule that a newly-eligible scene is
> shown **next**, rather than being slotted in by index.

**Rendering** uses a real 2D library (Pillow or skia) at 160×80, emitting raw
RGB565 for the agents and PNG for `rackview`.

### Synchronization

Four agents polling independently at 1 Hz would land their repaints up to a
second apart, which reads as sloppy rather than coordinated.

The conductor therefore stamps each frame with **`X-Display-At`**, a wall-clock
instant slightly in the future. Agents fetch early, hold the frame, and begin
the blit at that instant. Talos nodes are NTP-synced, so they start within
milliseconds of each other.

Because a full repaint takes seconds, "at once" means "**start** at once". The
design leans into this: a scene change is painted as a **top-to-bottom banded
wipe**, so four panels wiping in unison is the intended effect rather than a
symptom of a slow bus.

### Panel agent internals

Poll `GET /tile/{node}` at 1 Hz with an ETag. On a new frame, diff row by row
(80 rows × 320 bytes), coalesce contiguous changed rows into single
address-window burst writes, and fall back to a full repaint above ~60 % change.

Tile identity comes from `NODE_NAME` via the downward API; the conductor maps
node name to tile index.

Fallback frames render locally with no dependencies: an identity card at
startup, an "offline" card if the conductor is unreachable for 30 s.

### Palette and night mode

Two palettes, `day` and `night`, selected by local time. Night uses dark
grounds and dim accents — this is about basement glare, not power, since no
hours are saved either way.

**Backlight bleed sets a floor** (observed in Phase 0): a near-black ground
renders washed out rather than black, and cannot be made darker. Contrast must
therefore come from lifting the foreground, never from lowering the ground.
This also bounds what night mode can achieve — it reduces *content* brightness,
but the panel has a minimum glow that nothing in software can remove.

Severity overrides the palette:

- `critical` → forces the **bright** `day` palette plus red.
- `warning` → keeps the night ground but uses **full-brightness amber** for the
  accent, so it reads at 2am without lighting the room.

### Alert behaviour, tiered by severity

Tiers map 1:1 onto the `severity` label Alertmanager already emits, so the
classification costs nothing to maintain:

| Severity | Behaviour |
| --- | --- |
| `critical` | Rotation **stops**. All four panels become the incident. Red border. Held until resolved. |
| `warning` | Rotation continues, but an `ALERTS` scene is injected into the cycle, with an amber accent on every panel. |
| `info` | Accent colour only. Rotation untouched. |

### Scene inventory, v1

**Base (always eligible):** `FLEET`, `STORAGE`, `NETWORK`, `GITOPS`,
`WORKLOADS`, `CLOCK`, `IDENTITY`, `TRIVIA`.

| Scene | The four tiles |
| --- | --- |
| `FLEET` | 4 Pis (temp/load) · 3 brokkr (temp/load) · cluster CPU+mem · hottest node + uptime |
| `STORAGE` | Longhorn used/degraded · TrueNAS pool fill · VolSync last run · 14 d capacity trend |
| `NETWORK` | BGP sessions to UniFi · cluster throughput · CoreDNS QPS + served_stale · WAN up/down |
| `GITOPS` | Kustomizations ready · HelmReleases ready · last commit author + subject · open Renovate PRs |
| `WORKLOADS` | pods by phase · restarts (1 h) · pending/crashloop · top CPU consumer |
| `CLOCK` | big time, date, sunrise/sunset — genuinely useful in a basement |
| `IDENTITY` | cluster name, Talos + k8s version, uptime — a title card the rotation returns to |
| `TRIVIA` | days since last incident · longest-lived pod · most-restarted pod this week |

**Conditional (eligible only while true):** `ALERTS` (any warning firing),
`INCIDENT` (any critical — pins the set), `UPGRADE` (a tuppr roll in flight,
showing which node is draining).

The conditional scenes are the main defence against the rack becoming wallpaper.
A fixed rotation gets boring within a week; scenes that appear only when
something is happening stay interesting for years, and are the reason a glance
becomes a stop.

**Deferred to Phase 4** (homelab services — `MEDIA`, `HOME`, `CAMERAS`, `EV`,
`BACKUP`): the Homepage workload already holds working credentials and endpoints
for Plex, Frigate, Home Assistant and the \*arr stack, so this is largely "read
the widget config, reuse the key" rather than new integration. The provider
interface exists so this slots in without restructuring.

### rackview

Served by the conductor at `rackview.${SECRET_DOMAIN}`, `parentRefs` → the
`internal` Gateway, `sectionName: https`. The wildcard
`${SECRET_DOMAIN/./-}-production-tls` already covers it, and the UniFi
external-dns instance is scoped `--gateway-name=internal`, so the LAN A record
publishes itself. Internal-only falls out of the Gateway choice.

**Authentication: none — a deliberate decision, not an oversight.** The repo
contains exactly one `SecurityPolicy` (Authentik's own referencegrant); every
internal route is unauthenticated, and Homepage sits on this same Gateway
exposing considerably more than four node names.

The page shows four tiles laid out as the physical rack, integer-scaled 3× to
480×240 with `image-rendering: pixelated` so it reads as the panel rather than a
blurry upscale, with gaps matching the real bezels. Each tile is
`GET /tile/{node}.png` polled at 1 Hz with an ETag — four small PNGs a second,
no streaming machinery.

Below the tiles: current scene, seconds to the next, active palette, frame
sequence, and **per-provider staleness**. That last line is what makes it the
first place to look when a tile shows a stale marker.

Two query overrides for design work: `?scene=STORAGE` pins a scene,
`?palette=night` checks the dark palette at 2pm.

Consistency touches: a `gatus.home-operations.com/endpoint` annotation as
Homepage has, and a Homepage tile pointing at it.

## Error handling

The governing rule: **the display is never important enough to restart for.**

- A failed provider renders its tile from the last known value with a staleness
  marker — never a blank, never an error string.
- Conductor unreachable → agent shows its locally-rendered offline card.
- A failed I²C write triggers re-init and retry, then marks the pod unhealthy.
  It does not crash-loop.

## Testing

Scene rendering is a pure function from fixture data to a bitmap, which makes
the main defence **golden-image tests**: render every scene against recorded
data and diff against committed PNGs. Layout regressions are caught with no
hardware and no cluster.

- Providers: tested against recorded PromQL and API responses.
- Agent diff-and-coalesce: a pure function over two framebuffers, unit-tested
  directly, with the I²C write behind an interface.
- Bit-bang layer: tested against a fake GPIO backend asserting the emitted
  SDA/SCL edge sequence forms valid I²C frames.
- `--selftest` mode draws colour bars and text, for hardware bring-up.

Test fixture available now: a live `KubeClientCertificateExpiration` alert,
`severity: warning`, `instance: 10.0.10.32:6443` — exactly the shape a 160×80
tile must hold, and it exercises the injected-scene path rather than the pin
path. *(Worth resolving on its own merits, independent of this project.)*

## Deployment

`kubernetes/apps/observability/rackpanel/`, following the repo layout: namespace
`kustomization.yaml`, `app/helmrelease.yaml` via OCIRepository with an `&app`
anchor and the standard remediation block, `app/httproute.yaml`.

Source lives in a **new Gitea repo** built by Drone with Flux image automation,
per the first-party image pattern — one multi-arch image, two entrypoints.
Per `docs/runbooks/flux-image-automation.md`: a combined `image: repo:tag`
scalar takes a marker with **no** `:tag` suffix, and `update.path` must be
scoped to this app's directory only.

The agent DaemonSet needs tolerations for **both** the control-plane taint
(`jormungandr1`–`3`) and `node.kubernetes.io/low-power` (`jormungandr4`),
selected by a node label rather than hostnames.

Device access avoids `privileged: true`: a hostPath mount of `/dev/gpiochip0`
with `runAsUser: 0`, `capabilities.drop: [ALL]`,
`allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`. The namespace
needs the `psa-privileged` component.

## Phasing

**Phase 0 — hardware probe. COMPLETE (2026-08-18).** A throwaway privileged pod
on `jormungandr4` with `/dev/gpiochip0` mounted, bit-banging I²C via the GPIO
character-device v2 uAPI. Results:

| Question | Answer |
| --- | --- |
| Are GPIO 2/3 claimable? | Yes, as open-drain outputs; both idle high (board has pull-ups) |
| Does the bit-bang master produce valid I²C? | Yes — bus scan found **exactly `0x18`** and nothing else |
| Does ACK readback work through an open-drain output? | Yes |
| Do pixels reach the panel? | Yes — colour bars and corner markers rendered |
| Orientation | Identity; no transform needed |
| Clock stretching? | **Never** — zero events across three full fills |
| Real full-frame time | **4.3 s / ~55 kbit/s** in Python |

The only deferred item is the `DISPOFF` passthrough probe. Given the backlight
cannot be switched off regardless, and night mode is a dark palette rather than
a blank, its value is low and the risk of putting the MCU into an unrecoverable
state is non-zero. **Recommend not probing it.**

**Phase 1 — conductor, providers, base scenes, `rackview`.** No hardware
involved. This is deliberate: the I²C question is the one thing that could not
be de-risked remotely, so the ordering ensures that even if it proves hard, the
result is a working product rather than a stalled one.

**Phase 2 — panel-agent**: bit-bang I²C, row diffing, `X-Display-At`
synchronization, banded wipe, all four panels.

**Phase 3 — alerts and conditionals**: severity tiers, `ALERTS`/`INCIDENT`/
`UPGRADE`, night palette.

**Phase 4 — homelab service scenes**, sourced via Homepage's existing
credentials.

## Out of scope

- Any change to `talos/talconfig.yaml` schematics (see the warning above).
- Reflashing SPI EEPROM or relocating UEFI to SD — documented as fallbacks,
  not planned work.
- The `jormungandr4` Talos upgrade (v1.13.5 → v1.13.6). Real and wanted, but
  kept separate so a display experiment cannot be blamed for an upgrade problem.
- Any backlight scheduling. It is not physically possible, and would save
  nothing if it were.
