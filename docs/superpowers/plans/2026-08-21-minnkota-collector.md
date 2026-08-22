# Minnkota Demand-Response Collector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Archive Minnkota/Red Lake utility demand-response ripple state to InfluxDB (including a full backfill of the 2025-26 heating season) and publish the live "heat pump is curtailed" signal to Home Assistant over MQTT, so an automation can force aux heat the moment the utility disables the heat pump.

**Architecture:** A stateless Python CronJob, in the same shape as `beestat-collector`. Every 5 minutes it fetches a 2-day window from the unauthenticated `api.minnkotadr.com` ripple log, writes one InfluxDB point per *addressed* digital output, and publishes retained MQTT discovery + state for Home Assistant. A separate daily audit job re-walks the entire retained history (172 API calls, ~68 s) so interior gaps self-heal. The collector holds no state: it re-fetches and relies on InfluxDB's idempotency on `(measurement, tagset, field, timestamp)`.

**Tech Stack:** Python 3.12, `influxdb-client`, `paho-mqtt` 2.x, InfluxDB 2 (Flux), Mosquitto, Kubernetes CronJob, Flux CD + Drone/kaniko, Prometheus, Grafana.

**Spec:** `docs/briefs/2026-08-21-minnkota-dr-collector.md` — **read the `## Corrections` section first**; it overrides the body of that brief in five load-bearing ways.

---

## Global Constraints

Copied verbatim from the spec and from measurements taken 2026-08-21. Every task's requirements implicitly include this section.

