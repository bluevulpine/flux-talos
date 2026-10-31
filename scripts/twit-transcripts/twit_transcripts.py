#!/usr/bin/env python3
"""Mirror TWiT.tv episode transcripts as markdown for the qmd `twit-transcripts` collection.

Why this runs on aurelia and not in the cluster: qmd's index (~/.cache/qmd/index.sqlite) and
every collection it reads are local to this Mac, and the hourly `com.qmd-sessions.refresh`
LaunchAgent already runs `qmd update` + `qmd embed` over all collections. Writing markdown
into a local directory is therefore all it takes to become searchable; a CronJob would still
need a way to ship files back here. See docs/runbooks/twit-transcripts.md.

  update        the scheduled mode: walk https://twit.tv/posts/transcripts?page=N from page 1
                and fetch slugs not yet on disk, stopping at the first page with nothing new;
                then fetch any new GRC Security Now transcript (see below)
  backfill      gather every transcript slug from the full listing plus the sitemap and fetch
                the missing ones matching --show (a regex on the slug)
  grc-backfill  fetch GRC's Security Now transcripts 1..latest that are not on disk

Second source, Security Now only: GRC.com publishes its own transcripts of every episode at
https://www.grc.com/sn/sn-NNN.txt (1 onward; twit.tv's start at ~847). They are human-made,
unlike TWiT's AI ones, so they are the better text to quote, but have no timecodes. Both are
kept: TWiT's under security-now/, GRC's under security-now-grc/. GRC licenses them CC BY-NC-SA
2.5; the licence footer is kept in each file.

Politeness: twit.tv's robots.txt sets `Crawl-delay: 10`; GRC's sets none (checked
2026-10-21), and gets the same 10 s anyway. Every request is spaced at least that far apart,
so backfills are slow: ~40 min to walk twit.tv's listing before any fetching, ~3 h for
GRC's 1,100 Security Now episodes, ~10 h for every twit.tv show. They run in the background.
Each site has its own lock, so a backfill of one does not hold up the other's update.

State is the output directory itself: a slug is "known" when <out>/<show>/<slug>.md exists.
Slugs that 404 or carry no transcript body go to <out>/.state/skip.json so they are not
retried on every run. Delete a file (or its skip entry) to force a re-fetch.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import IO

BASE = "https://twit.tv"
LISTING = BASE + "/posts/transcripts?page={page}"
SITEMAP_INDEX = "https://sitemap.twit.tv/sitemap.xml"
USER_AGENT = "twit-transcripts-mirror/1.0 (personal search index; honours Crawl-delay)"
CRAWL_DELAY = 10.0
DEFAULT_OUT = Path.home() / "Documents" / "twit-transcripts"
GRC_URL = "https://www.grc.com/sn/sn-{n:03d}.txt"
GRC_DIR = "security-now-grc"

SLUG_HREF = re.compile(r'href="/posts/transcripts/([a-z0-9][a-z0-9-]*)"')
SITEMAP_LOC = re.compile(r"<loc>\s*([^<\s]+)\s*</loc>")
# Slugs are hand-typed and vary: `security-now-1100-transcript`, `security-now-episode-847-
# transcript`, `macbreak-weekly-411-transcripts`, `week-enterprise-tech-N-trascript`,
# `tech-news-2night-82transcript`, bare `week-tech-473`, and `coding-101-N-transcript`, where
# the show name itself has a number. The episode is the number directly before the
# "transcript" word (any spelling starting `tr`), else the last number in the slug.
EP_BEFORE_TR = re.compile(r"-(\d+)-?(?:episode-|best-)?tr[a-z]*(?:-(?P<extra>.*))?$")
EP_LAST = re.compile(r"-(\d+)(?:-(?P<extra>[^0-9].*))?$")

# Show prefixes that are typos or variants, mapped to the directory a reader would look in.
# `weel-tech-1105-transcript` is a TWiT typo for `week-tech` (This Week in Tech). AI User
# Group episodes are published under the Club TWiT umbrella feed (`twit-club-shows-<n>-
# transcript-ai-user-group-<m>`); they get their own directory because they are searched as
# a show in their own right.
SHOW_ALIASES = {
    "weel-tech": "week-tech",
    "this-week-in-tech": "week-tech",
    "hans-windows": "hands-windows",
    "home-theater-geek": "home-theater-geeks",
    "ask-tech-guys-episoide": "ask-tech-guys",
}
EXTRA_SHOWS = [(re.compile(r"ai-user-group"), "ai-user-group")]

_last_request = 0.0


def log(msg: str) -> None:
    print(f"[{dt.datetime.now().astimezone().isoformat(timespec='seconds')}] {msg}", flush=True)


def fetch(url: str, attempts: int = 4) -> str | None:
    """GET a URL with the crawl delay applied; None on 404, raises after repeated failures."""
    global _last_request
    for attempt in range(1, attempts + 1):
        wait = _last_request + CRAWL_DELAY - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        _last_request = time.monotonic()
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                return None
            if e.code != 429 and e.code < 500:
                raise
            retry_after = e.headers.get("Retry-After", "")
            backoff = int(retry_after) if retry_after.isdigit() else 60 * attempt
            log(f"HTTP {e.code} for {url}; retrying in {backoff}s ({attempt}/{attempts})")
        except (urllib.error.URLError, TimeoutError) as e:
            backoff = 60 * attempt
            log(f"{e} for {url}; retrying in {backoff}s ({attempt}/{attempts})")
        if attempt < attempts:
            time.sleep(backoff)
    raise RuntimeError(f"giving up on {url} after {attempts} attempts")


def classify(slug: str) -> tuple[str, int | None]:
    """Directory name and episode number for a slug."""
    m = EP_BEFORE_TR.search(slug) or EP_LAST.search(slug)
    if not m:
        return "other", None
    show = re.sub(r"-episode$", "", slug[: m.start()])
    show = SHOW_ALIASES.get(show, show)
    for pattern, name in EXTRA_SHOWS:
        if m["extra"] and pattern.search(m["extra"]):
            show = name
    return show, int(m.group(1))


def parse_date(byline: str) -> str | None:
    text = re.sub(r"(\d+)(st|nd|rd|th)", r"\1", byline.strip())
    for fmt in ("%b %d %Y", "%B %d %Y"):
        try:
            return dt.datetime.strptime(text, fmt).date().isoformat()
        except ValueError:
            pass
    return None


def body_to_markdown(body: str) -> str:
    # Each <p> is one speaker turn: `Speaker [hh:mm:ss]:<br>text`. Keeping the turn on one
    # line makes grep and qmd snippets show who said it alongside what was said.
    text = re.sub(r"<br\s*/?>\s*", " ", body)
    text = re.sub(r"</p>\s*", "\n\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text).replace("\xa0", " ")
    lines = [re.sub(r"[ \t]+", " ", ln).strip() for ln in text.split("\n")]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip() + "\n"


def render(slug: str, page: str) -> str | None:
    """Markdown with front matter, or None when the page has no transcript body."""
    title_m = re.search(r'<h1 class="post-title">(.*?)</h1>', page, re.S)
    body_m = re.search(r'<div class="body textual">(.*?)</div>', page, re.S)
    if not title_m or not body_m:
        return None
    body = body_to_markdown(body_m.group(1))
    if len(body) < 200:
        return None
    title = html.unescape(re.sub(r"<[^>]+>", "", title_m.group(1))).strip()
    byline_m = re.search(r'<p class="byline">(.*?)</p>', page, re.S)
    date = parse_date(re.sub(r"<[^>]+>", "", byline_m.group(1))) if byline_m else None
    show, ep = classify(slug)
    feed_ep = None
    # Show name as TWiT titles it: "Security Now 1100 transcript" -> "Security Now".
    show_name = re.sub(r"\s+\d+\s+transcript\b.*$", "", title, flags=re.I).strip() or title
    if show == "ai-user-group":
        # The slug number is the Club TWiT feed's; the AUG number people cite is the suffix.
        show_name = "AI User Group"
        aug = re.search(r"ai-user-group-(\d+)$", slug)
        feed_ep, ep = ep, int(aug.group(1)) if aug else None
    front = {
        "title": title,
        "show": show,
        "show_name": show_name,
        "episode": ep,
        "feed_episode": feed_ep,
        "date": date,
        "url": f"{BASE}/posts/transcripts/{slug}",
        "slug": slug,
        "source": "twit.tv",
        "fetched": dt.date.today().isoformat(),
        "note": "AI-generated transcript; not word-for-word. Timecodes match the ad-free edition.",
    }
    # json.dumps output is valid YAML for strings, ints and null.
    fm = "\n".join(f"{k}: {json.dumps(v)}" for k, v in front.items())
    return f"---\n{fm}\n---\n\n# {title}\n\n{body}"


class Store:
    def __init__(self, out: Path):
        self.out = out
        self.state = out / ".state"
        self.state.mkdir(parents=True, exist_ok=True)
        self.skip_path = self.state / "skip.json"
        self.skip: dict[str, str] = (
            json.loads(self.skip_path.read_text()) if self.skip_path.exists() else {}
        )
        self.known = {p.stem for p in out.glob("*/*.md")}

    def has(self, slug: str) -> bool:
        return slug in self.known or slug in self.skip

    def save(self, slug: str, md: str, show: str | None = None) -> Path:
        path = self.out / (show or classify(slug)[0]) / f"{slug}.md"
        path.parent.mkdir(exist_ok=True)
        tmp = path.with_suffix(".md.tmp")
        tmp.write_text(md, encoding="utf-8")
        os.replace(tmp, path)
        self.known.add(slug)
        return path

    def mark_skip(self, slug: str, reason: str) -> None:
        self.skip[slug] = f"{reason} ({dt.date.today().isoformat()})"
        tmp = self.skip_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.skip, indent=1, sort_keys=True))
        os.replace(tmp, self.skip_path)


def fetch_one(store: Store, slug: str) -> bool:
    # A failure that outlasts fetch()'s retries (403, persistent 5xx, timeouts) is logged and
    # skipped for this run only. Raising would end the run at the same slug every time, which
    # would stall `update` (the slug stays "new") and every restarted backfill. It is not put
    # in skip.json because these failures are usually temporary; the next run retries it.
    try:
        page = fetch(f"{BASE}/posts/transcripts/{slug}")
    except (urllib.error.URLError, RuntimeError) as e:
        log(f"error {slug}: {e}; will retry next run")
        return False
    if page is None:
        store.mark_skip(slug, "404")
        log(f"skip {slug}: 404")
        return False
    md = render(slug, page)
    if md is None:
        store.mark_skip(slug, "no transcript body")
        log(f"skip {slug}: no transcript body")
        return False
    log(f"saved {store.save(slug, md).relative_to(store.out)}")
    return True


def cmd_update(store: Store, max_pages: int) -> int:
    saved = 0
    for page_no in range(1, max_pages + 1):
        page = fetch(LISTING.format(page=page_no))
        slugs = list(dict.fromkeys(SLUG_HREF.findall(page or "")))
        if not slugs:
            log(f"page {page_no}: no transcript links; stopping")
            break
        new = [s for s in slugs if not store.has(s)]
        log(f"page {page_no}: {len(slugs)} listed, {len(new)} new")
        for slug in new:
            saved += fetch_one(store, slug)
        # The listing is newest-first, so a page with nothing new means everything older is
        # either on disk already or belongs to the backfill.
        if not new:
            break
    log(f"update done: {saved} saved")
    return 0


def sitemap_slugs() -> list[str]:
    index = fetch(SITEMAP_INDEX) or ""
    slugs: list[str] = []
    for loc in SITEMAP_LOC.findall(index):
        for url in SITEMAP_LOC.findall(fetch(loc) or ""):
            m = re.match(re.escape(BASE) + r"/posts/transcripts/([a-z0-9][a-z0-9-]*)$", url)
            if m:
                slugs.append(m.group(1))
    return list(dict.fromkeys(slugs))


def listing_slugs() -> list[str]:
    slugs: list[str] = []
    for page_no in range(1, 1000):
        found = SLUG_HREF.findall(fetch(LISTING.format(page=page_no)) or "")
        if not found:
            break
        slugs.extend(found)
        if page_no % 25 == 0:
            log(f"listing: walked {page_no} pages, {len(set(slugs))} slugs")
    return list(dict.fromkeys(slugs))


def cmd_backfill(store: Store, show_patterns: list[str], limit: int | None) -> int:
    # Both sources, because neither is complete on its own (checked 2026-10-21): the sitemap
    # was ~20 Security Now episodes behind and had 3 AI User Group episodes; the listing is
    # current but costs ~250 requests to walk. Cached for a day so a restarted backfill
    # resumes without re-walking.
    cache = store.state / "catalogue-slugs.json"
    if cache.exists() and time.time() - cache.stat().st_mtime < 86400:
        slugs = json.loads(cache.read_text())
    else:
        slugs = list(dict.fromkeys(listing_slugs() + sitemap_slugs()))
        cache.write_text(json.dumps(slugs))
    log(f"catalogue: {len(slugs)} transcript URLs")
    wanted = [re.compile(p) for p in show_patterns]
    todo = [s for s in slugs if not store.has(s) and (not wanted or any(w.search(s) for w in wanted))]
    if limit is not None:
        todo = todo[:limit]
    log(f"backfill: {len(todo)} to fetch (~{len(todo) * CRAWL_DELAY / 60:.0f} min at the crawl delay)")
    saved = sum(fetch_one(store, s) for s in todo)
    log(f"backfill done: {saved} saved")
    return 0


GRC_FIELD = re.compile(r"^([A-Z][A-Z ]*[A-Z]):\t+(.*?)\s*$", re.M)


def render_grc(n: int, text: str) -> str | None:
    """Markdown for a GRC transcript, or None if it does not look like one."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    fields = {k: v for k, v in GRC_FIELD.findall(text[:3000])}
    desc_m = re.search(r"^DESCRIPTION:\s+(.*)$", text, re.M)
    if "TITLE" not in fields or not desc_m:
        return None
    # The body is everything from DESCRIPTION on: it stays searchable, and the speaker turns
    # (`STEVE:  text`, one paragraph per line) need no conversion.
    body = "\n".join(ln.rstrip() for ln in text[desc_m.start():].split("\n")).strip()
    if len(body) < 500:
        return None
    date = None
    try:
        date = dt.datetime.strptime(fields.get("DATE", ""), "%B %d, %Y").date().isoformat()
    except ValueError:
        pass
    title = f"Security Now {n}: {fields['TITLE']}"
    front = {
        "title": title,
        "show": "security-now",
        "show_name": "Security Now",
        "episode": n,
        "date": date,
        "url": GRC_URL.format(n=n),
        "slug": f"sn-{n:04d}",
        "source": "grc.com",
        "fetched": dt.date.today().isoformat(),
        "description": desc_m.group(1).strip(),
        "note": "Human-made GRC transcript; no timecodes. Licensed CC BY-NC-SA 2.5 (see footer).",
    }
    fm = "\n".join(f"{k}: {json.dumps(v)}" for k, v in front.items())
    return f"---\n{fm}\n---\n\n# {title}\n\n{body}\n"


