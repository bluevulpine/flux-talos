# rackpanel Phase 2 — panel-agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a compiled Go DaemonSet that pulls each Pi's tile from the rackpanel conductor and paints it on the physical RM0004 LCD over bit-banged I²C, with all four panels starting their repaint together.

**Architecture:** A single static arm64 binary. `internal/i2c` is the only package that touches the kernel; everything above it (`panel`, `blit`, `card`, `tile`) is pure and tested against fakes. The agent polls `GET /tile/$NODE_NAME` at 2 Hz with an ETag, waits for `X-Display-At`, then either sweeps the full 160×80 frame (scene change) or writes only the row-runs that differ.

**Tech Stack:** Go 1.26 (no cgo), `golang.org/x/image/font/basicfont`, `prometheus/client_golang`, GPIO character-device v2 uAPI via raw `ioctl`. Built by Drone with kaniko into a `FROM scratch` image, deployed by Flux via app-template 5.1.0.

**Spec:** `docs/superpowers/specs/2026-08-19-rackpanel-phase2-panel-agent-design.md` (and its parent, `2026-08-18-rackpanel-design.md`)

**Source repo:** `~/Repositories/rackpanel` (Gitea: `gitea.derekjacobs.dev/bluevulpine/rackpanel`). Go code is added alongside the existing Python conductor. **Manifest changes go in `~/Repositories/flux-talos`** — two different repos, two different commit streams.

## Global Constraints

Copied verbatim from the spec. Every task's requirements implicitly include this section.

- **Panel geometry:** 160 × 80, RGB565, **high byte first**, no coordinate transform. `(0,0)` is the top-left physical pixel.
- **Window offsets:** `XSTART = 0`, `YSTART = 24`. Every Y coordinate sent to the MCU is offset by 24.
- **I²C address:** `0x18`. It is the only device on the bus.
- **Frame size:** 25,600 bytes. A row is 320 bytes. There are 80 rows.
- **Burst chunk cap:** 160 bytes.
- **Mandatory delay:** **700 µs after every 160-byte burst chunk.** Non-negotiable — without it the MCU drops bytes.
- **Command delay:** 10 µs after every 3-byte command.
- **Bit timing:** 3 ioctls per bit (`set(b,0)`, `set(b,1)`, `set(b,0)`). **Do not** fold the trailing low into the next bit; it zeroes the data hold time.
- **No clock-stretch handling.** Phase 0 measured zero stretch events; handling costs ~30 % throughput for nothing.
- **Per-row burst framing** (`BURST on → chunks → BURST off → SYNC`), even inside a multi-row run.
- **GPIO lines:** SDA = line 2, SCL = line 3 on `/dev/gpiochip0`, requested together as `OUTPUT | OPEN_DRAIN | BIAS_PULL_UP`.
- **Full-repaint threshold:** more than **48** of 80 rows differ.
- **Poll interval:** 500 ms (2 Hz). **`X-Display-At` cap:** 5 s.
- **Go module path:** `gitea.derekjacobs.dev/bluevulpine/rackpanel`
- **GPIO uAPI:** use `x/sys/unix`'s `GPIOV2*` types and `GPIO_V2_*_IOCTL` constants. Do **not** hand-roll the structs or recompute `_IOWR`.
- **Conductor URL (in cluster):** `http://rackpanel.observability.svc.cluster.local:8080`
- **Metric prefix:** `rackpanel_agent_`
- **No cgo.** `CGO_ENABLED=0` everywhere.

## File Structure

| File | Responsibility |
| --- | --- |
| `go.mod` | module + deps |
| `internal/fb/fb.go` | geometry constants, RGB565 packing |
| `internal/blit/blit.go` | pure framebuffer diff → row runs, full-repaint decision |
| `internal/card/card.go` | locally-rendered identity and offline cards |
| `internal/i2c/i2c.go` | `Bus` + `Pins` interfaces, bit-bang master |
| `internal/i2c/gpio_linux.go` | GPIO v2 uAPI `Pins` implementation |
| `internal/i2c/fake.go` | recording `Pins` fake, and an I²C frame decoder for tests |
| `internal/panel/panel.go` | RM0004 register protocol over an `i2c.Bus` |
| `internal/tile/tile.go` | conductor client, ETag, `X-Display-At` scheduling |
| `internal/metrics/metrics.go` | Prometheus collectors, `/healthz`, `/readyz`, `/metrics` |
| `cmd/panel-agent/main.go` | wiring, flags, signals, the control loop |
| `Dockerfile.agent` | cross-compiled scratch image |
| `.drone.yml` | + Go test step, + agent build step |

Dependency order: `fb` ← {`blit`, `card`, `panel`}; `i2c` ← `panel`; everything ← `main`.

**Parallel-safe task groups** (for subagent dispatch — no shared files):
- Group A, fully independent: **Task 2** (`fb`+`blit`), **Task 3** (`card`), **Task 4** (`i2c`), **Task 6** (`tile`)
- Then **Task 5** (`panel`, needs Task 4's `i2c.Bus` interface)
- Then **Task 7** (`main`, needs all)
- Then **Task 8** → **Task 9** → **Task 10** (strictly sequential; each deploys on the last)

**Task 1 is a prerequisite for Task 10 only** and can run at any time before it. Run it first anyway — it is cheap and it is the plan's only real unknown.

---

### Task 1: Prove non-privileged device access — ✅ DONE 2026-08-19, ANSWER: NO

> **Result: `EPERM`.** Measured with a controlled pair of pods on
> `jormungandr4` — same node, same `hostPath` `CharDevice` mount, only the
> security context differing. Unprivileged (`runAsUser: 0`, `drop: [ALL]`,
> `allowPrivilegeEscalation: false`) failed on **both** `O_RDONLY` and
> `O_RDWR`; `privileged: true` succeeded. The cgroup v2 device controller is
> the cause, which is why the errno is `EPERM` and not `EACCES`.
>
> **Consequence: the agent container carries `privileged: true`.** Task 10
> Step 2 below is already written for this outcome — no conditional to
> evaluate. Steps 1–5 of this task need not be re-run; they are kept as the
> record of how the answer was obtained.
>
> The frigate `/dev/bus/usb` precedent cited in the spec did **not** hold.
> See the spec's Risks section for the open question that leaves behind.

The spec records this as the plan's one untested assumption. Phase 0 ran a **privileged** pod; the manifest in Task 10 is non-privileged. Under cgroup v2 the device controller can deny `open()` on a char device that is present in the container's filesystem. Settle it now with a throwaway pod, exactly as Phase 0 did, so Task 10 is not a surprise.

**Files:**
- Create: `$SCRATCHPAD/device-probe.yaml`, where `$SCRATCHPAD` is this session's scratchpad directory (throwaway — **not** committed to either repo)

- [ ] **Step 1: Write the probe pod with the exact securityContext Task 10 will use**

```yaml
---
apiVersion: v1
kind: Pod
metadata:
  name: rackpanel-device-probe
  namespace: observability
spec:
  restartPolicy: Never
  nodeName: jormungandr4
  tolerations:
    - key: node.kubernetes.io/low-power
      operator: Exists
      effect: NoSchedule
  securityContext:
    runAsUser: 0
    runAsNonRoot: false
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: busybox:1.37
      command:
        - sh
        - -c
        - |
          echo "--- stat ---"
          stat /dev/gpiochip0 || echo "STAT FAILED rc=$?"
          echo "--- open read-write ---"
          if : > /dev/gpiochip0 2>/tmp/err; then
            echo "OPEN RW OK"
          else
            echo "OPEN RW FAILED rc=$?"; cat /tmp/err
          fi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: gpio
          mountPath: /dev/gpiochip0
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: gpio
      hostPath:
        path: /dev/gpiochip0
        type: CharDevice
    - name: tmp
      emptyDir: {}
```

- [ ] **Step 2: Run it and read the result**

```bash
kubectl apply -f "$SCRATCHPAD/device-probe.yaml"
kubectl -n observability wait --for=jsonpath='{.status.phase}'=Succeeded pod/rackpanel-device-probe --timeout=120s
kubectl -n observability logs rackpanel-device-probe
```

Expected on success: `stat` prints a character-special file, then `OPEN RW OK`.

Failure signature to look for: `OPEN RW FAILED` with `Operation not permitted` — that is the cgroup device controller, **not** file permissions (the process is UID 0 and the node's `/dev/gpiochip0` is root-owned `crw-------`).

- [ ] **Step 3: Clean up**

```bash
kubectl -n observability delete pod rackpanel-device-probe
```

- [ ] **Step 4: Record the verdict in the spec**

Edit `docs/superpowers/specs/2026-08-19-rackpanel-phase2-panel-agent-design.md`, section **Risks → The device-access assumption is untested**. Replace the "Mitigation" paragraph with the measured result and the date.

- If `OPEN RW OK`: state that non-privileged hostPath device access is confirmed on this cluster, and that Task 10's manifest stands as written.
- If `EPERM`: state the failure verbatim, and record that the agent container carries `privileged: true` **on the agent container only** as a consequence. Task 10's `containers.app.securityContext` then becomes `privileged: true` with `allowPrivilegeEscalation: true`, and the `capabilities.drop` line is removed (it is meaningless under `privileged`).

- [ ] **Step 5: Commit the spec update** (flux-talos repo)

```bash
cd ~/Repositories/flux-talos
git add docs/superpowers/specs/2026-08-19-rackpanel-phase2-panel-agent-design.md
git commit -m "docs(superpowers): record measured device-access result for rackpanel agent"
```

---

### Task 2: Geometry, RGB565 packing, and the framebuffer diff — ✅ DONE 2026-08-19

The diff is the component most likely to hold an off-by-one, and it needs no hardware, no cluster and no conductor. Build it first and build it properly.

**Files:**
- Create: `~/Repositories/rackpanel/go.mod`
- Create: `~/Repositories/rackpanel/internal/fb/fb.go`
- Create: `~/Repositories/rackpanel/internal/blit/blit.go`
- Test: `~/Repositories/rackpanel/internal/fb/fb_test.go`
- Test: `~/Repositories/rackpanel/internal/blit/blit_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `fb.Width, fb.Height, fb.RowBytes, fb.FrameBytes` — untyped int constants `160, 80, 320, 25600`
  - `fb.Word(r, g, b uint8) uint16`
  - `fb.Pack(img image.Image) ([]byte, error)`
  - `blit.Run{First, Last int}` — **inclusive** row indices
  - `blit.Plan(old, cur []byte, sceneChanged bool) (runs []blit.Run, full bool)`
  - `blit.FullRepaintRows = 48`

- [ ] **Step 1: Initialise the Go module**

```bash
cd ~/Repositories/rackpanel
go mod init gitea.derekjacobs.dev/bluevulpine/rackpanel
go mod edit -go=1.26
```

- [ ] **Step 2: Write the failing tests for `fb`**

Create `internal/fb/fb_test.go`:

```go
package fb

import (
	"image"
	"image/color"
	"testing"
)

func TestWordMatchesVendorPacking(t *testing.T) {
	// Same cases as the Python conductor's rgb565_word, which is the
	// authority: the agent must decode byte-identically to what the
	// conductor encodes, or every tile is subtly wrong.
	cases := []struct {
		r, g, b uint8
		want    uint16
	}{
		{0, 0, 0, 0x0000},
		{255, 255, 255, 0xFFFF},
		{255, 0, 0, 0xF800},
		{0, 255, 0, 0x07E0},
		{0, 0, 255, 0x001F},
		{8, 12, 18, 0x0862}, // the Phase 0 card's background
	}
	for _, c := range cases {
		if got := Word(c.r, c.g, c.b); got != c.want {
			t.Errorf("Word(%d,%d,%d) = %#04x, want %#04x", c.r, c.g, c.b, got, c.want)
		}
	}
}

func TestPackIsHighByteFirstAndRowMajor(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, Width, Height))
	img.Set(0, 0, color.RGBA{255, 0, 0, 255})   // first pixel
	img.Set(1, 0, color.RGBA{0, 0, 255, 255})   // second pixel, same row
	img.Set(0, 1, color.RGBA{0, 255, 0, 255})   // first pixel of row 1

	got, err := Pack(img)
	if err != nil {
		t.Fatalf("Pack: %v", err)
	}
	if len(got) != FrameBytes {
		t.Fatalf("len = %d, want %d", len(got), FrameBytes)
	}
	if got[0] != 0xF8 || got[1] != 0x00 {
		t.Errorf("pixel 0 = %#02x%#02x, want f800 (high byte first)", got[0], got[1])
	}
	if got[2] != 0x00 || got[3] != 0x1F {
		t.Errorf("pixel 1 = %#02x%#02x, want 001f", got[2], got[3])
	}
	if got[RowBytes] != 0x07 || got[RowBytes+1] != 0xE0 {
		t.Errorf("row 1 pixel 0 = %#02x%#02x, want 07e0", got[RowBytes], got[RowBytes+1])
	}
}