- **API base:** `https://api.minnkotadr.com`. **No authentication of any kind.** Do not add auth headers, tokens, or cookies.
- **`area` is required** by `/api/Ripple/list` even though its value does not change the response. Use `redlake`.
- **`startDate=X` returns a TWO-day window** (X and X+1). There is no `endDate`. Walk at a 2-day stride.
- **History begins 2025-09-13.** `2025-09-12` returns 0 rows. Full range = 342 days = 172 calls = ~68 s.
- **`datetime` is `YYMMDDTHHMMSS` in LOCAL wall-clock `America/Chicago`, and follows DST.** Convert to UTC before writing. Getting this wrong shifts every event 5–6 h and destroys the beestat join.
- **`---` means "not addressed by this command", NOT "not controlled".** Carry state forward per `(load_group, do)`. Never write a point for a `---` entry; never treat `---` as OFF.
- **`do` is a 16-element array mapping to DO09..DO24** (index 0 = DO09).
- **The log is not one-row-per-change.** Identical states repeat. Deduplicate on timestamp; never infer a transition from a row's mere arrival.
- **State polarity:** `ON` = load energized / permitted. `OFF` = **utility has shed the load**. "Curtailed" is the *inverse* of `state`. This inversion is the single most likely bug in the whole project.
- **User's load groups:** `3.09` / `DO13` = **"Dual Heat"** = the heat pump. `2.06` / `DO09` + `DO16` = **"Battery Storage"** = the EVSE off-peak window.
- **Filter on `lg` only.** Never on `area`, `coop`, or `name` — those describe the transmitting substation, not the member.
- **Never gate alerts on row novelty.** Measured: the co-op issues no commands at all for up to 6 consecutive days (and none for the user's groups for up to 16 days) in the off-season. That is normal, not a fault.
- **InfluxDB org** `homelab`, **bucket** `minnkota`, infinite retention, URL `http://influxdb.database.svc.cluster.local:8086`.
- **Secrets exclusively from OpenBao via ExternalSecret** (`secretStoreRef: openbao`, `ClusterSecretStore`, `engineVersion: v2`). PascalCase double-underscore field naming. **Never commit a secret value.**
- **YAML:** every `.yaml` except `*.sops.yaml` must pass `yamlfmt` — block-style arrays, `---` document start, LF endings. Run `lefthook run pre-commit` before every commit; do not skip hooks.
- **Every Kubernetes manifest starts with a `# yaml-language-server: $schema=...` line.**
- **Flux image-automation marker rule:** the image is a combined `repo:tag` scalar, so the marker takes **no** `:tag` suffix — `# {"$imagepolicy": "flux-system:minnkota-collector"}`. A `:tag` suffix overwrites the scalar with a bare tag and causes `ImagePullBackOff`. `update.path` must be scoped to this app's directory only.
- **paho-mqtt 2.x requires the versioned callback API**: `mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, ...)`. The 1.x constructor signature raises `ValueError` at import-time use.
- **Do not `flux reconcile` after pushing to `main`** — a GitHub webhook reconciles near-instantly. Push, wait, verify.

### Measured baseline (for verification steps)

| Fact | Value |
| --- | --- |
| Full backfill | 172 calls, ~68 s, 0 failures |
| Unique rows, full history | 12,532 |
| Addressed-DO points, all load groups | 115,804 |
| Addressed-DO points, groups 2.06 + 3.09 only | 10,536 |
| Heat-pump (3.09/DO13) shed events, 2025-09-13 → 2026-08-21 | **32** |
| Total heat-pump curtailment | **152.8 hours** |
| Longest single shed | 8.87 h (2026-01-23 05:10 → 14:02) |
| Days with data / calendar span | 332 / 342 |
| Longest all-group quiet run | 6 days (late May 2026) |

---

## File Structure

### Repo A — `minnkota-collector` (new, Gitea)

`git@gitea.derekjacobs.dev:bluevulpine/minnkota-collector.git`, cloned to `~/Repositories/minnkota-collector`. Source never goes in `flux-talos`.

| File | Responsibility |
| --- | --- |
| `minnkota_api.py` | HTTP client + timestamp parsing. Knows the API, knows nothing about InfluxDB. |
| `ripple_state.py` | Pure domain logic: carry-forward, `---` handling, point construction, curtailment inversion. No I/O. This is where the bugs would live, so this is where the tests concentrate. |
| `influx_archive.py` | Watermark reads + batched idempotent writes. Adapted from `beestat-collector`. |
| `mqtt_publish.py` | Home Assistant MQTT discovery + retained state. |
| `collector.py` | Orchestration, env config, run modes, exit codes. |
| `requirements.txt`, `Dockerfile`, `.dockerignore`, `.drone.yml`, `.gitignore`, `README.md` | Build + docs. |
| `tests/test_minnkota_api.py`, `tests/test_ripple_state.py`, `tests/test_mqtt_publish.py` | pytest. |

### Repo B — `flux-talos`

| File | Responsibility |
| --- | --- |
| `kubernetes/apps/home/minnkota-collector/ks.yaml` | Flux Kustomization |
| `kubernetes/apps/home/minnkota-collector/app/kustomization.yaml` | resource list + dashboard configMapGenerator |
| `.../app/configmap.yaml` | All non-secret config, incl. the pinned DO→name JSON |
| `.../app/externalsecret.yaml` | InfluxDB token + MQTT creds from OpenBao |
| `.../app/serviceaccount.yaml` | Identity; no OpenBao role needed |
| `.../app/cronjob.yaml` | 5-minute collector + daily audit |
| `.../app/prometheusrule.yaml` | Job-failed, ImagePullBackOff, staleness |
| `.../app/minnkota-dashboard.json` | Grafana dashboard |
| `kubernetes/apps/flux-system/minnkota-collector/{ks.yaml,app/*}` | Image automation |
| `kubernetes/apps/home/kustomization.yaml` | register (modify) |
| `kubernetes/apps/flux-system/kustomization.yaml` | register (modify) |
| `kubernetes/apps/observability/grafana/app/helmrelease.yaml` | datasource (modify) |
| `kubernetes/apps/observability/grafana/app/externalsecret.yaml` | token env (modify) |

---

## Task 1: API client and timestamp parsing

**Files:**
- Create: `~/Repositories/minnkota-collector/minnkota_api.py`
- Create: `~/Repositories/minnkota-collector/requirements.txt`
- Create: `~/Repositories/minnkota-collector/.gitignore`
- Test: `~/Repositories/minnkota-collector/tests/test_minnkota_api.py`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `DO_INDEX: tuple[str, ...]` — `("DO09", ..., "DO24")`, length 16.
  - `parse_ripple_datetime(raw: str, tz: ZoneInfo) -> datetime.datetime` — returns **naive UTC**.
  - `@dataclass(frozen=True) RippleRow` with fields `timestamp: datetime.datetime` (naive UTC), `load_group: str`, `substation: str`, `coop: str`, `ac: str`, `err: int`, `do: tuple[str, ...]`.
  - `class MinnkotaAPI` with `__init__(self, base_url: str, area: str, tz: ZoneInfo, min_interval_seconds: float = 0.15, timeout: int = 30)` and methods `ripple_list(start: datetime.date) -> list[RippleRow]`, `plan_list() -> list[dict]`, `schedule_list() -> list[dict]`, `system_condition() -> list[dict]`.
  - `class MinnkotaAPIError(RuntimeError)`.

- [ ] **Step 1: Create the repo skeleton**

```bash
cd ~/Repositories
git clone git@gitea.derekjacobs.dev:bluevulpine/minnkota-collector.git
cd minnkota-collector
mkdir -p tests
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
```

Create `.gitignore`:

```
.venv/
__pycache__/
*.pyc
.pytest_cache/
```

Create `requirements.txt`:

```
influxdb-client>=1.44.0
paho-mqtt>=2.1.0
tzdata>=2024.1
```

Then:

```bash
.venv/bin/pip install -r requirements.txt pytest
```

- [ ] **Step 2: Write the failing tests**

Create `tests/test_minnkota_api.py`:

```python
import datetime as dt
from zoneinfo import ZoneInfo

import pytest

from minnkota_api import (
    DO_INDEX,
    MinnkotaAPI,
    MinnkotaAPIError,
    RippleRow,
    parse_ripple_datetime,
)

CHICAGO = ZoneInfo("America/Chicago")


def test_do_index_covers_do09_through_do24():
    assert len(DO_INDEX) == 16
    assert DO_INDEX[0] == "DO09"
    assert DO_INDEX[4] == "DO13"
    assert DO_INDEX[7] == "DO16"
    assert DO_INDEX[-1] == "DO24"


def test_parse_datetime_is_local_chicago_in_winter():
    # 2025-11-07 is after the 2025-11-02 DST end, so CST = UTC-6.
    assert parse_ripple_datetime("251107T072100", CHICAGO) == dt.datetime(
        2025, 11, 7, 13, 21, 0
    )


def test_parse_datetime_is_local_chicago_in_summer():
    # 2026-08-21 is CDT = UTC-5.
    assert parse_ripple_datetime("260821T100100", CHICAGO) == dt.datetime(
        2026, 8, 21, 15, 1, 0
    )


def test_parse_datetime_follows_dst_not_a_fixed_offset():
    # The same wall-clock 07:10 shed maps to a DIFFERENT UTC hour either side
    # of the 2025-11-02 DST boundary. This is the whole point of Correction 5.
    before = parse_ripple_datetime("251101T071000", CHICAGO)  # CDT, UTC-5
    after = parse_ripple_datetime("251103T071000", CHICAGO)  # CST, UTC-6
    assert before.hour == 12
    assert after.hour == 13


def test_parse_datetime_rejects_garbage():
    with pytest.raises(ValueError):
        parse_ripple_datetime("not-a-timestamp", CHICAGO)


def test_ripple_list_parses_a_row(monkeypatch):
    payload = [
        {
            "ac": "ALL",
            "coop": "Red River",
            "datetime": "260821T100100",
            "do": ["OFF"] + ["---"] * 6 + ["OFF"] + ["---"] * 8,
            "err": 0,
            "lg": "2.06",
            "name": "Ada",
        }
    ]
    api = MinnkotaAPI("https://api.example", "redlake", CHICAGO, min_interval_seconds=0)
    monkeypatch.setattr(api, "_get_json", lambda path, params=None: payload)

    rows = api.ripple_list(dt.date(2026, 8, 21))

    assert len(rows) == 1
    row = rows[0]
    assert isinstance(row, RippleRow)
    assert row.load_group == "2.06"
    assert row.substation == "Ada"
    assert row.coop == "Red River"
    assert row.err == 0
    assert row.timestamp == dt.datetime(2026, 8, 21, 15, 1, 0)
    assert row.do[0] == "OFF"
    assert row.do[7] == "OFF"
    assert row.do[1] == "---"


def test_ripple_list_sends_area_and_startdate(monkeypatch):
    captured = {}

    def fake_get(path, params=None):
        captured["path"] = path
        captured["params"] = params
        return []

    api = MinnkotaAPI("https://api.example", "redlake", CHICAGO, min_interval_seconds=0)
    monkeypatch.setattr(api, "_get_json", fake_get)
    api.ripple_list(dt.date(2026, 8, 21))

    assert captured["path"] == "/api/Ripple/list"
    assert captured["params"] == {"area": "redlake", "startDate": "2026-08-21"}


def test_ripple_list_rejects_a_short_do_array(monkeypatch):
    payload = [
        {
            "ac": "ALL",
            "coop": "Red River",
            "datetime": "260821T100100",
            "do": ["ON", "OFF"],
            "err": 0,
            "lg": "2.06",
            "name": "Ada",
        }
    ]
    api = MinnkotaAPI("https://api.example", "redlake", CHICAGO, min_interval_seconds=0)
    monkeypatch.setattr(api, "_get_json", lambda path, params=None: payload)

    with pytest.raises(MinnkotaAPIError, match="expected 16"):
        api.ripple_list(dt.date(2026, 8, 21))
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd ~/Repositories/minnkota-collector && .venv/bin/python -m pytest tests/test_minnkota_api.py -v`

Expected: FAIL — `ModuleNotFoundError: No module named 'minnkota_api'`.

- [ ] **Step 4: Write the implementation**

Create `minnkota_api.py`:

```python
"""HTTP client for the Minnkota demand-response API.

There is deliberately no authentication here. api.minnkotadr.com is entirely
unauthenticated -- every endpoint returns 200 with no token, cookie, or key.
Adding auth would be inventing a requirement that does not exist.

The one genuinely subtle thing in this module is timestamp parsing. The API
emits `YYMMDDTHHMMSS` with no timezone, and it is LOCAL WALL-CLOCK time that
follows DST -- not UTC and not a fixed offset. The evidence: through November
2025, load group 2.06 sheds at exactly 07:10 and 17:10 every day, unchanged
across the 2025-11-02 DST boundary. A UTC reading would place that shed at
01:10 local, which is not a peak period under any tariff. Misreading this
shifts every event by 5-6 hours and silently destroys the join against
beestat runtime data.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from zoneinfo import ZoneInfo

log = logging.getLogger(__name__)

# The `do` array is 16 elements mapping to DO09..DO24. Index 0 is DO09.
DO_INDEX: tuple[str, ...] = tuple(f"DO{i:02d}" for i in range(9, 25))

# Values a DO entry can take. "---" means "this command did not address this
# output" -- NOT "this output is uncontrolled" and emphatically NOT "off".
ADDRESSED = frozenset({"ON", "OFF"})


class MinnkotaAPIError(RuntimeError):
    """Any failure talking to, or making sense of, the Minnkota API."""


@dataclass(frozen=True)
class RippleRow:
    """One ripple command as logged by the utility.

    `timestamp` is naive UTC. `do` is a 16-tuple aligned to DO_INDEX.
    """

    timestamp: dt.datetime
    load_group: str
    substation: str
    coop: str
    ac: str
    err: int
    do: tuple[str, ...]


def parse_ripple_datetime(raw: str, tz: ZoneInfo) -> dt.datetime:
    """`YYMMDDTHHMMSS` in local wall-clock -> naive UTC.

    Raises ValueError on anything that is not that exact shape.
    """
    naive_local = dt.datetime.strptime(raw, "%y%m%dT%H%M%S")
    # fold=0 resolves the ambiguous hour repeated at the DST fall-back to the
    # first (daylight) occurrence. The utility never issues commands during
    # that hour in practice, but picking explicitly beats picking by accident.
    aware_local = naive_local.replace(tzinfo=tz, fold=0)
    return aware_local.astimezone(dt.UTC).replace(tzinfo=None)


class MinnkotaAPI:
    def __init__(
        self,
        base_url: str,
        area: str,
        tz: ZoneInfo,
        min_interval_seconds: float = 0.15,
        timeout: int = 30,
    ):
        self._base = base_url.rstrip("/")
        self._area = area
        self._tz = tz
        self._min_interval = min_interval_seconds
        self._timeout = timeout
        self._last_call = 0.0

    # ------------------------------------------------------------------
    # Transport
    # ------------------------------------------------------------------

    def _get_json(self, path: str, params: dict | None = None):
        """GET + JSON decode, with a floor on inter-request spacing.

        This is a public utility's unauthenticated API being polled every five
        minutes. The rate floor is politeness, not a documented limit -- no
        429 or quota has ever been observed.
        """
        gap = time.monotonic() - self._last_call
        if gap < self._min_interval:
            time.sleep(self._min_interval - gap)

        url = self._base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)

        for attempt in range(4):
            try:
                with urllib.request.urlopen(url, timeout=self._timeout) as resp:
                    body = resp.read()
                self._last_call = time.monotonic()
                return json.loads(body)
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
                if attempt == 3:
                    raise MinnkotaAPIError(f"GET {url} failed: {exc}") from exc
                backoff = 2**attempt
                log.warning("GET %s failed (%s); retrying in %ss", url, exc, backoff)
                time.sleep(backoff)
        raise MinnkotaAPIError(f"GET {url} exhausted retries")

    # ------------------------------------------------------------------
    # Endpoints
    # ------------------------------------------------------------------

    def ripple_list(self, start: dt.date) -> list[RippleRow]:
        """The ripple log.

        NOTE: this returns a TWO-day window -- `start` and `start + 1` -- so a
        history walk steps by 2 days. There is no endDate parameter. `area` is
        required by the server even though its value does not change the
        response (load groups are globally unique across the ripple system).
        """
        raw = self._get_json(
            "/api/Ripple/list",
            {"area": self._area, "startDate": start.isoformat()},
        )
        rows: list[RippleRow] = []
        for item in raw:
            do = item.get("do") or []
            if len(do) != len(DO_INDEX):
                raise MinnkotaAPIError(
                    f"expected {len(DO_INDEX)} do entries, got {len(do)} "
                    f"for lg={item.get('lg')} at {item.get('datetime')}"
                )
            try:
                ts = parse_ripple_datetime(item["datetime"], self._tz)
            except (KeyError, ValueError) as exc:
                raise MinnkotaAPIError(f"bad datetime in row {item!r}: {exc}") from exc
            rows.append(
                RippleRow(
                    timestamp=ts,
                    load_group=str(item.get("lg", "")),
                    substation=str(item.get("name", "")),
                    coop=str(item.get("coop", "")),
                    ac=str(item.get("ac", "")),
                    err=int(item.get("err", 0)),
                    do=tuple(str(v) for v in do),
                )
            )
        return rows

    def plan_list(self) -> list[dict]:
        """Human-readable daily load-management forecast."""
        return self._get_json("/api/Plan/list")

    def schedule_list(self) -> list[dict]:
        """Yellow/Red Zone shed schedule."""
        return self._get_json("/api/Schedule/list")

    def system_condition(self) -> list[dict]:
        """System-condition percentage events."""
        return self._get_json("/api/SystemCondition")
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd ~/Repositories/minnkota-collector && .venv/bin/python -m pytest tests/test_minnkota_api.py -v`

Expected: PASS — 8 passed.

- [ ] **Step 6: Verify against the live API**

Run:

```bash
cd ~/Repositories/minnkota-collector
.venv/bin/python -c "
import datetime as dt
from zoneinfo import ZoneInfo
from minnkota_api import MinnkotaAPI
api = MinnkotaAPI('https://api.minnkotadr.com', 'redlake', ZoneInfo('America/Chicago'))
rows = api.ripple_list(dt.date(2025, 11, 7))
print(len(rows), 'rows')
hp = [r for r in rows if r.load_group == '3.09']
for r in hp[:4]:
    print(r.timestamp, r.load_group, r.do[4])
"
```

Expected: prints rows; the 3.09 row that reads `OFF` at DO13 has `timestamp` `2025-11-07 13:21:00` (i.e. 07:21 local, converted to UTC).

- [ ] **Step 7: Commit**

```bash
cd ~/Repositories/minnkota-collector
git add .gitignore requirements.txt minnkota_api.py tests/test_minnkota_api.py
git commit -m "feat: Minnkota API client with DST-correct local timestamp parsing"
```

---

## Task 2: Ripple state — carry-forward and point construction

This is the task most likely to produce silently wrong data. Two traps: treating `---` as OFF (inventing sheds), and forgetting that "curtailed" is the *inverse* of the DO state.

**Files:**
- Create: `~/Repositories/minnkota-collector/ripple_state.py`
- Test: `~/Repositories/minnkota-collector/tests/test_ripple_state.py`

**Interfaces:**
- Consumes: `RippleRow`, `DO_INDEX`, `ADDRESSED` from `minnkota_api`.
- Produces:
  - `@dataclass(frozen=True) DOReading` with `timestamp: datetime.datetime`, `load_group: str`, `do: str`, `energized: bool`, `state_text: str`.
  - `iter_readings(rows: Iterable[RippleRow]) -> Iterator[DOReading]` — one reading per *addressed* DO per row, in the order given.
  - `current_state(rows: Iterable[RippleRow]) -> dict[tuple[str, str], DOReading]` — carry-forward; key is `(load_group, do)`, value is the newest reading for it.
  - `load_name(load_group: str, do: str, do_names: dict[str, dict[str, str]]) -> str`
  - `tier_name(load_group: str, tiers: dict[str, str]) -> str`
  - `to_points(rows, do_names, tiers, area) -> list[influxdb_client.Point]`

- [ ] **Step 1: Write the failing tests**

Create `tests/test_ripple_state.py`:

```python
import datetime as dt

from minnkota_api import DO_INDEX, RippleRow
from ripple_state import (
    current_state,
    iter_readings,
    load_name,
    tier_name,
    to_points,
)

DO_NAMES = {
    "2.06": {"9": "Battery Storage", "16": "Battery Storage"},
    "3.09": {
        "9": "Dual Heat",
        "10": "Dual Heat",
        "11": "Dual Heat",
        "12": "Dual Heat",
        "13": "Dual Heat",
        "14": "Dual Heat",
        "15": "Dual Heat",
        "16": "Dual Heat",
        "17": "Misc Heat 3",
        "18": "Misc Heat 3",
        "24": "Ind. Contr Loads 3",
    },
}
TIERS = {
    "1": "Short-Term Loads (water heaters)",
    "2": "Intermediate-Term Loads (storage heat)",
    "3": "Long-Term Loads (dual heating furnaces, back-up generators)",
    "6": "Summer-Only Loads (irrigation, cycled air conditioning)",
}


def row(ts, lg, **do_values):
    """Build a RippleRow with every DO '---' except those named."""
    do = ["---"] * 16
    for name, value in do_values.items():
        do[DO_INDEX.index(name)] = value
    return RippleRow(
        timestamp=ts,
        load_group=lg,
        substation="Ada",
        coop="Red River",
        ac="ALL",
        err=0,
        do=tuple(do),
    )


T0 = dt.datetime(2025, 12, 3, 13, 19, 0)
T1 = dt.datetime(2025, 12, 3, 13, 22, 0)


def test_dashes_produce_no_reading():
    readings = list(iter_readings([row(T0, "3.09", DO09="OFF")]))
    assert len(readings) == 1
    assert readings[0].do == "DO09"


def test_reading_records_state_and_text():
    (reading,) = list(iter_readings([row(T0, "3.09", DO13="OFF")]))
    assert reading.load_group == "3.09"
    assert reading.do == "DO13"
    assert reading.energized is False
    assert reading.state_text == "OFF"
    assert reading.timestamp == T0


def test_on_is_energized():
    (reading,) = list(iter_readings([row(T0, "3.09", DO13="ON")]))
    assert reading.energized is True
    assert reading.state_text == "ON"


def test_partial_row_does_not_clear_unaddressed_dos():
    # This is Correction 4, the highest-risk bug in the project.
    # At 13:19 only DO09..DO12 are commanded OFF. DO13 was ON before and must
    # STILL read ON -- it was simply not addressed by that command.
    rows = [
        row(T0 - dt.timedelta(minutes=10), "3.09", DO13="ON", DO09="ON"),
        row(T0, "3.09", DO09="OFF", DO10="OFF", DO11="OFF", DO12="OFF"),
    ]
    state = current_state(rows)
    assert state[("3.09", "DO13")].energized is True
    assert state[("3.09", "DO09")].energized is False


def test_carry_forward_advances_when_the_do_is_addressed_again():
    rows = [
        row(T0, "3.09", DO13="ON"),
        row(T1, "3.09", DO13="OFF"),
    ]
    state = current_state(rows)
    assert state[("3.09", "DO13")].energized is False
    assert state[("3.09", "DO13")].timestamp == T1


def test_current_state_ignores_row_order():
    rows = [
        row(T1, "3.09", DO13="OFF"),
        row(T0, "3.09", DO13="ON"),
    ]
    state = current_state(rows)
    assert state[("3.09", "DO13")].timestamp == T1
    assert state[("3.09", "DO13")].energized is False


def test_current_state_keeps_load_groups_separate():
    rows = [
        row(T0, "3.09", DO09="OFF"),
        row(T0, "2.06", DO09="ON"),
    ]
    state = current_state(rows)
    assert state[("3.09", "DO09")].energized is False
    assert state[("2.06", "DO09")].energized is True


def test_load_name_resolves_dual_heat():
    assert load_name("3.09", "DO13", DO_NAMES) == "Dual Heat"
    assert load_name("2.06", "DO09", DO_NAMES) == "Battery Storage"


def test_load_name_falls_back_to_unknown():
    assert load_name("9.99", "DO13", DO_NAMES) == "Unknown"
    assert load_name("3.09", "DO19", DO_NAMES) == "Unknown"


def test_tier_name_uses_the_integer_prefix():
    assert tier_name("3.09", TIERS).startswith("Long-Term")
    assert tier_name("2.06", TIERS).startswith("Intermediate-Term")
    assert tier_name("7.01", TIERS) == "Unknown"


def test_to_points_sets_curtailed_as_the_inverse_of_state():
    # Polarity trap: OFF means the utility SHED the load, so curtailed = 1.
    points = to_points([row(T0, "3.09", DO13="OFF")], DO_NAMES, TIERS, "redlake")
    line = points[0].to_line_protocol()
    assert "curtailed=1i" in line
    assert "state=false" in line
    assert 'state_text="OFF"' in line


def test_to_points_curtailed_is_zero_when_energized():
    points = to_points([row(T0, "3.09", DO13="ON")], DO_NAMES, TIERS, "redlake")
    line = points[0].to_line_protocol()
    assert "curtailed=0i" in line
    assert "state=true" in line


def test_to_points_tags_the_stable_do_index_and_the_name():
    points = to_points([row(T0, "3.09", DO13="OFF")], DO_NAMES, TIERS, "redlake")
    line = points[0].to_line_protocol()
    assert line.startswith("ripple_state,")
    assert "do=DO13" in line
    assert "load_group=3.09" in line
    assert r"load_name=Dual\ Heat" in line
    assert "area=redlake" in line


def test_to_points_emits_nothing_for_an_all_dashes_row():
    assert to_points([row(T0, "3.09")], DO_NAMES, TIERS, "redlake") == []


def test_to_points_emits_one_point_per_addressed_do():
    points = to_points(
        [row(T0, "3.09", DO09="OFF", DO13="OFF", DO24="ON")],
        DO_NAMES,
        TIERS,
        "redlake",
    )
    assert len(points) == 3
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/Repositories/minnkota-collector && .venv/bin/python -m pytest tests/test_ripple_state.py -v`

Expected: FAIL — `ModuleNotFoundError: No module named 'ripple_state'`.

- [ ] **Step 3: Write the implementation**

Create `ripple_state.py`:

```python
"""Pure interpretation of the ripple log. No I/O lives here.

Two things in this module are easy to get wrong and both fail silently.

1. `---` does not mean OFF and does not mean "uncontrolled". A logged row is
   ONE COMMAND ADDRESSED TO A SUBSET of the digital outputs; every DO the
   command did not address reads `---`, including DOs that are controlled and
   currently hold a state. Observed on 2025-12-03: at 07:19 local only
   DO09..DO12 were commanded OFF, and at 07:22 the rest followed. Between
   those two rows DO13 was still ON. Treating `---` as OFF would invent a
   three-minute shed that never happened; treating it as "no data" would
   leave a hole. So: never emit a point for `---`, and carry state forward.

2. "Curtailed" is the INVERSE of the DO state. `ON` means the load is
   energized -- the utility is PERMITTING it. `OFF` means the utility has SHED
   it. The whole point of this collector is counting the OFF intervals, so
   getting the polarity backwards would invert every conclusion drawn from
   the archive.
"""

from __future__ import annotations

import datetime as dt
from collections.abc import Iterable, Iterator
from dataclasses import dataclass

from influxdb_client import Point, WritePrecision

from minnkota_api import ADDRESSED, DO_INDEX, RippleRow

MEASUREMENT = "ripple_state"
UNKNOWN = "Unknown"


@dataclass(frozen=True)
class DOReading:
    timestamp: dt.datetime
    load_group: str
    do: str
    energized: bool
    state_text: str

    @property
    def curtailed(self) -> bool:
        """True when the utility has shed this load."""
        return not self.energized


def iter_readings(rows: Iterable[RippleRow]) -> Iterator[DOReading]:
    """One reading per ADDRESSED digital output, per row.

    Rows whose DO entry is `---` yield nothing for that output.
    """
    for row in rows:
        for index, value in enumerate(row.do):
            if value not in ADDRESSED:
                continue
            yield DOReading(
                timestamp=row.timestamp,
                load_group=row.load_group,
                do=DO_INDEX[index],
                energized=(value == "ON"),
                state_text=value,
            )


def current_state(rows: Iterable[RippleRow]) -> dict[tuple[str, str], DOReading]:
    """Carry state forward: newest reading per (load_group, do).

    Robust to unordered input -- a later row only wins if its timestamp is
    actually newer, so this is safe to feed the raw API response directly.
    """
    latest: dict[tuple[str, str], DOReading] = {}
    for reading in iter_readings(rows):
        key = (reading.load_group, reading.do)
        held = latest.get(key)
        if held is None or reading.timestamp >= held.timestamp:
            latest[key] = reading
    return latest


def load_name(
    load_group: str, do: str, do_names: dict[str, dict[str, str]]
) -> str:
    """Human label for one output, from the table pinned in the ConfigMap.

    The mapping is PER LOAD GROUP, not global -- DO13 is "Dual Heat" in group
    3.09 and something else entirely elsewhere. Keys are the bare DO number as
    a string ("13"), matching the SPA bundle's own object.
    """
    number = str(int(do.removeprefix("DO")))
    return do_names.get(load_group, {}).get(number, UNKNOWN)


def tier_name(load_group: str, tiers: dict[str, str]) -> str:
    """Programme tier, keyed on the integer prefix of the load group."""
    prefix = load_group.split(".", 1)[0]
    return tiers.get(prefix, UNKNOWN)


def to_points(
    rows: Iterable[RippleRow],
    do_names: dict[str, dict[str, str]],
    tiers: dict[str, str],
    area: str,
) -> list[Point]:
    """Build InfluxDB points -- one per addressed DO per row.

    No transition filtering. The source repeats identical states periodically,
    and writing every observation is both simpler and more faithful: InfluxDB
    dedupes on (measurement, tagset, field, timestamp), so a re-walk of the
    same window is a no-op. Volume is trivial: the entire 342-day history is
    ~116k points across all load groups.

    Fields deliberately mix types (bool / int / string). That is fine as long
    as queries pin `_field` BEFORE any group() -- grouping across a boolean and
    an int fails with "schema collision". `curtailed` exists purely so Grafana
    and Flux can do arithmetic without a bool-to-int dance.
    """
    points: list[Point] = []
    for row in rows:
        for reading in iter_readings([row]):
            point = (
                Point(MEASUREMENT)
                .tag("load_group", reading.load_group)
                .tag("do", reading.do)
                .tag("load_name", load_name(reading.load_group, reading.do, do_names))
                .tag("tier", tier_name(reading.load_group, tiers))
                .tag("substation", row.substation)
                .tag("coop", row.coop)
                .tag("area", area)
                .field("state", reading.energized)
                .field("curtailed", 0 if reading.energized else 1)
                .field("state_text", reading.state_text)
                .time(reading.timestamp, WritePrecision.S)
            )
            points.append(point)
    return points
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ~/Repositories/minnkota-collector && .venv/bin/python -m pytest tests/test_ripple_state.py -v`

Expected: PASS — 15 passed.

- [ ] **Step 5: Verify the shed count against the measured baseline**

This reproduces the headline number end-to-end. Create `scripts/verify_sheds.py`:

```python
"""One-off: reproduce the measured 32 sheds / 152.8 h from the live API."""
import datetime as dt
from zoneinfo import ZoneInfo

from minnkota_api import MinnkotaAPI
from ripple_state import iter_readings

api = MinnkotaAPI("https://api.minnkotadr.com", "redlake", ZoneInfo("America/Chicago"))
rows = {}
cur, end = dt.date(2025, 9, 13), dt.date(2026, 8, 22)
while cur < end:
    for r in api.ripple_list(cur):
        rows[(r.timestamp, r.load_group)] = r
    cur += dt.timedelta(days=2)

readings = sorted(
    (r for r in iter_readings(rows.values()) if r.load_group == "3.09" and r.do == "DO13"),
    key=lambda r: r.timestamp,
)

sheds, start, state = [], None, None
for r in readings:
    if r.curtailed and state is not True:
        start, state = r.timestamp, True
    elif not r.curtailed and state is True:
        sheds.append((start, r.timestamp))
        state = False
    elif not r.curtailed:
        state = False

total = sum((b - a).total_seconds() for a, b in sheds) / 3600
print(f"{len(sheds)} sheds, {total:.1f} hours")
```

Run: `cd ~/Repositories/minnkota-collector && .venv/bin/python scripts/verify_sheds.py`

Expected: `32 sheds, 152.8 hours`. If the count differs, the timestamp parsing or the `---` handling is wrong — stop and fix before proceeding.

- [ ] **Step 6: Commit**

```bash
cd ~/Repositories/minnkota-collector
git add ripple_state.py tests/test_ripple_state.py scripts/verify_sheds.py
git commit -m "feat: ripple state carry-forward and point construction

Never emits a point for an unaddressed ('---') output and carries state
forward per (load_group, do), so a partial command does not read as a shed.
curtailed is the inverse of the DO state: OFF means the utility shed the load."
```

---

## Task 3: InfluxDB archive layer

**Files:**
- Create: `~/Repositories/minnkota-collector/influx_archive.py`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `class InfluxArchive` with `__init__(self, url: str, token: str, org: str, bucket: str, batch_size: int = 5000)`, `write(self, points: list[Point], batch_size: int | None = None, retries: int = 4) -> int`, `newest(self, measurement: str, field: str, lookback_days: int) -> datetime | None`, `close(self) -> None`.

- [ ] **Step 1: Copy the proven implementation from beestat-collector**

```bash
cd ~/Repositories/minnkota-collector
cp ~/Repositories/beestat-collector/influx_archive.py .
```

- [ ] **Step 2: Trim it to what this collector needs**

`series_bounds()` exists in beestat because that collector must discover how far *back* its archive already reaches, chunk by chunk, against a 31-day server-side range cap. None of that applies here: the entire Minnkota history is 172 calls and the daily audit simply re-walks all of it. Delete `series_bounds` and keep `newest`, `write`, and the two helpers.

Replace the module docstring with:

```python
"""InfluxDB side of the archive: idempotent writes and a freshness read.

The collector holds NO state of its own -- no PVC, no checkpoint file. It
re-fetches and relies on an InfluxDB point being identified by
(measurement, tag set, field, timestamp), so re-writing a row that is already
present is a no-op rather than a duplicate. Overlapping re-fetches are
therefore free and gap-filling falls out of the design.

Unlike beestat-collector there is no backward watermark here. That collector
needs one because it walks a year of 5-minute history in 30-day chunks against
a server-side range cap. The Minnkota history is 342 days reachable in 172
calls (~68 s), so the daily audit just re-walks the whole thing. Simpler beats
clever when the whole dataset costs a minute to refetch.
"""
```

Then delete the `series_bounds` method in its entirety.

- [ ] **Step 3: Verify it imports and the trim is clean**

Run:

```bash
cd ~/Repositories/minnkota-collector
.venv/bin/python -c "
import influx_archive, inspect
names = [n for n, _ in inspect.getmembers(influx_archive.InfluxArchive, inspect.isfunction)]
assert 'series_bounds' not in names, names
assert {'write', 'newest', 'close'} <= set(names), names
print('ok:', sorted(n for n in names if not n.startswith('_')))
"
```

Expected: `ok: ['close', 'newest', 'write']`.

- [ ] **Step 4: Commit**

```bash
cd ~/Repositories/minnkota-collector
git add influx_archive.py
git commit -m "feat: InfluxDB archive layer adapted from beestat-collector

Drops series_bounds: with the whole 342-day history reachable in 172 calls,
the daily audit re-walks everything rather than tracking a backward watermark."
```

---

## Task 4: MQTT publisher with Home Assistant discovery

**Files:**
- Create: `~/Repositories/minnkota-collector/mqtt_publish.py`
- Test: `~/Repositories/minnkota-collector/tests/test_mqtt_publish.py`

**Interfaces:**
- Consumes: `DOReading` from `ripple_state`.
- Produces:
  - `@dataclass(frozen=True) EntitySpec` with `slug: str`, `name: str`, `component: str`, `device_class: str | None`, `icon: str | None`.
  - `discovery_payload(spec: EntitySpec, node_id: str, discovery_prefix: str, expire_after: int) -> tuple[str, dict]` — returns `(topic, payload)`.
  - `binary_state_payload(reading: DOReading | None) -> str` — `"ON"` when curtailed, `"OFF"` when energized, `"OFF"` when the reading is missing.
  - `class HAPublisher` with `__init__(self, host, port, username, password, client_id, discovery_prefix="homeassistant", node_id="minnkota", expire_after=1800)`, `connect()`, `publish_discovery(specs: list[EntitySpec])`, `publish_state(slug: str, payload: str)`, `publish_attributes(slug: str, attrs: dict)`, `disconnect()`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_mqtt_publish.py`:

```python
import datetime as dt
import json

from ripple_state import DOReading
from mqtt_publish import (
    EntitySpec,
    binary_state_payload,
    discovery_payload,
    state_topic,
)

SPEC = EntitySpec(
    slug="heat_pump_curtailed",
    name="Heat pump curtailed",
    component="binary_sensor",
    device_class="problem",
    icon=None,
)


def reading(energized):
    return DOReading(
        timestamp=dt.datetime(2025, 12, 3, 13, 22, 0),
        load_group="3.09",
        do="DO13",
        energized=energized,
        state_text="ON" if energized else "OFF",
    )


def test_curtailed_is_on_when_the_load_is_off():
    # The polarity trap. OFF at the utility == the load is shed == the HA
    # binary_sensor should read ON ("there is a problem").
    assert binary_state_payload(reading(energized=False)) == "ON"


def test_curtailed_is_off_when_the_load_is_energized():
    assert binary_state_payload(reading(energized=True)) == "OFF"


def test_missing_reading_is_not_reported_as_curtailed():
    # Absence of data must never look like a shed -- that would drive the
    # thermostat to propane for no reason.
    assert binary_state_payload(None) == "OFF"


def test_discovery_topic_follows_the_ha_convention():
    topic, _ = discovery_payload(SPEC, "minnkota", "homeassistant", 1800)
    assert topic == "homeassistant/binary_sensor/minnkota/heat_pump_curtailed/config"


def test_discovery_payload_has_a_stable_unique_id():
    _, payload = discovery_payload(SPEC, "minnkota", "homeassistant", 1800)
    assert payload["unique_id"] == "minnkota_heat_pump_curtailed"
    assert payload["object_id"] == "minnkota_heat_pump_curtailed"


def test_discovery_payload_points_at_the_state_topic():
    _, payload = discovery_payload(SPEC, "minnkota", "homeassistant", 1800)
    assert payload["state_topic"] == state_topic("minnkota", "heat_pump_curtailed")
    assert payload["state_topic"] == "minnkota/heat_pump_curtailed/state"


def test_discovery_payload_sets_expire_after():
    # A CronJob pod exits, so an MQTT last-will cannot express liveness.
    # expire_after is what makes HA mark the entity unavailable if the
    # collector dies, instead of trusting a stale retained value forever.
    _, payload = discovery_payload(SPEC, "minnkota", "homeassistant", 1800)
    assert payload["expire_after"] == 1800


def test_discovery_payload_groups_entities_under_one_device():
    _, payload = discovery_payload(SPEC, "minnkota", "homeassistant", 1800)
    device = payload["device"]
    assert device["identifiers"] == ["minnkota_demand_response"]
    assert device["name"] == "Minnkota Demand Response"


def test_discovery_payload_carries_device_class():
    _, payload = discovery_payload(SPEC, "minnkota", "homeassistant", 1800)
    assert payload["device_class"] == "problem"


def test_discovery_payload_omits_null_device_class():
    spec = EntitySpec("plan", "DR plan", "sensor", None, "mdi:transmission-tower")
    _, payload = discovery_payload(spec, "minnkota", "homeassistant", 1800)
    assert "device_class" not in payload
    assert payload["icon"] == "mdi:transmission-tower"


def test_discovery_payload_is_json_serialisable():
    _, payload = discovery_payload(SPEC, "minnkota", "homeassistant", 1800)
    json.dumps(payload)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/Repositories/minnkota-collector && .venv/bin/python -m pytest tests/test_mqtt_publish.py -v`

Expected: FAIL — `ModuleNotFoundError: No module named 'mqtt_publish'`.

- [ ] **Step 3: Write the implementation**

Create `mqtt_publish.py`:

```python
"""Publish current demand-response state to Home Assistant over MQTT.

Everything here is published RETAINED. A CronJob pod exits after each run, so
without retain the broker would hold nothing between runs and Home Assistant
would show `unknown` after any restart.

Retain alone would be dangerous, though: a retained value survives the
collector dying, so a stale "not curtailed" could persist indefinitely and the
automation would never know it had gone blind. `expire_after` on the discovery
payload is the counterweight -- HA marks the entity `unavailable` once no
update has arrived within the window. With a 5-minute cadence, 1800 s is six
missed runs.

Discovery config is published on every run rather than once. It is idempotent,
it costs one small retained message per entity, and it means a broker that
loses its retained store (or a fresh HA install) recovers without intervention.

paho-mqtt 2.x requires the versioned callback API. The bare `mqtt.Client()`
constructor from 1.x still exists but emits a deprecation path that behaves
differently on connect; pass CallbackAPIVersion.VERSION2 explicitly.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass

import paho.mqtt.client as mqtt

from ripple_state import DOReading

log = logging.getLogger(__name__)

DEVICE_ID = "minnkota_demand_response"
DEVICE_NAME = "Minnkota Demand Response"


class MQTTError(RuntimeError):
    """Any failure publishing to the broker."""


@dataclass(frozen=True)
class EntitySpec:
    slug: str
    name: str
    component: str  # "binary_sensor" or "sensor"
    device_class: str | None = None
    icon: str | None = None


def state_topic(node_id: str, slug: str) -> str:
    return f"{node_id}/{slug}/state"


def attributes_topic(node_id: str, slug: str) -> str:
    return f"{node_id}/{slug}/attributes"


def discovery_payload(
    spec: EntitySpec, node_id: str, discovery_prefix: str, expire_after: int
) -> tuple[str, dict]:
    """Build the (topic, payload) pair for one HA MQTT discovery entity."""
    unique = f"{node_id}_{spec.slug}"
    topic = f"{discovery_prefix}/{spec.component}/{node_id}/{spec.slug}/config"
    payload: dict = {
        "name": spec.name,
        "unique_id": unique,
        "object_id": unique,
        "state_topic": state_topic(node_id, spec.slug),
        "json_attributes_topic": attributes_topic(node_id, spec.slug),
        "expire_after": expire_after,
        "device": {
            "identifiers": [DEVICE_ID],
            "name": DEVICE_NAME,
            "manufacturer": "Minnkota Power Cooperative",
            "model": "Ripple load management",
        },
    }
    if spec.component == "binary_sensor":
        payload["payload_on"] = "ON"
        payload["payload_off"] = "OFF"
    if spec.device_class:
        payload["device_class"] = spec.device_class
    if spec.icon:
        payload["icon"] = spec.icon
    return topic, payload


def binary_state_payload(reading: DOReading | None) -> str:
    """ON == the utility has shed this load.

    A missing reading returns OFF, never ON. Absence of evidence is not
    evidence of a shed, and a false ON would push the house onto propane for
    no reason.
    """
    if reading is None:
        return "OFF"
    return "ON" if reading.curtailed else "OFF"


class HAPublisher:
    def __init__(
        self,
        host: str,
        port: int,
        username: str,
        password: str,
        client_id: str = "minnkota-collector",
        discovery_prefix: str = "homeassistant",
        node_id: str = "minnkota",
        expire_after: int = 1800,
        timeout: int = 15,
    ):
        self._node_id = node_id
        self._discovery_prefix = discovery_prefix
        self._expire_after = expire_after
        self._timeout = timeout
        self._host = host
        self._port = port
        self._client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2, client_id=client_id
        )
        if username:
            self._client.username_pw_set(username, password)

    def connect(self) -> None:
        try:
            self._client.connect(self._host, self._port, keepalive=self._timeout)
            self._client.loop_start()
        except OSError as exc:
            raise MQTTError(f"connect to {self._host}:{self._port} failed: {exc}") from exc

    def disconnect(self) -> None:
        self._client.loop_stop()
        self._client.disconnect()

    def _publish(self, topic: str, payload: str) -> None:
        info = self._client.publish(topic, payload, qos=1, retain=True)
        info.wait_for_publish(timeout=self._timeout)
        if not info.is_published():
            raise MQTTError(f"publish to {topic} was not confirmed")

    def publish_discovery(self, specs: list[EntitySpec]) -> None:
        for spec in specs:
            topic, payload = discovery_payload(
                spec, self._node_id, self._discovery_prefix, self._expire_after
            )
            self._publish(topic, json.dumps(payload))

    def publish_state(self, slug: str, payload: str) -> None:
        self._publish(state_topic(self._node_id, slug), payload)

    def publish_attributes(self, slug: str, attrs: dict) -> None:
        self._publish(attributes_topic(self._node_id, slug), json.dumps(attrs))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ~/Repositories/minnkota-collector && .venv/bin/python -m pytest tests/test_mqtt_publish.py -v`

Expected: PASS — 11 passed.

- [ ] **Step 5: Run the whole suite**

Run: `cd ~/Repositories/minnkota-collector && .venv/bin/python -m pytest -v`

Expected: PASS — 34 passed.

- [ ] **Step 6: Commit**

```bash
cd ~/Repositories/minnkota-collector
git add mqtt_publish.py tests/test_mqtt_publish.py
git commit -m "feat: MQTT publisher with Home Assistant discovery

Retained + expire_after: retain survives the CronJob pod exiting, expire_after
stops a stale retained value from looking live if the collector dies. A missing
reading publishes OFF, never ON -- absence of data must not force propane."
```

---

## Task 5: Collector orchestration

**Files:**
- Create: `~/Repositories/minnkota-collector/collector.py`
- Create: `~/Repositories/minnkota-collector/README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: a `main()` entry point with the documented exit codes.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 2 | Configuration error (missing/invalid env) |
| 3 | Minnkota API error |
| 4 | Audit ran but the API returned no rows for **any** load group over `STALE_FAIL_DAYS` — the source looks dead |
| 5 | InfluxDB error |
| 6 | MQTT error |

Exit 4 deliberately does **not** gate on the user's own load groups. Measured: groups 2.06 and 3.09 went 16 consecutive days with no command in May 2026, and that is normal off-season behaviour. Across *all* groups the longest quiet run was 6 days, so a 10-day window has margin. The check only runs in audit mode, because the 5-minute job fetches a 2-day window and cannot see 10 days.

- [ ] **Step 1: Write the implementation**

Create `collector.py`:

```python
"""Archive Minnkota demand-response state and publish it to Home Assistant.

Two run modes, selected by AUDIT_MODE:

  normal (every 5 min) -- fetch the trailing 2-day ripple window plus the small
      plan/schedule/system endpoints, write them, and publish current state to
      MQTT. This is the mode that feeds the aux-heat automation, so it is cheap
      and frequent: 4 API calls per run.

  audit (daily)        -- re-walk the ENTIRE retained history from
      BACKFILL_START_DATE. 172 calls, ~68 s. Writes are idempotent, so this
      costs nothing but repairs any interior gap the trailing window stepped
      over. It also runs the freshness gate.

The collector holds no state. Where to resume is not tracked because there is
nothing to resume: the normal run always fetches "the last two days" and the
audit always fetches "everything".
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
import sys
import time
from zoneinfo import ZoneInfo

from influxdb_client import Point, WritePrecision

from influx_archive import InfluxArchive
from minnkota_api import MinnkotaAPI, MinnkotaAPIError
from mqtt_publish import (
    EntitySpec,
    HAPublisher,
    MQTTError,
    binary_state_payload,
)
from ripple_state import current_state, to_points

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s"
)
log = logging.getLogger("minnkota-collector")

