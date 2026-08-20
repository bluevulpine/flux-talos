# rackpanel Phase 2 — the panel-agent

**Date:** 2026-08-19
**Status:** Design — accepted, not yet implemented.
**Parent spec:** `2026-08-18-rackpanel-design.md` (Phase 0 complete, Phase 1 live)
**Goal:** Put the conductor's frames on the four physical RM0004 panels, in
unison, via a compiled DaemonSet.

## What already exists

Phase 1 is deployed and serving. Verified live on 2026-08-19:

```
GET https://rackview.derekjacobs.dev/tile/jormungandr1
200  content-length: 25600   content-type: application/octet-stream
     etag: "10e298319778de05"
     x-scene: FLEET   x-frame-seq: 4   x-tile-index: 0
     x-display-at: 1787149703.280
```

`If-None-Match` returns 304 with the validators echoed. `/status` reports the
scene, palette, sequence and per-provider staleness. `observability` is already
labelled `pod-security.kubernetes.io/enforce: privileged`.

Phase 0 established the wire protocol against real hardware; the reference
implementation is `reference/phase0-probe.py` in the rackpanel repo. **This
design ports that file rather than re-deriving anything from the vendor C
driver.**

## Scope

In: the Go agent, its image and build pipeline, its DaemonSet, its metrics, and
its local fallback cards.

Out: scene content, palettes, alert tiers (Phase 3), homelab service scenes
(Phase 4), and any change to `talos/talconfig.yaml`.

## Packaging: two images, one repo

The parent spec assumed one multi-arch image with two entrypoints, then flagged
the assumption for the implementation plan to settle. **Settled: two images from
the one existing repo.**

```
rackpanel/
  src/rackpanel/          python conductor   -> rackpanel        (amd64)
  cmd/panel-agent/        go agent           -> rackpanel-agent  (arm64)
  internal/{i2c,panel,tile,blit,card,metrics}/
  Dockerfile              conductor
  Dockerfile.agent        agent
  go.mod   pyproject.toml
```

One repo, because the tile wire format and the header contract are a single
interface and must not be able to drift between two repositories — Phase 3 and 4
both touch it.

Two images, because a single image would make the Pis pull ~150 MB of Python to
run a 10 MB static binary (measured 2026-08-19: `GOOS=linux GOARCH=arm64
CGO_ENABLED=0` with `-trimpath -ldflags="-s -w"` yields **9.9 MB**; an earlier
draft guessed ~3 MB, which underestimated the Prometheus client library), and would re-roll the DaemonSet on every conductor
rendering change. A `FROM scratch` agent also has no shell, no package manager
and nothing to patch, which matters more than usual for a container running as
UID 0 with a device mounted.

## Module layout

| Package | Responsibility | Touches hardware |
| --- | --- | --- |
| `internal/i2c` | bit-bang master over `/dev/gpiochip0` | yes — the only one |
| `internal/panel` | RM0004 registers, windows, bursts | via an `i2c.Bus` interface |
| `internal/tile` | fetch loop, ETag, `X-Display-At` scheduling | no |
| `internal/blit` | framebuffer diff → row runs | no — pure |
| `internal/card` | local identity / offline rendering | no — pure |
| `internal/metrics` | Prometheus registry, `/healthz`, `/readyz` | no |
| `cmd/panel-agent` | wiring, flags, signals | no |

The boundary that matters is `panel` depending on an *interface*, not on
`i2c` — it is what lets the entire register protocol be asserted against a fake
bus that records every transaction, with no Pi in the loop.

## The I²C and panel layers: a verbatim port

**Corrected 2026-08-19.** An earlier draft of this section claimed
`golang.org/x/sys/unix` provides no GPIO v2 uAPI types. That was checked
against v0.43.0 with a wrong-cased grep. The version this module actually
resolves to — **v0.47.0** — ships them, under `GPIOV2…` names (not `GpioV2…`):

