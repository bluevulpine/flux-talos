# vault-sync: Obsidian vault Syncthing peer + git auto-committer

A Syncthing peer that holds a live replica of the Obsidian vault, plus a CronJob that
commits that replica to Gitea `bluevulpine/obsidian-vault` every 15 minutes. **This pod is
the only writer to that repo.** The Mac and NAS are readers.

| Piece | Where |
| --- | --- |
| Syncthing GUI | `https://syncthing-vault.${SECRET_DOMAIN}`, internal gateway, behind Authentik forward auth |
| Vault on disk | PVC `vault-sync-data`, subdirectory `vault/` (Syncthing: `/var/syncthing/data/vault`, committer: `/data/vault`) |
| Syncthing config | PVC `vault-sync-config` at `/var/syncthing/config` |
| Push credential | OpenBao `secret/vault-sync` field `VaultSync__SshPrivateKey` = Gitea deploy key `vault-sync` (write) |
| GUI login | OpenBao `secret/vault-sync` fields `VaultSync__GuiUser` / `VaultSync__GuiPassword`, applied on every pod start by the `gui-auth` init container |
| Gitea host key | pinned in `app/resources/known_hosts` |

Neither PVC is backed up by kopiur on purpose: the vault lives in Gitea, on the NAS and on
the Mac, and losing Syncthing's config costs only a re-pair.

## One-time setup

Already done (2026-10-12): the deploy key exists on the repo and in OpenBao, and the GUI
login is in OpenBao (`bao kv get -field=VaultSync__GuiPassword secret/vault-sync`). Change
it with `bao kv patch` (never `put`, which drops the other fields); Reloader rolls the pod.

1. **Pair Syncthing.** Get the pod's device ID:
   `kubectl -n productivity exec deploy/vault-sync-syncthing -c app -- syncthing cli show system | jq -r .myID`
   - On the **NAS** (`vault` Syncthing, `LPIWKNK-…`): Add Remote Device → the pod's ID,
     name `k8s-vault-sync`, share folder `ftk9p-v9mgn` (Obsidian) with it.
   - In the **pod's** GUI: Add Remote Device →
     `LPIWKNK-CZJS3DZ-GZBOFFU-RZAUXEE-7KJVZJW-35C2FLR-2BRGPEE-YLJWCAE`, tick **Introducer**.
     Accept the shared folder and set its path to **`/var/syncthing/data/vault`**.
   - The introducer brings in the Mac (`HZGAOE4-…`); accept it on the Mac if prompted.
   - The pod dials out; nothing dials in. It finds the NAS through global discovery. If
     the NAS has global discovery off, set the NAS device's address in the pod to
     `tcp://<nas-ip>:22000`.
   - Wait for the folder to show *Up to Date* (~726 MiB first pull).
2. **First commit.** Each run skips until Syncthing has created the folder
   (`.stfolder`), then bootstraps: `git init`, adopt `origin/main`, commit any drift.
   Force one:
   `kubectl -n productivity create job --from=cronjob/vault-sync-committer first-run && kubectl -n productivity logs -f job/first-run`
   Expected: `bootstrap: adopting origin/main…` then `nothing to commit`.
3. **Mac becomes read-only toward origin.** Either obsidian-git in pull-only mode, or a
   launchd job every 15 min:
   `cd ~/Documents/Obsidian && git fetch -q origin && git reset -q origin/main`
   (The working tree already matches via Syncthing; this only moves HEAD.)

## Invariants

- `.git` is never replicated by Syncthing (`.stignore` on every device; the script writes
  the pod's).
- Only the pod pushes. If you push from the Mac by hand, do it only when Syncthing shows
  Up to Date, or the next run "reverts" your push to the replicated state.
- Syncthing conflict copies (`*.sync-conflict-*`) are git-ignored by the repo's
  `.gitignore`. Resolve them in Obsidian.

## When the committer fails

Each schedule is one attempt (`backoffLimit: 0`); a failed Job means one of:

- **Stale Syncthing temp files.** A `.syncthing.*` temp file older than 6h is a pull that
  keeps failing; the Job lists them. Fix the file in Syncthing (folder errors in the GUI).
  Temp files under 10 minutes old make the run skip; ones in between are ignored.
- **The deletion guard,** below.

## The deletion guard

A tree that is still syncing looks like a mass deletion. A run that stages more than
`MAX_DELETIONS` (default 25) deletions refuses to commit and fails the Job. If the
deletions are real (you removed a folder), run once with the limit raised:

```bash
kubectl -n productivity create job --from=cronjob/vault-sync-committer allow-deletes \
  --dry-run=client -o json \
  | jq '.spec.template.spec.containers[0].env += [{"name":"MAX_DELETIONS","value":"100000"}]' \
  | kubectl apply -f -
```
