# documents

Derek's `~/Documents`, as a live Syncthing replica inside the hermes pod — the
same pattern as `ai/vault`, one level up the tree. Two goals: a backup copy
beyond iCloud/Time Machine, and read access for the agents (organizing help,
the reader-email archive under `Fiction/`). Hermes mounts it at
`/opt/data/documents`; the sidecar's Syncthing folder path is the same.

This app is only the volume. The Syncthing sidecar, its init container and the
GUI route live in `ai/hermes`, because the claim is RWO and the peer has to
share the pod that holds it.

## How the tree moves

```
Mac (aurelia) ── Syncthing ── NAS ──┬── TrueNAS sync job → Storj (off-site)
                                  ├── productivity/vault-sync (vault only)
                                  └── ai/hermes sidecar (this)
```

- The NAS is the introducer, as for the vault. The pod side dials out; its sync
  port is not exposed.
- Nothing in this pod runs git against this tree, and nothing commits it
  anywhere. Backup is the NAS dataset's Storj sync job, not kopiur, not Gitea
  (the vault is the only Syncthing tree with a committer).

## Overlap with the vault share (the one hard rule)

The Obsidian vault (`~/Documents/Obsidian`) is already its own Syncthing folder
on this pod. Two Syncthing folders covering the same bytes is unsupported and
corrupts indexes, so `/Obsidian` is excluded from THIS share on every device
that holds it — seeded into the pod's `.stignore` by the hermes init
container, and it must also be in the Mac-side and NAS-side `.stignore` for
this share (`.stignore` is per-device and never synced).

## Per-device excludes = backup coverage ≠ agent visibility

Because `.stignore` is per-device, the NAS replica can hold everything (so
Storj backs it all up) while the pod's exclude list keeps sensitive subtrees
(taxes, financial records, anything Derek names) off the cluster entirely.
The pod's `.stignore` is editable in the sidecar's GUI; the init container
only seeds it when absent, so manual curation survives pod restarts.

## Who writes what

Agents in this pod READ the whole tree and WRITE only subtrees Derek has
designated (starting with the reader-email archive under `Fiction/`). The Mac
writes everything else. One writer per file, like the vault's `AGENTS.md`
rules — a `*.sync-conflict-*` copy here means the discipline broke. `.git`
directories are excluded on both ends: the Fiction repo stays Mac-git-only,
and the pod's contributions flow back as plain file writes.