func TestPackRejectsWrongSize(t *testing.T) {
	if _, err := Pack(image.NewRGBA(image.Rect(0, 0, 100, 80))); err == nil {
		t.Fatal("expected an error for a 100x80 image")
	}
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd ~/Repositories/rackpanel && go test ./internal/fb/`
Expected: build failure — `undefined: Word`, `undefined: Pack`.

- [ ] **Step 4: Implement `fb`**

Create `internal/fb/fb.go`:

```go
// Package fb holds the panel's geometry and its RGB565 wire format.
//
// Verified against hardware in Phase 0: high byte first, pixels
// left-to-right then top-to-bottom, no coordinate transform. This must stay
// byte-identical to the conductor's src/rackpanel/framebuffer.py.
package fb

import (
	"fmt"
	"image"
)

const (
	Width      = 160
	Height     = 80
	RowBytes   = Width * 2
	FrameBytes = Width * Height * 2
)

// Word packs 8-bit RGB into a 16-bit 5-6-5 word (the vendor's ST7735_COLOR565).
func Word(r, g, b uint8) uint16 {
	return uint16(r&0xF8)<<8 | uint16(g&0xFC)<<3 | uint16(b>>3)
}

// Pack converts a 160x80 image into the panel's 25,600-byte wire format.
func Pack(img image.Image) ([]byte, error) {
	b := img.Bounds()
	if b.Dx() != Width || b.Dy() != Height {
		return nil, fmt.Errorf("tile must be %dx%d, got %dx%d", Width, Height, b.Dx(), b.Dy())
	}
	out := make([]byte, FrameBytes)
	i := 0
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			// color.Color.RGBA returns 16-bit alpha-premultiplied values.
			r, g, bl, _ := img.At(x, y).RGBA()
			w := Word(uint8(r>>8), uint8(g>>8), uint8(bl>>8))
			out[i] = byte(w >> 8)
			out[i+1] = byte(w)
			i += 2
		}
	}
	return out, nil
}
```

- [ ] **Step 5: Run the `fb` tests to verify they pass**

Run: `cd ~/Repositories/rackpanel && go test ./internal/fb/`
Expected: PASS.

- [ ] **Step 6: Write the failing tests for `blit`**

Create `internal/blit/blit_test.go`:

```go
package blit

import (
	"reflect"
	"testing"

	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/fb"
)

// frame returns a zeroed frame with the given rows set to a non-zero marker.
func frame(dirtyRows ...int) []byte {
	f := make([]byte, fb.FrameBytes)
	for _, r := range dirtyRows {
		for i := 0; i < fb.RowBytes; i++ {
			f[r*fb.RowBytes+i] = 0xAB
		}
	}
	return f
}

func TestNoChangeProducesNoRuns(t *testing.T) {
	base := frame(5)
	runs, full := Plan(base, base, false)
	if full {
		t.Fatal("identical frames must not force a full repaint")
	}
	if len(runs) != 0 {
		t.Fatalf("runs = %v, want none", runs)
	}
}

func TestSingleChangedRow(t *testing.T) {
	runs, full := Plan(frame(), frame(7), false)
	if full {
		t.Fatal("one changed row must not force a full repaint")
	}
	if want := []Run{{First: 7, Last: 7}}; !reflect.DeepEqual(runs, want) {
		t.Fatalf("runs = %v, want %v", runs, want)
	}
}

func TestAdjacentRowsCoalesceIntoOneRun(t *testing.T) {
	runs, _ := Plan(frame(), frame(3, 4, 5), false)
	if want := []Run{{First: 3, Last: 5}}; !reflect.DeepEqual(runs, want) {
		t.Fatalf("runs = %v, want %v", runs, want)
	}
}

func TestDisjointRunsStaySeparate(t *testing.T) {
	runs, _ := Plan(frame(), frame(3, 4, 20, 21), false)
	want := []Run{{First: 3, Last: 4}, {First: 20, Last: 21}}
	if !reflect.DeepEqual(runs, want) {
		t.Fatalf("runs = %v, want %v", runs, want)
	}
}

func TestFirstAndLastRowBoundaries(t *testing.T) {
	runs, _ := Plan(frame(), frame(0, fb.Height-1), false)
	want := []Run{{First: 0, Last: 0}, {First: fb.Height - 1, Last: fb.Height - 1}}
	if !reflect.DeepEqual(runs, want) {
		t.Fatalf("runs = %v, want %v", runs, want)
	}
}

func TestThresholdBoundary(t *testing.T) {
	atLimit := make([]int, FullRepaintRows) // 48 rows -> still a diff
	for i := range atLimit {
		atLimit[i] = i
	}
	if _, full := Plan(frame(), frame(atLimit...), false); full {
		t.Fatalf("%d changed rows must not trigger a full repaint", FullRepaintRows)
	}

	overLimit := make([]int, FullRepaintRows+1) // 49 rows -> full
	for i := range overLimit {
		overLimit[i] = i
	}
	if _, full := Plan(frame(), frame(overLimit...), false); !full {
		t.Fatalf("%d changed rows must trigger a full repaint", FullRepaintRows+1)
	}
}

func TestSceneChangeAlwaysForcesFullRepaint(t *testing.T) {
	base := frame(5)
	if _, full := Plan(base, base, true); !full {
		t.Fatal("a scene change must sweep even when no pixels differ")
	}
}

func TestNilOrWrongSizedPreviousForcesFullRepaint(t *testing.T) {
	if _, full := Plan(nil, frame(), false); !full {
		t.Fatal("no previous frame must force a full repaint")
	}
	if _, full := Plan(make([]byte, 10), frame(), false); !full {
		t.Fatal("a wrong-sized previous frame must force a full repaint")
	}
}

func TestFullRepaintReturnsNoRuns(t *testing.T) {
	runs, full := Plan(nil, frame(), false)
	if !full {
		t.Fatal("expected full")
	}
	if runs != nil {
		t.Fatalf("a full repaint must return nil runs, got %v", runs)
	}
}
```

- [ ] **Step 7: Run the `blit` tests to verify they fail**

Run: `cd ~/Repositories/rackpanel && go test ./internal/blit/`
Expected: build failure — `undefined: Plan`, `undefined: Run`, `undefined: FullRepaintRows`.

- [ ] **Step 8: Implement `blit`**

Create `internal/blit/blit.go`:

```go
// Package blit decides what to write to the panel: which rows changed, and
// whether it is cheaper to sweep the whole frame instead.
//
// Pure. No hardware, no conductor, no clock. This is the part most likely to
// hold an off-by-one, so it is the part with no excuse for being untestable.
package blit

import (
	"bytes"

	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/fb"
)

// FullRepaintRows is the diff/sweep crossover: above this many changed rows,
// a full sweep costs less than the per-run window and burst framing. 48 of 80
// is the spec's 60 %.
const FullRepaintRows = 48

// Run is an inclusive range of row indices to write in one address window.
type Run struct {
	First, Last int
}

// Plan compares two frames and returns either the row runs to write, or
// full=true meaning sweep the entire 160x80 in one window.
//
// A full sweep already paints top-to-bottom because the MCU auto-increments
// within the window, which is the banded wipe the design calls for -- it needs
// no second pass and no wipe colour.
func Plan(old, cur []byte, sceneChanged bool) (runs []Run, full bool) {
	if sceneChanged || len(old) != fb.FrameBytes || len(cur) != fb.FrameBytes {
		return nil, true
	}

	changed := make([]int, 0, fb.Height)
	for r := 0; r < fb.Height; r++ {
		lo := r * fb.RowBytes
		hi := lo + fb.RowBytes
		if !bytes.Equal(old[lo:hi], cur[lo:hi]) {
			changed = append(changed, r)
		}
	}
	if len(changed) == 0 {
		return nil, false
	}
	if len(changed) > FullRepaintRows {
		return nil, true
	}

	runs = make([]Run, 0, len(changed))
	start := changed[0]
	prev := changed[0]
	for _, r := range changed[1:] {
		if r != prev+1 {
			runs = append(runs, Run{First: start, Last: prev})
			start = r
		}
		prev = r
	}
	runs = append(runs, Run{First: start, Last: prev})
	return runs, false
}
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `cd ~/Repositories/rackpanel && go test ./internal/fb/ ./internal/blit/ -v`
Expected: PASS, all cases.

- [ ] **Step 10: Commit**

```bash
cd ~/Repositories/rackpanel
git add go.mod internal/fb internal/blit
git commit -m "feat(agent): panel geometry, RGB565 packing and framebuffer diff

Pure, hardware-free foundation for the Go panel-agent. Plan() returns
inclusive row runs or full=true; a full sweep needs no second pass because
the MCU auto-increments within one address window, which IS the banded wipe.

Threshold is 48 of 80 rows (60%), tested on both sides of the boundary."
```

---

### Task 3: Local identity and offline cards — ✅ DONE 2026-08-19

So a panel stops showing the vendor boot image within about a second of the pod starting, and shows something honest when the conductor is gone. No TTF, no embedded assets, no network.

**Files:**
- Create: `~/Repositories/rackpanel/internal/card/card.go`
- Test: `~/Repositories/rackpanel/internal/card/card_test.go`

**Interfaces:**
- Consumes: `fb.Width`, `fb.Height`, `fb.FrameBytes`, `fb.Pack`
- Produces:
  - `card.Identity(node string) ([]byte, error)` — 25,600 bytes
  - `card.Offline(node string, since time.Duration) ([]byte, error)` — 25,600 bytes

- [ ] **Step 1: Add the font dependency**

```bash
cd ~/Repositories/rackpanel
go get golang.org/x/image/font/basicfont@v0.35.0
```

- [ ] **Step 2: Write the failing test**

Create `internal/card/card_test.go`:

```go
package card

import (
	"testing"
	"time"

	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/fb"
)

func TestIdentityIsAFullFrame(t *testing.T) {
	got, err := Identity("jormungandr4")
	if err != nil {
		t.Fatalf("Identity: %v", err)
	}
	if len(got) != fb.FrameBytes {
		t.Fatalf("len = %d, want %d", len(got), fb.FrameBytes)
	}
}

func TestOfflineIsAFullFrame(t *testing.T) {
	got, err := Offline("jormungandr4", 95*time.Second)
	if err != nil {
		t.Fatalf("Offline: %v", err)
	}
	if len(got) != fb.FrameBytes {
		t.Fatalf("len = %d, want %d", len(got), fb.FrameBytes)
	}
}

func TestCardsAreVisuallyDistinct(t *testing.T) {
	id, _ := Identity("jormungandr4")
	off, _ := Offline("jormungandr4", time.Minute)
	same := 0
	for i := range id {
		if id[i] == off[i] {
			same++
		}
	}
	// Most of a card is shared ground, so the bound is deliberately loose:
	// it catches "one card silently renders as the other", not small
	// differences in wording.
	if same > fb.FrameBytes*95/100 {
		t.Fatalf("identity and offline cards are %d%% identical", same*100/fb.FrameBytes)
	}
}

func TestCardsAreNotBlank(t *testing.T) {
	// A blank card is the failure mode that looks like success: the panel
	// shows a flat colour and nobody can tell the renderer never drew text.
	for name, fn := range map[string]func() ([]byte, error){
		"identity": func() ([]byte, error) { return Identity("jormungandr4") },
		"offline":  func() ([]byte, error) { return Offline("jormungandr4", time.Minute) },
	} {
		got, err := fn()
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		distinct := map[uint16]int{}
		for i := 0; i < len(got); i += 2 {
			distinct[uint16(got[i])<<8|uint16(got[i+1])]++
		}
		if len(distinct) < 2 {
			t.Errorf("%s card is a single flat colour -- nothing was drawn", name)
		}
	}
}

func TestNodeNameAffectsOutput(t *testing.T) {
	a, _ := Identity("jormungandr1")
	b, _ := Identity("jormungandr4")
	identical := true
	for i := range a {
		if a[i] != b[i] {
			identical = false
			break
		}
	}
	if identical {
		t.Fatal("the node name is not being drawn -- all four panels would be identical")
	}
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd ~/Repositories/rackpanel && go test ./internal/card/`
Expected: build failure — `undefined: Identity`, `undefined: Offline`.

- [ ] **Step 4: Implement `card`**

Create `internal/card/card.go`:

```go
// Package card renders the agent's own fallback frames.
//
// These must work with no conductor, no network and no assets, because they
// are exactly what is shown when those things are missing. basicfont is a
// compiled-in 7x13 bitmap face: no TTF file to mount, no font to fail to load.
package card

import (
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"time"

	"golang.org/x/image/font"
	"golang.org/x/image/font/basicfont"
	"golang.org/x/image/math/fixed"

	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/fb"
)

var (
	ground = color.RGBA{8, 12, 18, 255}
	accent = color.RGBA{64, 224, 208, 255}
	amber  = color.RGBA{255, 176, 0, 255}
	bright = color.RGBA{240, 244, 248, 255}
	dim    = color.RGBA{110, 125, 140, 255}
)

// Identity is drawn at startup, before the first tile arrives. Its job is to
// replace the vendor boot image immediately and prove the write path works.
func Identity(node string) ([]byte, error) {
	img := base(accent)
	text(img, 6, 20, "RACKPANEL", accent)
	text(img, 6, 40, node, bright)
	text(img, 6, 62, "waiting for conductor", dim)
	return fb.Pack(img)
}

// Offline is drawn after the conductor has been unreachable long enough that
// the last good tile is no longer trustworthy.
func Offline(node string, since time.Duration) ([]byte, error) {
	img := base(amber)
	text(img, 6, 20, "OFFLINE", amber)
	text(img, 6, 40, node, bright)
	text(img, 6, 62, fmt.Sprintf("no conductor %ds", int(since.Seconds())), dim)
	return fb.Pack(img)
}

// base returns a grounded tile with a 3px accent rule along the top edge.
//
// Contrast is lifted in the foreground rather than dropped in the ground:
// Phase 0 found backlight bleed sets a floor, so a near-black ground renders
// washed out and cannot be made darker.
func base(rule color.RGBA) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, fb.Width, fb.Height))
	draw.Draw(img, img.Bounds(), &image.Uniform{ground}, image.Point{}, draw.Src)
	draw.Draw(img, image.Rect(0, 0, fb.Width, 3), &image.Uniform{rule}, image.Point{}, draw.Src)
	return img
}

func text(dst *image.RGBA, x, y int, s string, c color.RGBA) {
	d := &font.Drawer{
		Dst:  dst,
		Src:  &image.Uniform{c},
		Face: basicfont.Face7x13,
		Dot:  fixed.P(x, y),
	}
	d.DrawString(s)
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd ~/Repositories/rackpanel && go test ./internal/card/ -v`
Expected: PASS, all five cases.

> **Deviation from the spec, on purpose.** The spec's testing table says
> "golden RGB565 for the identity and offline cards". These are property
> tests instead. A golden file would pin every pixel of a card whose exact
> wording will change, producing churn that gets regenerated without being
> read — and the Phase 1 conductor already hit the platform-sensitivity trap
> that golden text rendering invites. The properties asserted here (not
> blank, not identical to each other, affected by the node name) are the
> failures that would actually ship. Change this if a card's layout ever
> becomes something worth pinning.

- [ ] **Step 6: Commit**

```bash
cd ~/Repositories/rackpanel
git add go.mod go.sum internal/card
git commit -m "feat(agent): local identity and offline cards

Rendered with basicfont so there is no TTF to mount and no asset to fail to
load -- these are precisely the frames shown when something is missing.

Tested for the failure that looks like success: a card that renders as a
single flat colour, or one that ignores the node name and makes all four
panels identical."
```

---

### Task 4: Bit-banged I²C over the GPIO character device — ✅ DONE 2026-08-19

A direct port of `reference/phase0-probe.py`. Every constant and delay in that file was verified against the real hardware; **do not re-derive anything from the vendor C driver in `~/Repositories/pirackpro`.**

**Files:**
- Create: `~/Repositories/rackpanel/internal/i2c/i2c.go`
- Create: `~/Repositories/rackpanel/internal/i2c/gpio_linux.go`
- Create: `~/Repositories/rackpanel/internal/i2c/fake.go`
- Test: `~/Repositories/rackpanel/internal/i2c/i2c_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `i2c.Bus` interface — `Write(addr uint8, data []byte) error`, `Probe(addr uint8) (bool, error)`, `Close() error`
  - `i2c.Pins` interface — `Set(sda, scl int) error`, `Get() (sda, scl int, err error)`, `Close() error`
  - `i2c.NewBitBang(p Pins) *BitBang` — implements `Bus`
  - `i2c.OpenGPIO(chip string, sda, scl int, consumer string) (Pins, error)` — Linux only
  - `i2c.NewFakePins(ackAll bool) *FakePins` with `Frames() []Frame`, `Frame{Addr uint8, Read bool, Data []byte, Complete bool}`

- [ ] **Step 1: Write the failing test**

Create `internal/i2c/i2c_test.go`:

```go
package i2c

import (
	"reflect"
	"testing"
)

func TestWriteEmitsOneWellFormedFrame(t *testing.T) {
	p := NewFakePins(true)
	b := NewBitBang(p)
	if err := b.Write(0x18, []byte{0x2A, 0x00, 0x9F}); err != nil {
		t.Fatalf("Write: %v", err)
	}
	frames := p.Frames()
	if len(frames) != 1 {
		t.Fatalf("got %d frames, want 1: %+v", len(frames), frames)
	}
	f := frames[0]
	if f.Addr != 0x18 {
		t.Errorf("addr = %#02x, want 0x18", f.Addr)
	}
	if f.Read {
		t.Error("frame is marked read; a panel write must set the R/W bit to 0")
	}
	if !f.Complete {
		t.Error("frame did not end with a STOP condition")
	}
	if want := []byte{0x2A, 0x00, 0x9F}; !reflect.DeepEqual(f.Data, want) {
		t.Errorf("data = % x, want % x", f.Data, want)
	}
}

func TestWriteUsesThreeIoctlsPerBit(t *testing.T) {
	// The 3-ioctl sequence (set(b,0), set(b,1), set(b,0)) is what Phase 0
	// proved. Folding the trailing low into the next bit is a third faster
	// and zeroes the data hold time after the falling clock edge -- if a
	// future optimisation does that, this test is the tripwire.
	p := NewFakePins(true)
	b := NewBitBang(p)
	if err := b.Write(0x18, []byte{0xFF}); err != nil {
		t.Fatalf("Write: %v", err)
	}
	// 2 bytes on the wire (address + payload), 8 data bits each.
	// Each written bit is 3 Set calls. Each ACK read is also 3 Sets
	// (release-low, clock-high, release-low) plus 1 Get.
	const writtenBits = 16
	const ackSlots = 2
	wantSets := 1 /*NewBitBang idles the lines*/ +
		3 /*start*/ + writtenBits*3 + ackSlots*3 + 3 /*stop*/
	if p.Sets != wantSets {
		t.Errorf("Set calls = %d, want %d (3 per written bit)", p.Sets, wantSets)
	}
	if p.Gets != ackSlots {
		t.Errorf("Get calls = %d, want %d (one per ACK)", p.Gets, ackSlots)
	}
}

func TestNackAbortsTheFrameAndStops(t *testing.T) {
	p := NewFakePins(false) // nothing on the bus ACKs
	b := NewBitBang(p)
	err := b.Write(0x18, []byte{0x01, 0x02, 0x03})
	if err == nil {
		t.Fatal("expected an error when the device does not ACK")
	}
	frames := p.Frames()
	if len(frames) != 1 {
		t.Fatalf("got %d frames, want 1", len(frames))
	}
	if len(frames[0].Data) != 0 {
		t.Errorf("payload was sent after an address NAK: % x", frames[0].Data)
	}
	if !frames[0].Complete {
		t.Error("a NAKed frame must still be closed with a STOP, or the bus is left wedged")
	}
}

func TestProbeReportsPresence(t *testing.T) {
	present, err := NewBitBang(NewFakePins(true)).Probe(0x18)
	if err != nil || !present {
		t.Fatalf("Probe on an ACKing bus = (%v, %v), want (true, nil)", present, err)
	}
	absent, err := NewBitBang(NewFakePins(false)).Probe(0x18)
	if err != nil {
		t.Fatalf("Probe error: %v", err)
	}
	if absent {
		t.Error("Probe reported a device on a silent bus")
	}
}