| Provided by `x/sys/unix` v0.47.0 | Notes |
| --- | --- |
| `GPIOV2LineRequest`, `GPIOV2LineConfig`, `GPIOV2LineConfigAttribute`, `GPIOV2LineAttribute`, `GPIOV2LineValues` | field-for-field identical to the probe's `ctypes` layout |
| `GPIO_V2_GET_LINE_IOCTL` = `0xc250b407` | encodes size `0x250` = **592** |
| `GPIO_V2_LINE_SET_VALUES_IOCTL` = `0xc010b40f` | encodes size `0x010` = **16** |
| `GPIO_V2_LINE_GET_VALUES_IOCTL` = `0xc010b40e` | |

So the structs are **not** hand-rolled, the `_IOWR` arithmetic is not
reimplemented, and there are no size assertions to maintain — the sizes are
proven by the upstream ioctl constants themselves. Only the three line-flag
values are absent from `x/sys` and defined locally:

```go
const (
    flagOutput     = 1 << 3 // GPIO_V2_LINE_FLAG_OUTPUT
    flagOpenDrain  = 1 << 6 // GPIO_V2_LINE_FLAG_OPEN_DRAIN
    flagBiasPullUp = 1 << 8 // GPIO_V2_LINE_FLAG_BIAS_PULL_UP
)
```

This is strictly better than the hand-rolled version it replaces: struct
layout is the thing most likely to be silently wrong across a uAPI change,
and it is now upstream's problem rather than ours.

Lines 2 (SDA) and 3 (SCL) requested together as
`OUTPUT | OPEN_DRAIN | BIAS_PULL_UP`, so one `GPIO_V2_LINE_SET_VALUES` sets both.
Calls go through `unix.Syscall(unix.SYS_IOCTL, …)` against a reused
`LineValues` struct, so the hot path allocates nothing. The blit goroutine calls
`runtime.LockOSThread()`.

### Ported unchanged, deliberately

These are the Phase 0 findings that cost real effort to establish. Each is
carried over as-is:

- **3 ioctls per bit** (`set(b,0)`, `set(b,1)`, `set(b,0)`), 3 more for the ACK
  read.
- **700 µs after every 160-byte burst chunk.** Mandatory. Without it the MCU
  drops bytes and the write pointer trails, leaving previous-frame pixels in a
  diagonal.
- **10 µs after every command.**
- **No clock-stretch handling.** Measured zero stretch events across three full
  fills; the handling costs ~30 % throughput for nothing.
- `XSTART=0`, `YSTART=24`; RGB565 high byte first; no coordinate transform.
- **Per-row burst framing** (`BURST on → 2×160 B → BURST off → SYNC`), even
  inside a multi-row run. Overhead is ~4 % of bytes and ~3.2 ms per full frame —
  and it is the framing that has actually been proven to work on this MCU.

### One optimisation explicitly declined

Folding the trailing `set(b,0)` into the next bit's leading edge would cut the
hot path to 2 ioctls per bit, roughly a third faster. It is **not** taken,
because it drives the data hold time after the falling clock edge to zero.

Phase 0's governing lesson was that "the diagonal was clock stretching" is a
plausible-sounding conclusion the instrument contradicted. Port first, measure
on hardware, and only then optimise against a number.

### Throughput — PROJECTED vs MEASURED 2026-08-20

**The projection was wrong by roughly 4x, and the premise behind it was wrong.**

| | full sweep (80 rows) | diff (22 rows) |
| --- | --- | --- |
| Python probe, unthrottled (Phase 0) | 4.40 s | — |
| **Go agent, 500m CPU limit (measured)** | **4.24 – 4.61 s** | **1.21 s** |
| Projected in this spec | 0.83 – 1.2 s | 0.16 – 0.22 s |

Cost remains purely proportional to bytes: 22 rows at 1.21 s sits exactly on
the 80-row / 4.4 s line, so there is still no fixed overhead worth optimising.

