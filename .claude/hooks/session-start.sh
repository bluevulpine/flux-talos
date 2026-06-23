#!/usr/bin/env bash
set -euo pipefail

# Superpowers plugin bootstrap for Claude Code web sessions.
#
# Web sessions run in fresh ephemeral containers cloned from the repo. The
# plugin *declaration* lives in .claude/settings.json (extraKnownMarketplaces +
# enabledPlugins), but the plugin *payload* lives in ~/.claude/plugins/cache,
# which is outside the repo and not persisted. This hook re-fetches it on
# session start so the declared plugin actually loads. Idempotent.

# Only needed in the remote/web environment; local installs persist on their own.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Already present in this container — skip the network round-trip.
if [ -d "$HOME/.claude/plugins/cache/superpowers-marketplace/superpowers" ]; then
  exit 0
fi

# Keep stdout clean so install chatter is not injected into the session context.
{
  claude plugin marketplace add obra/superpowers-marketplace
  claude plugin install superpowers@superpowers-marketplace
} >"$HOME/.claude/superpowers-bootstrap.log" 2>&1 || true

exit 0
