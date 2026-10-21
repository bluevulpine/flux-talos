#!/usr/bin/env python3
"""Mirror TWiT.tv episode transcripts as markdown for the qmd `twit-transcripts` collection.

Why this runs on aurelia and not in the cluster: qmd's index (~/.cache/qmd/index.sqlite) and
every collection it reads are local to this Mac, and the hourly `com.qmd-sessions.refresh`
LaunchAgent already runs `qmd update` + `qmd embed` over all collections. Writing markdown
into a local directory is therefore all it takes to become searchable; a CronJob would still
need a way to ship files back here. See docs/runbooks/twit-transcripts.md.

  update    walk https://twit.tv/posts/transcripts?page=N from page 1 and fetch slugs not
            yet on disk, stopping at the first page with nothing new (the scheduled mode)
  backfill  list every transcript URL from the sitemap and fetch the missing ones matching
            --show (a regex on the slug); the listing only paginates newest-first, so the
            sitemap is the cheap way to reach the back catalogue

Politeness: twit.tv's robots.txt sets `Crawl-delay: 10`, so every request (listing, sitemap,
transcript) is spaced at least 10 s apart. A full Security Now backfill is ~3 h for that
reason; it is a one-off and runs in the background.

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

BASE = "https://twit.tv"
LISTING = BASE + "/posts/transcripts?page={page}"
SITEMAP_INDEX = "https://sitemap.twit.tv/sitemap.xml"
USER_AGENT = "twit-transcripts-mirror/1.0 (personal search index; honours Crawl-delay)"
CRAWL_DELAY = 10.0
DEFAULT_OUT = Path.home() / "Documents" / "twit-transcripts"

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

    def save(self, slug: str, md: str) -> Path:
        show, _ = classify(slug)
        path = self.out / show / f"{slug}.md"
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
    page = fetch(f"{BASE}/posts/transcripts/{slug}")
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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=Path(os.environ.get("TWIT_TRANSCRIPTS_DIR", DEFAULT_OUT)))
    sub = ap.add_subparsers(dest="cmd", required=True)
    up = sub.add_parser("update", help="fetch new transcripts from the listing")
    up.add_argument("--max-pages", type=int, default=10)
    bf = sub.add_parser("backfill", help="fetch the back catalogue from the sitemap")
    bf.add_argument("--show", action="append", default=[], help="slug regex; repeatable; omit for all")
    bf.add_argument("--limit", type=int)
    args = ap.parse_args()

    store = Store(args.out.expanduser())
    # One writer at a time: a multi-hour backfill and the scheduled update would otherwise
    # double the request rate. The update just skips its turn; the next one catches up.
    lock = open(store.state / ".lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("another run holds the lock; skipping")
        return 0
    if args.cmd == "update":
        return cmd_update(store, args.max_pages)
    return cmd_backfill(store, args.show, args.limit)


if __name__ == "__main__":
    sys.exit(main())