def grc_known(store: Store) -> set[int]:
    return {int(p.stem[3:]) for p in (store.out / GRC_DIR).glob("sn-*.md")}


def grc_fetch_one(store: Store, n: int) -> bool | None:
    """True saved, False unusable, None 404 (not published, or never transcribed)."""
    text = fetch(GRC_URL.format(n=n))
    if text is None:
        return None
    md = render_grc(n, text)
    if md is None:
        log(f"grc sn-{n}: not a transcript")
        return False
    log(f"saved {store.save(f'sn-{n:04d}', md, GRC_DIR).relative_to(store.out)}")
    return True


def cmd_grc_update(store: Store) -> int:
    known = grc_known(store)
    if not known:
        log("grc: nothing on disk yet; run grc-backfill first")
        return 0
    # GRC posts the transcript a few days after the episode, so the next number 404s until
    # then. That is the normal idle case, one request, and is never recorded as a gap.
    n, saved = max(known) + 1, 0
    try:
        while saved < 5 and grc_fetch_one(store, n):
            n, saved = n + 1, saved + 1
    except (urllib.error.URLError, RuntimeError) as e:
        log(f"grc sn-{n}: {e}; will retry next run")
    log(f"grc update done: {saved} saved")
    return 0


def cmd_grc_backfill(store: Store) -> int:
    known = grc_known(store)
    gaps_path = store.state / "grc-missing.json"
    gaps = set(json.loads(gaps_path.read_text())) if gaps_path.exists() else set()
    # Upper bound: the newest Security Now number seen from either source; grc-update then
    # walks past it. TWiT's files give it without probing GRC.
    twit_sn = [classify(p.stem)[1] or 0 for p in (store.out / "security-now").glob("*.md")]
    upper = max([*twit_sn, *known, 1])
    todo = [n for n in range(1, upper + 1) if n not in known and n not in gaps]
    log(f"grc backfill: {len(todo)} to fetch (~{len(todo) * CRAWL_DELAY / 60:.0f} min)")
    saved = 0
    for n in todo:
        try:
            result = grc_fetch_one(store, n)
        except (urllib.error.URLError, RuntimeError) as e:
            # Not a gap: the next backfill retries it (see fetch_one for why not raise).
            log(f"grc sn-{n}: {e}; will retry next run")
            continue
        if result:
            saved += 1
        elif result is None and n == upper:
            pass  # TWiT is usually ahead of GRC; the newest number is unpublished, not a gap
        else:
            gaps.add(n)
            gaps_path.write_text(json.dumps(sorted(gaps)))
            log(f"grc sn-{n}: recorded as missing")
    log(f"grc backfill done: {saved} saved")
    return cmd_grc_update(store)