func TestIdleStateIsBothLinesReleased(t *testing.T) {
	p := NewFakePins(true)
	NewBitBang(p)
	sda, scl := p.Level()
	if sda != 1 || scl != 1 {
		t.Errorf("idle = (sda %d, scl %d), want (1, 1): open-drain idles high", sda, scl)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/Repositories/rackpanel && go test ./internal/i2c/`
Expected: build failure — `undefined: NewFakePins`, `undefined: NewBitBang`.

- [ ] **Step 3: Implement the bus and the bit-bang master**

Create `internal/i2c/i2c.go`:

```go
// Package i2c is a bit-banged I2C master, ported from the Phase 0 hardware
// probe (reference/phase0-probe.py in this repo).
//
// It exists because Talos on these Pis instantiates no I2C adapter: the
// drivers are built in but the device tree has i2c_arm off, there is no
// config.txt to edit (UEFI boots from SPI EEPROM), configfs has no
// device-tree entry, and /dev/mem is absent. Driving GPIO 2/3 from userspace
// is the only route that needs no firmware change and no physical access.
//
// This is sound rather than merely clever because I2C has no minimum clock
// rate: the master owns the clock, so scheduling jitter on a busy Kubernetes
// node makes a transfer slower, never incorrect.
package i2c

import "fmt"

// Bus is a write-only I2C master. The panel MCU is never read from beyond
// its per-byte ACK, so there is no Read method.
type Bus interface {
	Write(addr uint8, data []byte) error
	Probe(addr uint8) (bool, error)
	Close() error
}

// Pins is the two-wire electrical layer. Open-drain: 1 releases the line to
// the board's pull-up, 0 drives it low.
type Pins interface {
	Set(sda, scl int) error
	Get() (sda, scl int, err error)
	Close() error
}

// BitBang drives an I2C frame one edge at a time over Pins.
type BitBang struct {
	p Pins
}

func NewBitBang(p Pins) *BitBang {
	b := &BitBang{p: p}
	_ = b.p.Set(1, 1) // idle: both released high
	return b
}

func (b *BitBang) start() error {
	if err := b.p.Set(1, 1); err != nil {
		return err
	}
	if err := b.p.Set(0, 1); err != nil {
		return err
	}
	return b.p.Set(0, 0)
}

func (b *BitBang) stop() error {
	if err := b.p.Set(0, 0); err != nil {
		return err
	}
	if err := b.p.Set(0, 1); err != nil {
		return err
	}
	return b.p.Set(1, 1)
}

// writeBit is deliberately three Set calls. See the package doc and the
// spec: folding the trailing low into the next bit zeroes the data hold
// time after the falling clock edge.
func (b *BitBang) writeBit(v int) error {
	if err := b.p.Set(v, 0); err != nil {
		return err
	}
	if err := b.p.Set(v, 1); err != nil {
		return err
	}
	return b.p.Set(v, 0)
}

func (b *BitBang) readBit() (int, error) {
	if err := b.p.Set(1, 0); err != nil {
		return 0, err
	}
	if err := b.p.Set(1, 1); err != nil {
		return 0, err
	}
	sda, _, err := b.p.Get()
	if err != nil {
		return 0, err
	}
	if err := b.p.Set(1, 0); err != nil {
		return 0, err
	}
	return sda, nil
}

// writeByte returns whether the slave ACKed.
func (b *BitBang) writeByte(v byte) (bool, error) {
	for i := 7; i >= 0; i-- {
		if err := b.writeBit(int(v>>uint(i)) & 1); err != nil {
			return false, err
		}
	}
	bit, err := b.readBit()
	if err != nil {
		return false, err
	}
	return bit == 0, nil
}

// Write sends START, addr+W, the payload, then STOP. The STOP is always
// issued, including on a NAK -- leaving a frame open wedges the bus for
// every later transfer.
func (b *BitBang) Write(addr uint8, data []byte) (err error) {
	if err = b.start(); err != nil {
		return err
	}
	defer func() {
		if serr := b.stop(); err == nil {
			err = serr
		}
	}()

	acked, err := b.writeByte(addr << 1)
	if err != nil {
		return err
	}
	if !acked {
		return fmt.Errorf("i2c: no ACK from address %#02x", addr)
	}
	for i, c := range data {
		acked, err = b.writeByte(c)
		if err != nil {
			return err
		}
		if !acked {
			return fmt.Errorf("i2c: no ACK for byte %d of %d", i, len(data))
		}
	}
	return nil
}

// Probe reports whether anything ACKs at addr.
func (b *BitBang) Probe(addr uint8) (present bool, err error) {
	if err = b.start(); err != nil {
		return false, err
	}
	defer func() {
		if serr := b.stop(); err == nil {
			err = serr
		}
	}()
	return b.writeByte(addr << 1)
}

func (b *BitBang) Close() error { return b.p.Close() }
```

- [ ] **Step 4: Implement the fake pins and the frame decoder**

Create `internal/i2c/fake.go`:

```go
package i2c

// FakePins records every edge and decodes them back into I2C frames, so the
// bit-bang layer can be asserted without hardware. It verifies the master
// emits *valid I2C*, not merely that it calls the methods we expected.

// Frame is one decoded transaction.
type Frame struct {
	Addr     uint8
	Read     bool
	Data     []byte
	Complete bool // a STOP was seen
}

type FakePins struct {
	Sets, Gets int

	ack      bool
	sda, scl int

	inFrame bool
	bits    []int
	bytes   []byte
	frames  []Frame

	// The decoder counts 9 bit-times per byte: 8 data then the ACK slot,
	// which the master drives high while the (fake) slave pulls it low.
	bitInByte int
}

func NewFakePins(ackAll bool) *FakePins {
	return &FakePins{ack: ackAll, sda: 1, scl: 1}
}

func (f *FakePins) Level() (sda, scl int) { return f.sda, f.scl }

func (f *FakePins) Set(sda, scl int) error {
	f.Sets++
	prevSDA, prevSCL := f.sda, f.scl
	f.sda, f.scl = sda, scl

	// START: SDA falls while SCL is high. STOP: SDA rises while SCL is high.
	if prevSCL == 1 && scl == 1 {
		switch {
		case prevSDA == 1 && sda == 0:
			f.beginFrame()
		case prevSDA == 0 && sda == 1:
			f.endFrame()
		}
		return nil
	}
	// A bit is sampled on the rising clock edge.
	if prevSCL == 0 && scl == 1 && f.inFrame {
		f.sample(sda)
	}
	return nil
}

func (f *FakePins) Get() (int, int, error) {
	f.Gets++
	// During an ACK slot the slave owns SDA. Model a device that either
	// always ACKs (pulls low) or is absent (line floats high).
	if f.ack {
		return 0, f.scl, nil
	}
	return 1, f.scl, nil
}

func (f *FakePins) Close() error { return nil }

func (f *FakePins) Frames() []Frame { return f.frames }

func (f *FakePins) beginFrame() {
	f.inFrame = true
	f.bits = f.bits[:0]
	f.bytes = nil
	f.bitInByte = 0
	f.frames = append(f.frames, Frame{})
}

func (f *FakePins) endFrame() {
	if !f.inFrame {
		return
	}
	f.inFrame = false
	cur := &f.frames[len(f.frames)-1]
	cur.Complete = true
	if len(f.bytes) > 0 {
		cur.Addr = f.bytes[0] >> 1
		cur.Read = f.bytes[0]&1 == 1
		if len(f.bytes) > 1 {
			cur.Data = append([]byte(nil), f.bytes[1:]...)
		}
	}
}

func (f *FakePins) sample(bit int) {
	f.bitInByte++
	if f.bitInByte <= 8 {
		f.bits = append(f.bits, bit)
		return
	}
	// The 9th bit-time is the ACK slot; assemble the byte and reset.
	var b byte
	for _, v := range f.bits {
		b = b<<1 | byte(v)
	}
	f.bytes = append(f.bytes, b)
	f.bits = f.bits[:0]
	f.bitInByte = 0
}
```

> **Note for the implementer:** the ACK slot is a rising edge like any other,
> so `sample` sees 9 edges per byte. `bitInByte` reaching 9 is what closes the
> byte. If the decoder ever reports one byte too few, this counter is why.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd ~/Repositories/rackpanel && go test ./internal/i2c/ -v`
Expected: PASS, all five cases.

- [ ] **Step 6: Implement the real GPIO pins**

Create `internal/i2c/gpio_linux.go`:

```go
//go:build linux

package i2c

// GPIO character-device v2 uAPI.
//
// CORRECTED 2026-08-19: an earlier draft hand-rolled these structs because a
// check against x/sys v0.43.0 found no GPIO v2 types. v0.47.0 -- what this
// module resolves to -- ships them as GPIOV2* (note the casing; a GpioV2*
// grep finds nothing). Use them: struct layout is the thing most likely to be
// silently wrong across a uAPI change, and upstream owns it.
//
// The sizes the probe asserted are proven by the ioctl constants themselves:
// GPIO_V2_GET_LINE_IOCTL = 0xc250b407 encodes 0x250 = 592, and
// GPIO_V2_LINE_SET_VALUES_IOCTL = 0xc010b40f encodes 0x010 = 16.

import (
	"fmt"
	"os"
	"unsafe"

	"golang.org/x/sys/unix"
)

// The only GPIO v2 values x/sys does NOT export.
const (
	flagOutput     = 1 << 3 // GPIO_V2_LINE_FLAG_OUTPUT
	flagOpenDrain  = 1 << 6 // GPIO_V2_LINE_FLAG_OPEN_DRAIN
	flagBiasPullUp = 1 << 8 // GPIO_V2_LINE_FLAG_BIAS_PULL_UP
)

// gpioPins holds SDA on mask bit 0 and SCL on mask bit 1, so one ioctl
// drives both lines. The lineValues struct is reused across calls: this is
// the hot path (~713,000 ioctls per full frame) and it must not allocate.
type gpioPins struct {
	chip *os.File
	line int
	v    unix.GPIOV2LineValues
}

// OpenGPIO claims sda and scl on chip as open-drain outputs with the
// internal pull-up biased on. Both idle high; the RM0004 board also has
// external pull-ups.
func OpenGPIO(chip string, sda, scl int, consumer string) (Pins, error) {
	f, err := os.OpenFile(chip, os.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", chip, err)
	}

	var req unix.GPIOV2LineRequest
	req.Offsets[0] = uint32(sda)
	req.Offsets[1] = uint32(scl)
	copy(req.Consumer[:len(req.Consumer)-1], consumer)
	req.Num_lines = 2
	req.Config.Flags = flagOutput | flagOpenDrain | flagBiasPullUp

	if err := ioctl(f.Fd(), unix.GPIO_V2_GET_LINE_IOCTL, unsafe.Pointer(&req)); err != nil {
		f.Close()
		return nil, fmt.Errorf("claim gpio lines %d/%d: %w", sda, scl, err)
	}
	if req.Fd < 0 {
		f.Close()
		return nil, fmt.Errorf("kernel returned no line fd for %s", chip)
	}

	p := &gpioPins{chip: f, line: int(req.Fd)}
	if err := p.Set(1, 1); err != nil {
		p.Close()
		return nil, fmt.Errorf("set idle state: %w", err)
	}
	return p, nil
}

func (p *gpioPins) Set(sda, scl int) error {
	p.v.Mask = 0b11
	p.v.Bits = uint64(sda&1) | uint64(scl&1)<<1
	return ioctl(uintptr(p.line), unix.GPIO_V2_LINE_SET_VALUES_IOCTL, unsafe.Pointer(&p.v))
}

func (p *gpioPins) Get() (int, int, error) {
	p.v.Mask = 0b11
	p.v.Bits = 0
	if err := ioctl(uintptr(p.line), unix.GPIO_V2_LINE_GET_VALUES_IOCTL, unsafe.Pointer(&p.v)); err != nil {
		return 0, 0, err
	}
	return int(p.v.Bits & 1), int(p.v.Bits >> 1 & 1), nil
}

func (p *gpioPins) Close() error {
	_ = p.Set(1, 1) // release both lines before letting go
	err := unix.Close(p.line)
	if cerr := p.chip.Close(); err == nil {
		err = cerr
	}
	return err
}

func ioctl(fd, req uintptr, arg unsafe.Pointer) error {
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, fd, req, uintptr(arg)); errno != 0 {
		return errno
	}
	return nil
}
```

- [ ] **Step 7: Verify it compiles for the target and the tests still pass**

```bash
cd ~/Repositories/rackpanel
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build ./...
go test ./internal/i2c/ -v
go vet ./internal/i2c/
```

Expected: clean build for `linux/arm64`, tests PASS.

Note this file is `//go:build linux`: the GPIO types live in `ztypes_linux.go`, so a plain `go build` on macOS will not compile it. The `GOOS=linux GOARCH=arm64` build above is the one that matters.

- [ ] **Step 8: Commit**

```bash
cd ~/Repositories/rackpanel
git add go.mod go.sum internal/i2c
git commit -m "feat(agent): bit-banged I2C over the GPIO character device

Direct port of reference/phase0-probe.py -- every constant and delay in it
was verified against the real hardware, so nothing here is re-derived from
the vendor C driver.

Kept deliberately: 3 ioctls per bit (folding the trailing low into the next
bit is a third faster and zeroes the data hold time), and no clock-stretch
handling (Phase 0 measured zero stretch events; handling costs ~30%).

The fake pins decode recorded edges back into I2C frames, so the tests
assert the master emits valid I2C rather than that it called the methods we
expected. uAPI struct sizes are asserted at compile time."
```

---

### Task 5: The RM0004 register protocol — ✅ DONE 2026-08-19 (7/7 passing)

**Files:**
- Create: `~/Repositories/rackpanel/internal/panel/panel.go`
- Test: `~/Repositories/rackpanel/internal/panel/panel_test.go`

**Interfaces:**
- Consumes: `i2c.Bus`, `fb.Width`, `fb.Height`, `fb.RowBytes`, `fb.FrameBytes`, `blit.Run`
- Produces:
  - `panel.Addr = 0x18`, `panel.XStart = 0`, `panel.YStart = 24`, `panel.BurstMax = 160`
  - `panel.New(bus i2c.Bus, sleep func(time.Duration)) *panel.Panel` — pass `nil` for `sleep` to use `time.Sleep`
  - `(*Panel).WriteRun(first, last int, rows []byte) error` — `rows` is `(last-first+1)*fb.RowBytes` bytes
  - `(*Panel).WriteFull(frame []byte) error`
  - `(*Panel).Present(addr uint8) (bool, error)`

- [ ] **Step 1: Write the failing test**

Create `internal/panel/panel_test.go`:

```go
package panel

import (
	"testing"
	"time"

	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/fb"
)

// recordBus captures every Write so the register sequence can be asserted.
type recordBus struct {
	writes [][]byte
	// Zero value means a device answers, matching the real panel, so the
	// other tests in this file need no setup.
	probeAbsent bool
}

func (r *recordBus) Write(addr uint8, data []byte) error {
	if addr != Addr {
		return nil
	}
	r.writes = append(r.writes, append([]byte(nil), data...))
	return nil
}
func (r *recordBus) Probe(uint8) (bool, error) { return !r.probeAbsent, nil }
func (r *recordBus) Close() error              { return nil }

// commands returns only the 3-byte register writes.
func (r *recordBus) commands() [][]byte {
	var out [][]byte
	for _, w := range r.writes {
		if len(w) == 3 {
			out = append(out, w)
		}
	}
	return out
}

func newTestPanel() (*Panel, *recordBus, *time.Duration) {
	bus := &recordBus{}
	var slept time.Duration
	p := New(bus, func(d time.Duration) { slept += d })
	return p, bus, &slept
}

func TestWriteRunAppliesYStartOffset(t *testing.T) {
	p, bus, _ := newTestPanel()
	if err := p.WriteRun(0, 0, make([]byte, fb.RowBytes)); err != nil {
		t.Fatalf("WriteRun: %v", err)
	}
	cmds := bus.commands()
	if len(cmds) < 2 {
		t.Fatalf("got %d commands, want at least 2", len(cmds))
	}
	// X window spans the full width, unshifted.
	if cmds[0][0] != regX || cmds[0][1] != XStart || cmds[0][2] != fb.Width-1+XStart {
		t.Errorf("X window = % x, want %02x 00 %02x", cmds[0], regX, fb.Width-1)
	}
	// Y window is shifted by YStart=24 at BOTH ends. Shifting only one end
	// is the classic way this goes wrong: the image renders squashed rather
	// than obviously broken.
	if cmds[1][0] != regY || cmds[1][1] != YStart || cmds[1][2] != YStart {
		t.Errorf("Y window = % x, want %02x %02x %02x", cmds[1], regY, YStart, YStart)
	}
}

func TestWriteRunWindowsTheWholeRunOnce(t *testing.T) {
	p, bus, _ := newTestPanel()
	if err := p.WriteRun(10, 12, make([]byte, 3*fb.RowBytes)); err != nil {
		t.Fatalf("WriteRun: %v", err)
	}
	cmds := bus.commands()
	if cmds[1][1] != 10+YStart || cmds[1][2] != 12+YStart {
		t.Errorf("Y window = % x, want rows 10..12 offset by %d", cmds[1], YStart)
	}
	// One window per run, not one per row.
	windows := 0
	for _, c := range cmds {
		if c[0] == regY {
			windows++
		}
	}
	if windows != 1 {
		t.Errorf("issued %d Y windows for one run, want 1", windows)
	}
}

func TestChunksAreCappedAt160Bytes(t *testing.T) {
	p, bus, _ := newTestPanel()
	if err := p.WriteRun(0, 0, make([]byte, fb.RowBytes)); err != nil {
		t.Fatalf("WriteRun: %v", err)
	}
	payloads := 0
	for _, w := range bus.writes {
		if len(w) == 3 {
			continue
		}
		if len(w) > BurstMax {
			t.Fatalf("chunk of %d bytes exceeds the %d-byte cap", len(w), BurstMax)
		}
		payloads++
	}
	if payloads != fb.RowBytes/BurstMax {
		t.Errorf("sent %d chunks for one row, want %d", payloads, fb.RowBytes/BurstMax)
	}
}

func TestMandatoryDelaysAreIssued(t *testing.T) {
	// The 700us post-chunk delay is what stops the MCU dropping bytes; without
	// it the write pointer trails and the previous frame shows through as a
	// diagonal. It is the single most expensive thing to rediscover.
	p, bus, slept := newTestPanel()
	if err := p.WriteRun(0, 0, make([]byte, fb.RowBytes)); err != nil {
		t.Fatalf("WriteRun: %v", err)
	}
	chunks := 0
	cmds := 0
	for _, w := range bus.writes {
		if len(w) == 3 {
			cmds++
		} else {
			chunks++
		}
	}
	want := time.Duration(chunks)*ChunkDelay + time.Duration(cmds)*CmdDelay
	if *slept != want {
		t.Errorf("slept %v, want %v (%d chunks x %v + %d cmds x %v)",
			*slept, want, chunks, ChunkDelay, cmds, CmdDelay)
	}
}

func TestWriteFullUsesOneWindowForTheWholeFrame(t *testing.T) {
	p, bus, _ := newTestPanel()
	if err := p.WriteFull(make([]byte, fb.FrameBytes)); err != nil {
		t.Fatalf("WriteFull: %v", err)
	}
	windows := 0
	for _, c := range bus.commands() {
		if c[0] == regY {
			windows++
		}
	}
	// One window over all 80 rows is what makes the MCU's auto-increment
	// paint top-to-bottom -- the banded wipe, for free.
	if windows != 1 {
		t.Errorf("issued %d windows for a full sweep, want 1", windows)
	}
}

func TestSizeMismatchesAreRejected(t *testing.T) {
	p, _, _ := newTestPanel()
	if err := p.WriteRun(0, 1, make([]byte, fb.RowBytes)); err == nil {
		t.Error("expected an error: 2 rows requested, 1 row of data supplied")
	}
	if err := p.WriteFull(make([]byte, 100)); err == nil {
		t.Error("expected an error for a short frame")
	}
	if err := p.WriteRun(-1, 0, nil); err == nil {
		t.Error("expected an error for a negative first row")
	}
	if err := p.WriteRun(0, fb.Height, make([]byte, (fb.Height+1)*fb.RowBytes)); err == nil {
		t.Error("expected an error for a run past the last row")
	}
}

func TestPresentReportsWhatTheBusSaw(t *testing.T) {
	// The agent refuses to start when Present() is false, so a Panel that
	// always answered true would boot happily against a dead bus and then
	// write 25,600 bytes into the void on every frame.
	p, _, _ := newTestPanel()
	if ok, err := p.Present(Addr); err != nil || !ok {
		t.Errorf("Present on an answering bus = (%v, %v), want (true, nil)", ok, err)
	}

	silent := New(&recordBus{probeAbsent: true}, func(time.Duration) {})
	if ok, err := silent.Present(Addr); err != nil || ok {
		t.Errorf("Present on a silent bus = (%v, %v), want (false, nil)", ok, err)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/Repositories/rackpanel && go test ./internal/panel/`
Expected: build failure — `undefined: New`, `undefined: Addr`.

- [ ] **Step 3: Implement `panel`**

Create `internal/panel/panel.go`:

```go
// Package panel speaks the RM0004 MCU's register protocol.
//
// The MCU at 0x18 relays to an ST7735 160x80 RGB565 TFT. There is no init
// sequence to run -- the MCU initialises the ST7735 itself, which is why the
// vendor boot image persists until something overwrites it. There is also no
// brightness, backlight or display-off command anywhere in the protocol.
package panel

import (
	"fmt"
	"time"

	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/fb"
	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/i2c"
)

const (
	Addr = 0x18

	// The ST7735 is 132x162 of addressable RAM; this 160x80 panel is windowed
	// into it at a y offset of 24. Both ends of a Y window carry the offset.
	XStart = 0
	YStart = 24

	BurstMax = 160

	// Verified in Phase 0 and mandatory. Without ChunkDelay the MCU silently
	// drops bytes: the write pointer falls progressively behind across rows
	// and un-written pixels retain the PREVIOUS frame, tracing a diagonal.
	ChunkDelay = 700 * time.Microsecond
	CmdDelay   = 10 * time.Microsecond

	regBurst = 0x01
	regSync  = 0x03
	regX     = 0x2A
	regY     = 0x2B
	regChar  = 0x2C
)

type Panel struct {
	bus   i2c.Bus
	sleep func(time.Duration)
}

// New wraps a bus. Pass nil for sleep to use time.Sleep; tests pass a
// recorder so the mandatory delays can be asserted rather than trusted.
func New(bus i2c.Bus, sleep func(time.Duration)) *Panel {
	if sleep == nil {
		sleep = time.Sleep
	}
	return &Panel{bus: bus, sleep: sleep}
}

func (p *Panel) Present(addr uint8) (bool, error) { return p.bus.Probe(addr) }

func (p *Panel) cmd(reg, hi, lo byte) error {
	if err := p.bus.Write(Addr, []byte{reg, hi, lo}); err != nil {
		return err
	}
	p.sleep(CmdDelay)
	return nil
}

func (p *Panel) setWindow(x0, y0, x1, y1 int) error {
	if err := p.cmd(regX, byte(x0+XStart), byte(x1+XStart)); err != nil {
		return err
	}
	if err := p.cmd(regY, byte(y0+YStart), byte(y1+YStart)); err != nil {
		return err
	}
	if err := p.cmd(regChar, 0x00, 0x00); err != nil {
		return err
	}
	return p.cmd(regSync, 0x00, 0x01)
}

// burst streams payload into the current window, 160 bytes at a time.
func (p *Panel) burst(payload []byte) error {
	if err := p.cmd(regBurst, 0x00, 0x01); err != nil {
		return err
	}
	for off := 0; off < len(payload); off += BurstMax {
		end := off + BurstMax
		if end > len(payload) {
			end = len(payload)
		}
		if err := p.bus.Write(Addr, payload[off:end]); err != nil {
			return err
		}
		p.sleep(ChunkDelay)
	}
	if err := p.cmd(regBurst, 0x00, 0x00); err != nil {
		return err
	}
	return p.cmd(regSync, 0x00, 0x01)
}

// WriteRun paints rows [first, last] inclusive. rows must hold exactly that
// many rows of pixel data.
//
// The per-row burst framing is kept even inside a multi-row run: it is ~4 %
// of bytes and ~3.2 ms per full frame, and it is the framing Phase 0 actually
// proved against this MCU.
func (p *Panel) WriteRun(first, last int, rows []byte) error {
	if first < 0 || last < first || last >= fb.Height {
		return fmt.Errorf("panel: bad row run %d..%d (height %d)", first, last, fb.Height)
	}
	want := (last - first + 1) * fb.RowBytes
	if len(rows) != want {
		return fmt.Errorf("panel: run %d..%d needs %d bytes, got %d", first, last, want, len(rows))
	}
	if err := p.setWindow(0, first, fb.Width-1, last); err != nil {
		return err
	}
	for off := 0; off < len(rows); off += fb.RowBytes {
		if err := p.burst(rows[off : off+fb.RowBytes]); err != nil {
			return err
		}
	}
	return nil
}

// WriteFull sweeps the whole panel in one address window. The MCU
// auto-increments, so this paints top-to-bottom over roughly a second --
// which IS the banded wipe the design calls for, at no extra cost.
func (p *Panel) WriteFull(frame []byte) error {
	if len(frame) != fb.FrameBytes {
		return fmt.Errorf("panel: frame must be %d bytes, got %d", fb.FrameBytes, len(frame))
	}
	return p.WriteRun(0, fb.Height-1, frame)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ~/Repositories/rackpanel && go test ./internal/panel/ -v`
Expected: PASS, all seven cases.

- [ ] **Step 5: Commit**

```bash
cd ~/Repositories/rackpanel
git add internal/panel
git commit -m "feat(agent): RM0004 register protocol

Windows, bursts and the two mandatory delays, over an i2c.Bus interface so
the whole protocol is asserted against a recording fake.

Tests pin the things that fail quietly rather than loudly: YStart=24 applied
to BOTH ends of the Y window (shifting one end renders squashed, not
obviously broken), the 160-byte chunk cap, one window per run rather than
per row, and that the 700us/10us delays are actually issued."
```

---

### Task 6: Conductor client and display-at scheduling — ✅ DONE 2026-08-19

**Files:**
- Create: `~/Repositories/rackpanel/internal/tile/tile.go`
- Test: `~/Repositories/rackpanel/internal/tile/tile_test.go`

**Interfaces:**
- Consumes: `fb.FrameBytes`
- Produces:
  - `tile.Frame{Data []byte, ETag, Scene string, Seq int64, DisplayAt time.Time}`
  - `tile.ErrUnchanged` — sentinel returned on a 304
  - `tile.MaxDisplayWait = 5 * time.Second`
  - `tile.NewClient(baseURL, node string, hc *http.Client) *tile.Client`
  - `(*Client).Fetch(ctx context.Context) (*tile.Frame, error)`
  - `tile.Delay(now, displayAt time.Time) time.Duration` — pure

- [ ] **Step 1: Write the failing test**

Create `internal/tile/tile_test.go`:

```go
package tile

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/fb"
)

func serve(h http.HandlerFunc) (*Client, func()) {
	s := httptest.NewServer(h)
	return NewClient(s.URL, "jormungandr1", s.Client()), s.Close
}

func goodFrame(w http.ResponseWriter, etag string, displayAt string) {
	w.Header().Set("ETag", `"`+etag+`"`)
	w.Header().Set("X-Scene", "FLEET")
	w.Header().Set("X-Frame-Seq", "42")
	if displayAt != "" {
		w.Header().Set("X-Display-At", displayAt)
	}
	w.WriteHeader(http.StatusOK)
	w.Write(make([]byte, fb.FrameBytes))
}

func TestFetchParsesHeaders(t *testing.T) {
	c, done := serve(func(w http.ResponseWriter, r *http.Request) {
		goodFrame(w, "abc123", "1787149703.280")
	})
	defer done()

	f, err := c.Fetch(context.Background())
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if f.ETag != "abc123" {
		t.Errorf("ETag = %q, want abc123 (quotes stripped)", f.ETag)
	}
	if f.Scene != "FLEET" {
		t.Errorf("Scene = %q, want FLEET", f.Scene)
	}
	if f.Seq != 42 {
		t.Errorf("Seq = %d, want 42", f.Seq)
	}
	want := time.Unix(1787149703, 280000000)
	if f.DisplayAt.Sub(want).Abs() > time.Millisecond {
		t.Errorf("DisplayAt = %v, want %v", f.DisplayAt, want)
	}
	if len(f.Data) != fb.FrameBytes {
		t.Errorf("len(Data) = %d, want %d", len(f.Data), fb.FrameBytes)
	}
}

func TestFetchSendsIfNoneMatchAfterTheFirstFrame(t *testing.T) {
	var seen []string
	c, done := serve(func(w http.ResponseWriter, r *http.Request) {
		seen = append(seen, r.Header.Get("If-None-Match"))
		if r.Header.Get("If-None-Match") != "" {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		goodFrame(w, "abc123", "")
	})
	defer done()

	if _, err := c.Fetch(context.Background()); err != nil {
		t.Fatalf("first Fetch: %v", err)
	}
	if _, err := c.Fetch(context.Background()); !errors.Is(err, ErrUnchanged) {
		t.Fatalf("second Fetch err = %v, want ErrUnchanged", err)
	}
	if seen[0] != "" {
		t.Errorf("first request sent If-None-Match %q, want none", seen[0])
	}
	if seen[1] != `"abc123"` {
		t.Errorf("second request sent %q, want the quoted ETag", seen[1])
	}
}

func TestShortBodyIsRejectedAndDoesNotPoisonTheETag(t *testing.T) {
	// A truncated body must not become the cached validator, or the agent
	// 304s forever against a frame it never actually received.
	n := 0
	c, done := serve(func(w http.ResponseWriter, r *http.Request) {
		n++
		if n == 1 {
			w.Header().Set("ETag", `"short"`)
			w.WriteHeader(http.StatusOK)
			w.Write(make([]byte, 100))
			return
		}
		goodFrame(w, "good", "")
	})
	defer done()

	if _, err := c.Fetch(context.Background()); err == nil {
		t.Fatal("expected an error for a 100-byte body")
	}
	f, err := c.Fetch(context.Background())
	if err != nil {
		t.Fatalf("recovery Fetch: %v", err)
	}
	if f.ETag != "good" {
		t.Errorf("ETag = %q, want good", f.ETag)
	}
}

func TestNotFoundIsAnError(t *testing.T) {
	c, done := serve(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	defer done()
	if _, err := c.Fetch(context.Background()); err == nil {
		t.Fatal("expected an error for 404 (node not in RACKPANEL_NODES)")
	}
}

func TestRequestPathIncludesTheNode(t *testing.T) {
	var path string
	c, done := serve(func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.Path
		goodFrame(w, "abc", "")
	})
	defer done()
	if _, err := c.Fetch(context.Background()); err != nil {
		t.Fatal(err)
	}
	if path != "/tile/jormungandr1" {
		t.Errorf("path = %q, want /tile/jormungandr1", path)
	}
}

func TestDelay(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	cases := []struct {
		name      string
		displayAt time.Time
		want      time.Duration
	}{
		// The conductor only re-stamps display_at when the pixels change, so
		// a frame that has been up for 15s still carries its original
		// timestamp. Treating the header as always-future would stall every
		// panel that joins mid-scene.
		{"already past", now.Add(-3 * time.Second), 0},
		{"exactly now", now, 0},
		{"within the lead", now.Add(1200 * time.Millisecond), 1200 * time.Millisecond},
		{"absent header", time.Time{}, 0},
		{"implausibly far ahead", now.Add(time.Hour), MaxDisplayWait},
	}
	for _, c := range cases {
		if got := Delay(now, c.displayAt); got != c.want {
			t.Errorf("%s: Delay = %v, want %v", c.name, got, c.want)
		}
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/Repositories/rackpanel && go test ./internal/tile/`
Expected: build failure — `undefined: NewClient`, `undefined: Delay`.

- [ ] **Step 3: Implement `tile`**

Create `internal/tile/tile.go`:

```go
// Package tile fetches this node's frame from the conductor.
package tile

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/fb"
)

// MaxDisplayWait bounds how long an X-Display-At header may park a panel. A
// malformed or wildly skewed value must not take a display offline.
const MaxDisplayWait = 5 * time.Second

// ErrUnchanged means the conductor answered 304: the frame we already hold
// is current.
var ErrUnchanged = errors.New("tile: unchanged")

type Frame struct {
	Data      []byte
	ETag      string
	Scene     string
	Seq       int64
	DisplayAt time.Time
}

type Client struct {
	url  string
	hc   *http.Client
	etag string
}

func NewClient(baseURL, node string, hc *http.Client) *Client {
	if hc == nil {
		hc = &http.Client{Timeout: 5 * time.Second}
	}
	return &Client{
		url: strings.TrimSuffix(baseURL, "/") + "/tile/" + node,
		hc:  hc,
	}
}

func (c *Client) Fetch(ctx context.Context) (*Frame, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.url, nil)
	if err != nil {
		return nil, err
	}
	if c.etag != "" {
		req.Header.Set("If-None-Match", `"`+c.etag+`"`)
	}

	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusNotModified:
		io.Copy(io.Discard, resp.Body)
		return nil, ErrUnchanged
	case http.StatusOK:
	default:
		io.Copy(io.Discard, resp.Body)
		return nil, fmt.Errorf("tile: conductor returned %s", resp.Status)
	}

	data, err := io.ReadAll(io.LimitReader(resp.Body, fb.FrameBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) != fb.FrameBytes {
		// Deliberately do NOT cache this ETag: a truncated frame whose
		// validator we adopted would 304 forever against a frame we never
		// received.
		return nil, fmt.Errorf("tile: got %d bytes, want %d", len(data), fb.FrameBytes)
	}

	f := &Frame{
		Data:      data,
		ETag:      strings.Trim(strings.TrimPrefix(resp.Header.Get("ETag"), "W/"), `"`),
		Scene:     resp.Header.Get("X-Scene"),
		DisplayAt: parseDisplayAt(resp.Header.Get("X-Display-At")),
	}
	f.Seq, _ = strconv.ParseInt(resp.Header.Get("X-Frame-Seq"), 10, 64)
	c.etag = f.ETag
	return f, nil
}