**What the projection got wrong.** This spec claimed "the 5.19 µs ioctl is the
entire bottleneck... a raw `ioctl` syscall on arm64 costs roughly 1 µs; the
remainder is interpreter overhead." That was a projection from an assumed
syscall floor, explicitly labelled as such, and the hardware disagrees. A
compiled agent at a 500m limit performs the same as unthrottled Python.

**But the comparison is not apples to apples**, and the difference matters:
the Python probe ran in a privileged debug pod with **no CPU limit**, while
the Go agent runs under a deliberate `limits.cpu: 500m`. Measured CFS
throttling on the agent containers is **46–56 % of periods**, at an average of
only ~0.07 cores — the signature of bursty work exhausting its 50 ms quota
inside each 100 ms window during a blit and then stalling.

So the honest reading is that Go is roughly **2x** faster than Python here,
not the 4–5x projected, and half the measured 4.5 s is self-inflicted
throttling. **~2.2 s unthrottled is an inference from the throttle ratio, not
a measurement** — raising the limit and re-measuring is the outstanding work.

**Resolved 2026-08-20 by raising the limit to 1000m.** Measured after the
roll:

| CPU limit | full sweep | CFS throttling |
| --- | --- | --- |
| 500m | 4.24 – 4.61 s | **46 – 56 % of periods** |
| **1000m** | **2.24 – 2.87 s** | **0 %** |

Zero throttling at 1000m means **2.3 s is the unthrottled speed** — raising the
limit further buys nothing, and the earlier ~2.2 s inference was right. Final
accounting: Go is **1.9x** faster than Python (2.3 s vs 4.40 s), not the 4–5x
projected. The per-ioctl cost is ~2.7 µs, not the ~1 µs the projection assumed
as the arm64 syscall floor.

Wiping now occupies 11.5 % of a 20 s dwell rather than 22 %.

**What the bit-bang is actually achieving.** A full sweep puts 26,320 bytes on
the wire (80 rows x (9 command + 320 data)) = 236,880 bit-times. Subtracting
the fixed delays (160 chunks x 700 µs + 240 commands x 10 µs = 0.115 s) leaves
2.185 s, i.e. **~108 kbit/s — essentially I2C standard mode**. The bit-bang is
already running the bus at the speed a 100 kHz hardware controller would.

**Synchronization, on the other hand, exceeded the design.** Measured
`rackpanel_agent_frame_lag_seconds` across all four agents: **0.2 – 1.1 ms**.
The panels begin their sweep within a millisecond of each other, against a
design that only hoped for "within milliseconds".

## Control loop

```
startup:  draw local identity card          (vendor boot image gone within ~1 s)

every 500 ms:
  GET /tile/$NODE_NAME   If-None-Match: <last etag>
    304                        -> nothing to do
    404 / error                -> count it; after 30 s draw the offline card
    200 with != 25600 bytes    -> reject, count it, keep the current frame
    200                        -> parse X-Scene, X-Frame-Seq, X-Display-At
                                  wait until X-Display-At, then blit
```

### Poll at 2 Hz, not 1 Hz

The conductor's lead is 1.5 s (`RACKPANEL_LEAD`). At a 1 Hz poll an agent that
happens to sample just after a render wakes at +1.0 s and still makes the
window, but one that samples just before wakes at +1.9 s and has already missed
it — and the four panels visibly desynchronise. At 2 Hz every agent lands inside
the lead window. Four agents issuing 304s twice a second is negligible load, and
the 304 carries no body.

### `X-Display-At` is routinely in the past

The conductor dedupes on ETag and only stamps a new `display_at` when the pixels
actually change. A frame that has been on screen for fifteen seconds still
carries its original timestamp — the live check above showed `x-display-at`
about 1.5 s *behind* wall clock.

**Rule: past ⇒ blit immediately; future ⇒ sleep until it, capped at 5 s.**

This is called out because treating the header as always-future is the single
most natural way to write this loop and it would stall every panel that joins
mid-scene. The 5 s cap keeps a malformed or wildly-skewed header from parking a
panel indefinitely.

