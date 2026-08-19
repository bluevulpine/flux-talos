# rackpanel Phase 1 — Conductor & rackview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the rackpanel conductor — a service that gathers cluster state, selects a scene, renders four 160×80 tiles, and serves them plus a live web mirror at `rackview.${SECRET_DOMAIN}`.

**Architecture:** A single Python service. Providers poll data sources on independent intervals into a staleness-aware cache. A selector picks one scene for all four tiles from a stable cursor. Scenes render tiles with Pillow. A FastAPI app serves raw RGB565 frames (for the Phase 2 panel-agent) and PNGs (for the browser). No hardware is involved anywhere in this plan.

**Tech Stack:** Python 3.13, Pillow, FastAPI, uvicorn, httpx, pytest. Deployed via bjw-s `app-template` HelmRelease, built by Drone, tag-automated by Flux.

**Spec:** `docs/superpowers/specs/2026-08-18-rackpanel-design.md`

## Global Constraints

- **Tile geometry is exactly 160×80.** `TILE_WIDTH = 160`, `TILE_HEIGHT = 80`.
- **Output format is RGB565, high byte first**, 25,600 bytes per tile. Verified against hardware in Phase 0.
- **No coordinate transform.** `(0,0)` is the top-left physical pixel; x runs left-to-right, y top-to-bottom. Confirmed by the Phase 0 corner test.
- **A tile holds one label, one hero value, and one supporting line.** 22×8 chars at 7px, 14×4 at 11px, 10×3 at 16px. Anything needing more is two scenes.
- **Query Thanos, never Prometheus.** `http://thanos-query-frontend.observability.svc:10902`. Prometheus retains 2 days and silently truncates longer ranges.
- **Four nodes, fixed order:** `jormungandr1`, `jormungandr2`, `jormungandr3`, `jormungandr4` → tile index 0–3.
- **Never commit secrets.** All runtime config is env; anything sensitive comes from OpenBao via ExternalSecret.
- **Source lives in a separate Gitea repo** (`gitea.derekjacobs.dev/bluevulpine/rackpanel`), never in `flux-talos`. Only manifests go in `flux-talos`.
- **Python is fine for the conductor.** It is not latency-bound. (The Phase 2 panel-agent must be compiled — see the spec.)

---

### Task 1: Repo scaffold and the RGB565 framebuffer

**Files:**
- Create: `pyproject.toml`
- Create: `src/rackpanel/__init__.py`
- Create: `src/rackpanel/framebuffer.py`
- Test: `tests/test_framebuffer.py`

**Interfaces:**
- Consumes: nothing
- Produces: `TILE_WIDTH: int`, `TILE_HEIGHT: int`, `TILE_BYTES: int`, `to_rgb565(img: PIL.Image.Image) -> bytes`, `rgb565_word(r: int, g: int, b: int) -> int`

- [ ] **Step 1: Create the project skeleton**

```bash
mkdir -p src/rackpanel tests
cat > pyproject.toml <<'EOF'
[project]
name = "rackpanel"
version = "0.1.0"
requires-python = ">=3.13"
dependencies = [
    "pillow==11.3.0",
    "fastapi==0.121.2",
    "uvicorn==0.38.0",
    "httpx==0.28.1",
]

[project.optional-dependencies]
dev = ["pytest==8.4.2"]

[build-system]
requires = ["setuptools>=80"]
build-backend = "setuptools.build_meta"

[tool.setuptools.packages.find]
where = ["src"]

[tool.pytest.ini_options]
pythonpath = ["src"]
testpaths = ["tests"]
EOF
touch src/rackpanel/__init__.py
cat >> .gitignore <<'EOF'
build/
dist/
EOF
```

Pillow is pinned exactly because golden-image tests compare rendered pixels; an unpinned bump would fail every golden test at once.

- [ ] **Step 2: Write the failing test**

```python
# tests/test_framebuffer.py
import pytest
from PIL import Image

from rackpanel.framebuffer import (
    TILE_BYTES, TILE_HEIGHT, TILE_WIDTH, rgb565_word, to_rgb565,
)


def test_tile_dimensions_match_the_panel():
    assert (TILE_WIDTH, TILE_HEIGHT) == (160, 80)
    assert TILE_BYTES == 160 * 80 * 2


@pytest.mark.parametrize(
    "rgb,word",
    [
        ((0, 0, 0), 0x0000),
        ((255, 255, 255), 0xFFFF),
        ((255, 0, 0), 0xF800),
        ((0, 255, 0), 0x07E0),
        ((0, 0, 255), 0x001F),
    ],
)
def test_rgb565_word_matches_the_vendor_macro(rgb, word):
    assert rgb565_word(*rgb) == word


def test_to_rgb565_emits_high_byte_first():
    img = Image.new("RGB", (TILE_WIDTH, TILE_HEIGHT), (255, 0, 0))
    data = to_rgb565(img)
    assert len(data) == TILE_BYTES
    assert data[0] == 0xF8 and data[1] == 0x00


def test_to_rgb565_preserves_pixel_order_left_to_right_top_to_bottom():
    img = Image.new("RGB", (TILE_WIDTH, TILE_HEIGHT), (0, 0, 0))
    img.putpixel((1, 0), (255, 255, 255))   # second pixel of the first row
    data = to_rgb565(img)
    assert data[0:2] == b"\x00\x00"
    assert data[2:4] == b"\xff\xff"


def test_to_rgb565_rejects_wrong_size():
    with pytest.raises(ValueError, match="160x80"):
        to_rgb565(Image.new("RGB", (80, 160)))
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `pip install -e '.[dev]' && pytest tests/test_framebuffer.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'rackpanel.framebuffer'`

- [ ] **Step 4: Implement**

```python
# src/rackpanel/framebuffer.py
"""RGB565 conversion — the wire format the panel MCU expects.

Verified against hardware in Phase 0: high byte first, pixels in
left-to-right, top-to-bottom order, no coordinate transform.
"""
from PIL import Image

TILE_WIDTH = 160
TILE_HEIGHT = 80
TILE_BYTES = TILE_WIDTH * TILE_HEIGHT * 2


def rgb565_word(r: int, g: int, b: int) -> int:
    """Pack 8-bit RGB into a 16-bit 5-6-5 word (the vendor's ST7735_COLOR565)."""
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)


def to_rgb565(img: Image.Image) -> bytes:
    """Convert a 160x80 image to the panel's 25,600-byte wire format."""
    if img.size != (TILE_WIDTH, TILE_HEIGHT):
        raise ValueError(f"tile must be 160x80, got {img.size[0]}x{img.size[1]}")
    out = bytearray(TILE_BYTES)
    i = 0
    for r, g, b in img.convert("RGB").getdata():
        word = rgb565_word(r, g, b)
        out[i] = word >> 8
        out[i + 1] = word & 0xFF
        i += 2
    return bytes(out)
```

- [ ] **Step 5: Run tests, confirm pass**

Run: `pytest tests/test_framebuffer.py -v`
Expected: PASS (8 tests)

- [ ] **Step 6: Commit**

```bash
git add pyproject.toml src/rackpanel/ tests/test_framebuffer.py
git commit -m "feat: RGB565 framebuffer conversion for the panel wire format"
```

---

### Task 2: Palette with severity override

**Files:**
- Create: `src/rackpanel/palette.py`
- Test: `tests/test_palette.py`

**Interfaces:**
- Consumes: nothing
- Produces: `Palette` (frozen dataclass with fields `name, bg, fg, dim, accent, ok, warn, crit`, each an `(int,int,int)` RGB tuple), `DAY: Palette`, `NIGHT: Palette`, `select_palette(hour: int, severity: str | None = None) -> Palette`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_palette.py
import pytest

from rackpanel.palette import DAY, NIGHT, select_palette


def _luma(rgb):
    r, g, b = rgb
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def test_night_ground_is_darker_than_day():
    assert _luma(NIGHT.bg) < _luma(DAY.bg)


@pytest.mark.parametrize("hour", [7, 12, 18, 21])
def test_daytime_hours_use_the_day_palette(hour):
    assert select_palette(hour).name == "day"


@pytest.mark.parametrize("hour", [22, 23, 0, 3, 6])
def test_night_hours_use_the_night_palette(hour):
    assert select_palette(hour).name == "night"


def test_critical_forces_the_bright_palette_even_at_night():
    p = select_palette(hour=3, severity="critical")
    assert p.bg == DAY.bg
    assert p.accent == DAY.crit


def test_warning_at_night_keeps_the_dark_ground_but_brightens_the_accent():
    p = select_palette(hour=3, severity="warning")
    assert p.bg == NIGHT.bg                      # ground stays dark
    assert _luma(p.accent) > _luma(NIGHT.accent)  # accent reads at 2am


def test_info_severity_does_not_change_the_palette():
    assert select_palette(hour=12, severity="info") == select_palette(hour=12)


def test_hour_must_be_valid():
    with pytest.raises(ValueError):
        select_palette(24)
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `pytest tests/test_palette.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'rackpanel.palette'`

- [ ] **Step 3: Implement**

```python
# src/rackpanel/palette.py
"""Colour tokens for the two palettes, and the severity override rules.

Night mode exists for basement glare, not power: the panel backlight cannot
be dimmed or switched off, so no scheduling saves any hours (see the spec).
"""
from dataclasses import dataclass, replace

RGB = tuple[int, int, int]

NIGHT_START_HOUR = 22
NIGHT_END_HOUR = 7          # night is [22:00, 07:00)
BRIGHT_AMBER: RGB = (255, 176, 0)


@dataclass(frozen=True)
class Palette:
    name: str
    bg: RGB
    fg: RGB
    dim: RGB
    accent: RGB
    ok: RGB
    warn: RGB
    crit: RGB


# Tuned against the real panel, not a monitor. Backlight bleed puts a floor
# under "black" -- a near-black ground renders washed out and cannot be made
# darker. So contrast comes from lifting the FOREGROUND, never from lowering
# the ground: dropping the ground further only loses contrast for nothing.
# In particular NIGHT.dim must clear the bleed floor or small text vanishes.
DAY = Palette(
    name="day",
    bg=(12, 16, 22),
    fg=(245, 248, 251),
    dim=(155, 168, 182),
    accent=(64, 224, 208),
    ok=(80, 220, 120),
    warn=(255, 176, 0),
    crit=(255, 76, 76),
)

NIGHT = Palette(
    name="night",
    bg=(6, 9, 13),
    fg=(170, 180, 192),
    dim=(105, 115, 128),
    accent=(48, 150, 140),
    ok=(60, 150, 90),
    warn=(185, 130, 10),
    crit=(190, 60, 60),
)


def select_palette(hour: int, severity: str | None = None) -> Palette:
    """Pick the palette for this hour, letting alert severity override it."""
    if not 0 <= hour <= 23:
        raise ValueError(f"hour must be 0-23, got {hour}")

    # Critical outranks everything: make it bright regardless of the clock.
    if severity == "critical":
        return replace(DAY, accent=DAY.crit)

    is_night = hour >= NIGHT_START_HOUR or hour < NIGHT_END_HOUR
    base = NIGHT if is_night else DAY

    # Warning keeps the dark ground but must still read across a dark room.
    if severity == "warning":
        return replace(base, accent=BRIGHT_AMBER)

    return base