EXIT_OK = 0
EXIT_CONFIG = 2
EXIT_API = 3
EXIT_STALE = 4
EXIT_INFLUX = 5
EXIT_MQTT = 6


class ConfigError(RuntimeError):
    pass


def env(name: str, default: str | None = None, required: bool = False) -> str:
    value = os.environ.get(name, default)
    if required and not value:
        raise ConfigError(f"{name} is required")
    return value or ""


def env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except ValueError as exc:
        raise ConfigError(f"{name} must be an integer") from exc


def env_json(name: str, required: bool = True) -> dict:
    raw = env(name, required=required)
    try:
        return json.loads(raw) if raw else {}
    except json.JSONDecodeError as exc:
        raise ConfigError(f"{name} is not valid JSON: {exc}") from exc


def env_bool(name: str, default: bool = False) -> bool:
    return os.environ.get(name, str(default)).strip().lower() in {"1", "true", "yes"}


def _utcnow() -> dt.datetime:
    """Naive UTC 'now'.

    datetime.utcnow() is deprecated in 3.12 and, worse, returns a naive value
    that merely happens to be UTC -- which reads as a bug the first time
    someone compares it against an aware datetime. RippleRow.timestamp is
    naive UTC by design, so be explicit about matching it.
    """
    return dt.datetime.now(dt.UTC).replace(tzinfo=None)


