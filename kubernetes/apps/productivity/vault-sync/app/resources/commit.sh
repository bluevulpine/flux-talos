#!/bin/sh
# Auto-committer for the Obsidian vault. Runs as a CronJob against the
# Syncthing-replicated copy. This pod is the ONLY thing that pushes to origin;
# everything else is a reader (Mac: git fetch && git reset origin/main).
set -eu

: "${GIT_REMOTE:?GIT_REMOTE must be set}"
: "${GIT_AUTHOR_NAME:?GIT_AUTHOR_NAME must be set}"
: "${GIT_AUTHOR_EMAIL:?GIT_AUTHOR_EMAIL must be set}"
VAULT=/data/vault
# A partially synced tree (first pull, or a peer that is behind) shows up as a
# mass deletion. Refuse to push one. Raise this for a run that really deletes.
MAX_DELETIONS="${MAX_DELETIONS:-25}"

# Syncthing writes .stfolder when the share is accepted. Before pairing there is
# nothing here, and adopting origin over an empty tree would stage every file
# as deleted.
if [ ! -d "$VAULT/.stfolder" ]; then
  echo "syncthing folder not set up yet ($VAULT/.stfolder missing); skipping"
  exit 0
fi
cd "$VAULT"

# Syncthing must never replicate .git (per-device .stignore is not synced, so
# create it here). The repo's .gitignore already excludes .stignore.
[ -f .stignore ] || printf '.git\n.qmd\n' > .stignore

export HOME=/tmp
# The secret mount is root-owned 0440 (group via fsGroup); ssh wants a key the
# user owns at 0600.
install -m 0600 /secrets/id_ed25519 /tmp/id_ed25519
export GIT_SSH_COMMAND="ssh -i /tmp/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/scripts/known_hosts"
git config --global safe.directory "$VAULT"
git config --global user.name "$GIT_AUTHOR_NAME"
git config --global user.email "$GIT_AUTHOR_EMAIL"

if [ ! -d .git ]; then
  echo "bootstrap: adopting origin/main into existing working tree"
  git init -q -b main
fi
git remote set-url origin "$GIT_REMOTE" 2>/dev/null || git remote add origin "$GIT_REMOTE"
# Syncthing's own files, excluded here rather than relying on the vault repo's
# .gitignore (which covers .stignore and .stfolder/ today, not the rest).
printf '%s\n' .stignore .stfolder/ .stversions/ '.syncthing.*' > .git/info/exclude

# Skip this run if Syncthing is mid-transfer; the next one picks it up.
if [ -n "$(find . -path ./.git -prune -o -name '.syncthing.*' -mmin -10 -print | head -1)" ]; then
  echo "syncthing has in-flight files; skipping this run"
  exit 0
fi
# Syncthing keeps temp files of failed pulls (24h by default) to resume them.
# One that old means a file is stuck; fail so it alerts instead of the vault
# silently drifting from what is committed.
stale=$(find . -path ./.git -prune -o -name '.syncthing.*' -mmin +360 -print | head -5)
if [ -n "$stale" ]; then
  echo "stale syncthing temp files (failed pull?):" >&2
  echo "$stale" >&2
  exit 1
fi

git fetch -q origin main
# HEAD+index -> origin, working tree untouched. Adopts anything pushed since
# (should be nothing: this is the only pusher).
git reset -q origin/main
git add -A
if git diff --cached --quiet; then
  echo "nothing to commit"
  exit 0
fi

deleted=$(git diff --cached --name-only --diff-filter=D | wc -l | tr -d ' ')
if [ "$deleted" -gt "$MAX_DELETIONS" ]; then
  echo "refusing: $deleted deletions staged (MAX_DELETIONS=$MAX_DELETIONS)." >&2
  echo "Is Syncthing still pulling? If the deletions are real, re-run with MAX_DELETIONS raised. First 20:" >&2
  git diff --cached --name-only --diff-filter=D | head -20 >&2
  git reset -q
  exit 1
fi

changed=$(git diff --cached --name-only | wc -l | tr -d ' ')
git commit -q -m "auto: $(date -u +%Y-%m-%dT%H:%M:%SZ) ($changed files)" \
  -m "$(git diff --cached --name-only | head -20)"
git push -q origin main
echo "pushed: $changed files"