```

- [ ] **Step 4: Run tests, confirm pass**

Run: `pytest tests/test_palette.py -v`
Expected: PASS (12 tests)

- [ ] **Step 5: Commit**

```bash
git add src/rackpanel/palette.py tests/test_palette.py
git commit -m "feat: day/night palettes with alert-severity override"
```

---

### Task 3: Fonts, drawing primitives, and the golden-image harness

**Files:**
- Create: `src/rackpanel/assets/fonts/` (two vendored TTFs)
- Create: `src/rackpanel/render.py`
- Create: `tests/conftest.py`
- Test: `tests/test_render.py`

**Interfaces:**
- Consumes: `Palette` from Task 2; `TILE_WIDTH`, `TILE_HEIGHT` from Task 1
- Produces: `new_tile(palette: Palette) -> Image.Image`, `font(size: int, bold: bool = False) -> FreeTypeFont`, `draw_label(d, xy, text, palette)`, `draw_hero(d, xy, text, palette, color=None)`, `draw_bar(d, xy, w, h, frac, palette, color=None)`, `draw_sparkline(d, box, values, palette)`. Test fixture `assert_golden(img, name)`.

- [ ] **Step 1: Vendor the fonts**

Fonts must be vendored, not fetched at build time — golden tests compare pixels, so the exact font file has to be identical in CI, locally, and in the image.

Tag `version_2_37` has no `ttf/` directory in the git tree — the built TTFs
ship only as a release asset, so raw-blob URLs 404. Use the release zip:

```bash
mkdir -p src/rackpanel/assets/fonts
curl -sSL --max-time 120 -o /tmp/dejavu.zip \
  https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-2.37.zip
unzip -j -o /tmp/dejavu.zip \
  'dejavu-fonts-ttf-2.37/ttf/DejaVuSans.ttf' \
  'dejavu-fonts-ttf-2.37/ttf/DejaVuSans-Bold.ttf' \
  -d src/rackpanel/assets/fonts/
# Vendoring a font means vendoring its licence -- DejaVu is Bitstream Vera,
# which requires the licence to travel with the files.
unzip -j -o /tmp/dejavu.zip 'dejavu-fonts-ttf-2.37/LICENSE' \
  -d src/rackpanel/assets/fonts/
rm /tmp/dejavu.zip
ls -l src/rackpanel/assets/fonts/
```

Expected: `DejaVuSans.ttf` ≈ 757 KB, `DejaVuSans-Bold.ttf` ≈ 706 KB, plus
`LICENSE`. Verify both actually load before going further — a truncated file
or an HTML error page saved under a `.ttf` name fails later and confusingly:

```bash
python -c "from PIL import ImageFont as F; [F.truetype(f'src/rackpanel/assets/fonts/{n}', 11) for n in ('DejaVuSans.ttf','DejaVuSans-Bold.ttf')]; print('both fonts load')"
```

Add to `pyproject.toml` so the fonts ship inside the wheel:

```toml
[tool.setuptools.package-data]
rackpanel = ["assets/fonts/*.ttf"]
```

- [ ] **Step 2: Write the golden-image fixture**

```python
# tests/conftest.py
import warnings
from pathlib import Path

import pytest
from PIL import Image, ImageChops

GOLDEN_DIR = Path(__file__).parent / "golden"


@pytest.fixture
def assert_golden(request):
    """Compare a rendered tile against a committed reference PNG.

    Set RACKPANEL_UPDATE_GOLDEN=1 to (re)write references. On mismatch the
    actual render is written next to the reference for eyeballing -- a diff
    you can look at beats a pixel count you can't.
    """
    import os

    def _assert(img: Image.Image, name: str) -> None:
        GOLDEN_DIR.mkdir(exist_ok=True)
        ref_path = GOLDEN_DIR / f"{name}.png"
        updating = os.environ.get("RACKPANEL_UPDATE_GOLDEN") == "1"
        if updating:
            img.save(ref_path)
            # Return, do NOT pytest.skip(). skip() raises, which aborts the
            # whole test at the first call -- so a test that loops over the
            # four tiles would only ever write tile 0 and silently leave the
            # other three stale. Update mode deliberately does not assert;
            # the warning keeps that visible, and re-running without the flag
            # is what actually verifies.
            warnings.warn(
                f"golden reference written, NOT asserted: {ref_path}",
                stacklevel=2,
            )
            return
        if not ref_path.exists():
            # Fail, never auto-baseline. Silently regenerating a missing
            # reference makes the suite pass green after a golden is lost to
            # a bad merge or left uncommitted -- the exact failure this
            # harness exists to prevent.
            pytest.fail(
                f"missing golden reference: {ref_path}. If this tile is new "
                f"or intentionally changed, re-run with "
                f"RACKPANEL_UPDATE_GOLDEN=1 to create it."
            )
        ref = Image.open(ref_path).convert("RGB")
        got = img.convert("RGB")
        assert got.size == ref.size, f"size {got.size} != golden {ref.size}"
        diff = ImageChops.difference(ref, got)
        if diff.getbbox() is not None:
            actual = GOLDEN_DIR / f"{name}.actual.png"
            got.save(actual)
            changed = sum(1 for px in diff.convert("L").getdata() if px)
            pytest.fail(
                f"{name}: {changed} pixels differ from golden. "
                f"Wrote {actual} -- compare, then re-run with "
                f"RACKPANEL_UPDATE_GOLDEN=1 if the change is intended."
            )

    return _assert
```

- [ ] **Step 3: Write the failing test**

```python
# tests/test_render.py
import pytest
from PIL import Image

from rackpanel.framebuffer import TILE_HEIGHT, TILE_WIDTH
from rackpanel.palette import DAY, NIGHT
from rackpanel.render import (
    draw_bar, draw_hero, draw_label, draw_sparkline, font, new_tile,
)
from PIL import ImageDraw


def test_new_tile_is_panel_sized_and_uses_the_palette_ground():
    img = new_tile(DAY)
    assert img.size == (TILE_WIDTH, TILE_HEIGHT)
    assert img.getpixel((0, 0)) == DAY.bg


def test_font_is_cached_so_repeated_renders_do_not_reload():
    assert font(11) is font(11)
    assert font(11) is not font(12)
    assert font(11) is not font(11, bold=True)


def test_bar_fraction_is_clamped_to_the_unit_interval():
    img = new_tile(DAY)
    d = ImageDraw.Draw(img)
    draw_bar(d, (0, 0), 100, 6, 5.0, DAY)      # must not overflow the width
    assert img.getpixel((110, 3)) == DAY.bg


def test_sparkline_of_a_flat_series_draws_a_flat_line():
    img = new_tile(DAY)
    d = ImageDraw.Draw(img)
    draw_sparkline(d, (0, 0, 40, 20), [5.0] * 10, DAY)
    lit = [y for y in range(20) if img.getpixel((20, y)) != DAY.bg]
    assert len(lit) <= 2, "a flat series should not produce a tall line"


def test_sparkline_ignores_an_empty_series():
    img = new_tile(DAY)
    d = ImageDraw.Draw(img)
    draw_sparkline(d, (0, 0, 40, 20), [], DAY)
    assert img.getpixel((20, 10)) == DAY.bg


def test_full_tile_render_matches_golden(assert_golden):
    img = new_tile(DAY)
    d = ImageDraw.Draw(img)
    draw_label(d, (6, 5), "STORAGE", DAY)
    draw_hero(d, (6, 20), "92%", DAY)
    draw_bar(d, (6, 52), 148, 6, 0.92, DAY, DAY.ok)
    draw_sparkline(d, (6, 62, 148, 16), [1, 3, 2, 5, 4, 6, 5, 8], DAY)
    assert_golden(img, "render_primitives_day")


def test_night_palette_render_matches_golden(assert_golden):
    img = new_tile(NIGHT)
    d = ImageDraw.Draw(img)
    draw_label(d, (6, 5), "STORAGE", NIGHT)
    draw_hero(d, (6, 20), "92%", NIGHT)
    assert_golden(img, "render_primitives_night")
```

- [ ] **Step 4: Run it and confirm it fails**

Run: `pytest tests/test_render.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'rackpanel.render'`

- [ ] **Step 5: Implement**

```python
# src/rackpanel/render.py
"""Drawing primitives sized for a 160x80 tile.

Every helper assumes the tile budget from the spec: one label, one hero
value, one supporting line. If a scene needs more, it is two scenes.
"""
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from .framebuffer import TILE_HEIGHT, TILE_WIDTH
from .palette import RGB, Palette

FONT_DIR = Path(__file__).parent / "assets" / "fonts"

LABEL_SIZE = 11
HERO_SIZE = 30
SUPPORT_SIZE = 11


@lru_cache(maxsize=32)
def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    """Load a vendored TTF. Cached: rendering happens once a second."""
    name = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    return ImageFont.truetype(str(FONT_DIR / name), size)


def new_tile(palette: Palette) -> Image.Image:
    """A blank tile filled with the palette's ground colour."""
    return Image.new("RGB", (TILE_WIDTH, TILE_HEIGHT), palette.bg)


def draw_label(d: ImageDraw.ImageDraw, xy, text: str, palette: Palette) -> None:
    """The scene/field name. Small, accent-coloured, upper-left by convention."""
    d.text(xy, text.upper(), font=font(LABEL_SIZE, bold=True), fill=palette.accent)


def draw_hero(d, xy, text: str, palette: Palette, color: RGB | None = None) -> None:
    """The one number that matters on this tile."""
    d.text(xy, text, font=font(HERO_SIZE, bold=True), fill=color or palette.fg)


def draw_support(d, xy, text: str, palette: Palette, color: RGB | None = None) -> None:
    """The supporting line under the hero value."""
    d.text(xy, text, font=font(SUPPORT_SIZE), fill=color or palette.dim)


def draw_bar(d, xy, w: int, h: int, frac: float, palette: Palette,
             color: RGB | None = None) -> None:
    """A horizontal fill bar. `frac` is clamped, so callers cannot overflow."""
    x, y = xy
    frac = max(0.0, min(1.0, float(frac)))
    d.rectangle([x, y, x + w, y + h], fill=palette.dim)
    filled = int(w * frac)
    if filled > 0:
        d.rectangle([x, y, x + filled, y + h], fill=color or palette.accent)


def draw_sparkline(d, box, values, palette: Palette,
                   color: RGB | None = None) -> None:
    """A trend line in `box` = (x, y, w, h). Silently ignores empty series."""
    x, y, w, h = box
    vals = [float(v) for v in values]
    if len(vals) < 2:
        return
    lo, hi = min(vals), max(vals)
    span = hi - lo
    if span == 0:
        # A flat series is meaningful -- draw it flat, centred, not full-height.
        mid = y + h // 2
        d.line([(x, mid), (x + w, mid)], fill=color or palette.accent)
        return
    step = w / (len(vals) - 1)
    pts = [(x + i * step, y + h - ((v - lo) / span) * h) for i, v in enumerate(vals)]
    d.line(pts, fill=color or palette.accent, width=1)
```

- [ ] **Step 6: Generate goldens, then verify they hold**

```bash
RACKPANEL_UPDATE_GOLDEN=1 pytest tests/test_render.py -v   # writes references
pytest tests/test_render.py -v                              # all PASS
```

Expected: first run skips the two golden tests while writing PNGs; second run passes all.

- [ ] **Step 7: Eyeball the goldens**

```bash
open tests/golden/render_primitives_day.png tests/golden/render_primitives_night.png
```

Confirm the text is legible at 160×80. This is the moment to adjust `LABEL_SIZE`/`HERO_SIZE` — after this, changing them invalidates every golden in the repo.

**Judge on the panel, not the monitor.** Phase 0 confirmed 11 px support text is legible on the real hardware, and that the backlight bleed makes dark grounds render washed out rather than black. A tile that looks crisp on a laptop can lose its `dim` text entirely on the panel. If in doubt, raise `dim`, never lower `bg`.

- [ ] **Step 8: Commit**

```bash
git add src/rackpanel/render.py src/rackpanel/assets tests/conftest.py \
        tests/test_render.py tests/golden pyproject.toml