# ----------------------------------------------------------------------
# Entities published to Home Assistant
# ----------------------------------------------------------------------

ENTITIES = [
    EntitySpec(
        "heat_pump_curtailed",
        "Heat pump curtailed",
        "binary_sensor",
        device_class="problem",
    ),
    EntitySpec(
        "evse_curtailed",
        "EV charging curtailed",
        "binary_sensor",
        device_class="problem",
    ),
    EntitySpec(
        "dr_expected",
        "Demand response expected",
        "binary_sensor",
        icon="mdi:transmission-tower",
    ),
    EntitySpec(
        "dr_plan",
        "Demand response plan",
        "sensor",
        icon="mdi:message-text",
    ),
    EntitySpec(
        "last_run",
        "Collector last run",
        "sensor",
        device_class="timestamp",
    ),
]


def fetch_window(api: MinnkotaAPI, start: dt.date, end: dt.date) -> dict:
    """Walk [start, end) at a 2-day stride, deduplicating on (timestamp, lg).

    The API returns a TWO-day window per call, so a 2-day stride covers the
    range exactly once. Duplicates across window boundaries are collapsed here
    rather than relied on InfluxDB to absorb, purely so the logged row count
    means something.
    """
    rows: dict[tuple[dt.datetime, str], object] = {}
    cursor = start
    calls = 0
    while cursor < end:
        for row in api.ripple_list(cursor):
            rows[(row.timestamp, row.load_group)] = row
        calls += 1
        cursor += dt.timedelta(days=2)
    log.info("fetched %d unique rows in %d API calls", len(rows), calls)
    return rows


def side_channel_points(api: MinnkotaAPI, tz: ZoneInfo) -> tuple[list[Point], dict]:
    """Plan / schedule / system-condition -> points, plus the newest plan.

    These are small, cheap, and change at most daily. The newest plan entry is
    returned separately because it drives two Home Assistant entities.
    """
    points: list[Point] = []
    newest_plan: dict = {}

    plans = api.plan_list()
    if plans:
        newest_plan = max(plans, key=lambda p: p.get("dateTime", ""))
    for plan in plans:
        stamp = plan.get("dateTime")
        if not stamp:
            continue
        when = dt.datetime.fromisoformat(stamp).astimezone(dt.UTC).replace(tzinfo=None)
        points.append(
            Point("dr_plan")
            .tag("plan_id", str(plan.get("id", "")))
            .field("message", str(plan.get("message", "")))
            .field("dr_expected", bool(plan.get("isDemandResponseExpected", False)))
            .field("enabled", bool(plan.get("enabled", False)))
            .time(when, WritePrecision.S)
        )

    for item in api.schedule_list():
        stamp = item.get("dateTime")
        if not stamp:
            continue
        when = dt.datetime.fromisoformat(stamp).replace(tzinfo=tz)
        when = when.astimezone(dt.UTC).replace(tzinfo=None)
        points.append(
            Point("dr_schedule")
            .tag("program_type", str(item.get("programType", "")))
            .tag("property_type", str(item.get("propertyType", "")))
            .tag("schedule_day", str(item.get("scheduleDay", "")))
            .field("status", str(item.get("status", "")))
            .field("probability", str(item.get("probability", "")))
            .field("expected_time", str(item.get("expectedTime", "")))
            .field("enabled", bool(item.get("enabled", False)))
            .field("priority", int(item.get("priority", 0)))
            .time(when, WritePrecision.S)
        )

    for item in api.system_condition():
        stamp = item.get("dateTime")
        if not stamp:
            continue
        # This endpoint uses MM/DD/YYYY, unlike every other one.
        day = dt.datetime.strptime(stamp, "%m/%d/%Y").replace(tzinfo=tz)
        points.append(
            Point("system_condition")
            .tag("condition_id", str(item.get("id", "")))
            .field("percentage", float(item.get("percentage", 0.0)))
            .field("enabled", bool(item.get("enabled", False)))
            .time(day.astimezone(dt.UTC).replace(tzinfo=None), WritePrecision.S)
        )

    return points, newest_plan