### A blit is never aborted

If a newer frame arrives mid-write it is picked up on the next poll. A partially
written frame is worse than a stale one, and at ~1 s per sweep against a 20 s
dwell there is no benefit to preempting.

## Repaint strategy

| Condition | Action |
| --- | --- |
| `X-Scene` differs from the last blitted scene | full sweep |
| no previous framebuffer (startup, first frame after offline) | full sweep |
| more than 48 of 80 rows differ (60 %) | full sweep |
| otherwise | diff |

**Full sweep** is one address window over the whole 160×80 and 80 rows streamed
into it. The MCU auto-increments, so this *already* paints top-to-bottom over
~1 s: the banded wipe the parent spec calls for costs nothing extra and needs no
wipe colour, no second pass, and no per-palette decision. Four panels sweeping
together is the intended effect.

**Diff** compares 320-byte rows, coalesces contiguous changed rows into runs,
and issues one address window per run. A scene where a few numbers change
touches 10–20 rows.

`internal/blit` is a pure function from two framebuffers to a `[]RowRun`. It is
the component most likely to contain an off-by-one, and it is testable with no
hardware, no cluster and no conductor.

## Local cards

`image/draw` plus `golang.org/x/image/font/basicfont` (7×13), rendered to a
160×80 RGBA and converted to RGB565 by the same packer as the wire format. No
TTF, no embedded assets, no dependency on the conductor.

- **Identity card** at startup: node name, `rackpanel`, "waiting for conductor".
  Drawn before the first fetch, so a panel stops showing the vendor boot image
  within about a second of the pod starting.
- **Offline card** after 30 s of consecutive fetch failures.

## Observability

HTTP on `:8080`:

- `/healthz` — the process is alive and the control loop has ticked recently.
- `/readyz` — the last I²C write succeeded.
- `/metrics` — Prometheus.

The split is deliberate and follows the parent spec's rule that *the display is
never important enough to restart for*. A wedged panel fails **readiness**, so
the pod goes `NotReady` and shows up in alerting without ever being restarted.
Liveness only catches a genuinely stuck process. An I²C failure triggers re-init
and retry; it does not crash-loop.

```
rackpanel_agent_blit_seconds{node,kind="full"|"diff"}     histogram
rackpanel_agent_rows_written_total{node}                  counter
rackpanel_agent_i2c_errors_total{node,op}                 counter
rackpanel_agent_frame_lag_seconds{node}                   gauge   blit start - X-Display-At
rackpanel_agent_fetch_errors_total{node,reason}           counter
rackpanel_agent_frame_seq{node}                           gauge
```

`frame_lag_seconds` is the metric that answers "are the four panels actually in
unison?" — four series that track together mean the synchronisation works.
Scraped by a `PodMonitor`, which needs no extra Service.

## Deployment

The agent becomes a **second controller in the existing HelmRelease**
(`kubernetes/apps/observability/rackpanel/app/helmrelease.yaml`), so conductor
and agent versions are visible in one place and the existing image-automation
path covers both.

```yaml
controllers:
  rackpanel:            # unchanged Deployment
    pod:
      nodeSelector:
        kubernetes.io/arch: amd64
  agent:
    type: daemonset
    pod:
      nodeSelector:
        kubernetes.io/arch: arm64
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          effect: NoSchedule
        - key: node.kubernetes.io/low-power
          operator: Exists
          effect: NoSchedule
      securityContext:
        runAsUser: 0
        runAsNonRoot: false
        seccompProfile:
          type: RuntimeDefault
    containers:
      app:
        image:
          repository: gitea.derekjacobs.dev/bluevulpine/rackpanel-agent
          tag: 1-00000000  # {"$imagepolicy": "flux-system:rackpanel-agent:tag"}
        env:
          NODE_NAME:
            valueFrom:
              fieldRef:
                fieldPath: spec.nodeName
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: {drop: ["ALL"]}
        resources:
          requests: {cpu: 100m, memory: 32Mi}
          limits: {cpu: 500m, memory: 64Mi}

persistence:
  gpio:
    type: hostPath
    hostPath: /dev/gpiochip0
    advancedMounts:
      agent:
        app:
          - path: /dev/gpiochip0
```