// Delay reports how long to hold a frame before starting the blit.
//
// X-Display-At is routinely in the PAST: the conductor dedupes on ETag and
// only re-stamps when the pixels change, so a frame on screen for fifteen
// seconds still carries its original timestamp. Past means blit now.
func Delay(now, displayAt time.Time) time.Duration {
	if displayAt.IsZero() {
		return 0
	}
	d := displayAt.Sub(now)
	if d <= 0 {
		return 0
	}
	if d > MaxDisplayWait {
		return MaxDisplayWait
	}
	return d
}

func parseDisplayAt(v string) time.Time {
	if v == "" {
		return time.Time{}
	}
	secs, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return time.Time{}
	}
	return time.Unix(int64(secs), int64((secs-float64(int64(secs)))*1e9))
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ~/Repositories/rackpanel && go test ./internal/tile/ -v`
Expected: PASS, all six cases.

- [ ] **Step 5: Commit**

```bash
cd ~/Repositories/rackpanel
git add internal/tile
git commit -m "feat(agent): conductor client and display-at scheduling

Delay() is a pure function with the case that matters pinned in a test:
X-Display-At is routinely in the PAST, because the conductor dedupes on ETag
and only re-stamps when pixels change. Treating it as always-future would
stall every panel joining mid-scene.

A truncated body is rejected WITHOUT caching its ETag -- adopting that
validator would 304 forever against a frame we never received."
```

---

### Task 7: Metrics, probes, and the control loop — ✅ DONE 2026-08-19 (3/3 metrics tests; 38 tests across 7 packages)

**Files:**
- Create: `~/Repositories/rackpanel/internal/metrics/metrics.go`
- Create: `~/Repositories/rackpanel/cmd/panel-agent/main.go`
- Test: `~/Repositories/rackpanel/internal/metrics/metrics_test.go`

**Interfaces:**
- Consumes: everything above.
- Produces: the `panel-agent` binary, flags `--probe-device`, `--selftest`.

- [ ] **Step 1: Add the Prometheus dependency and resolve its graph**

```bash
cd ~/Repositories/rackpanel
go get github.com/prometheus/client_golang
go mod tidy
```

`go mod tidy` is not optional here. Adding the module without anything
importing it records the require line but **not** its transitive closure, so
`go.sum` stays missing `beorn7/perks`, `cespare/xxhash/v2`,
`prometheus/client_model`, `prometheus/common`, `prometheus/procfs`,
`munnerz/goautoneg` and `google.golang.org/protobuf`. Every build then fails
with `missing go.sum entry` the moment `metrics.go` imports it. Tidy also
promotes `x/image` and `x/sys` from `// indirect` to direct, which they now
are.

