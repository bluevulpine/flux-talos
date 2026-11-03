#!/bin/sh
# Plex library database maintenance: integrity check, then rebuild both
# databases by dump + re-import (which also defragments them and rebuilds
# every index), then swap the rebuilt files in.
#
# Why not ChuckPa's DBRepair: DBRepair.sh was retired upstream on 2026-11-02
# and removed from public view; its replacement (v26.10.00, first released
# 2026-10-16) is a proprietary compiled binary that may not be inspected. This
# script is the standard SQLite rebuild (integrity check -> .dump -> import
# into a fresh file -> verify -> swap), written from scratch, so every
# operation run against the only live copy of the library is readable here.
# DBRepair stays the fallback for real corruption: it also checks and rebuilds
# Plex's FTS tables version-aware, which a plain dump/import does not
# (upstream #247 is an import failing on fts4_metadata_titles_icu_segdir).
#
# Must run with Plex STOPPED, inside a pod using Plex's own image: "Plex
# SQLite" carries the ICU/FTS extensions the schema needs; a stock sqlite3
# cannot import the dump.
#
# Usage (inside the helper pod, as uid 568):
#   plexdb-maint.sh check   integrity + row counts only; changes nothing except
#                           a WAL checkpoint (folds the WAL into the .db)
#   plexdb-maint.sh rebuild check, then dump/import into $WORK/new; does NOT
#                           touch the live files
#   plexdb-maint.sh swap    move the rebuilt files from the last rebuild into
#                           place, keeping the originals under $WORK/orig
set -eu

SQLITE="/usr/lib/plexmediaserver/Plex SQLite"
DBDIR="${DBDIR:-/config/Library/Application Support/Plex Media Server/Plug-in Support/Databases}"
MAIN=com.plexapp.plugins.library.db
BLOBS=com.plexapp.plugins.library.blobs.db
# On the same filesystem as DBDIR, so the swap is a rename, not a copy.
WORKROOT="${WORKROOT:-/config/dbmaint}"
MODE="${1:-}"

die() { echo "FAIL: $*" >&2; exit 1; }
log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }
sq() { "$SQLITE" "$@"; }

[ -x "$SQLITE" ] || die "no Plex SQLite at $SQLITE (wrong image?)"
cd "$DBDIR" || die "cannot cd to $DBDIR"
[ -s "$MAIN" ] || die "$MAIN missing or empty"
[ -s "$BLOBS" ] || die "$BLOBS missing or empty"

# Tables whose row counts must survive the rebuild exactly. View state
# (metadata_item_settings/views) is what a bad repair loses first.
MAIN_TABLES="library_sections metadata_items media_items media_parts media_streams metadata_item_settings metadata_item_views accounts taggings tags"

counts() { # db tables... -> "table=count" lines
  db=$1; shift
  for t in "$@"; do
    n=$(sq "$db" "SELECT count(*) FROM $t;") || die "count($t) failed on $db (table missing after a PMS schema change?)"
    # An empty or non-numeric count on both sides would diff equal and hide
    # a missing table.
    case "$n" in '' | *[!0-9]*) die "count($t) on $db returned '$n'" ;; esac
    printf '%s=%s\n' "$t" "$n"
  done
}