Five details that are easy to get wrong:

1. **`nodeSelector` moves out of `defaultPodOptions`** into each controller's
   `pod:` block. Verified against app-template 5.1.0
   (`lib/pod/_getOption.tpl`): the default `defaultPodOptionsStrategy` is
   **`overwrite`**, not `merge`. A controller-level map option therefore
   *replaces* the default wholesale rather than merging into it.
2. **Consequence of the same rule:** the agent's `pod.securityContext` must
   restate `seccompProfile`. It does not inherit anything from
   `defaultPodOptions.securityContext`, and a silently dropped seccomp profile
   would not fail the render.
3. **`advancedMounts`, not `globalMounts`.** A `globalMounts` entry would mount
   `/dev/gpiochip0` into the conductor pod on an amd64 node, where the path does
   not exist.
4. **Image marker suffix.** The agent uses a dedicated `tag:` subfield, so the
   marker takes the **`:tag`** suffix — the opposite of a combined
   `image: repo:tag` scalar. Per `docs/runbooks/flux-image-automation.md`; a
   wrong suffix here caused a 14 h outage before.
5. **One automation, already scoped.** The existing
   `ImageUpdateAutomation/rackpanel` has `update.path:
   ./kubernetes/apps/observability/rackpanel`, so adding a second
   `ImageRepository` + `ImagePolicy` named `rackpanel-agent` under
   `kubernetes/apps/flux-system/rackpanel/app/` is sufficient. Do not add a
   second automation.
6. **The committed tag must be a tag that actually exists.** The `1-00000000`
   above is illustrative; the manifest must land carrying the first real tag
   Drone pushed. A placeholder tag leaves the DaemonSet in `ImagePullBackOff`
   until the automation's next 30 m interval, and an image pull failure does not
   trip this cluster's job-failure alerting.

### CPU limit as a deliberate throttle

All four agents blit simultaneously *by design*, and each burns roughly one core
for about a second. Three of the four are control-plane nodes running etcd.

Because I²C has no minimum clock rate, a CPU limit is a **safe** throttle: CFS
throttling stretches the clock, which makes the sweep slower but cannot make it
incorrect. The same limit would be reckless on SPI or WS2812, which have timing
floors.

`limits.cpu: 500m` is therefore chosen on purpose — accept roughly double the
sweep time rather than let a basement display add scheduling jitter to etcd. If
measurement shows the sweep is unacceptably slow, the limit is the first dial to
turn, and turning it is safe.

### Build

**Revised during execution 2026-08-19.** Drone gains a `go test ./...` step,
a **native cross-compile step**, and a kaniko step that only packages the
result:

```
test-go              go vet + go test               (golang:1.26-alpine)
build-agent-binary   CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build
build-and-push-agent plugins/kaniko, custom_platform: linux/arm64
```

`Dockerfile.agent` is `FROM scratch` with a single `COPY` — **no build
stage**. The original design assumed a multi-stage Dockerfile, which is wrong
in combination with the platform override: kaniko's `--customPlatform` also
selects the platform base images are pulled for, so the build stage would
fetch an *arm64* `golang` image and `RUN` an arm64 toolchain on the amd64
runner. Every Talos amd64 node carries the `binfmt-misc` extension, so that
would not fail loudly — it would silently emulate a Go compile under qemu.
Splitting the compile out leaves no base image and no `RUN` to emulate.

The plugin setting was **verified against `drone/drone-kaniko`'s source**, not
guessed: the flag is read from `PLUGIN_PLATFORM` or `PLUGIN_CUSTOM_PLATFORM`
and passed as `--customPlatform`.