git commit -m "feat: tile drawing primitives with golden-image tests"
```

---

### Task 4: Provider protocol, staleness cache, and the clock provider

**Files:**
- Create: `src/rackpanel/providers/__init__.py`
- Create: `src/rackpanel/providers/clock.py`
- Test: `tests/test_providers.py`

**Interfaces:**
- Consumes: nothing
- Produces: `Reading` (frozen dataclass: `data: dict`, `fetched_at: float`, `age: float`, `stale: bool`, `error: str | None`), `Provider` protocol (`name: str`, `interval: float`, `fetch() -> dict`), `ProviderCache(providers, now=time.monotonic)` with `.tick()` and `.get(name) -> Reading` and `.all() -> dict[str, Reading]`, `ClockProvider(tz: str)`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_providers.py
import pytest

from rackpanel.providers import ProviderCache, Reading
from rackpanel.providers.clock import ClockProvider


class FakeProvider:
    name = "fake"
    interval = 10.0

    def __init__(self):
        self.calls = 0
        self.value = {"n": 0}
        self.explode = False

    def fetch(self):
        self.calls += 1
        if self.explode:
            raise RuntimeError("boom")
        return dict(self.value)


class FakeClock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def test_first_tick_fetches_every_provider():
    p, clk = FakeProvider(), FakeClock()
    cache = ProviderCache([p], now=clk)
    cache.tick()
    assert p.calls == 1
    assert cache.get("fake").data == {"n": 0}


def test_provider_is_not_refetched_before_its_interval():
    p, clk = FakeProvider(), FakeClock()
    cache = ProviderCache([p], now=clk)
    cache.tick()
    clk.t += 5.0
    cache.tick()
    assert p.calls == 1


def test_provider_refetches_once_its_interval_elapses():
    p, clk = FakeProvider(), FakeClock()
    cache = ProviderCache([p], now=clk)
    cache.tick()
    clk.t += 10.0
    p.value = {"n": 1}
    cache.tick()
    assert p.calls == 2
    assert cache.get("fake").data == {"n": 1}


def test_a_failing_fetch_keeps_the_last_good_value_and_records_the_error():
    """The governing rule: never blank a tile, never show a stack trace."""
    p, clk = FakeProvider(), FakeClock()
    cache = ProviderCache([p], now=clk)
    cache.tick()
    clk.t += 10.0
    p.explode = True
    cache.tick()
    r = cache.get("fake")
    assert r.data == {"n": 0}          # last good value survives
    assert r.error == "boom"
    assert r.stale is True


def test_reading_is_stale_once_it_exceeds_three_intervals():
    p, clk = FakeProvider(), FakeClock()
    cache = ProviderCache([p], now=clk)
    cache.tick()
    assert cache.get("fake").stale is False
    clk.t += 31.0
    assert cache.get("fake").stale is True


def test_unknown_provider_returns_an_empty_errored_reading_not_a_keyerror():
    cache = ProviderCache([], now=FakeClock())
    r = cache.get("nope")
    assert r.data == {} and r.error is not None and r.stale is True


def test_clock_provider_reports_hour_and_formatted_time():
    data = ClockProvider(tz="UTC").fetch()
    assert 0 <= data["hour"] <= 23
    assert len(data["time"]) == 5 and data["time"][2] == ":"
    assert data["date"]
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `pytest tests/test_providers.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'rackpanel.providers'`

- [ ] **Step 3: Implement the cache**

```python
# src/rackpanel/providers/__init__.py
"""Provider plumbing.

A provider is anything with a name, a poll interval, and a fetch(). The
cache polls each on its own schedule and never lets a failure destroy the
last good value -- a tile shows stale data with a marker, never a blank.
"""
import time
from dataclasses import dataclass, field
from typing import Callable, Protocol, runtime_checkable

STALE_AFTER_INTERVALS = 3


@dataclass(frozen=True)
class Reading:
    data: dict
    fetched_at: float
    age: float
    stale: bool
    error: str | None = None


@runtime_checkable
class Provider(Protocol):
    name: str
    interval: float

    def fetch(self) -> dict: ...


@dataclass
class _Entry:
    provider: Provider
    data: dict = field(default_factory=dict)
    fetched_at: float | None = None
    last_attempt: float | None = None
    error: str | None = None


class ProviderCache:
    """Polls providers on independent intervals; serves the newest good value."""

    def __init__(self, providers, now: Callable[[], float] = time.monotonic):
        self._now = now
        self._entries = {p.name: _Entry(provider=p) for p in providers}

    def tick(self) -> None:
        """Fetch every provider whose interval has elapsed. Never raises."""
        t = self._now()
        for entry in self._entries.values():
            due = entry.last_attempt is None or (
                t - entry.last_attempt >= entry.provider.interval
            )
            if not due:
                continue
            entry.last_attempt = t
            try:
                entry.data = entry.provider.fetch()
                entry.fetched_at = t
                entry.error = None
            except Exception as exc:  # noqa: BLE001 -- a provider must not kill the loop
                entry.error = str(exc)

    def get(self, name: str) -> Reading:
        entry = self._entries.get(name)
        if entry is None:
            return Reading({}, 0.0, float("inf"), True, f"no provider named {name!r}")
        if entry.fetched_at is None:
            return Reading({}, 0.0, float("inf"), True, entry.error or "never fetched")
        age = self._now() - entry.fetched_at
        stale = age > entry.provider.interval * STALE_AFTER_INTERVALS
        return Reading(entry.data, entry.fetched_at, age,
                       stale or entry.error is not None, entry.error)

    def all(self) -> dict[str, Reading]:
        return {name: self.get(name) for name in self._entries}
```

- [ ] **Step 4: Implement the clock provider**

```python
# src/rackpanel/providers/clock.py
"""Wall clock. Cheap, always valid, and drives night-mode palette selection."""
from datetime import datetime
from zoneinfo import ZoneInfo


class ClockProvider:
    name = "clock"
    interval = 1.0

    def __init__(self, tz: str = "UTC"):
        self._tz = ZoneInfo(tz)

    def fetch(self) -> dict:
        now = datetime.now(self._tz)
        return {
            "hour": now.hour,
            "time": now.strftime("%H:%M"),
            "date": now.strftime("%a %d %b"),
            "iso": now.isoformat(),
        }
```

- [ ] **Step 5: Run tests, confirm pass**

Run: `pytest tests/test_providers.py -v`
Expected: PASS (7 tests)

- [ ] **Step 6: Commit**

```bash
git add src/rackpanel/providers tests/test_providers.py
git commit -m "feat: provider protocol, staleness cache, clock provider"
```

---

### Task 5: Kubernetes API client and the node provider

**Files:**
- Create: `src/rackpanel/k8s.py`
- Create: `src/rackpanel/providers/kube.py`
- Test: `tests/test_k8s.py`
- Test: `tests/test_provider_kube.py`

**Interfaces:**
- Consumes: `Provider` protocol from Task 4
- Produces: `KubeClient(host, token, ca_path, client=None)` with `.get(path: str) -> dict` and classmethod `.in_cluster()`; `KubeProvider(client)` producing `{"nodes": [{"name","ready","roles","arch"}], "ready": int, "total": int}`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_k8s.py
import httpx
import pytest

from rackpanel.k8s import KubeClient


def _client_with(handler):
    transport = httpx.MockTransport(handler)
    return KubeClient(
        host="https://kubernetes.default.svc",
        token="tok",
        ca_path=None,
        client=httpx.Client(transport=transport),
    )


def test_get_sends_the_bearer_token():
    seen = {}

    def handler(request):
        seen["auth"] = request.headers.get("authorization")
        return httpx.Response(200, json={"ok": True})

    assert _client_with(handler).get("/api/v1/nodes") == {"ok": True}
    assert seen["auth"] == "Bearer tok"


def test_non_2xx_raises_with_the_status_visible():
    def handler(request):
        return httpx.Response(403, json={"message": "forbidden"})

    with pytest.raises(RuntimeError, match="403"):
        _client_with(handler).get("/api/v1/nodes")
```

```python
# tests/test_provider_kube.py
import httpx

from rackpanel.k8s import KubeClient
from rackpanel.providers.kube import KubeProvider

NODE_LIST = {
    "items": [
        {
            "metadata": {"name": "jormungandr1",
                         "labels": {"node-role.kubernetes.io/control-plane": ""}},
            "status": {"conditions": [{"type": "Ready", "status": "True"}],
                       "nodeInfo": {"architecture": "arm64"}},
        },
        {
            "metadata": {"name": "brokkr01", "labels": {}},
            "status": {"conditions": [{"type": "Ready", "status": "False"}],
                       "nodeInfo": {"architecture": "amd64"}},
        },
    ]
}


def _provider():
    def handler(request):
        return httpx.Response(200, json=NODE_LIST)

    client = KubeClient("https://k", "t", None,
                        client=httpx.Client(transport=httpx.MockTransport(handler)))
    return KubeProvider(client)


def test_counts_ready_nodes():
    data = _provider().fetch()
    assert data["ready"] == 1
    assert data["total"] == 2


def test_extracts_role_and_arch_per_node():
    nodes = {n["name"]: n for n in _provider().fetch()["nodes"]}
    assert nodes["jormungandr1"]["control_plane"] is True
    assert nodes["jormungandr1"]["arch"] == "arm64"
    assert nodes["brokkr01"]["control_plane"] is False
    assert nodes["brokkr01"]["ready"] is False
```

- [ ] **Step 2: Run and confirm failure**

Run: `pytest tests/test_k8s.py tests/test_provider_kube.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'rackpanel.k8s'`

- [ ] **Step 3: Implement the client**

```python
# src/rackpanel/k8s.py
"""Minimal in-cluster Kubernetes API client.

Deliberately httpx rather than the official client library: we make a
handful of read-only GETs, and one HTTP client shared with the Thanos and
Alertmanager providers is less to reason about than a second SDK.
"""
import os

import httpx

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"


class KubeClient:
    def __init__(self, host: str, token: str, ca_path: str | None,
                 client: httpx.Client | None = None, timeout: float = 5.0):
        self._host = host.rstrip("/")
        self._token = token
        self._client = client or httpx.Client(
            verify=ca_path if ca_path else True, timeout=timeout
        )

    @classmethod
    def in_cluster(cls) -> "KubeClient":
        host = os.environ["KUBERNETES_SERVICE_HOST"]
        port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
        with open(f"{SA_DIR}/token") as fh:
            token = fh.read().strip()
        return cls(f"https://{host}:{port}", token, f"{SA_DIR}/ca.crt")

    def get(self, path: str) -> dict:
        resp = self._client.get(
            f"{self._host}{path}",
            headers={"Authorization": f"Bearer {self._token}"},
        )
        if resp.status_code // 100 != 2:
            raise RuntimeError(f"{path} -> HTTP {resp.status_code}")
        return resp.json()
```

- [ ] **Step 4: Implement the node provider**

```python
# src/rackpanel/providers/kube.py
"""Node inventory from the Kubernetes API."""
from ..k8s import KubeClient

CONTROL_PLANE_LABEL = "node-role.kubernetes.io/control-plane"


class KubeProvider:
    name = "kube"
    interval = 30.0

    def __init__(self, client: KubeClient):
        self._client = client

    def fetch(self) -> dict:
        payload = self._client.get("/api/v1/nodes")
        nodes = []
        for item in payload.get("items", []):
            meta = item.get("metadata", {})
            status = item.get("status", {})
            ready = any(
                c.get("type") == "Ready" and c.get("status") == "True"
                for c in status.get("conditions", [])
            )
            nodes.append({
                "name": meta.get("name", "?"),
                "ready": ready,
                "control_plane": CONTROL_PLANE_LABEL in (meta.get("labels") or {}),
                "arch": status.get("nodeInfo", {}).get("architecture", "?"),
            })
        nodes.sort(key=lambda n: n["name"])
        return {
            "nodes": nodes,
            "ready": sum(1 for n in nodes if n["ready"]),
            "total": len(nodes),
        }
```

- [ ] **Step 5: Run tests, confirm pass**

Run: `pytest tests/test_k8s.py tests/test_provider_kube.py -v`
Expected: PASS (6 tests)