blob_tables() { sq "$1" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"; }

integrity() { # db label
  r=$(sq "$1" "PRAGMA integrity_check;" | head -20)
  [ "$r" = "ok" ] || { echo "$r" >&2; die "integrity_check on $2: not ok"; }
  log "integrity_check $2: ok"
}

check() {
  for db in "$MAIN" "$BLOBS"; do
    log "checkpoint $db"
    # TRUNCATE folds the WAL into the database and empties it, so the copy
    # and the dump below see one self-contained file.
    sq "$db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
    integrity "$db" "$db"
  done
  ls -la "$DBDIR"/com.plexapp.plugins.library*.db*
}

rebuild() {
  TS=$(date -u +%Y%m%dT%H%M%SZ)
  WORK="$WORKROOT/$TS"
  mkdir -p "$WORK/orig" "$WORK/new"
  check

  log "copy originals to $WORK/orig"
  for f in "$MAIN" "$MAIN-wal" "$MAIN-shm" "$BLOBS" "$BLOBS-wal" "$BLOBS-shm"; do
    [ -e "$f" ] && cp -p "$f" "$WORK/orig/"
  done

  # shellcheck disable=SC2086 # word-splitting the table list is intended
  counts "$MAIN" $MAIN_TABLES >"$WORK/main.before"
  # shellcheck disable=SC2046 # word-splitting the table list is intended
  counts "$BLOBS" $(blob_tables "$BLOBS") >"$WORK/blobs.before"

  for db in "$MAIN" "$BLOBS"; do
    log "dump $db"
    sq "$db" ".output '$WORK/$db.sql'" .dump
    # .dump ends with "ROLLBACK; -- due to errors" when it hit an unreadable
    # page. This script is maintenance for a database that passed
    # integrity_check, not salvage: a corrupt library goes to DBRepair (see
    # the header), so stop here rather than import a partial dump.
    if tail -1 "$WORK/$db.sql" | grep -q '^ROLLBACK;'; then
      die "dump of $db ended in ROLLBACK (unreadable pages) - stop; use DBRepair"
    fi
    log "import $db"
    sq "$WORK/new/$db" <"$WORK/$db.sql"
    integrity "$WORK/new/$db" "rebuilt $db"
  done

  # shellcheck disable=SC2086
  counts "$WORK/new/$MAIN" $MAIN_TABLES >"$WORK/main.after"
  # shellcheck disable=SC2046
  counts "$WORK/new/$BLOBS" $(blob_tables "$BLOBS") >"$WORK/blobs.after"
  diff "$WORK/main.before" "$WORK/main.after" || die "main row counts differ (see $WORK)"
  diff "$WORK/blobs.before" "$WORK/blobs.after" || die "blobs row counts differ (see $WORK)"
  log "row counts identical:"
  cat "$WORK/main.after"
  ls -la "$WORK/orig" "$WORK/new"
  # Written only after every check above passed; swap requires it. (The
  # .after files exist even when the diff failed, so they prove nothing.)
  touch "$WORK/VERIFIED"
  log "rebuild OK in $WORK; run 'swap' to make it live"
}

swap() {
  # Newest run: the directory names are UTC timestamps, so glob order is
  # chronological.
  WORK=""
  for d in "$WORKROOT"/*/; do [ -d "$d" ] && WORK=${d%/}; done
  [ -n "$WORK" ] && [ -s "$WORK/new/$MAIN" ] && [ -s "$WORK/new/$BLOBS" ] || die "no completed rebuild under $WORKROOT"
  [ -e "$WORK/VERIFIED" ] || die "$WORK was not verified (rebuild failed or did not finish) - rebuild again"
  # The live files must still be the ones the rebuild read: if Plex ran in
  # between, its writes would be lost by the swap. Writes may sit only in the
  # WAL (the .db changes on checkpoint), and rebuild left each WAL truncated
  # to zero, so a non-empty WAL also means someone wrote.
  for db in "$MAIN" "$BLOBS"; do
    cmp -s "$db" "$WORK/orig/$db" || die "$db changed since the rebuild (did Plex start?) - rebuild again"
    [ ! -s "$db-wal" ] || die "$db-wal is not empty: something wrote since the rebuild - rebuild again"
  done
  log "swap from $WORK"
  for f in "$MAIN-wal" "$MAIN-shm" "$BLOBS-wal" "$BLOBS-shm"; do rm -f "$f"; done
  mv "$WORK/new/$MAIN" "$MAIN"
  mv "$WORK/new/$BLOBS" "$BLOBS"
  integrity "$MAIN" "live $MAIN"
  integrity "$BLOBS" "live $BLOBS"
  ls -la "$DBDIR"/com.plexapp.plugins.library*.db*
  log "done; originals kept in $WORK/orig (delete after Plex has run cleanly)"
}

case "$MODE" in
  check) check ;;
  rebuild) rebuild ;;
  swap) swap ;;
  *) die "usage: $0 check|rebuild|swap" ;;
esac
