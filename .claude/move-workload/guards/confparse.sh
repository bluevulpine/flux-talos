#!/bin/bash
# confparse.sh — parse a per-move config as DATA (never sourced, nothing in it is executed). Sourced by move-guards.sh AND by the test harnesses, so the
# README's "config is data" claim holds for the step that runs the harness against the real conf (N5).
#   parse_conf <file> "<KEY KEY ...>"   sets each key found in the file as a shell variable; returns 1 (message on stderr) on anything else.
# Accepted lines: blank, `# comment`, and KEY="value" (optional trailing # comment) for a KEY in the list, at most once, value free of $ ` \ and " —
# except a leading $HOME/, which is expanded from the PASSWD DATABASE, not from the environment (an inherited HOME=/tmp/attacker cannot redirect STATE_DIR).
_cp_home() {
  local h=""
  if command -v getent >/dev/null 2>&1; then h=$(getent passwd "$(id -un)" | cut -d: -f6); fi
  if [ -z "$h" ] && command -v dscl >/dev/null 2>&1; then h=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}'); fi
  [ -n "$h" ] || h=$HOME
  printf '%s' "$h"
}
# shellcheck disable=SC2016  # the single-quoted `$` below are regex/literal text, not expansions
_CP_LINE='^[[:space:]]*([A-Z][A-Z0-9_]*)="(\$HOME/[^"$`\\]*|[^"$`\\]*)"[[:space:]]*(#.*)?$'
parse_conf() {
  local f=${1:-} keys=${2:-} l k v seen=" " home=""
  [ -f "$f" ] || { echo "REFUSE (config): no such file [$f]" >&2; return 1; }
  while IFS= read -r l || [ -n "$l" ]; do
    [[ -z "${l//[[:space:]]/}" ]] && continue
    [[ $l =~ ^[[:space:]]*# ]] && continue
    [[ $l =~ $_CP_LINE ]] || { echo "REFUSE (config $f): line is not KEY=\"value\": [$l]" >&2; return 1; }
    k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
    case " $keys " in *" $k "*) ;; *) echo "REFUSE (config $f): unknown key [$k]" >&2; return 1;; esac
    case "$seen" in *" $k "*) echo "REFUSE (config $f): duplicate key [$k]" >&2; return 1;; esac
    seen="$seen$k "
    # shellcheck disable=SC2016
    case "$v" in '$HOME/'*) [ -n "$home" ] || home=$(_cp_home); v="$home/${v#'$HOME/'}";; esac
    printf -v "$k" '%s' "$v"
  done < "$f"
}