- [ ] **Step 6: Commit**

```bash
git add src/rackpanel/k8s.py src/rackpanel/providers/kube.py \
        tests/test_k8s.py tests/test_provider_kube.py
git commit -m "feat: in-cluster Kubernetes client and node provider"
```

---

### Task 6: Thanos provider

**Files:**
- Create: `src/rackpanel/providers/thanos.py`
- Test: `tests/test_provider_thanos.py`

**Interfaces:**
- Consumes: `Provider` protocol from Task 4
- Produces: `ThanosProvider(base_url, queries: dict[str, str], client=None)` producing `{"<key>": float | None, ...}` plus `{"_errors": list[str]}`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_provider_thanos.py
import httpx

from rackpanel.providers.thanos import ThanosProvider


def _provider(handler, queries=None):
    return ThanosProvider(
        "http://thanos:10902",
        queries or {"cpu": "sum(rate(x[5m]))"},
        client=httpx.Client(transport=httpx.MockTransport(handler)),
    )


def test_extracts_the_scalar_from_a_vector_result():
    def handler(request):
        return httpx.Response(200, json={
            "status": "success",
            "data": {"resultType": "vector",
                     "result": [{"metric": {}, "value": [1700000000, "3.5"]}]},
        })

    assert _provider(handler).fetch()["cpu"] == 3.5


def test_empty_result_yields_none_rather_than_raising():
    """An empty vector is a legitimate answer -- the tile shows a dash."""
    def handler(request):
        return httpx.Response(200, json={
            "status": "success",
            "data": {"resultType": "vector", "result": []},
        })

    assert _provider(handler).fetch()["cpu"] is None


def test_one_failing_query_does_not_lose_the_others():
    def handler(request):
        if "bad" in request.url.params.get("query", ""):
            return httpx.Response(422, json={"error": "parse error"})
        return httpx.Response(200, json={
            "status": "success",
            "data": {"resultType": "vector",
                     "result": [{"metric": {}, "value": [0, "1"]}]},
        })

    data = _provider(handler, {"good": "up", "bad": "bad{"}).fetch()
    assert data["good"] == 1.0
    assert data["bad"] is None
    assert any("bad" in e for e in data["_errors"])


def test_queries_hit_the_query_endpoint():
    seen = {}

    def handler(request):
        seen["path"] = request.url.path
        seen["query"] = request.url.params.get("query")
        return httpx.Response(200, json={
            "status": "success", "data": {"resultType": "vector", "result": []}})

    _provider(handler).fetch()
    assert seen["path"] == "/api/v1/query"
    assert seen["query"] == "sum(rate(x[5m]))"
```

- [ ] **Step 2: Run and confirm failure**

Run: `pytest tests/test_provider_thanos.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'rackpanel.providers.thanos'`

- [ ] **Step 3: Implement**

```python
# src/rackpanel/providers/thanos.py
"""PromQL against Thanos.

Thanos, never Prometheus: Prometheus retains 2 days and truncates longer
ranges silently, which reads as "we don't collect that" rather than an error.
"""
import httpx

DEFAULT_TIMEOUT = 8.0


class ThanosProvider:
    name = "thanos"
    interval = 15.0

    def __init__(self, base_url: str, queries: dict[str, str],
                 client: httpx.Client | None = None):
        self._base = base_url.rstrip("/")
        self._queries = dict(queries)
        self._client = client or httpx.Client(timeout=DEFAULT_TIMEOUT)

    def fetch(self) -> dict:
        out: dict = {"_errors": []}
        for key, promql in self._queries.items():
            try:
                out[key] = self._scalar(promql)
            except Exception as exc:  # noqa: BLE001 -- one bad query must not
                out[key] = None       # lose the other tiles' data
                out["_errors"].append(f"{key}: {exc}")
        return out

    def _scalar(self, promql: str) -> float | None:
        resp = self._client.get(f"{self._base}/api/v1/query",
                                params={"query": promql})
        if resp.status_code // 100 != 2:
            raise RuntimeError(f"HTTP {resp.status_code}")
        body = resp.json()
        result = body.get("data", {}).get("result", [])
        if not result:
            return None
        return float(result[0]["value"][1])
```

- [ ] **Step 4: Run tests, confirm pass**

Run: `pytest tests/test_provider_thanos.py -v`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add src/rackpanel/providers/thanos.py tests/test_provider_thanos.py
git commit -m "feat: Thanos PromQL provider with per-query failure isolation"
```

---

### Task 7: Scene protocol and the selector

**Files:**
- Create: `src/rackpanel/scenes/__init__.py`
- Create: `src/rackpanel/selector.py`
- Test: `tests/test_selector.py`

**Interfaces:**
- Consumes: `Reading` from Task 4, `Palette` from Task 2
- Produces: `SceneContext` (frozen dataclass: `readings: dict[str, Reading]`, `palette: Palette`), `Scene` protocol (`key: str`, `order: int`, `eligible(ctx) -> bool`, `render_tile(index: int, ctx) -> Image.Image`), `SceneSelector(scenes, dwell=20.0)` with `.select(now: float, ctx) -> Scene`

**Design note — a deliberate refinement of the spec.** The spec specifies `eligible[floor(unix/dwell) % len(eligible)]`. That formula re-indexes whenever the eligible set changes, which makes the rotation appear to skip. This task implements a **monotonic cursor over a stable full ordering, skipping ineligible scenes**, which satisfies the spec's stated requirements (stable ordering; newly-eligible shows next) without the modulo jump. This is safe because the conductor is the single decider — the four tiles come from one render pass, so cross-node determinism is not needed.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_selector.py
from PIL import Image

from rackpanel.palette import DAY
from rackpanel.scenes import SceneContext
from rackpanel.selector import SceneSelector


class FakeScene:
    def __init__(self, key, order, eligible=True):
        self.key, self.order, self._eligible = key, order, eligible

    def eligible(self, ctx):
        return self._eligible

    def render_tile(self, index, ctx):
        return Image.new("RGB", (160, 80))


def ctx():
    return SceneContext(readings={}, palette=DAY)


def test_holds_one_scene_for_the_whole_dwell():
    s = SceneSelector([FakeScene("a", 0), FakeScene("b", 1)], dwell=20.0)
    assert s.select(0.0, ctx()).key == s.select(19.9, ctx()).key


def test_advances_to_the_next_scene_after_the_dwell():
    s = SceneSelector([FakeScene("a", 0), FakeScene("b", 1)], dwell=20.0)
    first = s.select(0.0, ctx()).key
    assert s.select(20.0, ctx()).key != first


def test_rotation_is_stable_and_visits_every_scene():
    s = SceneSelector([FakeScene(k, i) for i, k in enumerate("abc")], dwell=10.0)
    seen = [s.select(t * 10.0, ctx()).key for t in range(3)]
    assert sorted(seen) == ["a", "b", "c"]


def test_ineligible_scenes_are_skipped_not_shown_blank():
    b = FakeScene("b", 1, eligible=False)
    s = SceneSelector([FakeScene("a", 0), b, FakeScene("c", 2)], dwell=10.0)
    seen = {s.select(t * 10.0, ctx()).key for t in range(6)}
    assert "b" not in seen


def test_a_newly_eligible_scene_is_shown_next_not_slotted_by_index():
    """The spec's explicit requirement -- an alert must not wait a full cycle."""
    alert = FakeScene("alert", 99, eligible=False)
    s = SceneSelector([FakeScene(k, i) for i, k in enumerate("abc")] + [alert],
                      dwell=10.0)
    for t in range(3):
        s.select(t * 10.0, ctx())
    alert._eligible = True
    assert s.select(30.0, ctx()).key == "alert"


def test_a_scene_becoming_ineligible_does_not_shift_the_others():
    """The modulo-jump bug: removing a scene must not skip an unrelated one."""
    c = FakeScene("c", 2)
    s = SceneSelector([FakeScene("a", 0), FakeScene("b", 1), c, FakeScene("d", 3)],
                      dwell=10.0)
    assert s.select(0.0, ctx()).key == "a"
    assert s.select(10.0, ctx()).key == "b"
    c._eligible = False
    assert s.select(20.0, ctx()).key == "d"   # skips c, does not jump past d


def test_no_eligible_scenes_returns_none():
    s = SceneSelector([FakeScene("a", 0, eligible=False)], dwell=10.0)
    assert s.select(0.0, ctx()) is None
```

- [ ] **Step 2: Run and confirm failure**

Run: `pytest tests/test_selector.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'rackpanel.scenes'`

- [ ] **Step 3: Implement the scene protocol**

```python
# src/rackpanel/scenes/__init__.py
"""Scene protocol.

All four panels show facets of the SAME scene, then change topic together.
A scene renders tile 0-3; index 0 is jormungandr1.
"""
from dataclasses import dataclass
from typing import Protocol, runtime_checkable

from PIL import Image

from ..palette import Palette
from ..providers import Reading

TILES_PER_SCENE = 4


@dataclass(frozen=True)
class SceneContext:
    readings: dict[str, Reading]
    palette: Palette

    def data(self, provider: str) -> dict:
        r = self.readings.get(provider)
        return r.data if r else {}

    def is_stale(self, provider: str) -> bool:
        r = self.readings.get(provider)
        return True if r is None else r.stale


@runtime_checkable
class Scene(Protocol):
    key: str
    order: int

    def eligible(self, ctx: SceneContext) -> bool: ...

    def render_tile(self, index: int, ctx: SceneContext) -> Image.Image: ...
```

- [ ] **Step 4: Implement the selector**

```python
# src/rackpanel/selector.py
"""Scene rotation.

A monotonic cursor over a stable ordering, skipping ineligible scenes. This
avoids the modulo re-indexing that would make the rotation appear to skip
whenever a conditional scene appears or disappears.
"""
from .scenes import Scene, SceneContext

DEFAULT_DWELL_SECONDS = 20.0


