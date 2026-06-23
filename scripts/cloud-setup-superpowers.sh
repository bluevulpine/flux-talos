#!/bin/bash
# Claude Code on the web — environment setup script (source of truth).
#
# IMPORTANT: This file is NOT executed automatically. It is the canonical copy
# of the setup script that must be pasted into the cloud environment settings
# ("Setup script" field) at claude.ai/code. Setup scripts are attached to the
# environment, not the repo.
#
# Why a setup script (and not a SessionStart hook): the setup script runs
# BEFORE Claude Code launches and its filesystem output is cached/snapshotted,
# so the plugin is on disk when Claude enumerates skills at process init. A
# SessionStart hook runs AFTER launch, too late for the skills to load that
# session. See https://code.claude.com/docs/en/claude-code-on-the-web
#
# Requires network access to github.com (default "Trusted" policy is fine).

# || true so an intermittent failure doesn't block the session from starting.
claude plugin marketplace add obra/superpowers-marketplace || true
claude plugin install superpowers@superpowers-marketplace || true
