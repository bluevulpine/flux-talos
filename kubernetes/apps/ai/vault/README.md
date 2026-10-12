# vault

The Obsidian vault, as a live Syncthing replica inside the hermes pod. Hermes
mounts it at `/opt/data/vault` (`OBSIDIAN_VAULT_PATH`); every Hermes profile
served by the one gateway sees the same files, and agents read and write them
directly. The whole vault is replicated, not only `_agents/`: Derek wants the
agents able to help with the rest of his Obsidian work too.

This app is only the two volumes and the GUI login Secret. The Syncthing
sidecar, its init container and the GUI route live in `ai/hermes`, because the
vault claim is RWO and the peer has to share the pod that holds it.

## How the vault moves

```
Mac (aurelia) ──┐                                  ┌── productivity/vault-sync
                ├── Syncthing ── NAS `vault` ───────┤      └─ committer → Gitea bluevulpine/obsidian-vault
phone (LiveSync)┘   (introducer)                   └── ai/hermes sidecar (this)
```

- The NAS is the introducer; every peer pairs with it and it hands out the rest.
- `productivity/vault-sync`'s committer is the **only** writer to the Gitea
  repo. Nothing in this pod runs git against the vault. An agent's edit reaches
  Gitea by Syncthing → NAS → vault-sync pod → its next 15-minute commit.
- Backups: none here on purpose. The vault lives on the NAS, on the Mac, in the
  vault-sync replica and in Gitea; a kopiur restore of this volume would only
  hand Syncthing a stale tree to reconcile. Losing both claims costs a re-pair
  and one ~730 MiB pull.

## Who writes what

The rules are the vault's own: `AGENTS.md` at the vault root, which every
Hermes profile reads because the vault is its working directory for memory
work. In short: agents write only under `_agents/`, one fact per line with a
provenance tag, no secrets. The cross-device rules matter most here, because
this replica and the Mac edit the same tree while apart:

- one writer per file: the daily log is `_agents/log/YYYY-MM-DD-<agent>.md`,
  never a shared file;
- agents in this pod write only their log, their notebook and `_agents/inbox/`;
  promotion into the curated `shared/` files happens from the Mac side (and
  the weekly dreaming pass), so no file is rewritten from two devices;
- a `*.sync-conflict-*` copy means the rule was broken. git ignores the copies,
  so vault-sync's committer fails its run while one exists (#2158), which is
  the alert.

What this side keeps out, via the per-device `.stignore` the init container
seeds (edit it on the volume; Syncthing never syncs ignore files):

| pattern | why |
| --- | --- |
| `lost+found` | ext4's root-owned dir at the volume root; would otherwise be announced to every peer |
| `.git`, `.qmd` | the Mac's local git checkout and search index |
| `.obsidian/plugins/obsidian-livesync` | holds CouchDB credentials; the vault's `.gitignore` excludes it from git for the same reason |

## One-time setup (after merge)

1. **Get the sidecar's device ID**
   `kubectl -n ai exec deploy/hermes -c syncthing -- syncthing --home=/var/syncthing/config device-id`
2. **On the NAS's Syncthing** add it as a remote device (name it something
   unambiguous, e.g. `k8s-hermes-vault`; the NAS itself is called `vault`) and
   share the Obsidian folder (`ftk9p-v9mgn`) with it.
3. **In the sidecar's GUI**, `https://syncthing-hermes.${SECRET_DOMAIN}` (Authentik,
   then the login from OpenBao `secret/vault-sync`: `VaultSync__GuiUser` /
   `VaultSync__GuiPassword`, the same as the vault-sync GUI):
   - add the NAS (`LPIWKNK-CZJS3DZ-GZBOFFU-RZAUXEE-7KJVZJW-35C2FLR-2BRGPEE-YLJWCAE`)
     as a remote device and tick **Introducer**;
   - accept the shared folder with path **`/opt/data/vault`** and folder type
     **Receive Only**. The NAS stays authoritative until the first sync has
     landed and the tree has been inspected.

   Receive Only limits Syncthing, not the agents: the mount is read-write and
   `OBSIDIAN_VAULT_PATH` is set from the moment this merges. Anything an agent
   writes before pairing, or while the folder is Receive Only, shows as
   "Locally Changed", never reaches the NAS, and **Revert Local Changes**
   deletes it. So until step 4, tell the Hermes profiles not to write to the
   vault, and do not press Revert without reading what the cluster side holds.
4. Wait for Up to Date, check the tree from the hermes side
   (`kubectl -n ai exec deploy/hermes -- ls -la /opt/data/vault`), then flip the
   folder to **Send & Receive**. Only then do agent writes propagate.

## Invariants

- The sidecar runs as uid/gid 10000, the same as the gateway: Syncthing
  replicates the Mac's 0600/0700 modes, so fsGroup alone would not let the
  agents read what it writes.
- Rotating the GUI login in OpenBao rolls the hermes pod (reloader on the
  Deployment), not only the sidecar.
- `.stignore` is seeded once and then owned by the volume; the init container
  does not overwrite an existing one.