class SceneSelector:
    def __init__(self, scenes, dwell: float = DEFAULT_DWELL_SECONDS):
        self._scenes = sorted(scenes, key=lambda s: (s.order, s.key))
        self._by_key = {s.key: s for s in self._scenes}
        self._dwell = dwell
        self._cursor = -1
        self._epoch: int | None = None
        self._current: str | None = None
        self._known_eligible: set[str] = set()
        self._pending: list[str] = []

    def select(self, now: float, ctx: SceneContext) -> Scene | None:
        eligible = {s.key for s in self._scenes if s.eligible(ctx)}

        # A scene that just became eligible jumps the queue -- an alert must
        # not wait a full cycle to appear.
        # Sort by (order, key) -- the SAME ordering as self._scenes. Sorting
        # by raw key would make cold boot and simultaneous alerts drain
        # alphabetically, so a high-priority scene could appear a full dwell
        # after a lower-priority one.
        for key in sorted(
            eligible - self._known_eligible,
            key=lambda k: (self._by_key[k].order, k),
        ):
            if key not in self._pending:
                self._pending.append(key)
        self._known_eligible = eligible

        if not eligible:
            self._current = None
            return None

        epoch = int(now // self._dwell)
        if epoch == self._epoch and self._current in eligible:
            return self._by_key[self._current]
        self._epoch = epoch

        while self._pending:
            key = self._pending.pop(0)
            if key in eligible:
                self._cursor = self._scenes.index(self._by_key[key])
                self._current = key
                return self._by_key[key]

        for _ in range(len(self._scenes)):
            self._cursor = (self._cursor + 1) % len(self._scenes)
            scene = self._scenes[self._cursor]
            if scene.key in eligible:
                self._current = scene.key
                return scene
        return None
```

- [ ] **Step 5: Run tests, confirm pass**

Run: `pytest tests/test_selector.py -v`
Expected: PASS (7 tests)

- [ ] **Step 6: Commit**

```bash
git add src/rackpanel/scenes/__init__.py src/rackpanel/selector.py \
        tests/test_selector.py
git commit -m "feat: scene protocol and cursor-based selector with no index jump"
```

---

### Task 8: IDENTITY and CLOCK scenes

**Files:**
- Create: `src/rackpanel/scenes/identity.py`
- Create: `src/rackpanel/scenes/clock.py`
- Test: `tests/test_scenes_basic.py`

**Interfaces:**
- Consumes: `Scene`, `SceneContext` (Task 7); `new_tile`, `draw_label`, `draw_hero`, `draw_support` (Task 3); `ClockProvider` data shape (Task 4); `KubeProvider` data shape (Task 5)
- Produces: `IdentityScene(cluster_name, talos_version, k8s_version)`, `ClockScene()`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_scenes_basic.py
import pytest

from rackpanel.palette import DAY, NIGHT
from rackpanel.providers import Reading
from rackpanel.scenes import SceneContext
from rackpanel.scenes.clock import ClockScene
from rackpanel.scenes.identity import IdentityScene


def reading(data, stale=False):
    return Reading(data, 0.0, 0.0, stale, None)


def ctx(palette=DAY, **readings):
    return SceneContext(readings={k: reading(v) for k, v in readings.items()},
                        palette=palette)


def test_identity_is_always_eligible():
    """Base scenes keep the rotation alive on a quiet day."""
    s = IdentityScene("home-kubernetes", "v1.13.6", "v1.36.2")
    assert s.eligible(ctx()) is True


def test_identity_renders_all_four_tiles_at_panel_size():
    s = IdentityScene("home-kubernetes", "v1.13.6", "v1.36.2")
    c = ctx(kube={"ready": 7, "total": 7})
    for i in range(4):
        assert s.render_tile(i, c).size == (160, 80)


def test_identity_rejects_an_out_of_range_tile_index():
    s = IdentityScene("home-kubernetes", "v1.13.6", "v1.36.2")
    with pytest.raises(IndexError):
        s.render_tile(4, ctx())


def test_clock_scene_renders_the_time_from_the_clock_provider(assert_golden):
    c = ctx(clock={"hour": 14, "time": "14:32", "date": "Mon 18 Aug",
                   "iso": "2026-08-18T14:32:00"})
    assert_golden(ClockScene().render_tile(0, c), "scene_clock_tile0")


def test_identity_tiles_match_golden(assert_golden):
    s = IdentityScene("home-kubernetes", "v1.13.6", "v1.36.2")
    c = ctx(kube={"ready": 7, "total": 7})
    for i in range(4):
        assert_golden(s.render_tile(i, c), f"scene_identity_tile{i}")


def test_night_palette_produces_a_darker_identity_tile():
    s = IdentityScene("home-kubernetes", "v1.13.6", "v1.36.2")
    day = s.render_tile(0, ctx(DAY, kube={"ready": 7, "total": 7}))
    night = s.render_tile(0, ctx(NIGHT, kube={"ready": 7, "total": 7}))
    assert night.getpixel((0, 0)) == NIGHT.bg
    assert day.getpixel((0, 0)) == DAY.bg
```

- [ ] **Step 2: Run and confirm failure**

Run: `pytest tests/test_scenes_basic.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'rackpanel.scenes.identity'`

- [ ] **Step 3: Implement IDENTITY**

```python
# src/rackpanel/scenes/identity.py
"""The title card the rotation returns to. Always eligible, always valid."""
from PIL import Image, ImageDraw

from ..render import draw_hero, draw_label, draw_support, new_tile
from . import TILES_PER_SCENE, SceneContext

NODE_NAMES = ["jormungandr1", "jormungandr2", "jormungandr3", "jormungandr4"]


class IdentityScene:
    key = "IDENTITY"
    order = 10

    def __init__(self, cluster_name: str, talos_version: str, k8s_version: str):
        self._cluster = cluster_name
        self._talos = talos_version
        self._k8s = k8s_version

    def eligible(self, ctx: SceneContext) -> bool:
        return True

    def render_tile(self, index: int, ctx: SceneContext) -> Image.Image:
        if not 0 <= index < TILES_PER_SCENE:
            raise IndexError(f"tile index must be 0-{TILES_PER_SCENE - 1}")
        p = ctx.palette
        img = new_tile(p)
        d = ImageDraw.Draw(img)
        kube = ctx.data("kube")

        if index == 0:
            draw_label(d, (6, 5), "CLUSTER", p)
            draw_support(d, (6, 26), self._cluster, p, p.fg)
            draw_support(d, (6, 44), "gitops · flux", p)
        elif index == 1:
            draw_label(d, (6, 5), "TALOS", p)
            draw_hero(d, (6, 22), self._talos.lstrip("v"), p)
        elif index == 2:
            draw_label(d, (6, 5), "KUBERNETES", p)
            draw_hero(d, (6, 22), self._k8s.lstrip("v"), p)
        else:
            ready, total = kube.get("ready"), kube.get("total")
            draw_label(d, (6, 5), "NODES", p)
            if total:
                colour = p.ok if ready == total else p.warn
                draw_hero(d, (6, 22), f"{ready}/{total}", p, colour)
            else:
                draw_hero(d, (6, 22), "--", p, p.dim)
            draw_support(d, (6, 60), NODE_NAMES[index], p)
        return img
```

- [ ] **Step 4: Implement CLOCK**

```python
# src/rackpanel/scenes/clock.py
"""Big time. Genuinely useful in a basement, and free to compute."""
from PIL import Image, ImageDraw

from ..render import draw_hero, draw_label, draw_support, new_tile
from . import TILES_PER_SCENE, SceneContext

TILE_LABELS = ["TIME", "DATE", "CLUSTER", "RACK"]


class ClockScene:
    key = "CLOCK"
    order = 20

    def eligible(self, ctx: SceneContext) -> bool:
        return bool(ctx.data("clock"))

    def render_tile(self, index: int, ctx: SceneContext) -> Image.Image:
        if not 0 <= index < TILES_PER_SCENE:
            raise IndexError(f"tile index must be 0-{TILES_PER_SCENE - 1}")
        p = ctx.palette
        img = new_tile(p)
        d = ImageDraw.Draw(img)
        clock = ctx.data("clock")
        kube = ctx.data("kube")

        draw_label(d, (6, 5), TILE_LABELS[index], p)
        if index == 0:
            draw_hero(d, (6, 24), clock.get("time", "--:--"), p)
        elif index == 1:
            draw_support(d, (6, 30), clock.get("date", "----"), p, p.fg)
        elif index == 2:
            ready, total = kube.get("ready"), kube.get("total")
            text = f"{ready}/{total}" if total else "--"
            draw_hero(d, (6, 24), text, p,
                      p.ok if total and ready == total else p.dim)
        else:
            draw_support(d, (6, 30), "4 pi · 3 amd64", p, p.fg)
        return img
```

- [ ] **Step 5: Generate and verify goldens**

```bash
RACKPANEL_UPDATE_GOLDEN=1 pytest tests/test_scenes_basic.py -v
pytest tests/test_scenes_basic.py -v
open tests/golden/scene_identity_tile0.png
```

Expected: second run PASS (10 tests). Eyeball at least one tile.

- [ ] **Step 6: Commit**

```bash
git add src/rackpanel/scenes/identity.py src/rackpanel/scenes/clock.py \
        tests/test_scenes_basic.py tests/golden
git commit -m "feat: IDENTITY and CLOCK scenes"
```

---

### Task 9: FLEET scene

**Files:**
- Create: `src/rackpanel/scenes/fleet.py`
- Create: `src/rackpanel/queries.py`
- Test: `tests/test_scene_fleet.py`

**Interfaces:**
- Consumes: `Scene`/`SceneContext` (Task 7), render primitives (Task 3), `KubeProvider` and `ThanosProvider` data shapes (Tasks 5–6)
- Produces: `FleetScene()`, `FLEET_QUERIES: dict[str, str]`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_scene_fleet.py
from rackpanel.palette import DAY
from rackpanel.providers import Reading
from rackpanel.queries import FLEET_QUERIES
from rackpanel.scenes import SceneContext
from rackpanel.scenes.fleet import FleetScene

KUBE = {
    "nodes": [
        {"name": "brokkr01", "ready": True, "control_plane": False, "arch": "amd64"},
        {"name": "jormungandr1", "ready": True, "control_plane": True, "arch": "arm64"},
    ],
    "ready": 2, "total": 2,
}
THANOS = {"cpu_pct": 34.2, "mem_pct": 61.0, "temp_max": 52.0, "_errors": []}


def ctx(kube=KUBE, thanos=THANOS, stale=False):
    return SceneContext(
        readings={"kube": Reading(kube, 0, 0, stale, None),
                  "thanos": Reading(thanos, 0, 0, stale, None)},
        palette=DAY,
    )


def test_fleet_needs_node_data_to_be_eligible():
    assert FleetScene().eligible(ctx()) is True
    assert FleetScene().eligible(ctx(kube={})) is False


def test_every_query_is_a_non_empty_string():
    assert FLEET_QUERIES
    assert all(isinstance(q, str) and q.strip() for q in FLEET_QUERIES.values())


def test_renders_four_panel_sized_tiles():
    s, c = FleetScene(), ctx()
    for i in range(4):
        assert s.render_tile(i, c).size == (160, 80)


def test_missing_metric_renders_a_dash_not_a_crash():
    """A provider failure must never blank a tile."""
    img = FleetScene().render_tile(1, ctx(thanos={"_errors": []}))
    assert img.size == (160, 80)


def test_stale_data_still_renders(assert_golden):
    img = FleetScene().render_tile(0, ctx(stale=True))
    assert img.size == (160, 80)


def test_fleet_tiles_match_golden(assert_golden):
    s, c = FleetScene(), ctx()
    for i in range(4):
        assert_golden(s.render_tile(i, c), f"scene_fleet_tile{i}")
```

- [ ] **Step 2: Run and confirm failure**

Run: `pytest tests/test_scene_fleet.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'rackpanel.queries'`

- [ ] **Step 3: Implement the query catalogue**

```python
# src/rackpanel/queries.py
"""PromQL for the scenes. Kept in one place so they can be reviewed together.

Every query below was validated against live Thanos data, because a query
that is wrong-but-plausible is worse than one that errors -- it puts a
confident, incorrect number on a wall display forever.

CLUSTER_ONLY exists because `job="node-exporter"` also scrapes two machines
that are NOT cluster nodes (`chronos`, `pinas`). Without the filter, "cluster
CPU" silently included a NAS.
"""

# The seven cluster nodes all expose node-exporter on :9100 at 10.0.10.x.
# The non-cluster targets have bare hostnames, so this pattern excludes them.
CLUSTER_ONLY = r'instance=~"10\.0\.10\..*:9100"'

FLEET_QUERIES: dict[str, str] = {
    # Weighting note: avg() over every (node, core) series is capacity-weighted,
    # not node-weighted. The 3 amd64 workers have 16 cores each against the
    # Pis' 4, so they carry ~75% of this number. That is the correct reading of
    # "what fraction of cluster compute is busy" -- but it does mean a maxed-out
    # Pi barely moves it. Deliberate; do not "fix" it to avg by(instance)
    # without deciding which question the tile is answering.
    "cpu_pct": (
        "100 * (1 - avg(rate(node_cpu_seconds_total{"
        f'mode="idle",{CLUSTER_ONLY}' "}[5m])))"
    ),
    "mem_pct": (
        f"100 * (1 - sum(node_memory_MemAvailable_bytes{{{CLUSTER_ONLY}}}) "
        f"/ sum(node_memory_MemTotal_bytes{{{CLUSTER_ONLY}}}))"
    ),
    # chip!~".*nvme.*" is load-bearing. Unfiltered, this returned 81.85C from
    # an NVMe SSD while the hottest CPU was 81.8C -- nearly identical, so the
    # wrong value looked entirely correct. What remains is real CPU silicon:
    # thermal_thermal_zone0 on the Pis, k10temp (pci...18_3) on the amd64 nodes.
    "temp_max": (
        f'max(node_hwmon_temp_celsius{{{CLUSTER_ONLY},chip!~".*nvme.*"}})'
    ),
}

ALL_QUERIES: dict[str, str] = {**FLEET_QUERIES}
```

- [ ] **Step 4: Implement the scene**

```python
# src/rackpanel/scenes/fleet.py
"""Node health across the whole cluster -- 4 Pis and 3 amd64 workers."""
from PIL import Image, ImageDraw

from ..render import draw_bar, draw_hero, draw_label, draw_support, new_tile
from . import TILES_PER_SCENE, SceneContext


def _pct(value) -> str:
    return "--" if value is None else f"{value:.0f}%"


class FleetScene:
    key = "FLEET"
    order = 30

    def eligible(self, ctx: SceneContext) -> bool:
        return bool(ctx.data("kube").get("total"))

    def render_tile(self, index: int, ctx: SceneContext) -> Image.Image:
        if not 0 <= index < TILES_PER_SCENE:
            raise IndexError(f"tile index must be 0-{TILES_PER_SCENE - 1}")
        p = ctx.palette
        img = new_tile(p)
        d = ImageDraw.Draw(img)
        kube, thanos = ctx.data("kube"), ctx.data("thanos")
        nodes = kube.get("nodes", [])

        if index == 0:
            ready, total = kube.get("ready", 0), kube.get("total", 0)
            draw_label(d, (6, 5), "NODES", p)
            draw_hero(d, (6, 22), f"{ready}/{total}", p,
                      p.ok if ready == total else p.crit)
            pis = sum(1 for n in nodes if n.get("arch") == "arm64")
            draw_support(d, (6, 60), f"{pis} pi · {len(nodes) - pis} amd64", p)
        elif index == 1:
            cpu = thanos.get("cpu_pct")
            draw_label(d, (6, 5), "CPU", p)
            draw_hero(d, (6, 22), _pct(cpu), p)
            draw_bar(d, (6, 62), 148, 6, (cpu or 0) / 100.0, p)
        elif index == 2:
            mem = thanos.get("mem_pct")
            draw_label(d, (6, 5), "MEMORY", p)
            draw_hero(d, (6, 22), _pct(mem), p)
            draw_bar(d, (6, 62), 148, 6, (mem or 0) / 100.0, p)
        else:
            temp = thanos.get("temp_max")
            draw_label(d, (6, 5), "HOTTEST", p)
            draw_hero(d, (6, 22), "--" if temp is None else f"{temp:.0f}°", p,
                      p.warn if temp and temp > 70 else p.fg)
            draw_support(d, (6, 60), "node_hwmon max", p)

        # Mark staleness against the provider THIS tile actually reads. Tile 0
        # is rendered purely from kube; tiles 1-3 from thanos. Checking only
        # thanos would let a stale kube tile show a frozen node count with no
        # marker at all -- exactly what the marker exists to prevent.
        if ctx.is_stale("kube" if index == 0 else "thanos"):
            # A dot, not an error string. Never blank a tile.
            d.ellipse([151, 3, 156, 8], fill=p.warn)
        return img
```

- [ ] **Step 5: Generate goldens and verify**

```bash
RACKPANEL_UPDATE_GOLDEN=1 pytest tests/test_scene_fleet.py -v
pytest -v
```

Expected: full suite PASS.

- [ ] **Step 6: Commit**

```bash
git add src/rackpanel/queries.py src/rackpanel/scenes/fleet.py \
        tests/test_scene_fleet.py tests/golden
git commit -m "feat: FLEET scene with cluster-wide node and resource tiles"
```

---

### Task 10: Conductor loop and the web API

**Files:**
- Create: `src/rackpanel/config.py`
- Create: `src/rackpanel/conductor.py`
- Create: `src/rackpanel/web.py`
- Test: `tests/test_conductor.py`
- Test: `tests/test_web.py`

**Interfaces:**
- Consumes: everything from Tasks 1–9
- Produces: `Settings.from_env()`, `Conductor(cache, selector, scenes_ctx_factory, nodes, dwell)` with `.tick()`, `.frame_for(node) -> Frame`, `.status() -> dict`; `Frame` (frozen dataclass: `node, index, scene_key, seq, display_at, rgb565: bytes, png: bytes, etag: str`); `create_app(conductor) -> FastAPI`

- [ ] **Step 1: Write the failing conductor test**

```python
# tests/test_conductor.py
import pytest
from PIL import Image

from rackpanel.conductor import Conductor
from rackpanel.palette import DAY
from rackpanel.providers import ProviderCache
from rackpanel.scenes import SceneContext
from rackpanel.selector import SceneSelector

NODES = ["n1", "n2", "n3", "n4"]


class StubScene:
    key = "STUB"
    order = 0

    def __init__(self):
        self.color = (10, 20, 30)

    def eligible(self, ctx):
        return True

    def render_tile(self, index, ctx):
        return Image.new("RGB", (160, 80), self.color)


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def build(scene=None, clk=None):
    scene = scene or StubScene()
    clk = clk or Clock()
    return Conductor(
        cache=ProviderCache([], now=clk),
        selector=SceneSelector([scene], dwell=20.0),
        palette_for=lambda readings: DAY,
        nodes=NODES,
        now=clk,
    ), scene, clk


def test_tick_produces_a_frame_for_every_node():
    c, _, _ = build()
    c.tick()
    for i, node in enumerate(NODES):
        f = c.frame_for(node)
        assert f.index == i
        assert len(f.rgb565) == 160 * 80 * 2
        assert f.png.startswith(b"\x89PNG")


def test_all_four_frames_share_one_sequence_number():
    """They come from one render pass -- that is what makes them coordinated."""
    c, _, _ = build()
    c.tick()
    seqs = {c.frame_for(n).seq for n in NODES}
    assert len(seqs) == 1


def test_sequence_does_not_advance_when_nothing_changed():
    c, _, clk = build()
    c.tick()
    first = c.frame_for("n1").seq
    clk.t += 1.0
    c.tick()
    assert c.frame_for("n1").seq == first


def test_sequence_advances_when_the_rendered_pixels_change():
    c, scene, clk = build()
    c.tick()
    first = c.frame_for("n1").seq
    scene.color = (200, 10, 10)
    clk.t += 1.0
    c.tick()
    assert c.frame_for("n1").seq > first


def test_display_at_is_in_the_future_and_shared_by_all_nodes():
    """The synchronisation trick: agents hold the frame and blit together."""
    c, _, clk = build()
    c.tick()
    times = {c.frame_for(n).display_at for n in NODES}
    assert len(times) == 1
    assert times.pop() > clk.t


def test_unknown_node_raises_keyerror():
    c, _, _ = build()
    c.tick()
    with pytest.raises(KeyError):
        c.frame_for("nope")


def test_status_reports_scene_and_provider_staleness():
    c, _, _ = build()
    c.tick()
    st = c.status()
    assert st["scene"] == "STUB"
    assert st["nodes"] == NODES
    assert "providers" in st
```

- [ ] **Step 2: Run and confirm failure**

Run: `pytest tests/test_conductor.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'rackpanel.conductor'`

- [ ] **Step 3: Implement config**

```python
# src/rackpanel/config.py
"""Runtime configuration. Everything from env; nothing sensitive lives here."""
import os
from dataclasses import dataclass

DEFAULT_NODES = "jormungandr1,jormungandr2,jormungandr3,jormungandr4"


@dataclass(frozen=True)
class Settings:
    nodes: list[str]
    dwell_seconds: float
    thanos_url: str
    timezone: str
    cluster_name: str
    talos_version: str
    k8s_version: str
    lead_seconds: float

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            nodes=[n.strip() for n in
                   os.environ.get("RACKPANEL_NODES", DEFAULT_NODES).split(",")
                   if n.strip()],
            dwell_seconds=float(os.environ.get("RACKPANEL_DWELL", "20")),
            thanos_url=os.environ.get(
                "RACKPANEL_THANOS_URL",
                "http://thanos-query-frontend.observability.svc:10902"),
            timezone=os.environ.get("TZ", "UTC"),
            cluster_name=os.environ.get("RACKPANEL_CLUSTER", "home-kubernetes"),
            talos_version=os.environ.get("RACKPANEL_TALOS_VERSION", "v1.13.6"),
            k8s_version=os.environ.get("RACKPANEL_K8S_VERSION", "v1.36.2"),
            lead_seconds=float(os.environ.get("RACKPANEL_LEAD", "1.5")),
        )
