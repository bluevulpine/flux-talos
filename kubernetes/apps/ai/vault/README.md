# vault

The shared notes vault: plain Markdown in Obsidian format, mounted by the hermes
pod at `/opt/data/vault` (`OBSIDIAN_VAULT_PATH`). Every Hermes profile served by
the one gateway sees the same files.

This app is only the volume and its backups. Hermes mounts it with
`existingClaim: vault`; nothing here runs.

## Layout and write rules

The rule that keeps two agents from fighting over a file is structural: one
writer per file.

- `agents/<name>/` — an agent's own notes and memory files. Only that agent writes here.
- `inbox/<name>/` — an agent's proposals for shared notes. Only that agent writes
  here; a human (or a designated curator) merges them into shared notes.
- Everything else — human-authored and shared notes. Agents read it and do **not**
  edit in place. Per-agent daily logs go in their own file
  (`daily/2026-10-04.bosun.md`) and are linked from the human's daily note.

## Backups

- kopiur, local leg every 30 min (`:03/:33`) and R2 nightly (02:08 UTC), via
  `components/kopiur`. Snapshot copy method (RWO volume held by hermes).
- The claim is born on kopiur: no VolSync history, no `dataSourceRef`. A rebuild
  restores through a kopiur Restore (docs/runbooks/kopiur-migration.md).

## Not done here

- Syncthing sidecar (NAS peer) and the commit-to-Gitea history job are separate PRs.
- The existing `productivity/obsidian` + `couchdb` (LiveSync) apps are untouched
  and hold their own copy of the vault.