def main() -> int:
    started = time.monotonic()
    try:
        tz = ZoneInfo(env("SOURCE_TZ", "America/Chicago"))
        api = MinnkotaAPI(
            base_url=env("MINNKOTA_BASE_URL", "https://api.minnkotadr.com"),
            area=env("MINNKOTA_AREA", "redlake"),
            tz=tz,
            min_interval_seconds=float(env("MIN_INTERVAL_SECONDS", "0.15")),
        )
        do_names = env_json("DO_NAME_MAP_JSON")
        tiers = env_json("TIER_NAME_MAP_JSON")
        area = env("MINNKOTA_AREA", "redlake")

        audit = env_bool("AUDIT_MODE", False)
        lookback_days = env_int("LOOKBACK_DAYS", 3)
        stale_fail_days = env_int("STALE_FAIL_DAYS", 10)
        backfill_start = dt.date.fromisoformat(env("BACKFILL_START_DATE", "2025-09-13"))

        hp_group = env("HEAT_PUMP_LOAD_GROUP", "3.09")
        hp_do = env("HEAT_PUMP_DO", "DO13")
        evse_group = env("EVSE_LOAD_GROUP", "2.06")
        evse_do = env("EVSE_DO", "DO09")

        influx = InfluxArchive(
            url=env("INFLUXDB_URL", required=True),
            token=env("INFLUXDB_TOKEN", required=True),
            org=env("INFLUXDB_ORG", "homelab"),
            bucket=env("INFLUXDB_BUCKET", "minnkota"),
        )
    except (ConfigError, ValueError) as exc:
        log.error("configuration error: %s", exc)
        return EXIT_CONFIG

    today = dt.datetime.now(tz).date()

    # ------------------------------------------------------------------
    # Fetch
    # ------------------------------------------------------------------
    try:
        if audit:
            log.info("audit mode: re-walking %s .. %s", backfill_start, today)
            rows = fetch_window(api, backfill_start, today + dt.timedelta(days=1))
        else:
            start = today - dt.timedelta(days=lookback_days)
            rows = fetch_window(api, start, today + dt.timedelta(days=1))
        extra_points, newest_plan = side_channel_points(api, tz)
    except MinnkotaAPIError as exc:
        log.error("Minnkota API error: %s", exc)
        influx.close()
        return EXIT_API

    # ------------------------------------------------------------------
    # Freshness gate (audit only)
    # ------------------------------------------------------------------
    if audit:
        cutoff = _utcnow() - dt.timedelta(days=stale_fail_days)
        recent = [r for r in rows.values() if r.timestamp >= cutoff]
        if not recent:
            log.error(
                "no ripple rows for ANY load group in the last %d days — "
                "the source looks dead",
                stale_fail_days,
            )
            influx.close()
            return EXIT_STALE

    # ------------------------------------------------------------------
    # Write
    # ------------------------------------------------------------------
    try:
        points = to_points(rows.values(), do_names, tiers, area)
        points.extend(extra_points)
        # Small batches: an 11-month backfill spans ~50 weekly shard groups and
        # a single large batch asks InfluxDB to create all of them at once,
        # which times out server-side. See reference-influxdb-write-traps.
        written = influx.write(points, batch_size=env_int("WRITE_BATCH_SIZE", 2000))
        elapsed = time.monotonic() - started
        influx.write(
            [
                Point("collector_run")
                .tag("mode", "audit" if audit else "incremental")
                .field("rows_fetched", len(rows))
                .field("points_written", written)
                .field("duration_seconds", float(elapsed))
                .time(_utcnow(), WritePrecision.S)
            ]
        )
        log.info("wrote %d points in %.1fs", written, elapsed)
    except Exception as exc:  # influxdb-client raises a wide variety
        log.error("InfluxDB error: %s", exc)
        influx.close()
        return EXIT_INFLUX
    finally:
        influx.close()

    # ------------------------------------------------------------------
    # Publish to Home Assistant
    # ------------------------------------------------------------------
    if not env_bool("MQTT_ENABLED", True):
        log.info("MQTT disabled; done")
        return EXIT_OK

    try:
        publisher = HAPublisher(
            host=env("MQTT_HOST", required=True),
            port=env_int("MQTT_PORT", 1883),
            username=env("MQTT_USER"),
            password=env("MQTT_PASSWORD"),
            discovery_prefix=env("MQTT_DISCOVERY_PREFIX", "homeassistant"),
            node_id=env("MQTT_NODE_ID", "minnkota"),
            expire_after=env_int("MQTT_EXPIRE_AFTER", 1800),
        )
        publisher.connect()

        state = current_state(rows.values())
        hp = state.get((hp_group, hp_do))
        evse = state.get((evse_group, evse_do))

        publisher.publish_discovery(ENTITIES)
        publisher.publish_state("heat_pump_curtailed", binary_state_payload(hp))
        publisher.publish_state("evse_curtailed", binary_state_payload(evse))
        publisher.publish_state(
            "dr_expected",
            "ON" if newest_plan.get("isDemandResponseExpected") else "OFF",
        )
        publisher.publish_state(
            "dr_plan", str(newest_plan.get("message", ""))[:255]
        )
        publisher.publish_state(
            "last_run", dt.datetime.now(dt.UTC).isoformat(timespec="seconds")
        )

        if hp:
            publisher.publish_attributes(
                "heat_pump_curtailed",
                {
                    "load_group": hp.load_group,
                    "digital_output": hp.do,
                    "utility_state": hp.state_text,
                    "last_change_utc": hp.timestamp.isoformat(timespec="seconds"),
                },
            )
        if evse:
            publisher.publish_attributes(
                "evse_curtailed",
                {
                    "load_group": evse.load_group,
                    "digital_output": evse.do,
                    "utility_state": evse.state_text,
                    "last_change_utc": evse.timestamp.isoformat(timespec="seconds"),
                },
            )

        publisher.disconnect()
        log.info(
            "published: heat_pump=%s evse=%s",
            binary_state_payload(hp),
            binary_state_payload(evse),
        )
    except MQTTError as exc:
        log.error("MQTT error: %s", exc)
        return EXIT_MQTT

    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Verify it runs against the live API without writing anywhere**

Run:

```bash
cd ~/Repositories/minnkota-collector
INFLUXDB_URL=http://localhost:1 INFLUXDB_TOKEN=x MQTT_ENABLED=false \
DO_NAME_MAP_JSON='{"3.09":{"13":"Dual Heat"}}' \
TIER_NAME_MAP_JSON='{"3":"Long-Term"}' \
.venv/bin/python collector.py; echo "exit=$?"
```

Expected: it fetches from the live API, then fails on the unreachable InfluxDB with `exit=5`. That proves config parsing, the API path, and point construction all work, and that InfluxDB failure is correctly classified.

- [ ] **Step 3: Write the README**

Create `README.md` documenting: what the collector does and why (the balance-point problem), the exit-code table above, every environment variable, the measurement/tag/field schema, the two run modes, and — prominently — the three traps from Global Constraints (`---` semantics, local-wall-clock timestamps, curtailed-is-the-inverse-of-state). Include the measured baseline table so a future reader can tell whether a re-run agrees with reality.

- [ ] **Step 4: Run the whole suite**

Run: `cd ~/Repositories/minnkota-collector && .venv/bin/python -m pytest -v`

Expected: PASS — 34 passed.

- [ ] **Step 5: Commit**

```bash
cd ~/Repositories/minnkota-collector
git add collector.py README.md
git commit -m "feat: collector orchestration with incremental and audit modes

Exit 4 (source looks dead) gates on ALL load groups over 10 days, never on the
user's own groups: 2.06/3.09 legitimately go 16 days without a command in the
off-season, so a per-group gate would alert every summer."
```

---

## Task 6: Container build and first image

**Files:**
- Create: `~/Repositories/minnkota-collector/Dockerfile`
- Create: `~/Repositories/minnkota-collector/.dockerignore`
- Create: `~/Repositories/minnkota-collector/.drone.yml`

**Interfaces:**
- Consumes: all source modules from Tasks 1–5.
- Produces: image `gitea.derekjacobs.dev/bluevulpine/minnkota-collector:<build>-<sha8>`.

- [ ] **Step 1: Create the Dockerfile**

```dockerfile
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/tmp

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY collector.py minnkota_api.py ripple_state.py influx_archive.py mqtt_publish.py ./

# Run as a non-root user (uid/gid 1000) to satisfy runAsNonRoot.
RUN groupadd --gid 1000 app \
    && useradd --uid 1000 --gid 1000 --no-create-home --shell /usr/sbin/nologin app \
    && chown -R app:app /app
USER 1000

CMD ["python", "collector.py"]
```

- [ ] **Step 2: Create .dockerignore**

```
# The image only needs requirements.txt + the app modules (see Dockerfile).
# Whitelist them and exclude everything else from the kaniko build context.
*
!requirements.txt
!collector.py
!minnkota_api.py
!ripple_state.py
!influx_archive.py
!mqtt_publish.py
```

- [ ] **Step 3: Create .drone.yml**

```yaml
---
kind: pipeline
type: kubernetes
name: build-and-push

trigger:
  branch:
    - main
  event:
    - push

steps:
  - name: build-and-push
    image: plugins/kaniko
    settings:
      registry: gitea.derekjacobs.dev
      repo: gitea.derekjacobs.dev/bluevulpine/minnkota-collector
      username:
        from_secret: registry_user
      password:
        from_secret: registry_token
      # <build-number>-<sha8>: immutable and sortable, so Flux image automation
      # can pick the newest build. (Gitea's :latest tag is immutable/frozen, and
      # bare SHAs aren't orderable — both unusable for automated promotion.)
      tags:
        - ${DRONE_BUILD_NUMBER}-${DRONE_COMMIT_SHA:0:8}
      dockerfile: Dockerfile
      context: .
```

- [ ] **Step 4: Build locally to prove the Dockerfile is sound**

This host has Apple's `container` CLI (there is no Docker daemon). It must be started before the first command or cold calls fail with an XPC error.

```bash
container system start
cd ~/Repositories/minnkota-collector
container build -t minnkota-collector:test .
```

Expected: build succeeds. First run takes ~78 s.

- [ ] **Step 5: Enable Drone for the repo and push**

In the Drone UI, activate `bluevulpine/minnkota-collector` and confirm the `registry_user` / `registry_token` secrets are present (copy the settings from `beestat-collector`).

```bash
cd ~/Repositories/minnkota-collector
git add Dockerfile .dockerignore .drone.yml
git commit -m "build: kaniko image build via Drone"
git push origin main
```

- [ ] **Step 6: Verify the image landed**

Watch the Drone build to completion, then confirm the tag exists in the Gitea registry UI under `bluevulpine/minnkota-collector`. **Record the exact tag** (e.g. `1-a1b2c3d4`) — Task 8's CronJob needs it as the initial image ref.

---

## Task 7: Cluster prerequisites — bucket, tokens, MQTT credentials

No git changes. These are one-time operational steps that Tasks 8–11 depend on. **No secret value may appear in a transcript, a file, or a commit.**

- [ ] **Step 1: Create the InfluxDB bucket**

```bash
kubectl -n database exec -it deploy/influxdb -- sh -c \
  'influx bucket create --name minnkota --org homelab --retention 0 \
     --token "$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN"'
```

Expected: prints the new bucket's ID. Retention `0` = infinite.

- [ ] **Step 2: Create a read/write token for the collector**

The collector needs **read as well as write** — `newest()` queries the bucket, and the audit's freshness reasoning depends on being able to read back.

```bash
kubectl -n database exec -it deploy/influxdb -- sh -c \
  'influx auth create --org homelab \
     --read-bucket <BUCKET_ID> --write-bucket <BUCKET_ID> \
     --description "minnkota-collector" \
     --token "$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN"'
```

- [ ] **Step 3: Create a read-only token for Grafana**

```bash
kubectl -n database exec -it deploy/influxdb -- sh -c \
  'influx auth create --org homelab --read-bucket <BUCKET_ID> \
     --description "grafana-minnkota-ro" \
     --token "$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN"'
```

- [ ] **Step 4: Store both tokens plus MQTT credentials in OpenBao**

Choose a fresh MQTT password for the collector. Then:

```bash
bao kv put secret/minnkota-collector \
  Minnkota__InfluxdbToken='<collector token>' \
  Minnkota__Mqtt__User='minnkota-collector' \
  Minnkota__Mqtt__Password='<new password>'

bao kv patch secret/grafana \
  Grafana__InfluxdbMinnkotaToken='<grafana read-only token>'
```

- [ ] **Step 5: Add the MQTT user to the mosquitto broker**

The broker's `passwd.conf` and `acl.conf` live in the `mosquitto` OpenBao key. Open it, add the `minnkota-collector` user with the same password, and grant it write on the topics it publishes:

```
user minnkota-collector
topic write minnkota/#
topic write homeassistant/binary_sensor/minnkota/#
topic write homeassistant/sensor/minnkota/#
```

Restart mosquitto so it reloads:

```bash
kubectl -n home rollout restart deployment/mosquitto
kubectl -n home rollout status deployment/mosquitto
```

- [ ] **Step 6: Verify the credentials work end-to-end**

```bash
kubectl -n home run mqtt-check --rm -it --restart=Never \
  --image=eclipse-mosquitto:2 -- \
  mosquitto_pub -h mosquitto.home.svc.cluster.local -p 1883 \
    -u minnkota-collector -P '<new password>' \
    -t 'minnkota/selftest/state' -m 'OK' -q 1 -d
```

Expected: a successful CONNACK and PUBLISH, no `Connection Refused: not authorised`.

---

## Task 8: Kubernetes manifests

**Files:**
- Create: `kubernetes/apps/home/minnkota-collector/ks.yaml`
- Create: `kubernetes/apps/home/minnkota-collector/app/kustomization.yaml`
- Create: `kubernetes/apps/home/minnkota-collector/app/configmap.yaml`
- Create: `kubernetes/apps/home/minnkota-collector/app/externalsecret.yaml`
- Create: `kubernetes/apps/home/minnkota-collector/app/serviceaccount.yaml`
- Create: `kubernetes/apps/home/minnkota-collector/app/cronjob.yaml`
- Modify: `kubernetes/apps/home/kustomization.yaml`

**Interfaces:**
- Consumes: the image tag from Task 6 Step 6; the OpenBao keys from Task 7.
- Produces: a running CronJob named `minnkota-collector` and `minnkota-collector-audit` in namespace `home`.

- [ ] **Step 1: Create ks.yaml**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app minnkota-collector
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn:
    - name: external-secrets-openbao-store
      namespace: external-secrets
  interval: 1h
  path: ./kubernetes/apps/home/minnkota-collector/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: home-kubernetes
    namespace: flux-system
  targetNamespace: home
  wait: false
  postBuild:
    substitute:
      APP: *app
```

- [ ] **Step 2: Create app/kustomization.yaml**

The dashboard file is added in Task 11; create it without the generator for now.

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
  - externalsecret.yaml
  - serviceaccount.yaml
  - cronjob.yaml
  - prometheusrule.yaml
```

