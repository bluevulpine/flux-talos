# TWiT transcripts → qmd `twit-transcripts`

TWiT.tv episode transcripts (Security Now, AI User Group, Intelligent Machines, This Week in
Tech and every other show TWiT transcribes) are mirrored as markdown on **aurelia** and
indexed by qmd, so any agent session on the Mac can search them.

| | |
| --- | --- |
| Fetcher | `scripts/twit-transcripts/twit_transcripts.py`, installed as `~/.local/bin/twit_transcripts.py` |
| Schedule | `net.bluevulpine.twit-transcripts` LaunchAgent, 00:40 / 06:40 / 12:40 / 18:40 local |
| Files | `~/Documents/twit-transcripts/<show>/<slug>.md` |
| Index | qmd collection `twit-transcripts`, refreshed hourly by `com.qmd-sessions.refresh` |
| Logs | `~/Library/Logs/twit-transcripts.log` (scheduled), `twit-transcripts-backfill.log` |
| Latency | ≤ ~7 h from publication to searchable (6 h fetch + 1 h index) |

## Why on the Mac, not a CronJob

qmd's index (`~/.cache/qmd/index.sqlite`) and every collection path in
`~/.config/qmd/index.yml` are local to aurelia, and the hourly qmd refresh already runs
`qmd update` + `qmd embed` over all collections. Writing markdown into a local directory is
the whole integration. A CronJob would need a PVC plus a way to sync the files back to the
Mac, and qmd would still only run here. The cost is that fetching stops while aurelia is off;
launchd runs a missed calendar slot once on wake, so the job catches up by itself.

The fetcher lives in this repo only so it is version-controlled next to the runbook; nothing
in Flux deploys it.

## For agents: how to query

Use the qmd MCP tool with `collections: ["twit-transcripts"]`:

```json
{
  "collections": ["twit-transcripts"],
  "intent": "Security Now discussion of passkeys and the FIDO spec",
  "searches": [
    {"type": "lex", "query": "passkeys FIDO"},
    {"type": "vec", "query": "what did Steve Gibson say about passkey syncing"}
  ]
}
```

- **One show only**: `query` has no path filter, so name the show in the `lex` sub-query
  (`"Security Now" passkeys`) and keep hits whose `file` starts with
  `twit-transcripts/<show>/`; raise `limit` if the show is crowded out. For exhaustive
  "every episode that mentions X", grep the show directory instead. Show directories:
  `security-now`, `ai-user-group`, `intelligent-machines`, `week-tech` (This Week in Tech),
  `macbreak-weekly`, `windows-weekly`, `week-google` (TWiG, Intelligent Machines'
  predecessor), … — `ls ~/Documents/twit-transcripts` for the full list.
- **A known episode**: `mcp__qmd__get` with `twit-transcripts/security-now/security-now-1100-transcript.md`,
  or `multi_get` with `twit-transcripts/security-now/security-now-10*.md`. Files are large
  (100–200 KB for a 2–3 h show); read with `fromLine`/`maxLines` around the hit's `line`.
- **Front matter**: `show`, `show_name`, `episode`, `date` (ISO), `url`, `slug`. For AI User
  Group, `episode` is the AUG number and `feed_episode` the Club TWiT feed number in the slug.
- **Turns** are one line each: `Speaker [hh:mm:ss]: text`. Grep works too:
  `grep -rn "Steve Gibson \[" ~/Documents/twit-transcripts/security-now | head`.
- **Quote with care**: TWiT's transcripts are AI-generated and not word-for-word (speaker
  labels and names are sometimes wrong, e.g. "Micah" for Mikah Sargent). Cite the episode URL
  and the timecode, and say it is from the transcript, not a verbatim quote. Timecodes are for
  the ad-free edition.

## What it fetches, and how politely

- `update` (scheduled) reads `https://twit.tv/posts/transcripts?page=N` from page 1 and
  fetches every slug not on disk, stopping at the first page with nothing new (cap 10 pages).
  An idle run is one request.
- `backfill --show <slug regex>` gathers the catalogue from **both** a full walk of the
  listing (~250 pages) and the sitemap (`sitemap.twit.tv`, 21 sub-sitemaps), then fetches what
  is missing. Neither source was complete alone on 2026-10-21: the sitemap stopped at
  Security Now 1081 (current: 1101) and had 3 AI User Group episodes. The slug list is cached
  for a day in `.state/catalogue-slugs.json`.
- Every request is ≥ 10 s apart: twit.tv's `robots.txt` sets `Crawl-delay: 10`. 429/5xx back
  off (honouring `Retry-After`) and retry 4×.
- One run at a time (`flock` on `.state/.lock`); a scheduled update that finds the backfill
  running skips its turn.
- A slug that 404s or has no transcript body goes in `.state/skip.json` and is not retried.
  Delete the entry, or a `.md`, to force a re-fetch.

Slugs are hand-typed and inconsistent (`security-now-episode-847-transcript`,
`macbreak-weekly-411-transcripts`, `week-enterprise-tech-N-trascript`, bare `week-tech-473`,
the `weel-tech` typo). `classify()` takes the number before the "tr…" word as the episode and
maps typos through `SHOW_ALIASES`; add an alias there if a new variant lands in its own
directory.

Coverage on twit.tv: transcripts start around Security Now 847 (late 2021); there is no
twit.tv transcript for earlier episodes.

## Install / reinstall

```bash
install -m 755 scripts/twit-transcripts/twit_transcripts.py ~/.local/bin/twit_transcripts.py
cp scripts/twit-transcripts/net.bluevulpine.twit-transcripts.plist ~/Library/LaunchAgents/
launchctl bootout gui/$(id -u)/net.bluevulpine.twit-transcripts 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/net.bluevulpine.twit-transcripts.plist
```

The collection entry in `~/.config/qmd/index.yml`:

```yaml
  twit-transcripts:
    path: /Users/bluevulpine/Documents/twit-transcripts
    pattern: "*/*.md"
```

`*/*.md` (not `**`) keeps `.state/` out of the index.

## Operating it

```bash
launchctl kickstart gui/$(id -u)/net.bluevulpine.twit-transcripts      # run an update now
tail -f ~/Library/Logs/twit-transcripts.log
nohup python3 -I ~/.local/bin/twit_transcripts.py backfill --show '^windows-weekly' \
  >> ~/Library/Logs/twit-transcripts-backfill.log 2>&1 &              # more back catalogue
nohup python3 -I ~/.local/bin/twit_transcripts.py backfill \
  >> ~/Library/Logs/twit-transcripts-backfill.log 2>&1 &              # everything (~10 h)
qmd update && qmd embed -c twit-transcripts                            # index now, not at :xx
```

Embedding cost measured 2026-10-21: 15 episodes = 724 chunks in 21 s, so the full catalogue
(~3.7k episodes) is roughly 1.5 h of `qmd embed`, spread over hourly refreshes.

## Failure signals

- No new files for > 1 day while TWiT is publishing: check the log for HTTP errors; a
  markup change shows up as every slug going to `skip.json` with "no transcript body".
- `qmd status` shows the collection's file count lagging `ls */*.md | wc -l`: the hourly
  refresh is skipping (it skips when an embed is already running); see
  `~/Library/Logs/qmd-sessions-refresh.log`.