```

- [ ] **Step 4: Implement the conductor**

```python
# src/rackpanel/conductor.py
"""Orchestration: poll, select, render once, serve four tiles.

One render pass produces all four tiles, which is what makes them mutually
consistent. Frames carry a shared display_at instant so the agents blit
together rather than up to a poll interval apart.
"""
import hashlib
import io
import time
from dataclasses import dataclass

from PIL import Image

from .framebuffer import to_rgb565
from .scenes import SceneContext


@dataclass(frozen=True)
class Frame:
    node: str
    index: int
    scene_key: str
    seq: int
    display_at: float
    rgb565: bytes
    png: bytes
    etag: str


class Conductor:
    def __init__(self, cache, selector, palette_for, nodes,
                 now=time.time, lead_seconds: float = 1.5):
        self._cache = cache
        self._selector = selector
        self._palette_for = palette_for
        self._nodes = list(nodes)
        self._now = now
        self._lead = lead_seconds
        self._frames: dict[str, Frame] = {}
        self._seq = 0
        self._scene_key = "-"

    def tick(self) -> None:
        """Poll due providers, pick a scene, render if the pixels changed."""
        self._cache.tick()
        readings = self._cache.all()
        ctx = SceneContext(readings=readings, palette=self._palette_for(readings))
        now = self._now()
        scene = self._selector.select(now, ctx)
        if scene is None:
            return
        self._scene_key = scene.key

        rendered = [scene.render_tile(i, ctx) for i in range(len(self._nodes))]
        digest = hashlib.sha256()
        payloads = []
        for img in rendered:
            raw = to_rgb565(img)
            digest.update(raw)
            payloads.append((img, raw))

        etag = digest.hexdigest()[:16]
        if self._frames and next(iter(self._frames.values())).etag == etag:
            return  # nothing changed -- do not burn a sequence number

        self._seq += 1
        display_at = now + self._lead
        frames = {}
        for i, (node, (img, raw)) in enumerate(zip(self._nodes, payloads)):
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            frames[node] = Frame(node, i, scene.key, self._seq, display_at,
                                 raw, buf.getvalue(), etag)
        self._frames = frames

    def frame_for(self, node: str) -> Frame:
        return self._frames[node]

    def status(self) -> dict:
        return {
            "scene": self._scene_key,
            "seq": self._seq,
            "nodes": self._nodes,
            "providers": {
                name: {
                    "age": round(r.age, 1),
                    "stale": r.stale,
                    "error": r.error or _subquery_error(r),
                }
                for name, r in self._cache.all().items()
            },
        }


def _subquery_error(reading) -> str | None:
    """Surface per-query failures that never reached the cache as an exception.

    ThanosProvider isolates a failing query into data["_errors"] and still
    returns successfully -- correct, because one bad query must not freeze the
    other tiles. But it means a provider whose queries ALL failed looks
    identical to a healthy one at /status, which the spec calls the first place
    to look when a tile shows a stale marker. Summarise here rather than
    changing the provider, so isolation is preserved.
    """
    data = reading.data
    if not isinstance(data, dict):
        return None
    errors = data.get("_errors")
    if not errors:
        return None
    if not isinstance(errors, list):
        # "_errors" is a dict-key convention, not an enforced shape, and this
        # runs inside an unguarded HTTP handler. A provider emitting a dict or
        # an int here must not turn /status into a 500.
        return "provider reported malformed _errors"
    return f"{len(errors)} quer{'y' if len(errors) == 1 else 'ies'} failed: {errors[0]}"