- [ ] **Step 2: Write the failing test**

Create `internal/metrics/metrics_test.go`:

```go
package metrics

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestReadyzReflectsPanelHealthNotProcessHealth(t *testing.T) {
	// The spec's rule: the display is never important enough to restart for.
	// A wedged panel must fail READINESS (pod goes NotReady, stays running),
	// never liveness.
	m := New("jormungandr1")
	srv := httptest.NewServer(m.Handler())
	defer srv.Close()

	m.MarkAlive()

	m.RecordI2CError("burst")
	if code := get(t, srv.URL+"/readyz"); code != http.StatusServiceUnavailable {
		t.Errorf("/readyz after an I2C error = %d, want 503", code)
	}
	if code := get(t, srv.URL+"/healthz"); code != http.StatusOK {
		t.Errorf("/healthz after an I2C error = %d, want 200 -- an I2C fault must not restart the pod", code)
	}

	m.RecordBlit("full", 900*time.Millisecond, 80)
	if code := get(t, srv.URL+"/readyz"); code != http.StatusOK {
		t.Errorf("/readyz after a successful blit = %d, want 200", code)
	}
}

func TestHealthzFailsWhenTheLoopStops(t *testing.T) {
	m := New("jormungandr1")
	m.LoopTimeout = 50 * time.Millisecond
	srv := httptest.NewServer(m.Handler())
	defer srv.Close()

	m.MarkAlive()
	if code := get(t, srv.URL+"/healthz"); code != http.StatusOK {
		t.Fatalf("/healthz = %d, want 200", code)
	}
	time.Sleep(80 * time.Millisecond)
	if code := get(t, srv.URL+"/healthz"); code != http.StatusServiceUnavailable {
		t.Errorf("/healthz after the loop stalled = %d, want 503", code)
	}
}

func TestMetricsExposesTheSpecdSeries(t *testing.T) {
	m := New("jormungandr1")
	srv := httptest.NewServer(m.Handler())
	defer srv.Close()

	m.RecordBlit("diff", 200*time.Millisecond, 15)
	m.RecordI2CError("write")
	m.RecordFetchError("refused")
	m.SetFrame(42, 250*time.Millisecond)

	resp, err := http.Get(srv.URL + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	// bytes.Buffer, not strings.Builder: Builder implements io.Writer but
	// NOT io.ReaderFrom, so it has no ReadFrom method and will not compile.
	body := new(bytes.Buffer)
	if _, err := body.ReadFrom(resp.Body); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"rackpanel_agent_blit_seconds",
		"rackpanel_agent_rows_written_total",
		"rackpanel_agent_i2c_errors_total",
		"rackpanel_agent_frame_lag_seconds",
		"rackpanel_agent_fetch_errors_total",
		"rackpanel_agent_frame_seq",
	} {
		if !strings.Contains(body.String(), want) {
			t.Errorf("missing metric %q", want)
		}
	}
}

func get(t *testing.T, url string) int {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd ~/Repositories/rackpanel && go test ./internal/metrics/`
Expected: build failure — `undefined: New`.

- [ ] **Step 4: Implement `metrics`**

Create `internal/metrics/metrics.go`:

```go
// Package metrics carries the agent's Prometheus series and its probe
// endpoints.
//
// The liveness/readiness split is load-bearing. The design's governing rule
// is that the display is never important enough to restart for: an I2C fault
// therefore fails READINESS -- the pod goes NotReady and shows up in
// alerting while staying up and retrying -- and never fails liveness.
package metrics

import (
	"net/http"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type Metrics struct {
	// LoopTimeout is how long the control loop may go without a tick before
	// /healthz reports the process as stuck.
	LoopTimeout time.Duration

	reg *prometheus.Registry

	blitSeconds *prometheus.HistogramVec
	rowsWritten prometheus.Counter
	i2cErrors   *prometheus.CounterVec
	fetchErrors *prometheus.CounterVec
	frameLag    prometheus.Gauge
	frameSeq    prometheus.Gauge

	mu        sync.Mutex
	lastTick  time.Time
	panelOK   bool
}

func New(node string) *Metrics {
	labels := prometheus.Labels{"node": node}
	m := &Metrics{
		LoopTimeout: 60 * time.Second,
		reg:         prometheus.NewRegistry(),
		blitSeconds: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:        "rackpanel_agent_blit_seconds",
			Help:        "Time spent writing a frame to the panel.",
			ConstLabels: labels,
			// A full sweep is ~1s and a typical diff ~0.2s, so the default
			// buckets (which top out at 10s) put everything in one bin.
			Buckets: []float64{0.05, 0.1, 0.2, 0.4, 0.8, 1.2, 2, 4, 8},
		}, []string{"kind"}),
		rowsWritten: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "rackpanel_agent_rows_written_total", Help: "Panel rows written.",
			ConstLabels: labels,
		}),
		i2cErrors: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "rackpanel_agent_i2c_errors_total", Help: "I2C write failures.",
			ConstLabels: labels,
		}, []string{"op"}),
		fetchErrors: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "rackpanel_agent_fetch_errors_total", Help: "Conductor fetch failures.",
			ConstLabels: labels,
		}, []string{"reason"}),
		frameLag: prometheus.NewGauge(prometheus.GaugeOpts{
			Name:        "rackpanel_agent_frame_lag_seconds",
			Help:        "Blit start minus X-Display-At. Four series tracking together means the panels are in unison.",
			ConstLabels: labels,
		}),
		frameSeq: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "rackpanel_agent_frame_seq", Help: "Last blitted X-Frame-Seq.",
			ConstLabels: labels,
		}),
	}
	m.reg.MustRegister(m.blitSeconds, m.rowsWritten, m.i2cErrors,
		m.fetchErrors, m.frameLag, m.frameSeq)
	m.panelOK = true
	return m
}

func (m *Metrics) MarkAlive() {
	m.mu.Lock()
	m.lastTick = time.Now()
	m.mu.Unlock()
}

func (m *Metrics) RecordBlit(kind string, d time.Duration, rows int) {
	m.blitSeconds.WithLabelValues(kind).Observe(d.Seconds())
	m.rowsWritten.Add(float64(rows))
	m.mu.Lock()
	m.panelOK = true
	m.mu.Unlock()
}

func (m *Metrics) RecordI2CError(op string) {
	m.i2cErrors.WithLabelValues(op).Inc()
	m.mu.Lock()
	m.panelOK = false
	m.mu.Unlock()
}

func (m *Metrics) RecordFetchError(reason string) { m.fetchErrors.WithLabelValues(reason).Inc() }

func (m *Metrics) SetFrame(seq int64, lag time.Duration) {
	m.frameSeq.Set(float64(seq))
	m.frameLag.Set(lag.Seconds())
}

func (m *Metrics) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(m.reg, promhttp.HandlerOpts{}))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		m.mu.Lock()
		stuck := !m.lastTick.IsZero() && time.Since(m.lastTick) > m.LoopTimeout
		m.mu.Unlock()
		if stuck {
			http.Error(w, "control loop stalled", http.StatusServiceUnavailable)
			return
		}
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		m.mu.Lock()
		ok := m.panelOK
		m.mu.Unlock()
		if !ok {
			http.Error(w, "last panel write failed", http.StatusServiceUnavailable)
			return
		}
		w.Write([]byte("ok"))
	})
	return mux
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd ~/Repositories/rackpanel && go test ./internal/metrics/ -v`
Expected: PASS, all three cases.

- [ ] **Step 5b: Stub OpenGPIO for non-Linux hosts**

`i2c.OpenGPIO` lives only in `gpio_linux.go` (`//go:build linux`). Once
`main.go` references it, `go build ./...` and `go test ./...` break on any
non-Linux developer machine — while CI, which builds on Linux, stays green.
That asymmetry is how the breakage hides. Create
`internal/i2c/gpio_other.go`:

```go
//go:build !linux

package i2c

import (
	"fmt"
	"runtime"
)

// OpenGPIO is unavailable off Linux: the GPIO character device is a Linux
// uAPI. This stub exists so the module still builds and tests on a
// developer machine.
func OpenGPIO(chip string, sda, scl int, consumer string) (Pins, error) {
	return nil, fmt.Errorf("i2c: GPIO character device unavailable on %s", runtime.GOOS)
}
```

- [ ] **Step 6: Write the control loop**

Create `cmd/panel-agent/main.go`:

```go
// Command panel-agent paints this node's rackpanel tile on the RM0004 LCD.
//
// It knows nothing about Kubernetes, Prometheus, scenes or palettes: the
// conductor decides what the panel shows, and this binary is the wire.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/blit"
	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/card"
	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/fb"
	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/i2c"
	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/metrics"
	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/panel"
	"gitea.derekjacobs.dev/bluevulpine/rackpanel/internal/tile"
)

const (
	pollInterval  = 500 * time.Millisecond
	offlineAfter  = 30 * time.Second
	gpioChip      = "/dev/gpiochip0"
	gpioSDA       = 2
	gpioSCL       = 3
	gpioConsumer  = "rackpanel-agent"
)

func main() {
	var (
		probeDevice = flag.Bool("probe-device", false, "open the GPIO chip, report, and exit")
		selftest    = flag.Bool("selftest", false, "draw the identity card and exit")
		listen      = flag.String("listen", ":8080", "address for /healthz, /readyz and /metrics")
	)
	flag.Parse()

	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	node := os.Getenv("NODE_NAME")
	if node == "" {
		log.Error("NODE_NAME is unset; the downward API env is missing")
		os.Exit(1)
	}
	conductor := os.Getenv("RACKPANEL_CONDUCTOR_URL")
	if conductor == "" {
		conductor = "http://rackpanel.observability.svc.cluster.local:8080"
	}

	if err := run(log, node, conductor, *listen, *probeDevice, *selftest); err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger, node, conductor, listen string, probeDevice, selftest bool) error {
	// The bit-bang hot path issues roughly 713,000 ioctls per full frame.
	// Pinning the OS thread keeps it off the scheduler's migration path.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	pins, err := i2c.OpenGPIO(gpioChip, gpioSDA, gpioSCL, gpioConsumer)
	if err != nil {
		return fmt.Errorf("open gpio: %w", err)
	}
	defer pins.Close()

	bus := i2c.NewBitBang(pins)
	p := panel.New(bus, nil)

	present, err := p.Present(panel.Addr)
	if err != nil {
		return fmt.Errorf("probe %#02x: %w", panel.Addr, err)
	}
	if !present {
		return fmt.Errorf("no device ACKed at %#02x", panel.Addr)
	}
	log.Info("panel found", "addr", fmt.Sprintf("%#02x", panel.Addr), "node", node)

	if probeDevice {
		fmt.Println("OK: /dev/gpiochip0 claimed and 0x18 ACKed")
		return nil
	}

	identity, err := card.Identity(node)
	if err != nil {
		return fmt.Errorf("render identity card: %w", err)
	}
	if err := p.WriteFull(identity); err != nil {
		return fmt.Errorf("write identity card: %w", err)
	}
	if selftest {
		return nil
	}

	m := metrics.New(node)
	srv := &http.Server{Addr: listen, Handler: m.Handler()}
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Error("metrics server", "err", err)
		}
	}()
	defer srv.Close()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	loop(ctx, log, m, p, tile.NewClient(conductor, node, nil), node, identity)
	return nil
}

func loop(ctx context.Context, log *slog.Logger, m *metrics.Metrics,
	p *panel.Panel, client *tile.Client, node string, shown []byte) {

	var (
		lastScene    string
		firstFailure time.Time
		offlineShown bool
	)

	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Info("shutting down")
			return
		case <-ticker.C:
		}
		m.MarkAlive()

		frame, err := client.Fetch(ctx)
		switch {
		case errors.Is(err, tile.ErrUnchanged):
			firstFailure = time.Time{}
			continue
		case err != nil:
			m.RecordFetchError(reason(err))
			if firstFailure.IsZero() {
				firstFailure = time.Now()
			}
			// Only replace a good tile once the conductor has been gone long
			// enough that what is on screen is no longer trustworthy.
			if !offlineShown && time.Since(firstFailure) > offlineAfter {
				if c, cerr := card.Offline(node, time.Since(firstFailure)); cerr == nil {
					if werr := p.WriteFull(c); werr != nil {
						m.RecordI2CError("offline-card")
					} else {
						m.RecordBlit("full", 0, fb.Height)
						shown, lastScene, offlineShown = c, "", true
					}
				}
			}
			continue
		}

		firstFailure = time.Time{}
		offlineShown = false

		if d := tile.Delay(time.Now(), frame.DisplayAt); d > 0 {
			select {
			case <-ctx.Done():
				return
			case <-time.After(d):
			}
		}

		runs, full := blit.Plan(shown, frame.Data, frame.Scene != lastScene)
		if !full && len(runs) == 0 {
			lastScene = frame.Scene
			continue
		}

		start := time.Now()
		if !frame.DisplayAt.IsZero() {
			m.SetFrame(frame.Seq, start.Sub(frame.DisplayAt))
		}

		// A blit is never aborted: a partially written frame is worse than a
		// stale one, and a newer frame is only 500ms away.
		var werr error
		rows := 0
		if full {
			werr = p.WriteFull(frame.Data)
			rows = fb.Height
		} else {
			for _, r := range runs {
				lo := r.First * fb.RowBytes
				hi := (r.Last + 1) * fb.RowBytes
				if werr = p.WriteRun(r.First, r.Last, frame.Data[lo:hi]); werr != nil {
					break
				}
				rows += r.Last - r.First + 1
			}
		}
		if werr != nil {
			m.RecordI2CError("write")
			log.Error("panel write failed", "err", werr, "scene", frame.Scene)
			// Do not adopt this frame as shown: the panel now holds a partial
			// image, and the next diff must be computed against reality --
			// which we no longer know. Force a sweep next time.
			shown, lastScene = nil, ""
			continue
		}

		kind := "diff"
		if full {
			kind = "full"
		}
		m.RecordBlit(kind, time.Since(start), rows)
		shown = frame.Data
		lastScene = frame.Scene
		log.Info("blitted", "scene", frame.Scene, "seq", frame.Seq,
			"kind", kind, "rows", rows, "took", time.Since(start).String())
	}
}

func reason(err error) string {
	if os.IsTimeout(err) {
		return "timeout"
	}
	return "error"
}
```

- [ ] **Step 7: Build and vet everything**

```bash
cd ~/Repositories/rackpanel
go build ./...
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o /dev/null ./cmd/panel-agent
go vet ./...
go test ./... -v
```

Expected: clean build for both host and `linux/arm64`; all tests PASS.

- [ ] **Step 8: Commit**

```bash
cd ~/Repositories/rackpanel
git add go.mod go.sum internal/metrics cmd/panel-agent
git commit -m "feat(agent): metrics, probes and the control loop

Liveness and readiness are split on purpose: an I2C fault fails READINESS so
the pod goes NotReady and stays running, per the design's rule that the
display is never important enough to restart for. Only a stalled control
loop fails liveness.

A failed write clears the shown framebuffer rather than adopting the frame:
the panel now holds a partial image and the next diff would be computed
against a reality we no longer know, so the next pass sweeps."
```

---

### Task 8: Build the arm64 image — ✅ DONE 2026-08-19 (image `6-348390b8`, verified `arm64`/`linux`)

> **Restructured during execution.** The original plan used a multi-stage
> `Dockerfile.agent` with a `golang` build stage plus
> `custom_platform: linux/arm64`. That combination is wrong: kaniko's
> `--customPlatform` also selects the platform **base images are pulled for**,
> so the build stage would fetch an *arm64* `golang:1.26-alpine` and then try
> to `RUN` an arm64 toolchain on the amd64 runner. All three Talos amd64 nodes
> carry the `binfmt-misc` extension, so this would **not** fail loudly — it
> would silently emulate a Go compile under qemu.
>
> Fixed by splitting compile from packaging: a Drone step cross-compiles
> natively on amd64, and `Dockerfile.agent` is `FROM scratch` with no `RUN`.
> Nothing is left to emulate.
>
> **The kaniko setting name was verified, not guessed.** `drone/drone-kaniko`
> reads the flag from `PLUGIN_PLATFORM` **or** `PLUGIN_CUSTOM_PLATFORM` and
> passes it as `--customPlatform`, so `custom_platform:` is correct.
> Confirmed on the pushed manifest: `Architecture: arm64`, `Os: linux`,
> 1 layer.

**Files:**
- Create: `~/Repositories/rackpanel/Dockerfile.agent`
- Rewrite: `~/Repositories/rackpanel/.dockerignore`
- Modify: `~/Repositories/rackpanel/.drone.yml`

**Interfaces:**
- Consumes: the `panel-agent` binary from Task 7.
- Produces: `gitea.derekjacobs.dev/bluevulpine/rackpanel-agent:<build>-<sha8>`, `linux/arm64`.

- [x] **Step 1: Write the agent Dockerfile — no build stage**

```dockerfile
FROM scratch
COPY dist/panel-agent /panel-agent
EXPOSE 8080
ENTRYPOINT ["/panel-agent"]
```

- [x] **Step 2: `.dockerignore`**

Shared by both image builds, so it must not exclude `dist/`.

```dockerignore
.git*
.drone.yml
docs/
tests/
reference/
__pycache__
*.pyc
*.egg-info
.venv
.pytest_cache
```

- [x] **Step 3: Drone steps**

```yaml
  - name: test-go
    image: golang:1.26-alpine
    commands:
      - go vet ./...
      - go test ./... -count=1

  - name: build-agent-binary
    image: golang:1.26-alpine
    commands:
      - CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o dist/panel-agent ./cmd/panel-agent
      - ls -lh dist/panel-agent

  - name: build-and-push-agent
    image: plugins/kaniko
    settings:
      dockerfile: Dockerfile.agent
      custom_platform: linux/arm64
      registry: gitea.derekjacobs.dev
      repo: gitea.derekjacobs.dev/bluevulpine/rackpanel-agent
      username: {from_secret: registry_user}
      password: {from_secret: registry_token}
      tags:
        - latest
        - ${DRONE_BUILD_NUMBER}-${DRONE_COMMIT_SHA:0:8}
```

- [x] **Step 4: Commit and push**

- [x] **Step 5: Verify the pushed image really is arm64**

```bash
CREDS=$(kubectl -n observability get secret gitea-registry-creds \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | python3 -c '
import json,sys,base64
d=json.load(sys.stdin); a=list(d["auths"].values())[0]
print(base64.b64decode(a["auth"]).decode() if "auth" in a else a["username"]+":"+a["password"])')
skopeo inspect --creds "$CREDS" \
  docker://gitea.derekjacobs.dev/bluevulpine/rackpanel-agent:latest \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["Architecture"], d["Os"])'
```

Result: `arm64 linux`. An `amd64` result would mean the Pis pull it and fail
with `exec format error`, which reads as a broken binary rather than a
mis-stamped image.

- [x] **Step 6: Record the winning tag** — **`6-348390b8`**. Task 10 commits
  this verbatim. A placeholder tag would leave the DaemonSet in
  `ImagePullBackOff` until the automation's next 30 m interval, and an image
  pull failure does **not** trip this cluster's job-failure alerting.

### Task 9: Flux image automation for the agent image

**Files:**
- Create: `flux-talos/kubernetes/apps/flux-system/rackpanel/app/imagerepository-agent.yaml`
- Create: `flux-talos/kubernetes/apps/flux-system/rackpanel/app/imagepolicy-agent.yaml`
- Modify: `flux-talos/kubernetes/apps/flux-system/rackpanel/app/kustomization.yaml`

**Interfaces:**
- Consumes: the image from Task 8.
- Produces: `ImagePolicy/rackpanel-agent` in `flux-system`, referenced by Task 10's `$imagepolicy` marker.

**Do NOT add a second `ImageUpdateAutomation`.** The existing one already has `update.path: ./kubernetes/apps/observability/rackpanel`, which covers both markers. A second automation over the same path is the "one automation per app" gotcha in `docs/runbooks/flux-image-automation.md`.

- [ ] **Step 1: Create the ImageRepository**

Create `kubernetes/apps/flux-system/rackpanel/app/imagerepository-agent.yaml`, mirroring the existing `imagerepository.yaml` but for the agent image:

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/image.toolkit.fluxcd.io/imagerepository_v1beta2.json
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageRepository
metadata:
  name: rackpanel-agent
spec:
  image: gitea.derekjacobs.dev/bluevulpine/rackpanel-agent
  interval: 5m
  secretRef:
    name: gitea-registry-creds