def locked(store: Store, name: str) -> IO[str] | None:
    # One writer per site: a multi-hour backfill and the scheduled update would otherwise
    # double the request rate to that site. The update just skips its turn; the next one
    # catches up. twit.tv's lock keeps its original name, `.lock`.
    lock = open(store.state / name, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        log(f"another run holds {name}; skipping")
        return None
    return lock


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=Path(os.environ.get("TWIT_TRANSCRIPTS_DIR", DEFAULT_OUT)))
    sub = ap.add_subparsers(dest="cmd", required=True)
    up = sub.add_parser("update", help="fetch new transcripts from twit.tv, then GRC")
    up.add_argument("--max-pages", type=int, default=10)
    bf = sub.add_parser("backfill", help="fetch the twit.tv back catalogue")
    bf.add_argument("--show", action="append", default=[], help="slug regex; repeatable; omit for all")
    bf.add_argument("--limit", type=int)
    sub.add_parser("grc-backfill", help="fetch GRC's Security Now transcripts 1..latest")
    args = ap.parse_args()

    store = Store(args.out.expanduser())
    if args.cmd == "grc-backfill":
        return cmd_grc_backfill(store) if locked(store, "grc.lock") else 0
    if args.cmd == "backfill":
        return cmd_backfill(store, args.show, args.limit) if locked(store, ".lock") else 0
    if lock := locked(store, ".lock"):
        cmd_update(store, args.max_pages)
        lock.close()
    if locked(store, "grc.lock"):
        cmd_grc_update(store)
    return 0


if __name__ == "__main__":
    sys.exit(main())