Confirmed on the first pushed manifest (`6-348390b8`): `Architecture: arm64`,
`Os: linux`, 1 layer. An `amd64` stamp would surface on the Pis as
`exec format error`, which reads as a broken binary rather than a mis-stamped
image.

## Testing

| Layer | Test |
| --- | --- |
| `blit` | table-driven diff/coalesce over synthetic framebuffers: no change, one row, two disjoint runs, adjacent runs, first/last row, all rows, the 48-row threshold either side |
| `panel` | fake bus records every transaction; assert exact register sequences, window arithmetic including `YSTART=24`, chunking at 160 B, and that the 700 µs / 10 µs delays are issued |
| `i2c` | fake GPIO backend asserts the emitted SDA/SCL edge sequence decodes back to valid I²C frames — START, addr+W, ACK sampling, data, STOP |
| `tile` | `httptest` conductor: 304 path, `X-Display-At` in the past / future / absent / malformed, wrong content length, 404, connection refused, ETag round-trip |
| `card` | golden RGB565 for the identity and offline cards |

`--selftest` draws colour bars and text for hardware bring-up, mirroring the
Phase 0 probe's final stage.

## Risks

### Device access requires `privileged: true` — MEASURED 2026-08-19

**The parent spec was wrong about this, and so was the precedent cited for it.**

That spec states device access avoids `privileged: true` via a hostPath mount
with `runAsUser: 0`. Phase 0 actually ran privileged, so that was an assumption.
Measured on `jormungandr4` with a controlled pair of pods — same node, same
`hostPath` `CharDevice` mount, only the security context differing:

| Pod security context | `open("/dev/gpiochip0")` |
| --- | --- |
| `runAsUser: 0`, `drop: [ALL]`, `allowPrivilegeEscalation: false` | **`EPERM`** on both `O_RDONLY` and `O_RDWR` |
| `privileged: true` | **OK** |

The device node is not the problem: `stat` reports `crw------- root root` and the
process is UID 0. It is the cgroup v2 device controller, which is why the errno
is `EPERM` rather than `EACCES`. Capabilities do not bypass it — runc attaches
the check as an eBPF program on the cgroup.

**The frigate precedent did not hold, and checking it found something else.**
An earlier draft cited `kubernetes/apps/home/frigate/app/helmrelease.yaml`,
which mounts `/dev/bus/usb` via a non-privileged hostPath, as evidence this
works on the cluster. It is not evidence of anything: **frigate has no Coral
configured at all.** Checked 2026-08-19 — the running pod reports a single
detector, `cpu`, and is serving frigate's stock example config
(`name_of_your_camera`, a placeholder RTSP URL, MQTT disabled). The
`SYS_RAWIO` capability and the `/dev/bus/usb` mount are vestigial.

So the hypothesis that a Coral was silently failing is **wrong** — there is no
Coral to fail. That is a separate finding about frigate, tracked outside this
spec; it says nothing either way about non-privileged device access, which is
settled by the controlled measurement above.

**Consequence:** the agent container carries `privileged: true`. Accepted
because the scope is narrow — one container on four Pis, running a ~10 MB `FROM scratch` image with no shell, no package manager and nothing
installed to abuse.
The alternative considered and rejected was `squat/generic-device-plugin`, which
would keep the agent unprivileged but moves the privilege into a new third-party
DaemonSet that is itself privileged, and adds a component to deploy, pin and
maintain for no net reduction in privilege on the node.

### Kaniko platform override

See Build above. Verified by inspecting the pushed manifest's
`.config.architecture` before the DaemonSet is pointed at it.

### Node selection is by architecture

The four Pis are currently the only `arm64` nodes, so
`kubernetes.io/arch: arm64` is exact today but describes the wrong property. It
is chosen over adding `nodeLabels` to `talconfig.yaml` because that would
require a machine-config apply across all four Pis for a cosmetic gain. If a
non-panel arm64 node is ever added, the fix is a one-line `nodeLabels` entry and
a selector change — noted here so the reason is on record rather than
rediscovered.
