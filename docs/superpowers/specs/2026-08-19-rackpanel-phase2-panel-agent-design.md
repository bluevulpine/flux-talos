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
run a 3 MB static binary, and would re-roll the DaemonSet on every conductor
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

`golang.org/x/sys/unix` provides **no** GPIO v2 uAPI types (checked against
v0.43.0). The structs are therefore hand-rolled, exactly mirroring the probe's
`ctypes` definitions, with the same size assertions promoted to compile-time
`unsafe.Sizeof` checks:

| Struct | Size |
| --- | --- |
| `LineAttribute` | 16 |
| `LineConfigAttribute` | 24 |
| `LineConfig` | 272 |
| `LineRequest` | 592 |

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

### Projected throughput

Per row: 3 command transactions (3 B each) + 2 data transactions (160 B each) =
329 bytes = 2,961 bit-times ≈ 8,913 ioctls.

| | ioctls | delays | total |
| --- | --- | --- | --- |
| full frame (80 rows) | ~713,000 | 112 ms + 2.4 ms | **0.83 s @ 1 µs, 1.2 s @ 1.5 µs** |
| typical diff (15 rows) | ~134,000 | 21 ms | ~0.16–0.22 s |

Consistent with the parent spec's projection from the arm64 syscall floor.
Python measured 5.19 µs per ioctl and 4.40 s per frame.

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

Drone gains a `go test ./...` step and a second kaniko step for
`Dockerfile.agent`: a `golang:1.26` build stage cross-compiling
`CGO_ENABLED=0 GOARCH=arm64`, then `FROM scratch` with the static binary and
nothing else.

Kaniko builds for the host architecture unless told otherwise, so the arm64
image must be produced with an explicit platform override
(`--customPlatform=linux/arm64`). **The exact `plugins/kaniko` setting name for
this is unverified and must be confirmed during implementation** — an image
whose config declares `amd64` will be pulled by the Pis and fail with `exec
format error`.

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

**The frigate precedent did not hold.** An earlier draft of this section cited
`kubernetes/apps/home/frigate/app/helmrelease.yaml`, which mounts `/dev/bus/usb`
via a non-privileged hostPath, as evidence this works on the cluster. The
measurement supersedes it. That leaves an open question worth checking on its
own merits, unrelated to rackpanel: if the same rule applies there, frigate's
Coral TPU may be unreachable and the CPU detector may be running silently.
**Not verified — recorded so it is not lost.**

**Consequence:** the agent container carries `privileged: true`. Accepted
because the scope is narrow — one container on four Pis, running a ~3 MB `FROM
scratch` image with no shell, no package manager and nothing installed to abuse.
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