**Note:** `prometheusrule.yaml` is created in Task 10. Until then, omit that line or the build fails. Add it back as part of Task 10.

- [ ] **Step 3: Create app/configmap.yaml**

The DO→name and tier tables are pinned here verbatim from the SPA bundle object `UP` / `WP` (bundle `main.1b282323.js`, read 2026-08-21). They are configuration to be re-verified after a site redeploy, not constants.

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: minnkota-collector-config
data:
  INFLUXDB_URL: "http://influxdb.database.svc.cluster.local:8086"
  INFLUXDB_ORG: "homelab"
  INFLUXDB_BUCKET: "minnkota"

  MINNKOTA_BASE_URL: "https://api.minnkotadr.com"
  # Required by the server, but inert: every area returns identical data and
  # every row is labelled coop "Red River" / substation "Ada". Load groups are
  # globally unique across the ripple system, so filtering happens on `lg`.
  MINNKOTA_AREA: "redlake"

  # The API emits YYMMDDTHHMMSS in LOCAL WALL-CLOCK time and follows DST.
  # Evidence: through Nov 2025 load group 2.06 sheds at exactly 07:10/17:10
  # daily, unchanged across the 2025-11-02 DST boundary. Reading these as UTC
  # shifts every event 5-6h and destroys the join against beestat runtime.
  SOURCE_TZ: "America/Chicago"

  # First day the API serves. 2025-09-12 returns zero rows; 2025-09-13 returns
  # 19. The full walk is 172 calls / ~68s, so the daily audit re-reads all of it.
  BACKFILL_START_DATE: "2025-09-13"

  # Trailing window for the 5-minute job. The API returns a 2-day window per
  # call, so 3 days is 2 calls — enough overlap to absorb a missed run without
  # making the frequent job expensive.
  LOOKBACK_DAYS: "3"

  # Audit-only freshness gate. Deliberately generous and deliberately scoped to
  # ALL load groups: the user's own groups (2.06/3.09) went 16 consecutive days
  # without a command in May 2026, which is normal off-season behaviour. Across
  # all groups the longest measured quiet run was 6 days.
  STALE_FAIL_DAYS: "10"

  # Politeness floor against an unauthenticated public utility API. No rate
  # limit has ever been observed; this is courtesy, not a documented cap.
  MIN_INTERVAL_SECONDS: "0.15"

  # An 11-month backfill spans ~50 weekly shard groups. One large batch asks
  # InfluxDB to create them all at once and times out server-side.
  WRITE_BATCH_SIZE: "2000"

  # The two loads that matter. Tagging is on the stable DO index, never the
  # human name, so correcting a label does not fork the series.
  HEAT_PUMP_LOAD_GROUP: "3.09"
  HEAT_PUMP_DO: "DO13"
  EVSE_LOAD_GROUP: "2.06"
  EVSE_DO: "DO09"

  MQTT_ENABLED: "true"
  MQTT_HOST: "mosquitto.home.svc.cluster.local"
  MQTT_PORT: "1883"
  MQTT_DISCOVERY_PREFIX: "homeassistant"
  MQTT_NODE_ID: "minnkota"
  # Six missed 5-minute runs. A CronJob pod exits, so an MQTT last-will cannot
  # express liveness; expire_after is what stops a stale retained value from
  # looking live forever if the collector dies.
  MQTT_EXPIRE_AFTER: "1800"

  # Extracted from the SPA bundle object `UP` (main.1b282323.js, 2026-08-21).
  # PER LOAD GROUP, not global — DO13 is "Dual Heat" in 3.09 and something else
  # entirely elsewhere. Re-verify after a site redeploy; the hash will change.
  DO_NAME_MAP_JSON: >-
    {
      "2.06": {"9": "Battery Storage", "16": "Battery Storage"},
      "3.09": {"9": "Dual Heat", "10": "Dual Heat", "11": "Dual Heat",
               "12": "Dual Heat", "13": "Dual Heat", "14": "Dual Heat",
               "15": "Dual Heat", "16": "Dual Heat", "17": "Misc Heat 3",
               "18": "Misc Heat 3", "24": "Ind. Contr Loads 3"},
      "3.01": {"9": "Dual Heat", "10": "Dual Heat", "11": "Dual Heat",
               "12": "Dual Heat", "13": "Dual Heat", "14": "Dual Heat",
               "15": "Dual Heat", "16": "Dual Heat", "17": "Misc Heat 3",
               "18": "Misc Heat 3", "19": "Dual Heat", "20": "Dual Heat",
               "21": "Dual Heat", "22": "Dual Heat",
               "24": "Ind. Controlled Loads 3"},
      "1.01": {"9": "Grain Dryers", "10": "Pk Ind Light", "11": "Water Heaters",
               "12": "Water Heaters", "13": "Water Heaters",
               "14": "Water Heaters", "15": "Clothes Dryer", "16": "Office Heat",
               "17": "Space Heat", "18": "Space Heat", "19": "Warehouse Fans",
               "20": "Warehouse Fans", "21": "Warehouse Heat",
               "22": "Warehouse Heat", "23": "Warehouse Heat",
               "24": "Warehouse Heat"},
      "1.02": {"11": "Water Heaters", "12": "Water Heaters",
               "13": "Water Heaters", "14": "Water Heaters",
               "15": "Misc Heat 1", "16": "Misc Heat 1", "17": "Water Heaters",
               "18": "Water Heaters", "19": "Water Heaters",
               "20": "Water Heaters", "24": "Ind. Controlled Loads 1"},
      "2.01": {"9": "Slab Heat", "10": "Slab Heat", "11": "Slab Heat",
               "12": "Slab Heat", "13": "Slab Heat", "14": "Slab Heat",
               "15": "Misc Heat 2", "16": "Misc Heat 2",
               "17": "Thermal Storage Heat", "18": "Thermal Storage Heat",
               "19": "Water Heaters", "20": "Water Heaters",
               "21": "Thermal Storage Heat", "22": "Thermal Storage Heat",
               "23": "Thermal Storage Heat", "24": "Ind. Controlled Loads 2"},
      "2.02": {"12": "Misc Loads 2", "13": "Misc Loads 2",
               "19": "Water Heaters", "20": "Water Heaters",
               "24": "Ind. Controlled Loads 2"},
      "2.03": {"9": "Slab Heat", "10": "Slab Heat", "11": "Slab Heat",
               "12": "Slab Heat", "13": "Slab Heat", "14": "Slab Heat",
               "15": "Misc Heat 2", "16": "Misc Heat 2",
               "17": "Thermal Storage Heat", "18": "Thermal Storage Heat",
               "19": "Water Heaters", "20": "Water Heaters",
               "21": "Thermal Storage Heat", "22": "Thermal Storage Heat",
               "23": "Thermal Storage Heat", "24": "Ind. Controlled Loads 2"},
      "2.04": {"12": "Misc Loads 2", "13": "Misc Loads 2",
               "19": "Water Heaters", "20": "Water Heaters",
               "24": "Ind. Controlled Loads 2"},
      "3.06": {"9": "Interruptible Alert", "10": "Industrial Loads",
               "11": "Commercial", "12": "Commercial", "13": "Commercial",
               "14": "Commercial", "15": "Industrial", "16": "Commercial",
               "17": "Commercial", "18": "Commercial", "19": "Commercial",
               "23": "Ind. Controlled Loads 3",
               "24": "Ind. Controlled Loads 3"},
      "3.07": {"9": "Interruptible Alert", "10": "Comm, Direct Control",
               "11": "Comm, Direct Control", "12": "Misc Loads 3",
               "13": "Misc Loads 3", "14": "Comm, Direct Control",
               "15": "Comm, Direct Control", "16": "Comm, Direct Control",
               "17": "Misc Loads 3", "18": "Misc Loads 3",
               "19": "Comm, Direct Control", "20": "Comm, Direct Control",
               "21": "Ind Controlled Loads 3", "22": "Voltage Reduction",
               "23": "Comm, Indirect Control", "24": "Ind Controlled Loads 3"},
      "3.08": {"10": "Industrial Interruptible Loads",
               "15": "Industrial Interruptible Loads"},
      "6.01": {"9": "Industrial Interruptible Loads",
               "10": "Low Temperature Grain Dryers",
               "11": "Reserved for Future Use", "12": "Miscellaneous Loads",
               "13": "Miscellaneous Loads", "14": "Reserved for Future Use",
               "15": "Reserved for Future Use", "16": "Reserved for Future Use",
               "17": "Reserved for Future Use", "18": "Reserved for Future Use",
               "19": "Reserved for Future Use",
               "20": "Irrigation Incremental Pricing Plan",
               "21": "Residential Locally Cycled Air Conditioning Loads",
               "22": "Commercial Locally Cycled Air Conditioning Loads",
               "23": "Indirectly Controlled Residential Loads",
               "24": "Indirectly Controlled Commercial Loads"}
    }

  # Programme tier, keyed on the integer prefix of the load group. From the
  # same bundle, object `WP`.
  TIER_NAME_MAP_JSON: >-
    {
      "1": "Short-Term Loads (water heaters)",
      "2": "Intermediate-Term Loads (storage heat)",
      "3": "Long-Term Loads (dual heating furnaces, back-up generators)",
      "6": "Summer-Only Loads (irrigation, cycled air conditioning)"
    }
```

- [ ] **Step 4: Create app/externalsecret.yaml**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/external-secrets.io/externalsecret_v1.json
# OpenBao KV item: "minnkota-collector"
# Required fields:
#   Minnkota__InfluxdbToken  — read+write token for the `minnkota` bucket
#   Minnkota__Mqtt__User     — broker user, also present in the `mosquitto` key
#   Minnkota__Mqtt__Password — matching password
#
# The InfluxDB token needs READ as well as write: the collector queries the
# bucket back for its freshness check rather than holding any local state.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: &name minnkota-collector-secret
spec:
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: *name
    template:
      engineVersion: v2
      data:
        INFLUXDB_TOKEN: "{{ .Minnkota__InfluxdbToken }}"
        MQTT_USER: "{{ .Minnkota__Mqtt__User }}"
        MQTT_PASSWORD: "{{ .Minnkota__Mqtt__Password }}"
  dataFrom:
    - extract:
        key: minnkota-collector
```

- [ ] **Step 5: Create app/serviceaccount.yaml**

```yaml
---
# Explicit identity for the collector's Jobs.
#
# Not bound to an OpenBao Kubernetes auth role: the Minnkota API has no
# credentials at all, and there is no session token to rotate and write back.
# ESO fetches the InfluxDB and MQTT secrets and mounts them as env, so the pod
# needs no API-server token — hence automountServiceAccountToken: false below.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: minnkota-collector
```

- [ ] **Step 6: Create app/cronjob.yaml**

Replace `<IMAGE_TAG>` with the tag recorded in Task 6 Step 6.

```yaml
---
# Five-minute incremental collector.
#
# Cadence is driven by the Home Assistant automation, not by the archive: the
# aux-heat switchover should happen when the utility sheds the heat pump, not
# after the indoor temperature has drooped far enough for the thermostat to
# stage up on its own. Five minutes is the latency budget for that.
#
# Minutes are 2-59/5 (:02, :07, :12, ...) rather than */5. A bare */5 fires on
# :00/:10/:20 alongside kia-collector's "*/10" and on :00/:15/:30/:45 alongside
# image-reflector-healer's "*/15". concurrencyPolicy: Forbid does NOT help
# against a sibling CronJob — it only serialises a CronJob against itself — so
# the collision has to be avoided at the schedule. The +2 offset clears both.
apiVersion: batch/v1
kind: CronJob
metadata:
  name: minnkota-collector
spec:
  schedule: "2-59/5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 2
      # Finished jobs age out in 1h. At a 5-minute cadence a one-off transient
      # failure disappears on its own (so KubeJobFailed auto-resolves), while a
      # persistent failure keeps producing fresh failed Jobs and stays alerting.
      ttlSecondsAfterFinished: 3600
      template:
        spec:
          restartPolicy: OnFailure
          serviceAccountName: minnkota-collector
          automountServiceAccountToken: false
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: collector
              # Full ref auto-updated by Flux image automation (ImagePolicy
              # flux-system:minnkota-collector).
              # NOTE: no ":tag" suffix on the marker — this is a combined
              # image:repo:tag scalar, so Flux must write the whole ref. A
              # ":tag" suffix would overwrite the scalar with the bare tag and
              # produce ImagePullBackOff.
              image: gitea.derekjacobs.dev/bluevulpine/minnkota-collector:<IMAGE_TAG> # {"$imagepolicy": "flux-system:minnkota-collector"}
              imagePullPolicy: Always
              envFrom:
                - configMapRef:
                    name: minnkota-collector-config
                - secretRef:
                    name: minnkota-collector-secret
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop:
                    - ALL
              volumeMounts:
                - name: tmp
                  mountPath: /tmp
              resources:
                requests:
                  cpu: 25m
                  memory: 64Mi
                limits:
                  # The incremental run holds two days of rows (~70) in memory.
                  # The audit run holds the full history (~12.5k rows / ~116k
                  # points) and is the sizing case.
                  memory: 512Mi
          volumes:
            - name: tmp
              emptyDir: {}
---
# Daily audit re-walk.
#
# The 5-minute job only refreshes a trailing 3-day window, so it steps straight
# over any interior hole — and holes happen whenever the cluster or the API is
# unavailable for more than that. This re-reads the entire retained range
# (2025-09-13 onward, 172 calls, ~68s). Writes are idempotent on
# (measurement, tagset, field, timestamp), so re-writing rows that are already
# present costs nothing but repairs anything that is not.
#
# 47 minutes past hour 5 avoids every taken slot: hours 0/6/12/18 (openbao
# snapshot, talos-backup), hour 3 (kopia r2 maintenance), hour 4:53
# (beestat-collector audit), and the 2-59/5 minutes of the job above.
apiVersion: batch/v1
kind: CronJob
metadata:
  name: minnkota-collector-audit
spec:
  schedule: "47 5 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 1
      ttlSecondsAfterFinished: 21600
      template:
        spec:
          restartPolicy: OnFailure
          serviceAccountName: minnkota-collector
          automountServiceAccountToken: false
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: collector
              # See the marker note on the incremental job above.
              image: gitea.derekjacobs.dev/bluevulpine/minnkota-collector:<IMAGE_TAG> # {"$imagepolicy": "flux-system:minnkota-collector"}
              imagePullPolicy: Always
              env:
                - name: AUDIT_MODE
                  value: "true"
                # The audit is the archive's repair pass, not the live signal.
                # Leaving MQTT on would republish state from a run that takes
                # ~70s, racing the incremental job for no benefit.
                - name: MQTT_ENABLED
                  value: "false"
              envFrom:
                - configMapRef:
                    name: minnkota-collector-config
                - secretRef:
                    name: minnkota-collector-secret
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop:
                    - ALL
              volumeMounts:
                - name: tmp
                  mountPath: /tmp
              resources:
                requests:
                  cpu: 50m
                  memory: 128Mi
                limits:
                  memory: 512Mi
          volumes:
            - name: tmp
              emptyDir: {}
```