```

- [ ] **Step 5: Run conductor tests, confirm pass**

Run: `pytest tests/test_conductor.py -v`
Expected: PASS (7 tests)

- [ ] **Step 6: Write the failing web test**

```python
# tests/test_web.py
from fastapi.testclient import TestClient
from PIL import Image

from rackpanel.conductor import Conductor
from rackpanel.palette import DAY
from rackpanel.providers import ProviderCache
from rackpanel.selector import SceneSelector
from rackpanel.web import create_app

NODES = ["n1", "n2", "n3", "n4"]


class StubScene:
    key, order = "STUB", 0

    def eligible(self, ctx):
        return True

    def render_tile(self, index, ctx):
        return Image.new("RGB", (160, 80), (10, 20, 30))


def client():
    c = Conductor(ProviderCache([]), SceneSelector([StubScene()]),
                  lambda r: DAY, NODES)
    c.tick()
    return TestClient(create_app(c))


def test_tile_endpoint_returns_raw_rgb565_with_sync_headers():
    r = client().get("/tile/n1")
    assert r.status_code == 200
    assert len(r.content) == 160 * 80 * 2
    assert r.headers["x-scene"] == "STUB"
    assert float(r.headers["x-display-at"]) > 0
    assert r.headers["etag"]


def test_tile_returns_304_when_the_agent_already_has_this_frame():
    c = client()
    etag = c.get("/tile/n1").headers["etag"]
    assert c.get("/tile/n1", headers={"If-None-Match": etag}).status_code == 304


def test_png_endpoint_returns_an_image():
    r = client().get("/tile/n1.png")
    assert r.status_code == 200
    assert r.headers["content-type"] == "image/png"
    assert r.content.startswith(b"\x89PNG")


def test_unknown_node_returns_404_not_500():
    assert client().get("/tile/nope").status_code == 404


def test_status_endpoint_exposes_provider_staleness():
    body = client().get("/status").json()
    assert body["scene"] == "STUB"
    assert "providers" in body


def test_rackview_page_renders_all_four_tiles():
    body = client().get("/").text
    for node in NODES:
        assert f"/tile/{node}.png" in body


def test_healthz_is_cheap_and_always_200():
    assert client().get("/healthz").status_code == 200
```

- [ ] **Step 7: Run and confirm failure**

Run: `pytest tests/test_web.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'rackpanel.web'`

- [ ] **Step 8: Implement the web app**

```python
# src/rackpanel/web.py
"""HTTP surface: raw frames for the agents, PNGs and a page for humans.

rackview renders from the same frames the panels receive, so it cannot
drift from what is physically on the rack.
"""
from fastapi import FastAPI, Header, Response
from fastapi.responses import HTMLResponse, JSONResponse