```

The `interval` and `secretRef` above are copied verbatim from the existing
`imagerepository.yaml`, so the two repositories stay consistent.

- [ ] **Step 2: Create the ImagePolicy**

Create `kubernetes/apps/flux-system/rackpanel/app/imagepolicy-agent.yaml`:

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/image.toolkit.fluxcd.io/imagepolicy_v1beta2.json
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImagePolicy
metadata:
  name: rackpanel-agent
spec:
  imageRepositoryRef:
    name: rackpanel-agent
  filterTags:
    # Drone tags images as <build-number>-<sha8>; extract the build number
    pattern: '^(?P<num>[0-9]+)-[0-9a-f]{8}$'
    extract: '$num'
  policy:
    numerical:
      order: asc
```

- [ ] **Step 3: Add both to the kustomization**

Modify `kubernetes/apps/flux-system/rackpanel/app/kustomization.yaml` so `resources` reads:

```yaml
resources:
  - ./imagerepository.yaml
  - ./imagerepository-agent.yaml
  - ./imagepolicy.yaml
  - ./imagepolicy-agent.yaml
  - ./imageupdateautomation.yaml
```

- [ ] **Step 4: Validate and commit**

```bash
cd ~/Repositories/flux-talos
kustomize build kubernetes/apps/flux-system/rackpanel/app | head -60
lefthook run pre-commit
git add kubernetes/apps/flux-system/rackpanel/app
git commit -m "feat(rackpanel): image automation for the arm64 panel-agent image

Second ImageRepository/ImagePolicy pair only -- the existing
ImageUpdateAutomation already scopes update.path to this app's directory and
covers both markers. A second automation over the same path is the
one-automation-per-app gotcha in docs/runbooks/flux-image-automation.md."
git push
```

- [ ] **Step 5: Verify the policy resolved**

```bash
kubectl -n flux-system get imagepolicy rackpanel-agent \
  -o jsonpath='{.status.latestRef.tag}{"\n"}'
```

Expected: the tag recorded in Task 8 Step 6. An empty result means the
`ImageRepository` cannot authenticate — check `kubectl -n flux-system describe
imagerepository rackpanel-agent`.

---

### Task 10: Deploy the DaemonSet and verify on hardware

**Files:**
- Modify: `flux-talos/kubernetes/apps/observability/rackpanel/app/helmrelease.yaml`
- Create: `flux-talos/kubernetes/apps/observability/rackpanel/app/podmonitor.yaml`
- Modify: `flux-talos/kubernetes/apps/observability/rackpanel/app/kustomization.yaml`

**Interfaces:**
- Consumes: Task 1's verdict, Task 8's image tag, Task 9's `ImagePolicy`.
- Produces: four running agents painting four panels.

- [ ] **Step 1: Move `nodeSelector` out of `defaultPodOptions`**

In `helmrelease.yaml`, **delete** the `nodeSelector` block from `defaultPodOptions` and add it to the conductor's controller instead:

```yaml
    controllers:
      rackpanel:
        type: deployment
        # ... existing keys unchanged ...
        pod:
          # amd64 only: rendering is the one CPU-hungry thing here, and the
          # Pis are already carrying the panels.
          nodeSelector:
            kubernetes.io/arch: amd64
```

This matters because app-template 5.1.0's `defaultPodOptionsStrategy` defaults
to **`overwrite`**, not `merge` (`lib/pod/_getOption.tpl`). Leaving the amd64
selector as a default and overriding it per-controller works, but stating each
controller's selector explicitly removes any question about precedence.

- [ ] **Step 2: Add the agent controller**

Add under `controllers:` in `helmrelease.yaml`:

```yaml
      agent:
        type: daemonset
        annotations:
          reloader.stakater.com/auto: "true"
        pod:
          # The four Pis are the only arm64 nodes. This selects the wrong
          # property (architecture, not "has a panel") but avoids a
          # machine-config apply across all four for a cosmetic gain. If a
          # non-panel arm64 node is ever added, add nodeLabels to
          # talconfig.yaml and switch this selector.
          nodeSelector:
            kubernetes.io/arch: arm64
          tolerations:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists
              effect: NoSchedule
            - key: node.kubernetes.io/low-power
              operator: Exists
              effect: NoSchedule
          # defaultPodOptionsStrategy is "overwrite", so this block REPLACES
          # defaultPodOptions.securityContext wholesale -- seccompProfile has
          # to be restated here or it is silently dropped.
          securityContext:
            runAsUser: 0
            runAsGroup: 0
            runAsNonRoot: false
            seccompProfile:
              type: RuntimeDefault
        containers:
          app:
            image:
              repository: gitea.derekjacobs.dev/bluevulpine/rackpanel-agent
              tag: 6-348390b8 # {"$imagepolicy": "flux-system:rackpanel-agent:tag"}
            env:
              TZ: "${TIMEZONE}"
              NODE_NAME:
                valueFrom:
                  fieldRef:
                    fieldPath: spec.nodeName
              RACKPANEL_CONDUCTOR_URL: http://rackpanel.observability.svc.cluster.local:8080
            probes:
              liveness:
                enabled: true
                custom: true
                spec:
                  httpGet: {path: /healthz, port: 8080}
                  initialDelaySeconds: 15
                  periodSeconds: 30
              readiness:
                enabled: true
                custom: true
                spec:
                  # A wedged panel goes NotReady and stays running. The
                  # display is never important enough to restart for.
                  httpGet: {path: /readyz, port: 8080}
                  initialDelaySeconds: 10
                  periodSeconds: 30
            securityContext:
              # Measured 2026-08-19 (Task 1): a non-privileged hostPath mount
              # of /dev/gpiochip0 fails open() with EPERM on both O_RDONLY and
              # O_RDWR, while an otherwise identical privileged pod on the same
              # node succeeds. The cgroup v2 device controller is the cause and
              # capabilities do not bypass it. The parent spec's claim that this
              # could avoid privileged:true was an assumption, not a result.
              #
              # Scope is deliberately narrow: one container on four Pis running
              # a ~10MB FROM scratch image with no shell and no package manager.
              privileged: true
              allowPrivilegeEscalation: true
              readOnlyRootFilesystem: true
            resources:
              requests:
                cpu: 100m
                memory: 32Mi
              limits:
                # A deliberate throttle, not a guess. All four agents blit
                # simultaneously by design and three of these nodes run etcd.
                # I2C has no minimum clock rate, so CFS throttling makes the
                # sweep slower and cannot make it incorrect -- the same limit
                # would be reckless on SPI or WS2812.
                cpu: 500m
                memory: 64Mi
```

**Set the `tag:` to the real tag from Task 8 Step 6**, not the placeholder above.

- [ ] **Step 3: Add the agent service and the GPIO mount**

Under `service:` in `helmrelease.yaml`, add a service for the agent — app-template derives named container ports from service ports, which is what lets the PodMonitor select `port: metrics`:

```yaml
      agent:
        controller: agent
        ports:
          metrics:
            port: 8080
```

Under `persistence:`, add:

```yaml
      gpio:
        type: hostPath
        hostPath: /dev/gpiochip0
        # advancedMounts, NOT globalMounts: a global mount would put
        # /dev/gpiochip0 into the conductor pod on an amd64 node, where the
        # path does not exist.
        advancedMounts:
          agent:
            app:
              - path: /dev/gpiochip0
```

- [ ] **Step 4: Add the PodMonitor**

Create `kubernetes/apps/observability/rackpanel/app/podmonitor.yaml`:

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/monitoring.coreos.com/podmonitor_v1.json
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: rackpanel-agent
spec:
  # frame_lag_seconds is the series that answers "are the four panels
  # actually in unison?" -- four series tracking together means yes.
  selector:
    matchLabels:
      app.kubernetes.io/name: rackpanel
      app.kubernetes.io/component: agent
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      interval: 30s
```

Add `- ./podmonitor.yaml` to `kubernetes/apps/observability/rackpanel/app/kustomization.yaml`.

- [ ] **Step 5: Verify the selector labels before pushing**

The `app.kubernetes.io/component` label is app-template's convention, not a guarantee. Render and check, rather than discovering an empty target list in Prometheus later:

`helm` pulling an OCI chart on this machine needs an empty `DOCKER_CONFIG`,
otherwise it fails in the credential helper before it ever reaches the
registry:

```bash
cd ~/Repositories/flux-talos
export DOCKER_CONFIG=$(mktemp -d)
helm template rackpanel oci://ghcr.io/bjw-s-labs/helm/app-template --version 5.1.0 \
  -f <(yq 'explode(.) | .spec.values' kubernetes/apps/observability/rackpanel/app/helmrelease.yaml) \
  | yq 'select(.kind == "DaemonSet") | .spec.template.metadata.labels'
```

Expected: labels including `app.kubernetes.io/name: rackpanel` and
`app.kubernetes.io/component: agent`. If the component label differs, correct
the PodMonitor selector to match what was rendered.

> `yq explode()` is required — the HelmRelease uses YAML anchors, and
> `helm template` will not resolve them.

- [ ] **Step 6: Validate and push**

```bash
cd ~/Repositories/flux-talos
kustomize build kubernetes/apps/observability/rackpanel/app > /dev/null && echo "kustomize OK"
lefthook run pre-commit
git add kubernetes/apps/observability/rackpanel/app
git commit -m "feat(rackpanel): panel-agent DaemonSet on the four Pis

Second controller in the existing HelmRelease so conductor and agent
versions stay visible together and one image-automation path covers both.

Three things that fail silently if got wrong, so they carry comments in the
manifest: advancedMounts rather than globalMounts (a global mount would put
/dev/gpiochip0 into the amd64 conductor pod), the restated seccompProfile
(defaultPodOptionsStrategy is overwrite, not merge), and the :tag marker
suffix, which is required for a dedicated tag subfield and wrong for a
combined image scalar.

The 500m CPU limit is a deliberate throttle: all four agents blit at once by
design and three of these nodes run etcd. I2C has no minimum clock rate, so
throttling makes the sweep slower and cannot make it incorrect."
git push
```

- [ ] **Step 7: Watch it roll**

A push to `main` triggers the Flux webhook, so reconciliation is near-instant. **Do not run `flux reconcile`** — wait and verify.

```bash
kubectl -n observability rollout status daemonset/rackpanel-agent --timeout=180s
kubectl -n observability get pods -l app.kubernetes.io/component=agent -o wide
```

Expected: four pods, one per `jormungandr*`, all `1/1 Running`.

If they are `CreateContainerError` or `RunContainerError`, read the event:
```bash
kubectl -n observability describe pod -l app.kubernetes.io/component=agent | grep -A5 Events
```
`operation not permitted` on the device would mean the `privileged: true` block from Step 2 did not render — check the rendered DaemonSet rather than adding more permissions blindly.

- [ ] **Step 8: Verify on the actual hardware**

```bash
kubectl -n observability logs -l app.kubernetes.io/component=agent --tail=20 --prefix
```

Expected per pod: a `panel found` line, then repeated `blitted` lines with a
`scene`, a `seq`, `kind=full` on scene changes and `kind=diff` between them.

**Then walk to the rack and look at it.** Four panels showing four different
facets of the same scene, changing together every 20 s. That is the acceptance
criterion; no log line substitutes for it.

- [ ] **Step 9: Confirm the panels are actually in unison**

```bash
kubectl -n observability port-forward svc/thanos-query-frontend 10902:10902 &
sleep 3
curl -sG 'http://127.0.0.1:10902/api/v1/query' \
  --data-urlencode 'query=rackpanel_agent_frame_lag_seconds' | python3 -m json.tool
kill %1
```

Expected: four series, values within a few hundred milliseconds of each other.
A single outlier means that node's agent is polling late or its blit is
throttled harder than the others.

Also confirm the sweep time matches the projection:

```bash
curl -sG 'http://127.0.0.1:10902/api/v1/query' \
  --data-urlencode 'query=histogram_quantile(0.9, sum by (node, le) (rate(rackpanel_agent_blit_seconds_bucket{kind="full"}[15m])))'
```

Expected: roughly 0.8–2.4 s. The spec projects 0.83 s at 1 µs per ioctl and
1.2 s at 1.5 µs, and the 500m CPU limit may roughly double that. Materially
slower than 2.4 s means raising the CPU limit is the first dial to turn — and
turning it is safe, because I²C tolerates a slower clock.

- [ ] **Step 10: Record the measured numbers in the spec**

Edit `docs/superpowers/specs/2026-08-19-rackpanel-phase2-panel-agent-design.md`,
section **Projected throughput**. Replace the projection table with the
measured full-sweep and diff times, dated, keeping the projection alongside for
comparison. The parent spec's Phase 0 table is the format to follow.

```bash
cd ~/Repositories/flux-talos
git add docs/superpowers/specs/2026-08-19-rackpanel-phase2-panel-agent-design.md
git commit -m "docs(superpowers): measured panel-agent throughput on hardware"
```

---

## Done when

- Four `rackpanel-agent` pods `1/1 Running`, one per Pi.
- All four physical panels show the current scene and change together.
- `rackpanel_agent_frame_lag_seconds` returns four series within a few hundred ms of each other.
- The spec records the measured device-access verdict (Task 1) and the measured throughput (Task 10).
- `go test ./...` passes in CI on every push.
