# Migrating Talos machine config from talhelper to topf

**Date:** 2026-08-31, **revised 2026-09-23** (see [Revision history](#revision-history))
**Status:** Design — topf chosen over OpenTofu on 2026-09-23. Nothing implemented.
**Goal:** Replace the archived `talhelper` with `topf` as the generator for this
cluster's Talos machine configuration, reproducing today's output exactly and
without re-keying the cluster.

## Revision history

**2026-09-23 revision.** The original was written against a 7-node cluster with
three Pi control planes and topf `21831714`. Both have changed. What moved:

| area | 2026-08-31 | 2026-09-23 |
|---|---|---|
| nodes | 7; jormungandr1/2/3 are control planes | **8**; `freyja01` (10.0.10.35, a Talos VM on vault) is the **only** control plane; jormungandr1-3 are low-power workers |
| schematics | 2 (`pi`, `amd`) | **3** — freyja01 has its own (`647d4118…4066`) |
| topf | pin main commit `21831714`; v0.5.0 hangs on EOF | **v0.6.0 is tagged and postdates the pin**; the hang fix is in it. v0.6.1-rc.1 is out. See [Version selection](#version-selection-pin-a-release-not-a-commit) |
| topf maintainers | "bus factor ~4" | 13 contributors, two do ~90% of commits (113 and 44), PostFinance-backed |
| Talos | cluster on v1.13.9, `talconfig.yaml` on v1.13.6 (drift) | drift already fixed: `talconfig.yaml` is `v1.13.9`. Talos v1.14.1 is released; topf supports 1.14 documents |
| `${SECRET_*}` | "at least two" | **three names, 16 occurrences** — `SECRET_DOMAIN` (8, the Nexus mirrors) was missed |
| apply blast radius | roll workers, then CPs; quorum survives | **applying to freyja01 is an API outage** if it needs a reboot |

Decision record: OpenTofu + `siderolabs/talos` was re-evaluated on 2026-09-23 and topf
kept. See [Deferred](#deferred-deliberately) for the reasoning.

## Why now

`budimanjojo/talhelper` was archived on 2026-08-26 (`"archived": true` via the
GitHub API; 694 stars, 36 forks). Its README now reads:

> This project is now archived and abandoned. I suggest people who depend on this
> tool to migrate to other similar tools like topf or talstomize

There is no community continuation to fall back on: all 36 forks have **0 stars**
(checked, sorted by stars descending). Staying put means depending on an abandoned
binary.

Nothing is on fire. talhelper 3.1.17 still generates this cluster's config cleanly
— verified 2026-08-31 against the current `talconfig.yaml`. The risk being managed
is future Talos config document kinds that talhelper will never learn, not a broken
tool today. That buys time to do this carefully.

## Why topf is a safe bet despite being pre-1.0

topf is pre-1.0 (v0.6.0 as of 2026-09-23), with a self-declared unstable CLI and a
thin maintainer base: 13 contributors, but two account for ~90% of commits (113 and
44). It is PostFinance-backed and shipped three releases in the past three weeks, which
is a better position than at 2026-08-31 but not a guarantee. Replacing
one community tool with another looks like trading the same risk for a newer version
of it. It isn't, and here is why: **the artifacts this migration produces are not
topf-specific.**

talhelper already emits **Talos-native multi-document config**, not a flattened
`machine.network`. A generated brokkr node is 11 documents:

```
doc 0     v1alpha1 (main machine config)
doc 1     HostnameConfig
doc 2     ExtensionServiceConfig
doc 3-4   VolumeConfig      (EPHEMERAL, IMAGECACHE)
doc 5-6   UserVolumeConfig  (data-1, data-2 — LUKS2)
doc 7     BondConfig        (bond0, 802.3ad)
doc 8     DHCPv4Config
doc 9-11  VLANConfig        (bond0.10 / .30 / .50)
```

talhelper's typed schema is a thin sugar layer over documents Talos accepts
directly. Migration is therefore **extraction, not translation**, and the extracted
documents are equally valid input for topf, for `talosctl machineconfig patch`, or
for the `siderolabs/talos` Terraform provider's `config_patches`.

If topf is archived in turn, the patch tree moves to its replacement with no rework:
the expensive part of this migration survives the tool. That is the case for
accepting a pre-1.0 dependency, and the claim to attack first if you disagree.

## Constraints

1. **No secrets land bare in source control.** Explicit requirement from Derek.
   [Secrets design](#secrets-design) is the load-bearing part of this spec.
2. **The cluster PKI must survive.** No re-PKI, no node wipe, no re-bootstrap.
3. **Output must reproduce the talhelper baseline** before anything touches a node.
4. **tuppr remains the Talos upgrade driver.** Its VolSync/Longhorn CEL health
   gates are tuned and working; topf is for generation and apply only.

## Current state, measured

`talos/talconfig.yaml` is 670 lines (main `0006b873`, 2026-09-23):

| section | lines | disposition |
|---|---:|---|
| header (cluster, versions, CIDRs, certSANs) | 16 | → `topf.yaml` (identity, versions) and `patches/all/` (pod/service CIDRs, cert SANs, `cni: none`, which topf has no typed field for) |
| `nodes:` block | 436 | → patch tree (the actual work) |
| global `patches:` | 174 | → `patches/all/`, essentially unedited |
| `controlPlane.patches:` | 44 | → `patches/control-plane/`, unedited |

Node variance is small, which is what makes the patch tree cheap:

| group | differing lines | what differs |
|---|---:|---|
| jormungandr1/2/3 | **1** | hostname |
| brokkr01/02/03 | **4** | hostname, 2 bond member MACs, `data-2` disk model |
| jormungandr4 | — | differs from j1-3 in three ways: VLANs 10/30/50 on `end0`, an `EPHEMERAL` VolumeConfig, and NIC selection (`interface: end0` rather than the `deviceSelector` hardware-address alias j1-3 and freyja01 use, so it renders no `LinkAliasConfig`) |
| freyja01 | — | the only control plane: own schematic, `/dev/vda`, VIP `10.0.10.30`, no bond or VLANs |

jormungandr1-3 and jormungandr4 share the `&lowpowerpatch` / `&lowpowertaint` /
`&extensionServices` / `&pischematic` anchors in `talconfig.yaml`. That is one `worker`
patch set plus a small `node/jormungandr4/` overlay, not two full node definitions.

Generated per-node document volume was measured on 2026-08-31 and is stale (106 lines
per brokkr, 31 per jormungandr control plane, 50 for jormungandr4; freyja01 is 10.5 KB
of rendered YAML on disk). **Phase 4 regenerates the baseline first.**

### The golden baseline

**The 2026-08-31 baseline is obsolete** — it predates freyja01 and the Pi conversion,
and it was generated at `v1.13.6`. Regenerate it from current `main` with
`talhelper genconfig` (3.1.17 is still installed) before extracting anything; that is
Phase 0. Whatever exists when Phase 7 uninstalls talhelper is the last one obtainable.

Three schematics, which the migration must reproduce byte-for-byte. The first two
were measured on 2026-08-31 and must be re-confirmed against the regenerated baseline;
the third is recorded in `talconfig.yaml` and was **not** in the original spec:

```
a6c707bf3d7244f037fb47e0953213f688655da5e494c8bac75d6ba75fd4b184   pi       jormungandr1-4
b915cd2395b3c0580b8883e6732162033e58ced480be4c041a0d7b06b751056a   amd      brokkr01-03
647d4118dd02ecb09b7753856462592033c23e92cf12b14c710e393124ec4066   freyja   freyja01
```

`freyja` differs from `pi` in extensions (qemu-guest-agent, tailscale, util-linux-tools
only) and has no IOMMU args, no microcode. Its schematic is inline in freyja01's node
entry, not an anchor, so a transcriber can miss it.

Installer image, per group:
`factory.talos.dev/metal-installer/<schematic>:v1.13.9`

topf constructs `<factory>/<platform>-installer[-secureboot]/<id>:v<version>` with
defaults `factory.talos.dev` / `metal` / secureboot off — the same string.

### Version drift: resolved by hand, but it will recur

On 2026-08-31 three places disagreed (`talconfig.yaml` v1.13.6, tuppr CR v1.13.5,
running v1.13.9). **As of 2026-09-23 all three read `v1.13.9`.** The drift was fixed by
hand, not structurally, and the mechanism that caused it is still in place:

- Renovate's Talos bump PR (**#1849**, v1.13.9 → v1.13.10, open since 2026-09-21)
  touches `talosupgrade.yaml` and the `etcd-defrag` cronjob **but not
  `talconfig.yaml`**. The `talos` group in `.renovate/groups.json5` matches only
  `/installer/` and `/talosctl/` images.
- So merging #1849 and letting tuppr roll leaves `talosVersion` behind the running
  nodes, and the next config apply would write a stale `machine.install.image`.

**Sequencing decision (2026-09-23, revised): hold #1849 until Phase 5 is signed off.**
An earlier draft of this note said to merge it first. Reading the PR changed that: it
also bumps the `etcd-defrag` cronjob's `talosctl` image from v1.13.9 to **v1.14.1**, a
minor ahead of every node, and merging starts a tuppr roll that reboots freyja01 — the
only control plane — as a second API outage. Holding is safe: the cluster is on v1.13.9,
v1.13.10 (2026-09-03) is a patch release whose visible changes are hardening and
bugfixes with nothing flagged as a CVE, and no auto-merge is queued. So the migration
happens on v1.13.9 and never straddles a bump.

Guard rails while it is held: do not merge #1849 from a `renovate-sweep` pass; if
Renovate rebases or replaces it, re-read the diff before merging; and after Phase 5,
decide whether the `talosctl` 1.14.1 image belongs in the same PR as the installer bump
or should be split. Bump `talosVersion` in the topf config by hand to match whenever
it does merge, since Renovate does not touch it (and see D1).
See [Phase 6](#phase-6--keep-the-versions-from-drifting-again).

## Target layout

```
talos/
├── topf.yaml                      # cluster + nodes; only `data:` is encrypted (see D1)
├── secrets.sops.yaml              # ← talsecret.sops.yaml, content unchanged
├── talosconfig                    # ← client config, was clusterconfig/talosconfig
├── schematics/
│   ├── pi.yaml                    # → a6c707bf…  (jormungandr1-4)
│   ├── amd.yaml                   # → b915cd23…  (brokkr01-03)
│   └── freyja.yaml                # → 647d4118…  (freyja01)
└── patches/
    ├── all/                       # global patches, split by concern
    ├── control-plane/             # applies to freyja01 only
    ├── worker/                    # shared by the 3 brokkr and 4 jormungandr workers
    └── node/
        ├── freyja01/              # vip 10.0.10.30, /dev/vda
        └── jormungandr4/          # VLANs on end0, EPHEMERAL VolumeConfig
```

`topf.yaml` carries cluster identity plus a flat node list (`host`, `ip`, `role`,
per-node `data:`). No typed fields for disks, NICs, volumes or taints — those are
patch files. That is the abstraction level Derek has explicitly accepted.

`worker/` is shared by both the amd (brokkr) and Pi (jormungandr) workers, so anything
that only one group needs — the bond, the `data-1`/`data-2` LUKS volumes, the hugepages
sysctl, `vfio_pci` — must be gated on `.Node.Data` or moved to a group-specific
directory. The `nvme_tcp` module is on every worker; jormungandr's `&lowpowerpatch`
adds it alongside the kubelet taint, and brokkr's inline patch adds it alongside
`vfio_pci`/`uio_pci_generic`.

Per-node `data:` absorbs the measured variance, so brokkr01/02/03 share one
templated patch set rather than three copies:

```yaml
nodes:
  - host: brokkr01
    ip: 10.0.10.38
    role: worker
    data:
      bondLinks: [enx844709336c1f, enx844709336c20]
      dataDisk2Model: "WD_BLACK SN770 2TB"
```

## Secrets design

### The invariants

Four statements that must not become false. Everything below exists to hold them up.

1. No file tracked in git contains an unencrypted secret — **including files named
   `*.sops.yaml`.**
2. The PKI bundle is only ever decrypted into a pipe or a gitignored path, never
   into a tracked one.
3. Secrets reach patch files through topf's `data:` mechanism, never as literals in
   a `.tpl` file — `.tpl` files bypass the SOPS pipeline.
4. Every `*.sops.yaml` file actually contains a `sops:` metadata block. **This is
   not enforced today** — see [the gitleaks exclusion
   hole](#the-gitleaks-exclusion-hole-present-today).

### Where each secret lives

| item | today | after |
|---|---|---|
| Talos PKI bundle | `talos/talsecret.sops.yaml` (SOPS) | `talos/secrets.sops.yaml` (SOPS, content identical) |
| `SECRET_TS_AUTHKEY` | `talos/talenv.sops.yaml` (SOPS) | `talos/topf.yaml` `data:` (partial SOPS, key `tsAuthKey`) |
| `SECRET_VOLUME_KEY` | same | same |
| `SECRET_DOMAIN` | same | same |
| rendered machine configs | `talos/clusterconfig/*.yaml` (plaintext, gitignored) | not written at all on the `apply` path; `render` only for the Phase 4 diff |

### `SECRET_TS_AUTHKEY`: kept as-is, and it may be expired

Decision (2026-09-23, Derek): **carry the existing `SECRET_TS_AUTHKEY` across unchanged.**
Tailscale auth keys expire (90 days at most), so the stored one is likely expired. It is
not rotated in this migration:

- **Dry-run stays clean.** The stored value is presumably what the nodes were applied
  with, so Phase 5's per-node `--dry-run` shows no diff on it. A placeholder would show a
  diff on every node, and applying it would write a fake key into each node's
  `ExtensionServiceConfig`, which likely restarts the tailscale extension service.
- **One variable at a time.** A changed key in the same migration makes any config diff
  harder to attribute.
- **Expiry probably does not matter for running nodes.** An auth key is only consulted at
  registration; an already-registered node keeps working on its node key. This is an
  *inference*, not tested on this cluster. It is why existing nodes appear to ignore the
  key.

Where an expired key **does** matter: any node whose Tailscale state is cleared (a node
reset or rebuild) cannot rejoin the tailnet until the key is refreshed. Rotating it is a
separate follow-up and **must happen before any node reset or rebuild**. During Phase 5,
watch jormungandr4 (the first apply) for a re-registration attempt after the config
lands; if the extension tries to log in again, stop and rotate the key before continuing.
The key is the `&extensionServices` anchor's `TS_AUTHKEY`, shared by all 8 nodes.

### Filenames: bend topf to `.sops.yaml`, not the reverse

The repo's existing creation rule requires a literal `.sops.` infix:

```yaml
  - # IMPORTANT: This rule MUST be above the others
    path_regex: talos/.*\.sops\.yaml
    age: "age1ww3u7me5lwxtgqcd8djkv485q30wu7k40hs9e2acg8qvdw4e8spq9t5dem"
```

Note there is **no `encrypted_regex` on the `talos/` rule** — anything matching it
gets whole-file encryption. (`encrypted_regex: ^(data|stringData)$` belongs to the
`kubernetes/` rule and is not the convention here.)

topf's *defaults* — `topf.yaml`, `secrets.yaml` — match no creation rule, so `sops
-e` would refuse them. Both names are configurable, so both bend to the repo:

- **`talos/secrets.sops.yaml`** — the PKI bundle. `secretsPath` is a free path,
  resolved relative to the config file's directory.
- **`talos/topf.sops.yaml`** — the cluster config. The `--topfconfig` flag takes an
  arbitrary path (`TOPFCONFIG` env var also works); `topf.yaml` is only its default.

Both then match the existing rule and get whole-file encryption. **No new
`.sops.yaml` rule is needed and no partial-encryption scheme is required** — an
earlier draft of this spec built one, on the mistaken belief that the config
filename was fixed and that the `talos/` convention was partial.

**Decision D1 (2026-09-23, Derek): partial encryption — implemented 2026-09-24 as
`talos/topf.yaml`, NOT `talos/topf.sops.yaml`.**

The problem it solves: `talosVersion` and `kubernetesVersion` live in the topf config,
and Renovate cannot read inside a fully SOPS-encrypted file. The `# renovate:` annotations
at `talos/talconfig.yaml:2-5` would be encrypted away, and those two lines are how
Renovate learns of Talos and Kubernetes bumps today.

Partial encryption (`encrypted_regex: ^data$`) keeps versions and the node list in the
clear and encrypts only `data:`, which also restores diffability. It costs a creation
rule and a regex that must stay right.

**The file must not be named `*.sops.yaml`.** Found during Phase 1: `.renovaterc.json5`
has `ignorePaths: ["**/*.sops.*"]`, so Renovate skips every such file whatever its
contents. A partially encrypted `topf.sops.yaml` would have been just as invisible as a
fully encrypted one. The file is therefore `talos/topf.yaml`, with its own creation rule
in `.sops.yaml` (above the general `talos/.*\.sops\.yaml` rule, which stays whole-file
for `secrets.sops.yaml`). Consequences, all handled in Phase 1:

- topf's default config name is `topf.yaml`, so **no `--topfconfig` flag** is needed when
  running from `talos/`.
- `mac_only_encrypted: true` is required, so Renovate's edit of a cleartext version does
  not invalidate the MAC. Tested: an in-place edit of `talosVersion` still decrypts.
- `yamlfmt` must exclude it (it would reformat ciphertext); gitleaks now scans it, which
  is fine because it holds only ciphertext.
- The "must carry a `sops:` block" pre-commit check covers `talos/topf.yaml` explicitly,
  since it no longer matches `*.sops.yaml`.
- Any `data:` key at any depth is encrypted by `^data$`, including a per-node `data:`.
  Per-node variance (bond MACs, disk models) is not secret, so **prefer `node/<host>/`
  patch files over per-node `data:`** to keep it readable in git. **Decided 2026-09-24
  (Derek): use `node/<host>/` patch files, not per-node `data:`.**

The whole-file paragraphs below describe the rejected alternative and are kept for the
reasoning.

The tradeoff of whole-file: the node inventory is no longer readable or diffable in
git. Partial encryption (`encrypted_regex: ^data$`) *does* work through topf's
decrypt path if that is wanted — verified — but it needs its own creation rule
placed above the general one, and it makes correctness depend on a regex staying
right forever. Whole-file is the simpler default, and was what this spec first assumed;
D1 above replaced it.

### Rendered configs: keep plaintext off the disk

talhelper writes fully-decrypted configs to `talos/clusterconfig/` and relies on a
generated `.gitignore`. That is the status quo and it is not good.

**topf improves on it, though not the way an earlier draft assumed.** `topf render`
cannot write to stdout — `--output` is a directory and the path is joined per node,
so there is no pipe to build around. But the production path never renders at all:

- **`topf apply`** encodes the config in memory and sends it over gRPC. It performs
  a server-side dry-run first and prints the node's own diff. **Nothing decrypted
  touches local disk.** Strictly better than talhelper.
- **`topf apply --dry-run`** — same diff, still no local plaintext. This is the
  per-node review gate in Phase 5.
- **`topf render`** is the *only* command that writes plaintext machine configs,
  and it exists here solely to produce the Phase 4 byte-diff against the talhelper
  baseline.

So plaintext on disk is a one-time comparison artifact rather than a standing
condition — provided Phase 1 adds the `output/` ignore rule first, which nothing in
the repo has today. Render to a pinned `-o talos/output`, and shred the directory
once Phase 4 is signed off.

There are exactly three writes in the tool: the render directory, the rendered
files, and the secrets bundle.

### Two silent-failure hazards in topf's SOPS handling

Both verified in source. Neither is hypothetical and both bear directly on the
no-bare-secrets constraint.

**1. A missing `sops` binary degrades silently — in principle.** *(Phase 0 finding,
2026-09-24: in this repo's setup it fails loudly instead; see
[Phase 0 results](#phase-0-results-2026-09-24).)* topf shells out to the `sops`
binary rather than using a Go library, and detects encryption by content (`sops
filestatus`) rather than filename. If `sops` is not on `PATH`, the check returns
"not encrypted" with **no error** — deliberate "graceful degradation" — and topf
then parses the ciphertext as literal YAML. The failure mode is a silently wrong
config, not a crash — **when nothing else in the run is encrypted**. Here the secrets
bundle always is, and parsing its ciphertext fails with `illegal base64 data`, so the
run aborts before any config is written. The bundle is an accidental canary. Do not
rely on it: keep the `sops --version` precondition.

**2. `topf secrets` writes plaintext if encryption fails.** The filesystem secrets
provider attempts `sops encrypt` and **ignores the error**, writing the bundle
either way at `0600` and reporting success. If sops is missing, no creation rule
matches, or the age key is unavailable, that writes an **unencrypted Talos PKI
bundle to disk while claiming to have succeeded** — precisely the constraint failing
without saying so.

This only fires on first-run secret *generation*. This migration imports an existing
bundle and never calls it, so the path is not on our route — but it must be named,
because "generate new secrets" is an obvious thing to reach for later.

**Mitigation for both:** confirm `sops --version` and `age` availability as a Phase 1
precondition, and after any secrets operation verify with `sops filestatus`
rather than trusting the exit code.

**Related:** `topf secrets` prints the full PKI bundle to stdout with a plain
`Println`, bypassing the redacting writer that `--redact` controls. Deliberate — it
is the "give me the secrets" command — but it must never be run into a log, a `tee`,
or a recorded terminal session.

### `.gitignore` additions

```
output/
talos/*.decrypted*
```

**`output/` is bare and un-anchored deliberately**, so it matches at any depth.
`topf render`'s default is `./output` — relative to the *current working directory*,
not to `talos/` (`cmd/topf/render.go:29`, `Value: "./output"`). Run from the repo
root, which is where `direnv` and `just` put you, and it writes to `./output/`. A
rule written as `talos/output/` would not match that, and eight plaintext machine
configs carrying the full PKI would sit unignored.

Neither path is ignored today — verified with `git check-ignore`:

```
output/            NOT IGNORED
talos/output/      NOT IGNORED
```

**This edit belongs to Phase 1, not to reading this section.** It is listed here as
design; it is executed there. See also Phase 4, which pins `-o` rather than
inheriting the cwd-relative default.

The existing `.decrypted~*.yaml` and `**/talosconfig` entries already cover the
sops-in-place and client-config cases.

## The gitleaks exclusion hole (present today)

A finding about the repo as it stands, not about topf. In scope because invariant 4
depends on it.

`.lefthook.toml` runs gitleaks on pre-commit but excludes `*.sops.yaml`:

```toml
[pre-commit.commands.gitleaks]
run = "gitleaks protect --staged --verbose --redact"
glob = ["*"]
exclude = ["*.sops.yaml"]
```

The exclusion is by **filename**, not by verified encryption. Reproduced 2026-08-31
in a scratch repo, staging a plaintext Talos bundle named `secrets.sops.yaml`:

```
│  gitleaks (skip) no matching staged files
```

A plaintext file named `*.sops.yaml` commits with **zero secret scanning** — exactly
the failure mode found in `~/Repositories/home-ops-main`, where two files named
`talsecret.sops.yaml` contain unencrypted Talos CA private keys.

gitleaks itself is not fooled, also verified — against a bare bundle it reports 10
findings, base64-decoding first:

```
RuleID:   private-key
Entropy:  5.555781
Tags:     [decoded:base64 decode-depth:1]
```

Detection works; only the exclusion defeats it. The hole is narrow — `gitleaks
protect --staged` scans the whole staged diff, so it fires only when the
`*.sops.yaml` file is the *sole* staged file — but it is real.

**Fix:** a pre-commit check that every `*.sops.yaml` file contains a `sops:`
metadata block, failing the commit otherwise. Cheap, precise, and it closes the hole
for the whole repo rather than just this migration.

## Version selection: pin a release, not a commit

**Revised 2026-09-23.** The original section pinned main commit `21831714` because
v0.5.0 hung on any non-interactive run and because every behaviour in this spec had
been verified against that commit rather than the tag. Both reasons have moved:

- **v0.6.0 (2026-09-03) postdates `21831714`**, so it contains the EOF-hang fix. The
  tag is now the reproducible, self-identifying choice. v0.6.1-rc.1 (2026-09-23) also
  exists; prefer the tag unless a Phase 0 finding needs something only in the rc.
- **A confirmation-prompt fix landed later still** (2026-09-21, "prevent concurrent
  prompts and improve nonTTY usecase", plus 2026-09-23 "send interactive prompts to
  stdErr"). That is in the rc, not in v0.6.0. **Do not blanket-pass `--confirm=false`** — see below.

**What is *not* yet re-verified.** Every claim in this spec about topf's SOPS handling,
merge order and schematic replacement was checked at `21831714`. Twenty-eight commits
followed, including one on **secrets redaction** (multi-line PEM handling, and a change
so that public key material is no longer redacted) and one on secrets docs. The
whole-file-SOPS design does not depend on redaction, but "does not depend on" is a
judgement, not a measurement. **Phase 0 re-runs the load-bearing checks against the
chosen release** before anything is built on them.

Install into the repo-local `.bin/`, which `.envrc` already puts on PATH and
`.gitignore` already excludes:

```bash
GOBIN="$PWD/.bin" go install github.com/postfinance/topf/cmd/topf@v0.6.0
```

A `go install` from a tag is stamped by module metadata, but `main.version` is only
set by release ldflags, so `topf --version` may still print `dev`. Verify with:

```bash
go version -m .bin/topf | grep '^\s*mod'   # expect ...topf  v0.6.0
```

topf **is** packaged now: `brew install postfinance/tap/topf` (README, 2026-09-23).
The spec originally said there was no Homebrew route. Prefer `go install` into `.bin/`
anyway — it pins the version per checkout and needs no global state — but the brew
route exists (issue #146 notes its cask uses deprecated `postflight` syntax).

**Do NOT pass `--confirm=false` (or `TOPF_CONFIRM=false`) as a blanket habit.** An earlier
draft said to. Phase 0 (2026-09-24, v0.6.0) showed why that is wrong. With a wrong or
missing `secretsPath`:

- default `--confirm`, stdin closed: prints `No secrets.yaml found … Generate a new one?
  [y/n]` a few times, then **exits 1 in under a second**. No hang, nothing written.
  The v0.5.0 infinite loop is fixed.
- `--confirm=false`: **silently generates a brand-new PKI, writes it to the path you gave
  as a PLAINTEXT file** (`sops filestatus` → `encrypted:false`, 8.8 KB of key material),
  and carries on rendering. A typo'd path becomes an unencrypted CA on disk with a
  success exit code.

So the safe default is the opposite of the old advice: leave `--confirm` **on** for
`render`, and use `--confirm=false` only for `apply`, only after a reviewed `--dry-run`,
and only after `topf clusterinfo` or `sops filestatus` has confirmed the secrets path.


**Talos 1.14 posture.** v0.6.0 bundles Talos machinery 1.14.x. While `talosVersion` is
`v1.13.x` topf generates 1.13-shaped config. **Do not bump `talosVersion` to 1.14 as
part of this migration.** The 1.14 defaults (`workloadIsolation: true`, an
auto-generated `KubeFlannelCNIConfig`) would arrive on the first `apply` and break
Cilium and any host-namespace workload. Treat that as a separate change.

## Migration phases

### Phase 0 — re-verify, and regenerate the baseline

No repo changes beyond `.bin/`. Gate for everything after it.

- Install topf per [Version selection](#version-selection-pin-a-release-not-a-commit)
  and confirm with `go version -m`.
- **Done 2026-09-24 — see [Phase 0 results](#phase-0-results-2026-09-24).** Re-run, against that build, the checks this design leans on: content-based SOPS
  detection with a missing `sops` on `PATH` (must degrade the way the spec says, so we
  know what to guard); `--topfconfig` at an arbitrary path; `secretsPath` relative
  resolution; merge order `all/` → `<role>/` → `node/<host>/`; `$patch: delete` versus
  `null`; schematic replacement. Record pass/fail and the version here.
- Regenerate the talhelper baseline from current `main`
  (`talhelper genconfig -o <scratch>`, **not** `talos/clusterconfig/` — that directory
  holds the configs the running nodes were applied from and is the rollback reference).
  Record talhelper version, machinery version and date next to it.
- Confirm all three schematic IDs from the baseline's installer images.

#### Phase 0 results (2026-09-24)

Run on topf **v0.6.0** (module `h1:nmnkOFXY…`, bundles Talos machinery **v1.14.0**) against
a synthetic fixture with a throwaway age key. No real secret was decrypted for the topf
checks. Baseline regeneration used the real bundle, into a mode-700 scratch directory.

| check | result |
|---|---|
| Regenerate talhelper baseline from `main` (3.1.17) | **Byte-identical to the live-applied `talos/clusterconfig/`** for all 8 nodes (0 differing lines each). Generation is deterministic, PKI included, so that directory is a valid rollback reference. |
| Schematic IDs | `a6c707bf…` (pi), `b915cd23…` (amd), **`647d4118…` (freyja) — all three reproduced offline** from transcribed `customization:` blocks. Installer images are `…:v1.13.9` on every node. |
| `${` left in the baseline | 0 |
| Merge order | `all/` → `<role>/` → `node/<host>/`, last wins. Confirmed. |
| `$patch: delete` | Removes a map key and a sysctl. Confirmed. |
| `key: null` | **Overwrites with an explicit `null`**; not a delete, and not "parent survives" as the spec said. |
| `${SECRET_DOMAIN}` in a `.tpl` and via `data:` | Renders **verbatim**. The hazard is real. |
| `admissionControl: null` on freyja01 | No-op under both tools; default `PodSecurity` present in both. Parity expected. |
| `talosVersion: v1.13.9` pin | topf emits 1.13-shaped config (`machine.install.image`, no `KubeFlannelCNIConfig`) despite bundling 1.14 machinery. |
| Partial SOPS (`encrypted_regex: ^data$`) at `conf/topf.sops.yaml` | **Works.** `talosVersion`/`kubernetesVersion` stay in the clear, `data:` decrypts and renders, and relative `patchesDir`, `secretsPath` and `@../schematics/…` resolve against the config's own directory, from any cwd. Decision D1 is sound. |
| Missing `sops` on `PATH` | **Fails loudly** (`illegal base64 data` reading the secrets bundle), exit 1, nothing written. Weaker than the spec's "silent" claim; see hazard 1. |
| sops present, age key missing | Clear `Failed to get the data key` error, exit 1. |
| Non-TTY, secrets file missing, default `--confirm` | Re-prompts a few times, exits 1 in <1s. **No hang.** |
| Non-TTY, secrets file missing, `--confirm=false` | **Generates a new PKI and writes it as a plaintext file.** See Version selection. |
| Multi-document patches | `VolumeConfig`, `UserVolumeConfig`, `LinkConfig` in one file render correctly at 1.13. A same-named document overlaid in a later layer **drops fields** (see Phase 3). |
| `topf talosconfig` | Prints to **stdout** (13 lines), writes no file, empty stderr. `endpoints` = the control plane only (`10.0.10.35` in the fixture); `nodes` = all. |
| Apply modes | `--mode reboot\|auto\|no-reboot\|staged\|try` (default `auto`), `--max-parallel` (default 1; control planes always one at a time), `--dry-run`, `--stabilization-duration` (default 30s). |
| Rendered `HostnameConfig` | topf emits its own (`auto: stable`); the baseline has one from talhelper. Phase 4 compares them. |

**Not yet done in Phase 0** (needs the cluster, so it belongs to Phase 5): what
`apply --dry-run` prints against a live node, and whether `--mode no-reboot` / `try` is
enough for the changes we expect on freyja01.

**Implications carried forward:**

- Phase 4's diff will not be a plain `diff -r`: topf writes 4-space YAML with different
  key order and document order (the baseline is 2-space). Compare **normalised** — parse
  each document, sort keys, key documents by kind+name — and classify what remains.
- The rollback baseline is `~/Repositories/flux-talos/talos/clusterconfig/` and must
  survive until Phase 7 is signed off.

### Phase 1 — scaffold the config and move the secrets

- **Preconditions:** `sops --version` and `age` resolve on PATH — a missing `sops`
  makes topf read ciphertext as literal YAML with no error. Install topf pinned to a
  release (see [Version selection](#version-selection-pin-a-release-not-a-commit)).
- `git mv talos/talsecret.sops.yaml talos/secrets.sops.yaml` (content untouched —
  topf's migration guide states the talhelper bundle is format-compatible, and
  `talosctl gen secrets` produces the identical structure).
- Write `topf.sops.yaml`: cluster identity, 8 nodes (7 workers + `freyja01`), per-node `data:`.
- **`clusterName` must be `home-kubernetes` verbatim.** topf names the talosconfig
  *context* after it, and the current context is `home-kubernetes`. Change the
  string and the regenerated client config gets a different context name, breaking
  anything doing `talosctl --context home-kubernetes` in a way that looks like a
  talosctl fault rather than a rename. It is the first field written and the
  easiest to get casually wrong.
- Move the three secrets (`SECRET_TS_AUTHKEY`, `SECRET_VOLUME_KEY`, `SECRET_DOMAIN`)
  from `talenv.sops.yaml` into encrypted `data:`.
- Add the `*.sops.yaml`-is-actually-encrypted pre-commit check.
- **Add `output/` to `.gitignore`** (bare, un-anchored — see
  [.gitignore additions](#gitignore-additions)). Nothing is ignored there today, and
  Phase 4 is the first phase that writes plaintext configs to disk.
- Verify by decrypt round-trip, not by reading the file.

#### Phase 1 results (2026-09-24)

Done in worktree `~/Repositories/flux-talos-talos-gen`, branch `talhelper-replacement`.

- **`.sops.yaml`**: new rule for `talos/topf\.yaml` (`encrypted_regex: ^data$`,
  `mac_only_encrypted: true`) above the general talos rule.
- **`.gitignore`**: `output/` (bare, un-anchored — verified it ignores both `output/x` and
  `talos/output/x`) and `talos/*.decrypted*`.
- **`.lefthook.toml`**: new `sops-encrypted` pre-commit check, **later strengthened after
  review** (see Phase 3 review round): it now runs `scripts/check-sops-encrypted.sh`, which
  verifies the values are `ENC[AES256_GCM,…]` ciphertext instead of grepping for a `sops:`
  marker. First version verified against a staged plaintext `*.sops.yaml` (gitleaks then
  reported `skip: no matching staged files`, i.e. the hole is real). `yamlfmt` now
  excludes `talos/topf.yaml`.
  The first version of the check flagged `.sops.yaml` itself (the SOPS config matches the
  name and is legitimately plaintext); it is now excluded. Re-tested: a plaintext
  `talos/topf.yaml` is still rejected.
- **`talos/secrets.sops.yaml`** is a **copy** of `talsecret.sops.yaml`, byte-identical
  (`cmp`), *not* a `git mv` as first written. talhelper still needs `talsecret.sops.yaml`
  for the rollback path and for regenerating the baseline; the old file is deleted in
  Phase 7. Two copies of the same ciphertext cannot diverge unless the PKI is rotated,
  which this migration does not do. **But `just talos gen-secrets` (untouched here) rewrites only
  `talsecret.sops.yaml`**, which would leave topf on a stale PKI with nothing to notice; this was
  raised by the automated PR review. Now guarded three ways: the `SOPS Check` workflow fails if
  the two ciphertexts are not byte-identical (no age key needed), the recipe prints a warning,
  and the Phase 5 runbook lists it as a hard rule.
- **`talos/topf.yaml`** written by piping `sops -d talenv.sops.yaml` through `yq` into
  `sops -e`, so no plaintext touched disk. Verified: only `data:` (`tsAuthKey`,
  `volumeKey`, `domain`) is ciphertext; versions, annotations, `clusterName` and all 8
  nodes are readable; **decrypted values are identical to `talenv.sops.yaml`** (compared
  by hash, never printed); one age recipient; `sops filestatus` → `encrypted: true`.
- **Dry run on synthetic data first**, including a Renovate-style in-place version edit
  followed by a successful decrypt, and a topf render straight from the file with no
  flag. Installer images split 1 × `647d4118…` (freyja01), 4 × `a6c707bf…`
  (jormungandr1-4), 3 × `b915cd23…` (brokkr01-03).
- `talenv.sops.yaml` is untouched: talhelper still reads it until Phase 7.

### Phase 2 — transcribe the schematics

`schematics/pi.yaml`, `schematics/amd.yaml` and `schematics/freyja.yaml`, from the
`&pischematic` and `&schematic` anchors and from freyja01's **inline** schematic — the
`customization:` block verbatim, comments dropped. Reference them as
`schematicId: "@schematics/pi.yaml"`.

Gate: topf's computed IDs must equal `a6c707bf…`, `b915cd23…` and `647d4118…`.

**This phase was de-risked for two of the three.** Both IDs were reproduced offline from those
transcribed blocks using the same library call topf makes
(`image-factory/pkg/schematic`, `Unmarshal` → `ID()`), byte-identical on the first
attempt. `freyja` has not been run through it yet. The transcription is mechanical and no network call is involved — topf
resolves IDs locally and only contacts the factory under `--submit-to-factory`,
which defaults off.

#### Phase 2 results (2026-09-24)

`talos/schematics/{pi,amd,freyja}.yaml` were **generated from `talconfig.yaml` with `yq`**
(`explode(.)` to resolve anchors, comments stripped), not transcribed by hand, so the
freyja01 inline schematic cannot be missed and the extraction is repeatable. Against the
real `talos/topf.yaml`, `topf schematic-ids` returns exactly the IDs the regenerated
talhelper baseline uses: `647d4118…` (freyja01, 1 node), `a6c707bf…` (jormungandr1-4),
`b915cd23…` (brokkr01-03). Set equality only; the per-node mapping is confirmed in
Phase 4 from the rendered installer images. Re-verified after the `yamlfmt` pre-commit
pass, since the ID depends on parsed content, not formatting.

### Phase 3 — extract the patch tree

Split the 160 global and 44 control-plane patch lines into files under `all/` and
`control-plane/`, one concern per file, numbered for lexicographic ordering.
Extract the per-node documents (`BondConfig`, `VLANConfig`, `VolumeConfig`,
`UserVolumeConfig`, `ExtensionServiceConfig`, `HostnameConfig`) from the golden
baseline into `worker/` templates driven by `.Node.Data`, plus
`node/jormungandr4/`.

Four things established by running topf, not by reading it:

**Merge order is `all/` → `<role>/` → `node/<host>/`, last wins, lexical within
each directory.** Numbering files is load-bearing, not cosmetic.

**The role directory is `control-plane`, not `controlplane`.** So is the `role:`
value in `topf.yaml`. Wrong spelling is a hard failure — `invalid node role
"controlplane": must be either "worker" or "control-plane"` — loud rather than
silent, but it will cost time on first run.

**Strip every `${SECRET_*}` during transcription.** topf has no `${...}`
substitution. A literal `${SECRET_TS_AUTHKEY}` copied out of `talconfig.yaml`
renders **verbatim into the machine config with no error at all** — talhelper
substitutes it, topf ships it. Counted against `main` on 2026-09-23: **three names,
sixteen occurrences.**

| name | count | where |
|---|---:|---|
| `SECRET_TS_AUTHKEY` | 1 | `extensionServices` (the `&extensionServices` anchor, shared by all 7 workers **and** freyja01) |
| `SECRET_VOLUME_KEY` | 7 | `passphrase:` in the brokkr `data-1`/`data-2` LUKS blocks (6) plus one in j4's commented-out block — do not carry the comment over |
| `SECRET_DOMAIN` | 8 | the eight Nexus registry mirrors in the global `patches:`. **The original spec missed this one**, and it is in the `all/` patch every node receives |

All become `{{ .Data.x }}` in a `.tpl`. This is the single most likely silent error in the
whole migration, and the Phase 4 diff exists partly to catch it.

**`$patch: delete` is the only way to remove something inherited from `all/`.**
Setting a key to `null` looks like deletion and is not. *(Corrected 2026-09-24.)* The
original said "the parent value survives"; v0.6.0 actually **overwrites the key with an
explicit `null`** (the parent value is lost and the key stays, rendered `nulled: null`).
Either way it is not a delete. Verified on a fixture, not on real config.

**This bites here once, but not the way first feared.** The `controlPlane.patches` block
contains `cluster.apiServer.admissionControl: null` ("Disable default API server
admission plugins"). **Measured 2026-09-24: it does nothing under either tool.** The
regenerated talhelper baseline for freyja01 still contains the default `PodSecurity`
admission plugin, and topf's render of the same patch does too. So the patch has never
done what its comment says, and parity is expected. Do **not** "fix" it during the
migration — that would change the rendered config on the only control plane. Phase 4
confirms the full `admissionControl` block matches; genuinely removing it, if wanted, is
a separate change.

**A same-named document in two layers loses fields.** Multi-document patches
(`VolumeConfig`, `UserVolumeConfig`, `LinkConfig`, …) merge by kind+name across layers,
but in the Phase 0 fixture a `node/` overlay of `VolumeConfig EPHEMERAL` that set only
`maxSize` **dropped the `diskSelector`** from the `worker/` document while keeping
`grow`. Do not layer a partial overlay onto a same-named document. Either restate the
whole `provisioning` block in the overlay, or (preferred) do not define the document in
two layers and drive the difference with `.Node.Data`. This is the mechanism that would
have bitten jormungandr4's `EPHEMERAL` volume.

#### Phase 3 results (2026-09-24)

`talos/patches/` is written: `all/` (14 files, incl. a guard), `control-plane/` (3), `worker/` (7)
and `node/<host>/` for freyja01, jormungandr4 and brokkr01-03 (9). Rendered with synthetic
secrets and compared against the regenerated talhelper baseline with a **normalizer**
(parse each document, flatten to sorted `Kind/name | path = value` lines, mask secrets):
**all 8 nodes differ by 0 lines**, and `talosctl validate --mode metal` accepts the output.
`grep '\${' talos/patches talos/schematics` returns nothing.

Design choices made while extracting:

- **Group differences are hostname-gated templates in `worker/`; per-node facts are
  `node/<host>/` files.** topf has no host groups. Rather than copy the same Pi or brokkr
  patch into three `node/` directories, one `.yaml.tpl` per concern is gated on
  `hasPrefix "jormungandr"` / `hasPrefix "brokkr"` / `regexMatch "^jormungandr[123]$"`. Only
  what genuinely differs per node lives in `node/`: brokkr's bond NICs and `data-2` disk
  model, jormungandr4's network and volume, freyja01's network and install disk. **No
  per-node `data:` is used** (decision D1 follow-up), so all of it stays readable in git.
- **No same-named document is defined in two layers** (the partial-overlay field loss
  measured in Phase 0). `data-1` is shared; `data-2` exists only per node.
- **`apiServer.certSANs` is control-plane only.** talhelper never wrote it to workers; putting
  it in `all/` produced a 4-line diff on every worker. `machine.certSANs` stays on all nodes.
  Both come from **one** role-gated template, `all/03-cert-sans.yaml.tpl`, so the list exists
  once (talconfig had one shared list; the first extraction had split it into two files that
  had to be kept in step).
- **`nfsmount.conf` has no trailing newline.** The original `|` block sat inside an outer
  `|-` patch that stripped the final newline; the patch uses `|-` to reproduce that exactly.
- **`machine.nodeTaints` is written in addition to the kubelet `registerWithTaints`** on the
  Pis, because talhelper's typed `nodeTaints` produced the former and the inline patch the
  latter.
- **The `admissionControl: null` patch was dropped, not ported.** It is a no-op under both
  tools (default `PodSecurity` is present either way), so omitting it renders identically and
  removes a comment that was never true.

**Repeatable offline check.** `talos/tools/render-check.sh` needs no real secret and no cluster.
It builds a throwaway fixture (synthetic age key, PKI bundle and data values, reusing the
cleartext of `topf.yaml` so the node list cannot drift), renders all 8 nodes, runs
`talosctl validate --mode metal` on each, asserts each node's installer image carries its own
schematic and never the extension-less default, asserts no `${` reached a render, and asserts
the guard **rejects** an unknown host, an unknown prefix, a role flip and a node with no
`schematicId`. Given a baseline directory it also runs the masked equivalence comparison.
23/23 pass; with the guard emptied, exactly the four guard checks fail, so the test
discriminates. Keep it as the regression test for the patch tree even after Phase 7.

**A defect in the first comparison, worth recording.** The normalizer initially masked every
field *named* `key`, which also masked `registerWithTaints[].key`, so a wrong taint key would
have compared as equal. It now masks by exact secret path prefix (`machine.ca`,
`cluster.secret`, …) and the taint key is compared. Any future comparison tool must mask by
path, not by field name.

**Review round (2026-09-24).** Three independent adversarial reviewers (read-only, told not
to touch real secrets) examined the patch tree's fidelity, the comparison method, and the
secrets/safety of the whole branch. No CRITICAL fidelity defect; several real gaps. What
changed as a result:

- **Comparison method (red-team, 19 fault injections).** Five faults were MISSED because
  masked values compare equal: a worker that gains the machine CA private key, a wrong LUKS
  passphrase, an empty Tailscale key, a wrong `data.domain`, a hardcoded domain. Fixes:
  masking now shows `<empty>` for blank values (so absent never equals present); real-secrets
  runs use **HMAC with a random per-run key** shared by both sides (a bare hash of the domain
  is dictionary-attackable); empty containers and non-map documents no longer collapse or get
  skipped; and the tool **fails** on empty input, on an unexpected rendered node, and on any
  difference. All five misses are now caught (empty TS key in both modes; the other four by
  `--hash`), re-verified on fixtures. The tools live in `talos/tools/` (`render-check.sh`, `norm.py`,
  `compare.sh`, `verify-real.sh`), tracked so they outlive the session; delete with
  `talconfig.yaml` in Phase 7.
- **A comparison-tool defect worth remembering**: the first `compare.sh` aborted after the
  first differing node, because `head` closing a pipe tripped `pipefail`. It failed safe
  (non-zero exit) but truncated the report.
- **Secrets were pasted unquoted into YAML** (`passphrase:`, `TS_AUTHKEY=`). A value with `#`
  was silently truncated and `0123` was read as octal. talhelper had the same exposure, so
  parity held, but the masked comparison would have hidden a mangled value. Now
  `| toJson`. Phase 4 verifies by HMAC that the rendered passphrase equals the data value; if
  it does not, the live LUKS slot 1 already holds a mangled key: **stop there**.
- **Adding or renaming a node went wrong silently** (`brokkr04` with no `node/` directory
  rendered and validated, with `bond0` VLANs but no `BondConfig`). New `all/00-guard.yaml.tpl`
  fails the render for an unknown hostname, a role mismatch, or a node with no schematic.
- **A node with no `schematicId` silently gets Talos's *default* schematic**
  (`37656798…`, no system extensions): it installs and validates, then breaks iSCSI/NFS/
  tailscale at the next upgrade. Removing the global Pi default (each node now names its own)
  makes that reachable, so the guard rejects an empty or default schematic.
- **The `sops-encrypted` hook was weak** (a plaintext file with a `sops: {}` stub, a real file
  with a hand-added plaintext key, and `yq -i` adding a plaintext `.data.newKey` all passed).
  Replaced by `scripts/check-sops-encrypted.sh`: one document, a valid `sops` block, and every
  scalar in scope is ENC ciphertext (`.data` for `topf.yaml`, `.data`/`.stringData` for
  `kubernetes/`, everything for `talos/*.sops.yaml`). Passes all 10 tracked SOPS files; rejects
  all 9 attack cases; still accepts Renovate-style edits of cleartext fields. **Limit**: it
  checks the ciphertext *form*, not that it decrypts (only `sops -d` verifies the MAC).
  It also runs server-side: `.github/workflows/sops-check.yaml` runs the same script over every
  tracked SOPS file and `talos/topf.yaml` on PRs and pushes to main, because a local hook is
  bypassable (`--no-verify`, or a checkout without lefthook).
- `.gitignore` gains `talos/secrets.yaml` (topf's default `secretsPath`, where a bare
  `--confirm=false` writes a new plaintext PKI). The `.sops.yaml` rule is anchored
  (`^talos/topf\.yaml$`) so it cannot match `topf.yaml.bak`.
- **Noted, not changed**: `all/05` and `all/11` use `machine.files`, which Talos deprecates (a
  1.14-era migration); document **order** differs from the baseline on every node (the leaf
  comparison ignores it; Phase 5's dry-run decides whether it matters).

**What this does not prove.** The comparison used *synthetic* secrets, so every masked value
is unchecked: the cluster PKI, the machine and bootstrap tokens, the Tailscale auth key, the
LUKS passphrase and the registry domain. `compare.sh --hash` HMACs them with a random per-run
key instead (`NORM_KEY`, set by the script; the earlier `NORM_HASH=1` no longer exists and
`norm.py` now errors on it), so a real-secrets render can be compared without printing anything;
that run is Derek's (see Phase 4).

**A limit of the masked (synthetic) mode, found by the automated PR review.** Its catch-all
for secret-shaped strings not covered by a known path reduces any 40+ character
`[A-Za-z0-9+/=_-]` value to `<long-string:N>`, so two *different* values of the same length
compare equal. Today every long value sits under a known secret path, so nothing is hidden, but
a future digest, UUID or token field would be. The `--hash` run does not have this gap (the
catch-all is HMAC'd there), which is one more reason it, not the synthetic run, is the gate.

### Phase 4 — prove the output matches

```bash
topf render -o talos/output      # pin the path; the default ./output is cwd-relative
diff -r talos/output <golden-baseline>
```

**Pass `-o` explicitly.** `topf render`'s default is `./output`, so where the
plaintext lands depends on which directory you happen to be standing in. Determined
beats defaulted when the output is eight machine configs containing the PKI.

**Precondition:** the `output/` rule from Phase 1 must already be in `.gitignore`.
This is the first phase that writes plaintext to disk.

**The diff will not be empty, and requiring that would be a trap.** The two tools
encode through different bundled Talos machinery:

```
talhelper 3.1.17    machinery v1.14.0-alpha.2   image-factory v1.4.0
topf @21831714      machinery v1.13.8           image-factory v1.3.2   (2026-08-31)
topf v0.6.0+        machinery v1.14.x           image-factory newer    (2026-09-23)
cluster running     Talos v1.13.9
```

**This comparison flipped on 2026-09-23.** The original reasoned that topf encoded with
1.13.8 and was therefore the closer match to the nodes. Current topf (main is on
machinery `v1.14.1`) is a *minor ahead* of the cluster, like talhelper. Neither
generator matches what the nodes run, so the baseline is not ground truth and neither
is topf. The talhelper column above was measured 2026-08-31 and must be re-read in
Phase 0. Pinning `talosVersion: v1.13.x` should make topf emit 1.13-shaped documents,
but that is a claim for Phase 0 to test, not to assume.

Expect residue from the encoder gap: fields that gained defaults, `omitempty`
changes, key ordering, schema keys present in one version and not the other.
Demanding an empty diff would either stall the migration on noise, or — worse —
bury a genuine transcription error inside a screenful of benign version churn. That
is the exact failure the gate exists to prevent.

**So the gate is classification, not emptiness:**

1. Enumerate the version-shaped differences once, deliberately, and write them down.
2. Every remaining line must fall in that set.
3. **A line that is not on the list is the bug.** That is a far easier thing to spot
   than a needle in a screenful.

Pay closest attention to anything matching `${`, per the Phase 3 hazard — a
surviving `${SECRET_*}` renders verbatim and looks like ordinary config.

**Baseline provenance, since "which talhelper made this" must not be a guess:**
generated 2026-08-31 with talhelper **3.1.17**, from `talconfig.yaml` unchanged
since 2026-07-21. The `clusterconfig/` files dated 2026-08-29 are newer than every
input, so they are not stale — but their generator is unrecorded, which is why the
attributable one is the reference.

**Regenerate the baseline before Phase 7, not after.** Phase 7 uninstalls talhelper;
whatever baseline exists at that moment is the last one obtainable.

### Phase 4 tooling and the real-secrets gate

The comparison in Phase 3 used synthetic secrets, so it cannot show that the PKI, tokens,
Tailscale key, LUKS passphrase or registry domain are right. `talos/tools/verify-real.sh`
closes that. Run by the operator (it needs the age key), it prints only `SAME` / `DIFFERENT` /
counts, never a value:

```bash
SOPS_AGE_KEY_FILE=~/Repositories/flux-talos/age.key talos/tools/verify-real.sh
```

1. `talsecret.sops.yaml` and `secrets.sops.yaml` are the same PKI bundle;
2. each of the three values in `topf.yaml` `data:` equals its `talenv.sops.yaml` original;
3. a **real-secrets render** (into a mode-700 temp dir, removed on exit) equals the baseline
   for all 8 nodes, HMAC-compared, so a wrong secret, a mangled passphrase or a missing key
   cannot compare equal.

The default baseline is the live-applied `~/Repositories/flux-talos/talos/clusterconfig/`,
which Phase 0 showed is byte-identical to what talhelper generates today. The script's own
negative cases were tested on synthetic data: a different PKI bundle, a different secret in
`talenv`, and a different rendered passphrase each produce `DIFFERENT` and `FAIL`.

**Gate to Phase 5: exit 0.** Anything else means do not apply.

`verify-real.sh` deliberately **withholds topf's error text on a render failure** (found by the
automated PR review): an error about a field can quote its value, and the script promises never
to print one. It prints how to reproduce the render by hand instead. Tested with a stand-in
topf that writes a canary "secret" to stderr: it never reaches the output.

**Result, 2026-09-24 (Derek ran it with the real age key): `RESULT: OK`.** The PKI bundles are
the same; `tsAuthKey`, `volumeKey` and `domain` equal their `talenv.sops.yaml` originals; and
a render with the real secrets matches the baseline for all 8 nodes (jormungandr1-3: 120
lines each, freyja01: 161, jormungandr4: 140, brokkr01-03: 177 each), **0 differing lines,
HMAC-compared**. That covers the cluster PKI, tokens, Tailscale key, LUKS passphrase (so
`| toJson` did not alter it) and registry domain. The only note the tool printed is that
document **order** differs from the baseline on every node; the leaf comparison ignores order
by design, and whether it matters is decided by Phase 5's per-node `--dry-run`.

This settles equivalence to talhelper's *output*. It does not settle equivalence to what the
nodes actually run (hand-applied drift is invisible here) or that `topf apply` sends the same
bytes as `topf render`; both are what the Phase 5 dry-run is for.

### The authoritative check is Phase 5, not this one

This phase compares topf against *another generator*. `topf apply --dry-run`
compares it against **what the node is actually running**, server-side, which is the
question that matters and the one no offline diff can answer. Phase 4 is the cheap
filter that catches gross errors before touching hardware; Phase 5's per-node
dry-run is the real gate.

> **Phases 1–4 never contact the cluster.** Everything above is files on disk and is
> reversible by deleting a branch. Nothing is applied to hardware until this gate
> passes.

### Phase 5 — apply, node by node

Workers before control planes, `--dry-run` first (which diffs against what is
actually *running* — strictly better than diffing against a previously generated
file). Verify node health between each.

Order: **jormungandr4, then jormungandr1/2/3, then brokkr01/02/03, then freyja01
last.** All seven are workers and any of them can be rolled without an API outage.
freyja01 is last because it is the only node where a mistake is a cluster-wide
outage, not a node-local one. jormungandr4
is a worker (`controlPlane: false`, verified in `talconfig.yaml`) and goes first
because it is the least critical node and exercises the most unusual patch path —
it is the only node with VLANs on a plain `end0` rather than a bond, the only one
with an `EPHEMERAL` VolumeConfig among the Pis, and the only worker with its own
`node/` directory. If the patch
tree is wrong anywhere, it is most likely wrong there, and that is the cheapest
place to find out. jormungandr1-3 then share its low-power patch set with one fewer
moving part (no VLANs, no EPHEMERAL VolumeConfig), so they are the cheapest confirmation
that `worker/` is right for the Pi group before it meets brokkr's bond and LUKS volumes.

**freyja01 is the only control plane; applying to it is an API outage if the change
needs a reboot.** Treat it like the vault maintenance window
(`docs/runbooks/vault-nas-maintenance.md`), because freyja01 is a VM on vault and the
two share a failure domain. Concretely:

- `topf apply --dry-run` first; read the node's own diff. If it shows a change that
  needs a reboot, stop and schedule it rather than proceeding.
- Prefer no-reboot apply modes. Confirm which mode topf uses by default and whether it
  can be forced (`--dry-run` output, and topf's `apply` flags) **in Phase 0**.
- Never apply to freyja01 in the same window as a change to the workers.
- With no second control plane there is no quorum to lose *and* none to fail over to. A
  bad config that stops `apiserver` coming back is recoverable only through the Talos
  API on that node, so confirm the talosconfig can reach freyja01 directly first.

**The step-by-step procedure is in [`docs/runbooks/talos-topf-migration-apply.md`](../../runbooks/talos-topf-migration-apply.md)**
(per-node commands, decision tables, stop conditions, rollback). The hazards it is built on:

**Phase 5 preconditions and hazards (from the 2026-09-24 safety review):**

- **topf silently falls back to an insecure TLS client.** Verified in v0.6.0
  `internal/topf/client.go`: `Client()` probes `:50000` for mTLS and, if the node does not
  demand a client certificate, uses `createInsecureClient` and pushes the full config. That is
  the maintenance-mode path, but it also fires for a spoofed IP, a node reset into
  maintenance mode, or a wrong `ip:`, and the config carries the CA keys, etcd and
  service-account keys. talosctl needs an explicit `--insecure`; topf does not. **Before each
  apply, run an mTLS-verified `talosctl -n <ip> version`**, and apply one node at a time with
  `--nodes-filter '^<host>$'`.
- **`--redact` does not cover the node's *current* values.** It masks the new `data:` values
  and a fixed list of PKI fields, but not the running node's TS_AUTHKEY or LUKS passphrase; a
  dry-run diff that touches those lines would print the old values. Do not run dry-runs into a
  log, `tee` or recorded terminal.
- **Stop conditions on freyja01's dry-run, in order of severity:** (1) any change to the
  `Layer2VIPConfig` (10.0.10.30, the cluster endpoint) or the `LinkAliasConfig`/DHCP selector:
  an API outage; (2) `HostnameConfig` (`auto: "off"` overriding topf's `auto: stable`): a
  hostname change breaks node and etcd identity; (3) the PKI or `clusterName`; (4) the
  tailscale `ExtensionServiceConfig` env: an extension restart and the second remote path to
  the node; (5) `install.disk` and the installer image, which only take effect at upgrade.
- A render that fails (for example the guard) still writes the nodes that succeeded. Confirm
  `apply` aborts on a render error before relying on it; if unsure, render first, then apply.

### Phase 6 — keep the versions from drifting again

The 2026-08-31 drift is already fixed (all three at `v1.13.9`). What remains is the
structural cause: nothing ties `talosVersion` to the tuppr CR, and Renovate's Talos
bump PR (**#1849**, open since 2026-09-21) does not touch `talconfig.yaml`.

- Decide #1849's timing before Phase 5 (see
  [Version drift](#version-drift-resolved-by-hand-but-it-will-recur)).
- After Phase 1 the version lives in `talos/topf.yaml`, **in the clear**, carrying the same
  `# renovate: datasource=github-releases depName=siderolabs/talos` annotation as
  `talconfig.yaml` does today (D1, and the file-name note in that section).
- Add a Renovate group so `talosVersion`, the tuppr CR and the `etcd-defrag` image bump
  in one PR. tuppr keeps ownership of upgrades; topf never runs `topf upgrade`.

### Phase 7 — retire talhelper

Remove `talconfig.yaml`, `talenv.sops.yaml`, the talhelper `just` recipes, and
`brew uninstall talhelper`. The recipes are in `talos/mod.just`: `gen-config` and
`gen-secrets` call talhelper directly, and the **upgrade-node recipe reads
`talos/clusterconfig/home-kubernetes-<node>.yaml`** — it will fail once that directory
is gone. `talos/update-node.sh` is a second consumer to check. Files that mention the
old toolchain and need a pass (grep at 2026-09-23): `.envrc`, `.mise.toml`,
`.gitignore`, `CLAUDE.md`, `.serena/memories/{core,tech_stack,suggested_commands}.md`,
`.claude/commands/renovate-sweep.md`, `.claude/renovate-sweep/triage-and-safety.md`,
`bootstrap/helmfile.d/01-apps.yaml`, `docs/runbooks/{controlplane-migration-to-vault-vm,
controlplane-migration-to-brokkr,brokkr03-airdisk-reprovision,cluster-ipv6-dual-stack}.md`,
and code comments in `etcd-defrag`, `tns-csi` and `prometheusrule`. Comments that say
"in talconfig.yaml" become wrong the day it is deleted.

**`.envrc` needs updating and it will break silently if missed:**

```bash
.envrc:16   export TALOSCONFIG="$(expand_path ./talos/clusterconfig/talosconfig)"
```

That path is talhelper's output directory. Once `clusterconfig/` is gone,
`TALOSCONFIG` points at nothing and every bare `talosctl` invocation in the repo
loses its context — no error, just no endpoints.

**Regenerating it needs a redirect, not the obvious command.** `topf talosconfig`
describes itself as "generate and **save** talosconfig from secrets bundle" and does
no such thing — it is a bare `fmt.Println` to stdout:

```bash
topf talosconfig > talos/talosconfig
```

Two consequences. That `Println` bypasses the redacting writer `--redact` controls,
and the payload is the **admin client certificate and key** — so never into a log, a
`tee`, or a recorded terminal, exactly as with `topf secrets`. And it calls
`t.Secrets()` first, so against a missing secrets file it reaches the generate-new-PKI
prompt, which on v0.5.0 is the infinite loop. One more reason for the pin.

**Put it at `talos/talosconfig`** — one level up from the generated directory, still
grouped with the Talos configuration, out of anything topf regenerates.

Three files need cleaning up in the same commit so exactly one talosconfig exists:

```
talosconfig                  25 B  stub  context: "" / contexts: {}   → delete
clusterconfig/talosconfig    25 B  stub  (root-level dir, April, stale) → delete
talos/clusterconfig/         the real one, plus 7 node configs         → delete
```

**Delete `.mise.toml` too.** It declares `TALOSCONFIG = "{{config_root}}/talosconfig"`
— the repo root, pointing at one of those empty stubs — and disagrees with `.envrc`,
which points into the generated directory. Derek has confirmed he has never run
`mise`; the file arrived by copy-paste from another homelab repo and has never been
active. It is inert today only because mise isn't installed, and it would silently
break `talosctl` the day it is. `direnv` + `.envrc` is the real env driver.

(An earlier draft chose the repo root specifically to make `.mise.toml` correct
without editing it. With that file deleted the constraint disappears, and
`talos/talosconfig` is the tidier resting place — the minimal move from where the
file lives today.)

Keep the filename `talosconfig`: `.gitignore:33` is `**/talosconfig`, which covers
any location but stops covering it under a different name. Confirmed with
`git check-ignore` rather than by reading the glob — writing an admin client cert
anywhere is only safe if that exact path is genuinely ignored, and the destination
is:

```
talos/talosconfig                 .gitignore:33:**/talosconfig   ← the destination
talosconfig                       .gitignore:33:**/talosconfig
clusterconfig/talosconfig         .gitignore:33:**/talosconfig
talos/clusterconfig/talosconfig   talos/clusterconfig/.gitignore:2
```

None is tracked.

**Order matters: generate, verify, then delete.** The only working talosconfig lives
in the directory this phase removes. Delete first and you are one failed command —
missing secrets, wrong `--topfconfig`, a v0.5.0 prompt hang — away from a repo
containing three talosconfigs, two of them empty stubs and none of them usable,
mid-migration against live hardware. It recovers from `secrets.sops.yaml`, but the
five minutes of "why can't I reach the cluster" are avoidable:

```bash
topf talosconfig > talos/talosconfig
talosctl --talosconfig ./talos/talosconfig config info   # expect context home-kubernetes, 1 endpoint (10.0.10.35), 8 nodes
# only after that check passes:
rm -rf talos/clusterconfig clusterconfig talosconfig .mise.toml
```

**Where the 25-byte stubs come from — mechanism reproduced.** They are talosctl's
own empty config, byte-for-byte:

```
context: ""
contexts: {}
```

Reproduced in a sandboxed `HOME`: with no default config present and `TALOSCONFIG`
pointing at a path that does not exist yet, an ordinary `talosctl config` command
creates exactly that file at that path. No broken pipe or partial write required —
a successful command produces it.

**And `TALOSCONFIG` does not reliably control where config writes land.** With a
default `~/.talos/config` already present, the same command *ignores* `TALOSCONFIG`
and writes the default instead, reporting the named path as missing. Worth knowing
whenever a talosctl config write seems to have done nothing: check `~/.talos/config`
before concluding it failed.

Practical consequence for this phase: after the real client config lives at
`talos/talosconfig`, a stray `talosctl config` command with `TALOSCONFIG` set and the
file absent would recreate it as an empty stub. The `config info` check above is
worth keeping as a periodic smoke test, not only a migration step.

### Populate the global config while you are here

`~/.talos/config` is currently the empty stub, so any `talosctl` run *without*
`TALOSCONFIG` — outside the repo, or in a shell where direnv has not loaded — has no
cluster context. That is not theoretical: during the 2026-08-29 tuppr upgrade
failure on brokkr01, the Talos layer was the only remaining source of the error
(tuppr had already deleted the job) and it was unreachable for exactly this reason.

```bash
talosctl config merge ./talos/talosconfig
```

**Do not pass `--talosconfig` here.** The merge *target* is the default config and
the argument is the *source*; naming the same file as both merges it into itself,
which collides on context name and **renames the active context to
`home-kubernetes-1` in the source file** — inflicting the precise breakage Phase 1
exists to prevent, on the file generated minutes earlier. Verified in a sandbox: the
correct form leaves the source byte-identical and populates `~/.talos/config` with
context `home-kubernetes` and both endpoints.

**Tradeoff, and it is a judgement call.** A populated `~/.talos/config` puts admin
credentials within reach of any shell on the machine, not just the repo with direnv
loaded. Against that, tuppr has now failed two upgrades where the Talos layer was
the only diagnostic left. Reachability is the better trade here, but it is Derek's
to make.

**Content parity was confirmed 2026-08-31 and must be re-confirmed** — the cluster has
changed under it. topf sets `endpoints` to the control-plane nodes and `nodes` to all
nodes. Today that means endpoints `10.0.10.35` only, nodes all eight (`.31-.35`,
`.38-.40`); the live file agrees. **The endpoint must not list a Pi**: workers do not
proxy Talos API requests, so a talosconfig that still names one fails with
`no request forwarding`.

### Update the agent-facing docs, or the deleted files come back

This is not tidiness. Three documents currently tell any agent reading them that the
toolchain is mise-managed:

```
.serena/memories/tech_stack.md:33         ## Toolchain (managed via mise)
.serena/memories/tech_stack.md:48         - `.mise.toml` — tool versions + env vars
.serena/memories/suggested_commands.md:3  ...or `.mise.toml` env is active
.claude/renovate-sweep/repo-runbook.md:34 Dev tooling lives under mise/Homebrew
```

**That is the propagation mechanism for a false belief.** An agent reads
`tech_stack.md`, concludes the toolchain is mise-managed, and writes the next change
on that footing — which is plausibly how `.mise.toml` arrived and certainly how it
would return. Delete the file without correcting these and the claim outlives it.

Update in the same commit, stating what is actually true: `direnv` + `.envrc` for
env, Homebrew for tools, and topf pinned in `.bin/`.

Also: `CLAUDE.md` states the source of truth is `talos/talconfig.yaml`, and
`docs/runbooks/cluster-ipv6-dual-stack.md` references `just talos gen-config`.

**Not a concern, checked:** `dev-shell` installs and activates mise, but nothing
under `kubernetes/apps/develop/dev-shell/` clones this repo — no `git clone`, no
reference to it at all. Its home PVC is persistent, so a checkout placed there by
hand would make `.mise.toml` live in that pod. One deliberate action away, not
happening now.

## Acceptance criteria

- [ ] `topf render` output is equivalent to the talhelper golden baseline after normalisation (parsed, key-sorted, keyed by kind+name), or
      every difference is explained and accepted.
- [ ] Both schematic IDs reproduce exactly.
- [ ] **`grep -rn '\${' talos/patches/ talos/schematics/` returns nothing.** Any
      surviving `${SECRET_*}` would render verbatim into a live machine config
      without raising an error.
- [ ] `sops -d talos/secrets.sops.yaml` round-trips; cluster PKI unchanged.
- [ ] No file in the repo contains an unencrypted secret — verified by running
      gitleaks across the working tree *without* the `*.sops.yaml` exclusion.
- [ ] The new pre-commit check rejects a plaintext file named `*.sops.yaml`.
- [ ] All 8 nodes healthy after apply; `talosctl health` clean.
- [ ] Talos version is consistent across the topf config, the tuppr CR, and the
      running cluster, and Renovate still sees the version (D1).
- [ ] `admissionControl` on freyja01 renders identically to the baseline.
- [ ] `topf apply --dry-run` shows an empty diff, or only expected differences, on every
      node — freyja01 last.

## Rollback

Through Phase 4, rollback is deleting a branch — nothing has touched the cluster.

After Phase 5, `talconfig.yaml` is still in git history and talhelper 3.1.17 still
runs, so regenerating and re-applying the previous config is a working escape hatch.
Keep the golden baseline until Phase 7 is signed off. **Do not delete
`talconfig.yaml` until the cluster has been healthy on topf-generated config through
at least one tuppr upgrade cycle** — the first event that would expose a latent
difference.

## Risks

| risk | mitigation |
|---|---|
| topf is pre-1.0 with a self-declared unstable CLI | The patch tree is raw Talos documents — see [Why topf is a safe bet](#why-topf-is-a-safe-bet-despite-being-pre-10) |
| topf lags new Talos document kinds | Resolved for 1.14: v0.6.0 supports the 1.14 documents. Still watch 1.15 (`v1.15.0-alpha.0` exists); tuppr controls upgrade timing so we are not forced |
| `.tpl` files bypass the SOPS pipeline entirely — an `ENC[...]` literal would pass through verbatim into the machine config | Invariant 3: secrets route through `data:`, never as a literal in a `.tpl` |
| **`${SECRET_*}` is inert in topf and fails silently** — talhelper substituted it, topf renders it verbatim into a live config with no error | Strip during Phase 3; `grep -rn '\${'` in the acceptance criteria; Phase 4 diff catches it |
| **freyja01 is the only control plane on the same host as vault** — an apply needing a reboot is an API outage, and a config that stops `kube-apiserver` is recoverable only via the Talos API | Apply last, `--dry-run` first, no-reboot modes, vault-maintenance-window discipline; see Phase 5 |
| **Whole-file SOPS hides `talosVersion`/`kubernetesVersion` from Renovate** | Decision D1: partial encryption (decided 2026-09-23) |
| **`admissionControl: null` is a no-op** (both tools keep the default `PodSecurity` plugin) — the patch never did what its comment claims | Measured parity; do not change it in this migration; Phase 4 confirms |
| **A node with no `schematicId` silently gets Talos's default (extension-less) schematic** | `all/00-guard.yaml.tpl` fails the render; no global default |
| **Adding/renaming a node renders and validates but lacks its network, disk or bond** | The same guard fails on an unknown hostname or role |
| **Secrets pasted unquoted into YAML** (`#` truncates, `0123` becomes octal) | `| toJson`; Phase 4 verifies the rendered passphrase by HMAC |
| **topf falls back to an insecure TLS client when a node does not demand mTLS** | mTLS-verified `talosctl version` before each apply; one node at a time |
| **`--confirm=false` with a wrong secrets path mints a new plaintext PKI** | Do not blanket-pass it; keep `--confirm` on for `render`; verify the secrets path before any `--confirm=false` apply |
| **A partial `node/` overlay of a same-named document drops fields** (`diskSelector` lost) | Do not layer same-named documents; drive differences with `.Node.Data` |
| **Renovate #1849 rolls Talos while topf is being introduced** | Sequence it: never straddle the bump (see Version drift) |
| **`{{ }}` inside a YAML comment in a `.tpl` still expands** — commenting out a template line does not disable it | Fails loudly via `missingkey=error` rather than silently, but delete template lines rather than commenting them |
| Per-node `installer.schematic` **replaces** the cluster-wide one rather than merging | Three schematics exist and all are written out in full, so this costs nothing here. `{{ .SchematicID }}` in a `.tpl` resolves per node |
| **A missing `sops` binary can degrade silently** — measured 2026-09-24: loud in this setup only because the secrets bundle is encrypted | Verify `sops --version` as a Phase 1 precondition; check with `sops filestatus`, not exit codes |
| **`topf secrets` writes a plaintext PKI bundle if encryption fails**, and reports success | Not on our route — we import an existing bundle rather than generating one. Never run `topf secrets` on this cluster |
| `topf secrets` prints the bundle to stdout unredacted | Never into a log, `tee`, or recorded terminal |
| **v0.5.0 spun forever on EOF at any confirm prompt** — discarded read error, unbounded loop | Fixed before v0.6.0 (measured: exits 1 in <1s instead of hanging). Pin the v0.6.0 tag. Do **not** use `--confirm=false` as a blanket habit — see Version selection |
| Behaviour in this spec was verified at `21831714`, 28 commits before the current rc, including a secrets-redaction change | Phase 0 re-verifies the load-bearing checks against the chosen release |
| `mise` is not installed on this machine despite `.mise.toml` existing (`direnv` + `.envrc` is the actual env driver) | Delete `.mise.toml` in Phase 7; `brew install postfinance/tap/topf` exists but `go install` into `.bin/` pins per checkout |

## Open questions

Verified by Pollen against topf's source at `main` (`21831714`, 2026-08-27), which
is ahead of v0.5.0 and includes a rewrite of `internal/decryption`.

**Answered:**

1. **Partial SOPS encryption works** — decrypts correctly through
   `decryption.ReadFileWithSecrets` and still identifies plaintext secrets for
   redaction. Moot in practice; see 7.
2. **`topf render` cannot write to stdout** — REFUTED. `--output` is a directory.
   But `topf apply` never writes to disk at all, so the property is achieved by a
   better route. Design updated.
3. **`secretsPath` accepts any path; SOPS is detected by content, not filename** —
   topf shells out to the `sops` binary and parses `sops filestatus`.
4. **Both schematic IDs reproduced exactly**, offline, first attempt, from the
   `customization:` blocks transcribed out of `talconfig.yaml`. Phase 2 is
   de-risked.
7. **`--topfconfig` takes an arbitrary path** (`TOPFCONFIG` env var too);
   `topf.yaml` is only a default. This removes the need for partial encryption
   entirely.

5. **Merge order confirmed by execution** — `all/` → `<role>/` → `node/<host>/`,
   last wins, lexical within each directory. `$patch: delete` removes an inherited
   subtree; `key: null` does not.
8. **Per-node `installer.schematic` replaces, does not merge** — proven by hash:
   an overridden node's installer image carried the standalone hash of its own
   schematic file, which a merged schematic could not produce.

**All seven closed** (against `21831714`; re-verified against the chosen release in Phase 0). Nothing on this list was unverified at that commit. The only things left
untested are those that need real hardware — `apply`'s live dry-run output,
`--online`, and health checks — which belong to Phase 5.

**Revised rather than withdrawn:** an earlier draft flagged "env substitution runs
over comments," carried over from talhelper. That was wrong in one direction and
right in another, and the correction matters:

- **`${...}` does not expand at all in topf** — so a leftover `${SECRET_*}` is
  inert and lands verbatim in a live config, silently. Now in Risks and the
  acceptance criteria.
- **`{{ }}` in a `.tpl` comment does expand**, because Go templates are text-level.
  Commenting out a template line does not disable it. This fails loudly thanks to
  `missingkey=error`, but the hazard is real.

### One comfort worth recording

Patches are **strictly schema-validated at load time** — `configpatcher.LoadPatch`
rejects unknown keys against the target Talos version before anything is generated.
A typo or a field that moved between Talos releases fails at `topf render`, before
Phase 4 and long before hardware. For a 386-line extraction that is a meaningful
safety net.

Worth one clarification, since a test fixture briefly made this look like a
problem: **`machine.install.diskSelector` is valid and Derek's usage is correct.**
Two different `diskSelector` schemas exist and they are not interchangeable —
`machine.install.diskSelector` takes `model:`/`serial:`/`wwid:`, while
`VolumeConfig`'s takes a CEL `match:` expression. Derek's config uses each in its
right place, and `talosctl validate -m metal` accepts the golden baseline. A
fixture that put `match:` under `machine.install.diskSelector` was correctly
rejected — the validator working, not a topf limitation.

## Deferred, deliberately

- **`installDisk: /dev/sda` on the four Pis.** The disk reports `TRANSPORT usb`, so
  a device-path pin is fragile in principle — but its WWID is `naa.5000000000000001`
  and model `2115`, both generic USB-SATA bridge values that may not discriminate
  between identical adapters. Worth revisiting; not part of a migration whose gate
  is byte-identical output.
- **Talos 1.14.** Explicitly out of scope; see Version selection.
- **Converge jormungandr1-4 (follow-up, after Phase 5).** All four are the same Pi model
  and all are workers, so they should render identically. Today jormungandr4 differs
  (VLANs 10/30/50, an `EPHEMERAL` `VolumeConfig`, `interface: end0` instead of the
  `deviceSelector` alias). Kept out of the migration on purpose so Phases 4-5 reproduce
  today's config exactly. Inspected live 2026-09-24: the `sda` disks are the same USB
  bridge (`2115`, `naa.5000000000000001`) but **240 GB on j1-3 vs 250 GB on j4**, and
  `EPHEMERAL` is 239 GB vs 249 GB. j4's `maxSize: 100GiB`/`grow: false` block is **not
  in effect** on the live volume (the partition predates it and does not shrink), so it
  is a no-op today: drop it from j4 or apply it everywhere, knowing a real cap needs a
  wipe. Before adding VLANs to j1-3, check whether any workload relies on j4 being the
  only Pi with Multus legs. After the migration this is one shared `worker/` Pi patch
  set and deleting `node/jormungandr4/`.
- **OpenTofu + `siderolabs/talos`.** Re-evaluated 2026-09-23 with Derek and **not
  chosen**. The provider is healthy (v0.12.0 on 2026-09-21, first-party, Talos SDK
  1.14.0) and `tofu import` of the existing PKI was verified viable on 2026-08-31. The
  reasons it lost, each checkable:
  - **State.** It needs a state backend, and the obvious one (Garage S3 on vault)
    shares fate with freyja01, the only control plane, which is also on vault. State
    would hold the PKI. R2 avoids the shared fate but adds a dependency. topf is
    stateless.
  - **v0.12.0 is a redesign.** It adds `talos_machine` and `talos_cluster` resources
    (reboot recovery, upgrade handling), which overlap with tuppr, the deliberate
    upgrade driver (constraint 4). Adopting it means choosing which owns upgrades.
  - **A first apply against all 8 nodes**, one of them the only control plane.
  - **Not verified, so not counted against it:** whether a `talos_version` contract
    cleanly pins 1.13-shaped output on an SDK 1.14 provider; Raspberry Pi overlay support
    in the current schematic resource.

  The patch tree this migration produces is exactly what the provider's
  `config_patches` would consume, so this stays reversible.