- [ ] **Step 7: Register the app**

Add `  - ./minnkota-collector/ks.yaml` to the `resources:` list in `kubernetes/apps/home/kustomization.yaml`, after the `chargepoint-collector` line.

- [ ] **Step 8: Validate**

```bash
cd /Users/bluevulpine/Repositories/flux-talos/.claude/worktrees/minnkota-collector
lefthook run pre-commit
kubectl kustomize kubernetes/apps/home/minnkota-collector/app | head -40
```

Expected: pre-commit passes (yamlfmt + gitleaks clean); the kustomize build renders without error.

- [ ] **Step 9: Commit**

```bash
cd /Users/bluevulpine/Repositories/flux-talos/.claude/worktrees/minnkota-collector
git add kubernetes/apps/home/minnkota-collector kubernetes/apps/home/kustomization.yaml
git commit -m "feat(home): minnkota-collector — archive utility DR state, signal HA

Schedule is 2-59/5 rather than */5: a bare */5 collides with kia-collector's
*/10 on :00/:10/:20 and image-reflector-healer's */15 on the quarter hours,
and Forbid does not serialise across sibling CronJobs."
```

---

## Task 9: Flux image automation

**Files:**
- Create: `kubernetes/apps/flux-system/minnkota-collector/ks.yaml`
- Create: `kubernetes/apps/flux-system/minnkota-collector/app/kustomization.yaml`
- Create: `kubernetes/apps/flux-system/minnkota-collector/app/imagerepository.yaml`
- Create: `kubernetes/apps/flux-system/minnkota-collector/app/imagepolicy.yaml`
- Create: `kubernetes/apps/flux-system/minnkota-collector/app/imageupdateautomation.yaml`
- Modify: `kubernetes/apps/flux-system/kustomization.yaml`

**Interfaces:**
- Consumes: the `$imagepolicy` markers written in Task 8 Step 6.
- Produces: `ImagePolicy` `flux-system:minnkota-collector`.

- [ ] **Step 1: Create ks.yaml**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app minnkota-collector-image
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn:
    - name: flux-instance
      namespace: flux-system
    - name: external-secrets-openbao-store
      namespace: external-secrets
  interval: 1h
  path: ./kubernetes/apps/flux-system/minnkota-collector/app
  prune: true
  retryInterval: 2m
  sourceRef:
    kind: GitRepository
    name: home-kubernetes
    namespace: flux-system
  targetNamespace: flux-system
  timeout: 5m
  wait: false
```

- [ ] **Step 2: Create app/kustomization.yaml**

```yaml
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

- [ ] **Step 3: Create app/imagerepository.yaml**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/image.toolkit.fluxcd.io/imagerepository_v1beta2.json
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageRepository
metadata:
  name: &app minnkota-collector
spec:
  image: gitea.derekjacobs.dev/bluevulpine/minnkota-collector
  interval: 5m
  secretRef:
    name: gitea-registry-creds
```

- [ ] **Step 4: Create app/imagepolicy.yaml**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/image.toolkit.fluxcd.io/imagepolicy_v1beta2.json
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImagePolicy
metadata:
  name: &app minnkota-collector
spec:
  imageRepositoryRef:
    name: *app
  filterTags:
    # Drone tags images as <build-number>-<sha8>; extract the build number
    pattern: '^(?P<num>[0-9]+)-[0-9a-f]{8}$'
    extract: '$num'
  policy:
    numerical:
      order: asc
```

- [ ] **Step 5: Create app/imageupdateautomation.yaml**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/image.toolkit.fluxcd.io/imageupdateautomation_v1beta2.json
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageUpdateAutomation
metadata:
  name: &app minnkota-collector
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
    # Scoped to this app's directory only. Setters rewrites EVERY $imagepolicy
    # marker under this path, so a broader scan (e.g. ./kubernetes) would
    # silently drive other apps' images from this policy.
    path: ./kubernetes/apps/home/minnkota-collector
    strategy: Setters
```

- [ ] **Step 6: Register**

Add `  - ./minnkota-collector/ks.yaml` to `kubernetes/apps/flux-system/kustomization.yaml`, next to the `beestat-collector` entry on line 14.

- [ ] **Step 7: Validate and commit**

```bash
cd /Users/bluevulpine/Repositories/flux-talos/.claude/worktrees/minnkota-collector
lefthook run pre-commit
git add kubernetes/apps/flux-system/minnkota-collector kubernetes/apps/flux-system/kustomization.yaml
git commit -m "feat(flux-system): image automation for minnkota-collector

update.path scoped to the app dir: Setters rewrites every \$imagepolicy marker
beneath it, so a repo-wide scan would drive other apps' images from this policy."
```

---

## Task 10: Alerting

**Files:**
- Create: `kubernetes/apps/home/minnkota-collector/app/prometheusrule.yaml`
- Modify: `kubernetes/apps/home/minnkota-collector/app/kustomization.yaml` (re-add the `prometheusrule.yaml` line if it was omitted in Task 8)

**Interfaces:**
- Consumes: the CronJob names from Task 8.
- Produces: four alert rules.

- [ ] **Step 1: Create prometheusrule.yaml**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/monitoring.coreos.com/prometheusrule_v1.json
#
# Note what is deliberately NOT alerted on: the absence of new ripple rows.
# The co-op legitimately issues no commands for days at a time — measured, the
# user's own load groups went 16 consecutive days without one in May 2026, and
# all groups together went 6. A "no new data" alert would fire every summer and
# be trained away, which is worse than not having it.
#
# Liveness is therefore expressed as "the collector ran", not "the utility did
# something".
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: minnkota-collector
spec:
  groups:
    - name: minnkota-collector.rules
      rules:
        # Any failed Job. Exit 4 means the audit ran but the API returned
        # nothing for ANY load group over 10 days — the source looks dead.
        - alert: MinnkotaCollectorJobFailed
          annotations:
            summary: >-
              Minnkota collector job {{ $labels.job_name }} failed — utility
              demand-response state is not being archived and the Home Assistant
              aux-heat signal is going stale. Check
              `kubectl logs -n home job/{{ $labels.job_name }}`.
              Exit 3 = Minnkota API error; exit 4 = the API returned no rows for
              any load group in 10 days; exit 5 = InfluxDB; exit 6 = MQTT.
          expr: |
            kube_job_status_failed{namespace="home", job_name=~"minnkota-collector.*"} > 0
          for: 15m
          labels:
            severity: critical

        # A CronJob whose image can't be pulled never RUNS, so it never marks a
        # Job failed and MinnkotaCollectorJobFailed would miss it entirely. This
        # is the exact failure mode that caused the 14h kia-collector outage on
        # 2026-07-11 — a bad $imagepolicy marker rewrote the image ref to a bare
        # tag. See docs/runbooks/flux-image-automation.md.
        - alert: MinnkotaCollectorImagePullFailing
          annotations:
            summary: >-
              Minnkota collector pod {{ $labels.pod }} can't pull its image
              ({{ $labels.reason }}) — the collector isn't running at all. Check
              the image ref in the CronJob and the Flux image automation
              (kubernetes/apps/flux-system/minnkota-collector/).
          expr: |
            kube_pod_container_status_waiting_reason{namespace="home", pod=~"minnkota-collector.*", reason=~"ImagePullBackOff|ErrImagePull|InvalidImageName"} > 0
          for: 15m
          labels:
            severity: critical

        # The live signal is what the aux-heat automation depends on. At a
        # 5-minute cadence, 30 minutes is six consecutive missed cycles — the
        # same window as the MQTT expire_after, so Home Assistant marks the
        # entity unavailable at roughly the moment this fires.
        - alert: MinnkotaCollectorStale
          annotations:
            summary: >-
              Minnkota collector has not had a successful run in over 30m. The
              Home Assistant `binary_sensor.minnkota_heat_pump_curtailed` entity
              will be going unavailable, so the aux-heat automation is blind.
              Check `kubectl get cronjob,jobs -n home | grep minnkota`.
          expr: |
            time() - max(kube_cronjob_status_last_successful_time{namespace="home", cronjob="minnkota-collector"}) > 1800
          for: 10m
          labels:
            severity: critical

        # The daily audit repairs interior gaps the 3-day trailing window steps
        # over. Losing it is not an emergency — the 5-minute job still archives
        # new data and still drives Home Assistant — so this is a warning.
        - alert: MinnkotaCollectorAuditStale
          annotations:
            summary: >-
              Minnkota collector audit has not succeeded in over 48h — interior
              gaps in the archive will not be repaired. The 5-minute collector
              is likely still fine; check
              `kubectl get jobs -n home | grep minnkota-collector-audit`.
          expr: |
            time() - max(kube_cronjob_status_last_successful_time{namespace="home", cronjob="minnkota-collector-audit"}) > 172800
          for: 30m
          labels:
            severity: warning
```

- [ ] **Step 2: Ensure kustomization.yaml lists it**

`kubernetes/apps/home/minnkota-collector/app/kustomization.yaml` must contain `  - prometheusrule.yaml` in `resources:`.

- [ ] **Step 3: Validate and commit**

```bash
cd /Users/bluevulpine/Repositories/flux-talos/.claude/worktrees/minnkota-collector
lefthook run pre-commit
kubectl kustomize kubernetes/apps/home/minnkota-collector/app | grep -c PrometheusRule
git add kubernetes/apps/home/minnkota-collector
git commit -m "feat(home): minnkota-collector alerts

Deliberately does not alert on absent ripple rows: the co-op issues no commands
for up to 6 days across all groups (16 for ours) in the off-season, so a
data-novelty alert would fire every summer and get trained away."
```

---

## Task 11: Grafana datasource

**Files:**
- Modify: `kubernetes/apps/observability/grafana/app/helmrelease.yaml` (after the `InfluxDB-Beestat` datasource block, around line 217)
- Modify: `kubernetes/apps/observability/grafana/app/externalsecret.yaml` (after line 43)

**Interfaces:**
- Consumes: the read-only token stored in Task 7 Step 4.
- Produces: Grafana datasource uid `influxdb-minnkota`.

- [ ] **Step 1: Add the datasource**

Append to the `datasources` list in `helmrelease.yaml`, matching the surrounding style exactly:

```yaml
          - name: InfluxDB-Minnkota
            type: influxdb
            uid: influxdb-minnkota
            access: proxy
            url: http://influxdb.database.svc.cluster.local:8086
            jsonData:
              version: Flux
              organization: homelab
              defaultBucket: minnkota
            # Read-only, bucket-scoped token — provisioned via grafana-secret env
            # (INFLUXDB_MINNKOTA_TOKEN <- OpenBao grafana/Grafana__InfluxdbMinnkotaToken).
            secureJsonData:
              token: $INFLUXDB_MINNKOTA_TOKEN
```

- [ ] **Step 2: Add the token env**

Append to the `data:` block in the grafana `externalsecret.yaml`, matching the existing `default ""` pattern so Grafana still starts if the OpenBao field is missing:

```yaml
        # Renders empty until the OpenBao grafana item gains Grafana__InfluxdbMinnkotaToken.
        INFLUXDB_MINNKOTA_TOKEN: '{{ .Grafana__InfluxdbMinnkotaToken | default "" | nospace }}'
```

- [ ] **Step 3: Validate and commit**

```bash
cd /Users/bluevulpine/Repositories/flux-talos/.claude/worktrees/minnkota-collector
lefthook run pre-commit
git add kubernetes/apps/observability/grafana/app
git commit -m "feat(observability): grafana datasource for the minnkota bucket"
```

---

## Task 12: Deploy, backfill, and verify

No new files. This is the task that proves the whole thing works.

- [ ] **Step 1: Merge to main**

```bash
cd /Users/bluevulpine/Repositories/flux-talos/.claude/worktrees/minnkota-collector
git push -u origin worktree-minnkota-collector
gh pr create --fill --head worktree-minnkota-collector
```

Have the PR reviewed, then merge. **Do not push directly to `main`.**

- [ ] **Step 2: Wait for reconciliation and confirm the objects exist**

A GitHub webhook reconciles on push to `main`. Wait, then:

```bash
kubectl get ks -n flux-system minnkota-collector minnkota-collector-image
kubectl get cronjob -n home | grep minnkota
kubectl get externalsecret -n home minnkota-collector-secret
```

Expected: both Kustomizations `Ready=True`; two CronJobs; the ExternalSecret `SecretSynced`.

- [ ] **Step 3: Run the backfill manually**

Do not wait for 05:47. Trigger the audit job by hand:

```bash
kubectl -n home create job minnkota-backfill --from=cronjob/minnkota-collector-audit
kubectl -n home wait --for=condition=complete job/minnkota-backfill --timeout=600s
kubectl -n home logs job/minnkota-backfill
```

Expected in the logs: `fetched 12532 unique rows in 172 API calls` (±a few rows, since the log grows), then `wrote ~115804 points`.

- [ ] **Step 4: Verify the archive reproduces the measured baseline**