from .conductor import Conductor

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>rackview</title>
<meta http-equiv="refresh" content="300">
<style>
 :root {{ color-scheme: dark; }}
 body {{ background:#0b0f14; color:#e6edf3; font:14px/1.5 ui-monospace,monospace;
        margin:0; padding:24px; }}
 h1 {{ font-size:16px; letter-spacing:.14em; color:#40e0d0; margin:0 0 18px; }}
 .rack {{ display:flex; gap:14px; flex-wrap:wrap; }}
 .panel img {{ width:480px; height:240px; image-rendering:pixelated;
               display:block; border:2px solid #1c2430; border-radius:6px;
               max-width:100%; height:auto; }}
 .panel figcaption {{ color:#6e7d8c; font-size:12px; margin-top:6px; }}
 #meta {{ margin-top:22px; color:#6e7d8c; font-size:12px; white-space:pre; }}
</style></head><body>
<h1>RACKVIEW</h1>
<div class="rack">{panels}</div>
<div id="meta">loading…</div>
<script>
const NODES = {nodes};
function bust() {{
  for (const n of NODES) {{
    const el = document.getElementById('t-' + n);
    if (el) el.src = '/tile/' + n + '.png?_=' + Date.now();
  }}
  fetch('/status').then(r => r.json()).then(s => {{
    const p = Object.entries(s.providers).map(
      ([k, v]) => `  ${{k}}: ${{v.age}}s${{v.stale ? ' STALE' : ''}}` +
                  `${{v.error ? ' — ' + v.error : ''}}`).join('\\n');
    document.getElementById('meta').textContent =
      `scene: ${{s.scene}}   frame: ${{s.seq}}\\nproviders:\\n${{p}}`;
  }});
}}
setInterval(bust, 1000); bust();
</script></body></html>"""


def create_app(conductor: Conductor) -> FastAPI:
    app = FastAPI(title="rackpanel conductor")

    @app.get("/healthz")
    def healthz():
        return {"ok": True}

    @app.get("/status")
    def status():
        return JSONResponse(conductor.status())

    @app.get("/tile/{node}.png")
    def tile_png(node: str):
        try:
            frame = conductor.frame_for(node)
        except KeyError:
            return Response(status_code=404)
        return Response(frame.png, media_type="image/png",
                        headers={"Cache-Control": "no-store"})

    @app.get("/tile/{node}")
    def tile_raw(node: str, if_none_match: str | None = Header(default=None)):
        try:
            frame = conductor.frame_for(node)
        except KeyError:
            return Response(status_code=404)
        if if_none_match == frame.etag:
            # Echo the validators, per RFC 7232. The agent already knows this
            # ETag, but a 304 that carries nothing is fragile for any future
            # client that re-reads them from the response.
            return Response(
                status_code=304,
                headers={"ETag": frame.etag, "Cache-Control": "no-store"},
            )
        return Response(
            frame.rgb565,
            media_type="application/octet-stream",
            headers={
                "ETag": frame.etag,
                "X-Scene": frame.scene_key,
                "X-Frame-Seq": str(frame.seq),
                "X-Display-At": f"{frame.display_at:.3f}",
                "X-Tile-Index": str(frame.index),
                "Cache-Control": "no-store",
            },
        )

    @app.get("/", response_class=HTMLResponse)
    def rackview():
        nodes = conductor.status()["nodes"]
        panels = "".join(
            f'<figure class="panel"><img id="t-{n}" src="/tile/{n}.png" '
            f'alt="{n}" width="480" height="240">'
            f'<figcaption>{n}</figcaption></figure>'
            for n in nodes
        )
        import json
        return HTMLResponse(PAGE.format(panels=panels, nodes=json.dumps(nodes)))

    return app
```

- [ ] **Step 9: Run the full suite**

Run: `pytest -v`
Expected: PASS (all tests across every module)

- [ ] **Step 10: See it for real**

```python
# src/rackpanel/__main__.py
"""Entrypoint: wire providers, start the poll loop, serve."""
import threading
import time

import uvicorn

from .config import Settings
from .conductor import Conductor
from .k8s import KubeClient
from .palette import select_palette
from .providers import ProviderCache
from .providers.clock import ClockProvider
from .providers.kube import KubeProvider
from .providers.thanos import ThanosProvider
from .queries import ALL_QUERIES
from .scenes.clock import ClockScene
from .scenes.fleet import FleetScene
from .scenes.identity import IdentityScene
from .selector import SceneSelector
from .web import create_app

TICK_SECONDS = 1.0


def build_conductor(settings: Settings) -> Conductor:
    providers = [ClockProvider(settings.timezone),
                 ThanosProvider(settings.thanos_url, ALL_QUERIES)]
    try:
        providers.append(KubeProvider(KubeClient.in_cluster()))
    except (KeyError, OSError):
        pass  # running outside the cluster: kube tiles show dashes

    cache = ProviderCache(providers)
    scenes = [
        IdentityScene(settings.cluster_name, settings.talos_version,
                      settings.k8s_version),
        ClockScene(),
        FleetScene(),
    ]

    def palette_for(readings):
        hour = readings["clock"].data.get("hour", 12) if "clock" in readings else 12
        return select_palette(hour)

    return Conductor(cache, SceneSelector(scenes, settings.dwell_seconds),
                     palette_for, settings.nodes,
                     lead_seconds=settings.lead_seconds)


def main() -> None:
    settings = Settings.from_env()
    conductor = build_conductor(settings)
    try:
        # Guarded like the loop below. Unguarded, a first-tick failure kills
        # the process BEFORE uvicorn binds -- a total outage caused by the
        # display, which is exactly what must never happen. A failed first
        # tick just means the first request 404s until the loop succeeds.
        conductor.tick()
    except Exception as exc:  # noqa: BLE001
        print(f"initial tick failed: {exc}", flush=True)

    def loop():
        while True:
            try:
                conductor.tick()
            except Exception as exc:  # noqa: BLE001 -- the display is never
                print(f"tick failed: {exc}", flush=True)  # worth crashing for
            time.sleep(TICK_SECONDS)

    threading.Thread(target=loop, daemon=True).start()
    uvicorn.run(create_app(conductor), host="0.0.0.0", port=8080)


if __name__ == "__main__":
    main()
```

```bash
RACKPANEL_DWELL=5 python -m rackpanel &
sleep 3 && open http://localhost:8080
```

Expected: four tiles in the browser, rotating every 5 s. Kube tiles show dashes outside the cluster; that is the designed degradation, not a failure.

- [ ] **Step 11: Commit**

```bash
git add src/rackpanel/config.py src/rackpanel/conductor.py \
        src/rackpanel/web.py src/rackpanel/__main__.py \
        tests/test_conductor.py tests/test_web.py
git commit -m "feat: conductor render loop, tile API and rackview page"
```

---

### Task 11: Container image, CI, and GitOps deployment

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`
- Create: `.drone.yml`
- Create (in `flux-talos`): `kubernetes/apps/observability/rackpanel/ks.yaml`
- Create (in `flux-talos`): `kubernetes/apps/observability/rackpanel/app/{kustomization,ocirepository,helmrelease,httproute,rbac,gitea-registry-externalsecret}.yaml`
- Create (in `flux-talos`): `kubernetes/apps/flux-system/rackpanel/ks.yaml`
- Create (in `flux-talos`): `kubernetes/apps/flux-system/rackpanel/app/{kustomization,imagerepository,imagepolicy,imageupdateautomation}.yaml`
- Modify (in `flux-talos`): `kubernetes/apps/observability/kustomization.yaml`
- Modify (in `flux-talos`): `kubernetes/apps/flux-system/kustomization.yaml`

**Interfaces:**
- Consumes: `python -m rackpanel` entrypoint (Task 10)
- Produces: a running Deployment serving `rackview.${SECRET_DOMAIN}`

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
FROM python:3.13-slim AS build
WORKDIR /app
COPY pyproject.toml ./
COPY src ./src
RUN pip install --no-cache-dir --target=/deps .

FROM python:3.13-slim AS runtime
ENV PYTHONUNBUFFERED=1 PYTHONPATH=/deps
WORKDIR /app
COPY --from=build /deps /deps
RUN useradd --uid 1000 --create-home app
USER 1000
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/healthz')"
CMD ["python", "-m", "rackpanel"]
```

```
# .dockerignore
.git*
tests/
docs/
__pycache__
*.pyc
.venv
```

Multi-stage keeps build tooling out of the runtime layer, and the vendored fonts ride along inside the installed package via `package-data` from Task 3.

- [ ] **Step 2: Write the Drone pipeline**

```yaml
# .drone.yml
---
kind: pipeline
type: kubernetes          # NOT "docker" -- this cluster runs drone-runner-kube,
                          # which never picks up a docker-type pipeline. Verified
                          # against kubernetes/apps/develop/drone (drone-runner-kube)
                          # and all 5 sibling first-party repos.
name: build-and-push

trigger:
  branch:
    - main
  event:
    - push

steps:
  - name: test
    image: python:3.13-slim
    commands:
      - pip install --quiet -e '.[dev]'
      - pytest -q

  - name: build-and-push
    image: plugins/kaniko
    settings:
      registry: gitea.derekjacobs.dev
      repo: gitea.derekjacobs.dev/bluevulpine/rackpanel
      username:
        from_secret: registry_user      # org-wide secret names; NOT gitea_username
      password:
        from_secret: registry_token
      tags:
        - latest
        - ${DRONE_BUILD_NUMBER}-${DRONE_COMMIT_SHA:0:8}
```

Steps run sequentially, so `test` gates `build-and-push` without needing
`depends_on`. The `latest` tag is harmless to image automation: the ImagePolicy
pattern `^(?P<num>[0-9]+)-[0-9a-f]{8}$` simply does not match it.

The tag format `<build>-<sha8>` is required — the ImagePolicy in Step 6 extracts the build number with `^(?P<num>[0-9]+)-[0-9a-f]{8}$`.

**Do not copy this file's shape from the brief alone — check a sibling repo.** The
five existing first-party repos (`helium-archiver`, `kia-collector`,
`chargepoint-collector`, `bluevulpine.net.web`, `unifi-phantom-clients-cleanup`)
are the ground truth for pipeline type and secret names. Getting either wrong
fails *silently*: a wrong `type` means no runner ever claims the build, so no
image is produced, so the ImagePolicy never resolves and the placeholder tag
deploys as `ImagePullBackOff`.

- [ ] **Step 3: Verify the image builds and runs locally**

```bash
docker build -t rackpanel:dev .
docker run --rm -p 8080:8080 -e RACKPANEL_DWELL=5 rackpanel:dev &
sleep 5 && curl -sf localhost:8080/healthz && curl -sI localhost:8080/tile/jormungandr1
```

Expected: `{"ok":true}`, then headers including `X-Scene`, `X-Display-At` and `ETag`.

- [ ] **Step 4: Commit the source repo and push**

```bash
git add Dockerfile .dockerignore .drone.yml
git commit -m "ci: container image and Drone pipeline"
git push origin main
```

Watch Drone build it, then confirm the tag exists before writing manifests that reference it.

- [ ] **Step 5: Write the app manifests (in `flux-talos`)**

```yaml
# kubernetes/apps/observability/rackpanel/ks.yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app rackpanel
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  interval: 1h
  path: ./kubernetes/apps/observability/rackpanel/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: home-kubernetes
    namespace: flux-system
  targetNamespace: observability
  wait: false
  postBuild:
    substitute:
      APP: *app
      NS: observability
```

```yaml
# kubernetes/apps/observability/rackpanel/app/kustomization.yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./gitea-registry-externalsecret.yaml
  - ./rbac.yaml
  - ./ocirepository.yaml
  - ./helmrelease.yaml
  - ./httproute.yaml
```

```yaml
# kubernetes/apps/observability/rackpanel/app/ocirepository.yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: rackpanel
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 5.0.1
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

```yaml
# kubernetes/apps/observability/rackpanel/app/rbac.yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rackpanel
---
# Least privilege: the conductor only ever reads. Node and pod listing is all
# Phase 1 needs; Flux CR access arrives with the GITOPS scene.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rackpanel-reader
rules:
  - apiGroups: [""]
    resources: ["nodes", "pods"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rackpanel-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: rackpanel-reader
subjects:
  - kind: ServiceAccount
    name: rackpanel
    namespace: observability
```

```yaml
# kubernetes/apps/observability/rackpanel/app/helmrelease.yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: &app rackpanel
spec:
  chartRef:
    kind: OCIRepository
    name: rackpanel
  interval: 1h
  values:
    controllers:
      rackpanel:
        type: deployment
        annotations:
          reloader.stakater.com/auto: "true"
        replicas: 1
        strategy: RollingUpdate
        serviceAccount:
          identifier: rackpanel
        containers:
          app:
            # First-party image — built by Drone CI from
            # https://gitea.derekjacobs.dev/bluevulpine/rackpanel
            image:
              repository: gitea.derekjacobs.dev/bluevulpine/rackpanel
              tag: 1-00000000 # {"$imagepolicy": "flux-system:rackpanel:tag"}
            env:
              TZ: "${TIMEZONE}"
              RACKPANEL_NODES: jormungandr1,jormungandr2,jormungandr3,jormungandr4
              RACKPANEL_DWELL: "20"
              RACKPANEL_THANOS_URL: http://thanos-query-frontend.observability.svc:10902
              RACKPANEL_CLUSTER: home-kubernetes
            probes:
              liveness: &probe
                enabled: true
                custom: true
                spec:
                  httpGet: {path: /healthz, port: 8080}
                  initialDelaySeconds: 10
                  periodSeconds: 20
              readiness: *probe
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities: {drop: ["ALL"]}
            resources:
              requests:
                cpu: 50m
                memory: 128Mi
              limits:
                memory: 384Mi
    defaultPodOptions:
      # amd64 only: rendering is the one CPU-hungry thing here, and the Pis
      # are already carrying the panels.
      nodeSelector:
        kubernetes.io/arch: amd64
      imagePullSecrets:
        - name: gitea-registry-creds
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
    service:
      app:
        controller: rackpanel
        ports:
          http:
            port: 8080
    persistence:
      tmp:
        type: emptyDir
        globalMounts:
          - path: /tmp
```

```yaml
# kubernetes/apps/observability/rackpanel/app/httproute.yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/gateway.networking.k8s.io/httproute_v1.json
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: rackpanel
  annotations:
    gatus.home-operations.com/endpoint: |
      group: observability
spec:
  hostnames: ["rackview.${SECRET_DOMAIN}"]
  parentRefs:
    - name: internal
      namespace: network
      sectionName: https
  rules:
    - backendRefs:
        - name: rackpanel
          port: 8080
```

Copy `gitea-registry-externalsecret.yaml` verbatim from `kubernetes/apps/home/helium-archiver/app/` — the registry pull secret is needed in every namespace that pulls a first-party image.

- [ ] **Step 6: Write the image-automation manifests**

```yaml
# kubernetes/apps/flux-system/rackpanel/app/imagerepository.yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/image.toolkit.fluxcd.io/imagerepository_v1beta2.json
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageRepository
metadata:
  name: &app rackpanel
spec:
  image: gitea.derekjacobs.dev/bluevulpine/rackpanel
  interval: 5m
  secretRef:
    name: gitea-registry-creds
```

```yaml
# kubernetes/apps/flux-system/rackpanel/app/imagepolicy.yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/image.toolkit.fluxcd.io/imagepolicy_v1beta2.json
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImagePolicy
metadata:
  name: &app rackpanel
spec:
  imageRepositoryRef:
    name: *app
  filterTags:
    pattern: '^(?P<num>[0-9]+)-[0-9a-f]{8}$'
    extract: '$num'
  policy:
    numerical:
      order: asc
```

```yaml
# kubernetes/apps/flux-system/rackpanel/app/imageupdateautomation.yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/image.toolkit.fluxcd.io/imageupdateautomation_v1beta2.json
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageUpdateAutomation
metadata:
  name: &app rackpanel
spec:
  interval: 30m
  sourceRef:
    kind: GitRepository
    name: flux-talos-ssh
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        name: Flux
        email: flux@derekjacobs.dev
      messageTemplate: |
        chore(images): update {{ range .Changed.Changes }}{{ println .NewValue }}{{ end }}
    push:
      branch: main
  update:
    # Scoped to this app only. A repo-wide path would rewrite every other
    # app's $imagepolicy markers (runbook gotcha 2).
    path: ./kubernetes/apps/observability/rackpanel
    strategy: Setters
```

```yaml
# kubernetes/apps/flux-system/rackpanel/app/kustomization.yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: flux-system
resources:
  - ./imagerepository.yaml
  - ./imagepolicy.yaml
  - ./imageupdateautomation.yaml
```

Copy `kubernetes/apps/flux-system/helium-archiver/ks.yaml` to `.../rackpanel/ks.yaml`, changing `&app helium-archiver-image` to `&app rackpanel-image` and the `path:` to `./kubernetes/apps/flux-system/rackpanel/app`.

**Marker check — the runbook's gotcha 1.** The HelmRelease uses a dedicated `tag:` subfield, so the marker **must** carry the `:tag` suffix. A `:tag` marker on a combined `image: repo:tag` scalar overwrites the whole scalar with the bare tag and yields `ImagePullBackOff`.

- [ ] **Step 7: Register both Kustomizations**

Add `- ./rackpanel/ks.yaml` to `kubernetes/apps/observability/kustomization.yaml` (alphabetically, after `./kube-prometheus-stack/ks.yaml`) and to `kubernetes/apps/flux-system/kustomization.yaml`.

`observability` already includes the `psa-privileged` component, so nothing further is needed there.

- [ ] **Step 8: Validate before committing**

```bash
kustomize build kubernetes/apps/observability/rackpanel/app >/dev/null
kustomize build kubernetes/apps/flux-system/rackpanel/app >/dev/null
grep -rn '$imagepolicy' kubernetes/apps/observability/rackpanel/
lefthook run pre-commit
```

Expected: both builds succeed, exactly one marker found (carrying `:tag`), hooks pass including `yamlfmt` and `gitleaks`.

- [ ] **Step 9: Commit and verify in-cluster**

```bash
git add kubernetes/apps/observability/rackpanel kubernetes/apps/flux-system/rackpanel \
        kubernetes/apps/observability/kustomization.yaml \
        kubernetes/apps/flux-system/kustomization.yaml
git commit -m "feat(observability): deploy rackpanel conductor and rackview"
```

Push to `main` — the GitHub webhook reconciles Flux near-instantly, so do **not** run `flux reconcile`. Then verify:

```bash
flux get image policy rackpanel -n flux-system
kubectl -n observability get pods -l app.kubernetes.io/name=rackpanel
kubectl -n observability get httproute rackpanel
curl -sI https://rackview.${SECRET_DOMAIN}/healthz
```

Expected: the policy has selected a real tag, the pod is `Running` and ready, and the page loads. **Open `https://rackview.<domain>` and confirm four tiles rotating together.**

---

## Self-Review

**Spec coverage (Phase 1 scope):** framebuffer ✓ Task 1 · palette + severity override ✓ Task 2 · tile budget and render primitives ✓ Task 3 · provider protocol, intervals, staleness, "never blank a tile" ✓ Task 4 · Thanos-not-Prometheus ✓ Task 6 · stable ordering and newly-eligible-shows-next ✓ Task 7 · base scenes ✓ Tasks 8–9 · one render pass, shared seq, `X-Display-At` ✓ Task 10 · rackview with per-provider staleness, integer scaling, `pixelated`, no auth ✓ Task 10 · internal Gateway route, gatus annotation ✓ Task 11 · image automation with correct marker suffix and scoped path ✓ Task 11.

**Deferred by design, each to its own plan:** panel-agent and bit-bang I²C (Phase 2) · ALERTS/INCIDENT/UPGRADE conditional scenes and the Alertmanager provider (Phase 3) · STORAGE/NETWORK/GITOPS/WORKLOADS/TRIVIA scenes, which are the same shape as FLEET · homelab service scenes via Homepage credentials (Phase 4) · the `?scene=` and `?palette=` overrides.

**Type consistency:** `Reading`, `SceneContext`, `Palette`, `Frame` field names are used identically across tasks. `render_tile(index, ctx)` and `eligible(ctx)` match the protocol in every scene. `ProviderCache.tick()`/`.get()`/`.all()` match their uses in Task 10.

**Known follow-up:** Task 10's `Conductor` renders every tick and compares digests to decide whether to bump `seq`. That is correct but wasteful once there are many scenes; if profiling shows it matters, gate rendering on scene key plus provider `fetched_at`. Not premature-optimised here.