```bash
kubectl -n database exec -i deploy/influxdb -- influx query --org homelab \
  --token "$(kubectl -n home get secret minnkota-collector-secret -o jsonpath='{.data.INFLUXDB_TOKEN}' | base64 -d)" '
from(bucket: "minnkota")
  |> range(start: 2025-09-01T00:00:00Z)
  |> filter(fn: (r) => r._measurement == "ripple_state")
  |> filter(fn: (r) => r._field == "curtailed")
  |> filter(fn: (r) => r.load_group == "3.09" and r.do == "DO13")
  |> group()
  |> count()
'
```

Expected: a count matching the DO13 reading count from the history (the `verify_sheds.py` run in Task 2 Step 5 is the reference).

Then confirm the earliest point is 2025-09-13 and that `load_name` resolved:

```bash
kubectl -n database exec -i deploy/influxdb -- influx query --org homelab \
  --token "$(kubectl -n home get secret minnkota-collector-secret -o jsonpath='{.data.INFLUXDB_TOKEN}' | base64 -d)" '
from(bucket: "minnkota")
  |> range(start: 2025-09-01T00:00:00Z)
  |> filter(fn: (r) => r._measurement == "ripple_state" and r._field == "curtailed")
  |> filter(fn: (r) => r.load_group == "3.09" and r.do == "DO13")
  |> group()
  |> min(column: "_time")
'
```

Expected: `_time` is `2025-09-14T...` or earlier, and the row carries `load_name=Dual Heat`.

- [ ] **Step 5: Verify the 5-minute job and the MQTT signal**

```bash
kubectl -n home get jobs | grep minnkota-collector
kubectl -n home logs job/$(kubectl -n home get jobs -o name | grep minnkota-collector | grep -v audit | tail -1 | cut -d/ -f2)
```

Expected: `published: heat_pump=OFF evse=...` (heat pump `OFF` = not curtailed, correct for August).

Subscribe to confirm the retained values are actually on the broker:

```bash
kubectl -n home run mqtt-sub --rm -it --restart=Never --image=eclipse-mosquitto:2 -- \
  mosquitto_sub -h mosquitto.home.svc.cluster.local -p 1883 \
    -u minnkota-collector -P '<password>' -t 'minnkota/#' -v -W 5
```

Expected: retained messages on `minnkota/heat_pump_curtailed/state`, `minnkota/evse_curtailed/state`, `minnkota/last_run/state`, plus the attribute topics.

- [ ] **Step 6: Confirm the entities appeared in Home Assistant**

In Home Assistant, go to **Settings → Devices & Services → MQTT** and confirm a device named **Minnkota Demand Response** with five entities. Check that `binary_sensor.minnkota_heat_pump_curtailed` reads **Off** (i.e. not curtailed) and that its attributes show `load_group: 3.09`, `digital_output: DO13`, `utility_state: ON`.

**Sanity check the polarity here, deliberately.** `utility_state: ON` must correspond to the binary sensor reading `Off`. If they match instead of inverting, the polarity bug is live and every conclusion downstream will be backwards.

---

## Task 13: Grafana dashboard

**Files:**
- Create: `kubernetes/apps/home/minnkota-collector/app/minnkota-dashboard.json`
- Modify: `kubernetes/apps/home/minnkota-collector/app/kustomization.yaml`

**Interfaces:**
- Consumes: the `minnkota` bucket and the `influxdb-minnkota` datasource.
- Produces: a provisioned dashboard.

Panels, all against datasource uid `influxdb-minnkota`:

1. **Stat — "Heat pump curtailed right now"**: last `curtailed` for `3.09`/`DO13`, value mappings `0 → Permitted` (green) / `1 → CURTAILED` (red).
2. **State timeline — "Heat pump curtailment"**: `curtailed` for `3.09`/`DO13` over the selected range.
3. **State timeline — "EV charging window"**: `curtailed` for `2.06`/`DO09`.
4. **Stat — "Curtailment hours, this heating season"**: integral of `curtailed` over time, in hours.
5. **Bar chart — "Curtailed hours by month"**.
6. **Table — "Shed events"**: start, end, duration.
7. **Stat — "Collector last run"**: last `_time` from `collector_run`.

- [ ] **Step 1: Write the dashboard JSON**

Follow the traps documented in `reference-grafana-flux-dashboard-traps`, all of which render without error and so must be checked visually:

- Use `rename` rather than `set(key: "_field")` — `set` leaves the field named `_value`, so every target collides and **no `byName` override applies**.
- For per-tag series naming use `displayName: ${__field.labels.<tag>}`.
- For a duration in hours use `suffix: h`, **not** the built-in `h` unit, which rescales 77.9 h to "3.2 days".
- A `barchart`'s x field inherits the panel unit — set the unit per-field, not per-panel.
- `barchart` has **no** `drawStyle`, so a second-axis series needs its own panel.
- Do not `import "math"` — Grafana prepends `option v = {...}` and the import fails to compile. Validate any query by prepending that same `option v` line locally.
- In `kustomization.yaml`, Grafana template variables must be written `$$` because this Kustomization has `postBuild.substitute` and envsubst would otherwise eat `${...}`.

- [ ] **Step 2: Add the configMapGenerator**

```yaml
# Grafana dashboards, provisioned via the sidecar (label grafana_dashboard=1).
# NOTE: the JSON uses "$$" for Grafana template variables. This Kustomization has
# postBuild.substitute, whose envsubst would otherwise consume "${...}" as an
# unset variable; "$$" collapses to a literal "$" so Grafana sees "${...}".
# See docs/runbooks/flux-image-automation.md, Gotcha 4.
configMapGenerator:
  - name: minnkota-collector-dashboards
    files:
      - minnkota-dashboard.json
generatorOptions:
  disableNameSuffixHash: true
  labels:
    grafana_dashboard: "1"
```

- [ ] **Step 3: Validate, commit, and LOOK at it**

```bash
cd /Users/bluevulpine/Repositories/flux-talos/.claude/worktrees/minnkota-collector
lefthook run pre-commit
kubectl kustomize kubernetes/apps/home/minnkota-collector/app | grep -A2 grafana_dashboard
git add kubernetes/apps/home/minnkota-collector
git commit -m "feat(home): minnkota demand-response dashboard"
```

After it reconciles, **open the dashboard and take a screenshot**. Every trap listed above renders without an error message — a green build proves nothing. Confirm specifically that the "Curtailment hours" stat reads close to **152.8 h** for 2025-09-13 → 2026-08-21.

---

## Task 14: The payoff — split the balance point, and automate aux heat

**Files:**
- Modify: `kubernetes/apps/home/beestat-collector/app/beestat-longterm-dashboard.json`
- Create: `docs/runbooks/minnkota-aux-heat-automation.md`

**Interfaces:**
- Consumes: `ripple_state` in the `minnkota` bucket; `runtime_thermostat` in the `beestat` bucket.
- Produces: a corrected balance-point panel and a documented Home Assistant automation.

- [ ] **Step 1: Determine how the ecobee exposes aux-only in this Home Assistant**

**This must be discovered, not assumed.** The correct mechanism depends on the ecobee integration version and on how the thermostat is configured, and asserting a service name that does not exist would produce an automation that silently never fires.

In Home Assistant, open **Developer Tools → States**, find the ecobee `climate.*` entity, and record:
- `hvac_modes` — does it include an aux-only mode?
- `preset_modes` — is there a preset that forces auxiliary heat?
- Then **Developer Tools → Actions**, filter on `ecobee.` and record which services exist.

Write what you find into `docs/runbooks/minnkota-aux-heat-automation.md` before writing the automation.

- [ ] **Step 2: Write the automation against whatever Step 1 found**

The trigger and conditions are settled regardless of the action:

```yaml
alias: Force aux heat while the utility curtails the heat pump
description: >-
  Red Lake Electric sheds the heat pump (ripple load group 3.09, DO13
  "Dual Heat") during peak periods. Measured 2025-09-13..2026-08-21: 32 events,
  152.8 hours. When that happens the compressor has no power, so the thermostat
  keeps calling for compressor heat, gets nothing, and only stages up to propane
  after the indoor temperature has drooped. This closes that gap.
triggers:
  - trigger: state
    entity_id: binary_sensor.minnkota_heat_pump_curtailed
    to: "on"
conditions:
  # Only act while actually heating. In cooling season DO13 has been ON
  # continuously since 2026-05-12, so this should never fire then anyway --
  # but the guard costs nothing and makes the intent explicit.
  - condition: state
    entity_id: climate.<ECOBEE_ENTITY>
    attribute: hvac_action
    state: heating
actions:
  # <<< action discovered in Step 1 >>>
mode: single
```

And the matching restore automation on `to: "off"`.

**Note the failure mode that matters:** `binary_sensor.minnkota_heat_pump_curtailed` has `expire_after: 1800`, so if the collector dies the entity goes `unavailable` rather than `off`. A `to: "off"` trigger will therefore *not* fire on collector death — which is correct, because "I stopped knowing" is not "the utility restored the load". Handle the restore explicitly with an `unavailable` guard if the discovered action is one that would strand the thermostat.

- [ ] **Step 3: Split the balance-point panel**

The existing panel reads aux runtime at 35–40 °F as though it were all thermostat lockout. Add a second series that separates the two causes, by joining beestat runtime against the curtailment state:

- Series A — **"Aux while the utility curtailed"**: `runtime_thermostat.auxiliary_heat_1` where the joined `ripple_state` `curtailed` is 1.
- Series B — **"Aux on the thermostat's own decision"**: the same, where `curtailed` is 0.

Cross-bucket joins in Flux need both streams on a common time grid. Aggregate both to a 5-minute window (beestat's native resolution) and use `fill(usePrevious: true)` on the curtailment stream — it is written only when a DO is *addressed*, so between commands it has no points and a naive join would drop every row.

- [ ] **Step 4: Verify the split against the known total**

The two series must sum to the original single series. Additionally, Series A's total should be bounded by 152.8 h — the utility cannot have curtailed for longer than it curtailed.

Take a screenshot of the corrected panel.

- [ ] **Step 5: Commit**

```bash
cd /Users/bluevulpine/Repositories/flux-talos/.claude/worktrees/minnkota-collector
lefthook run pre-commit
git add kubernetes/apps/home/beestat-collector/app/beestat-longterm-dashboard.json docs/runbooks/minnkota-aux-heat-automation.md
git commit -m "feat(home): split balance-point aux runtime by utility curtailment

32 shed events / 152.8h in 2025-26 were being read as thermostat lockout. The
two causes have opposite fixes, so the panel now separates them."
```

---

## Self-Review

**Spec coverage**

| Spec requirement | Task |
| --- | --- |
| Source in Gitea repo, Drone + kaniko, files copied from beestat-collector | 1, 6 |
| Manifests at `kubernetes/apps/home/minnkota-collector/` (`app/` + `ks.yaml`) | 8 |
| Flux image automation at `kubernetes/apps/flux-system/minnkota-collector/` | 9 |
| New InfluxDB bucket `minnkota`, infinite retention, org `homelab`, created by `kubectl exec` | 7 |
| Tokens into OpenBao via `bao kv put`, never in a transcript | 7 |
| Grafana datasource `influxdb-minnkota` + `INFLUXDB_MINNKOTA_TOKEN` | 11 |
| No OpenBao K8s auth role; `automountServiceAccountToken: false` | 8 |
| CronJob, `Forbid`, `ttlSecondsAfterFinished`, non-root, RO rootfs, drop ALL, requests/limits | 8 |
| PrometheusRule: job-failed, ImagePullBackOff, last-success staleness, non-zero exit on archiving nothing | 10 |
| Poll every 5–10 min, avoiding taken cron slots | 8 (`2-59/5`, `47 5`) |
| Stateless watermark, re-fetch with overlap | 3, 5 |
| Schema: `ripple_state` tagged on stable `do`, plus `dr_plan` / `dr_schedule` / `system_condition` | 2, 5 |
| Beware InfluxDB write traps (mixed types, batch/shard count) | 2, 3, 5 |
| Payoff: join against `auxiliary_heat_1`, split the balance point | 14 |
| **Correction 1** — backfill the full history from 2025-09-13 | 5, 12 |
| **Correction 2** — 2-day window per call | 1, 5 |
| **Correction 3** — pin the DO→name table | 8 |
| **Correction 4** — `---` is "not addressed"; carry forward | 2 |
| **Correction 5** — local wall-clock with DST | 1 |
| **Correction 6** — live MQTT signal to Home Assistant | 4, 5, 14 |
| **Correction 7** — `/api/Status/list` cross-check | *not implemented* |

**Gap, accepted deliberately:** Correction 7 (`/api/Status/list`) is a redundant cross-check on state the collector already derives from the ripple log, and it uses a third timestamp format. It is left out to avoid a second source of truth for the same fact. If carried-forward state is ever suspected of drifting, add it then.

**Placeholder scan:** Two intentional placeholders remain, both because the value cannot be known until an earlier step runs: `<IMAGE_TAG>` in Task 8 (produced by Task 6 Step 6) and the action block in Task 14 Step 2 (produced by Task 14 Step 1's discovery against the live Home Assistant). Both are called out at their point of use. The Task 13 dashboard JSON is specified by panel list and constraint rather than by literal JSON, since a 700-line Grafana document is better generated against the live datasource than transcribed.

**Type consistency:** `DOReading` is constructed in `ripple_state.iter_readings` and consumed in `mqtt_publish.binary_state_payload` and `collector.main` — field names `timestamp`/`load_group`/`do`/`energized`/`state_text` and the derived `curtailed` property agree across all three. `RippleRow` is produced by `MinnkotaAPI.ripple_list` and consumed by `iter_readings`/`to_points` — `timestamp`/`load_group`/`substation`/`coop`/`ac`/`err`/`do` agree. `InfluxArchive.write` and `.newest` signatures match their call sites in `collector.main`. `EntitySpec` field order (`slug`, `name`, `component`, `device_class`, `icon`) matches the positional construction in `test_discovery_payload_omits_null_device_class` and the keyword construction in `collector.ENTITIES`.
