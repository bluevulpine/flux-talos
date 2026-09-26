# Runbook: Phase 5 of the talhelper → topf migration (per-node dry-run and apply)

**Audience:** the operator (Derek). **Design and rationale:**
[`docs/superpowers/specs/2026-08-31-talhelper-to-topf-design.md`](../superpowers/specs/2026-08-31-talhelper-to-topf-design.md).

> **Status: COMPLETE (2026-09-25).** All 8 nodes applied and verified healthy. See
> [Results](#results-2026-09-25) below for what actually happened; keep the rest of this
> document as the reference procedure for the next time a patch-tree change needs a
> re-apply.

## Results (2026-09-25)

Every node — jormungandr4, jormungandr1-3, brokkr01-03, then freyja01 in its own window
— showed the identical class of dry-run diff: **a pure document reorder with zero
field-level change**, exactly the hazard this runbook's intro predicted. None needed a
reboot. All 7 workers were applied first; freyja01's preconditions were re-verified
same-day (hours had passed) before its own apply, including a fresh manual etcd
snapshot. Full per-node table and evidence: the design spec's "Phase 5 results"
section. Post-apply, the whole cluster stayed healthy — every Flux Kustomization
Ready, no disrupted pod, all 8 nodes on the correct schematic and `v1.13.9`.

**Not exercised** — the classes of diff this runbook's decision tables were written
for never came up: drift, a wrong secret, an actual reboot-requiring change, or any of
the freyja01 stop conditions firing. Re-read those sections in full the next time a
real field-level diff appears; this run only confirmed the reorder case.

## What Phase 5 actually is

The configs topf renders equal what talhelper generated, and the nodes were applied from
that output. Verified with the real secrets on 2026-09-24 (`talos/tools/verify-real.sh`:
`RESULT: OK`, 0 differing lines on all 8 nodes). So **the expected result of every per-node
`topf apply --dry-run` is "no changes" (exit 0)**, and Phase 5 is mostly *proving a no-op*,
not applying anything.

What the offline comparison cannot show, and this phase can:

- **drift**: someone hand-applied something to a node after talhelper generated its config;
- **render vs apply**: that `topf apply` sends the bytes `topf render` wrote;
- **document order**: the render orders documents differently from the baseline on every node
  (the leaf comparison ignores order). Talos should not care; the dry-run is where we find out.

**Phase 5 is complete when all 8 dry-runs exit 0**, or every diff is understood and accepted
(and applied deliberately, one node at a time). You only run a real apply for an *accepted*
diff. A clean cluster needs none.

## Hard rules

1. **One node at a time**, always with `--nodes-filter '^<host>$'` (a regex, so anchor it).
   Never run `topf apply` unfiltered.
2. **Never `--confirm=false` without a reviewed dry-run.** With a wrong secrets path it
   generates a brand-new PLAINTEXT PKI and carries on (measured). Leave `--confirm` on.
3. **Never run `topf secrets`.** It prints the whole PKI bundle and, if encryption fails,
   writes it plaintext.
4. **Keep `--redact` on (default), and keep dry-runs out of logs, `tee` and recorded terminals.**
   `--redact` masks the new `data:` values and a fixed list of PKI fields, but **not the
   running node's current** Tailscale key or LUKS passphrase. A diff touching those lines
   would print the old values.
5. **Verify mTLS before every apply** (step A below). topf silently falls back to an
   insecure TLS client when a node does not demand a client certificate, and would push the
   full config, CA keys included, to whatever answers on that IP.
6. **freyja01 is last and gets its own window.** It is the only control plane: a change that
   needs a reboot is a cluster-wide API outage.
7. **Do not merge Renovate #1849, and do not let tuppr roll, while this runs.** Never straddle
   a Talos bump.
8. **Do not run `just talos gen-secrets` (rotate the PKI) during the migration.** The PKI bundle
   exists twice until Phase 7 (`talsecret.sops.yaml` for talhelper, `secrets.sops.yaml` for topf)
   and the recipe only rewrites the first. CI (`SOPS Check`) fails if they diverge; if you must
   rotate, change both in one commit and re-run `verify-real.sh`.

## Before you start (once)

```bash
cd ~/Repositories/flux-talos-talos-gen          # or a checkout of main after the PR merges
export SOPS_AGE_KEY_FILE=$HOME/Repositories/flux-talos/age.key
export TC=$HOME/Repositories/flux-talos/talos/clusterconfig/talosconfig   # talosctl client config
```

`$TC` has one endpoint (freyja01, `10.0.10.35`) and all 8 nodes, so `talosctl -n <worker-ip>`
is proxied through the control plane. That file is also the rollback reference; **do not
delete `talos/clusterconfig/` until Phase 7 is signed off**.

1. **Re-run the real-secrets gate.** Anything that changed under `talos/` since the last run
   invalidates it.
   ```bash
   talos/tools/verify-real.sh        # must end: RESULT: OK
   ```
2. **The topf binary is the verified one.**
   ```bash
   go version -m .bin/topf | grep -E '^\s*mod\s+github.com/postfinance/topf'   # expect v0.6.0
   ```
3. **Cluster is healthy and nothing is mid-flight.**
   ```bash
   kubectl get nodes -o wide                          # 8 nodes Ready
   kubectl get talosupgrade,kubernetesupgrade         # talos: Completed, nothing rolling
   talosctl --talosconfig $TC -n 10.0.10.35 health --server=false
   (cd talos && ../.bin/topf nodes)                   # all Ready ✓, Running, Talos v1.13.9
   ```
   In `topf nodes`, check the **Schematic** column matches (freyja01 `647d…`, Pis `a6c7…`,
   brokkr `b915…`). A node whose *running* schematic differs from topf's would be re-imaged
   at the next upgrade.
4. **A recent etcd backup exists.** The cluster runs `talos-s3-backup` (hourly) and
   `talos-offsite` (hourly) in `kube-system`:
   ```bash
   kubectl -n kube-system get cronjob talos-s3-backup talos-offsite
   ```
   Confirm both ran within the last hour. For extra safety before touching freyja01, take
   one by hand to a path **outside the repo**, mode 600 (it contains cluster secrets):
   `( umask 077; talosctl --talosconfig $TC -n 10.0.10.35 etcd snapshot ~/etcd-pre-topf.db )`.
5. **No overlapping maintenance.** Nothing scheduled on vault (freyja01 is a VM on it; see
   [`vault-nas-maintenance.md`](vault-nas-maintenance.md)), no VolSync/Longhorn operation you
   are waiting on.

## Order

`jormungandr4` → `jormungandr1` → `jormungandr2` → `jormungandr3` → `brokkr01` → `brokkr02` →
`brokkr03` → **`freyja01`** (separate window).

jormungandr4 is first because it exercises the most unusual patch path (VLANs on a plain
`end0`, its own `node/` directory, its own `EPHEMERAL` volume), so a wrong patch tree is most
likely wrong there, and it is the cheapest node to find out on.

## Per worker node

Set the node, then work through A → D. Do not skip ahead.

```bash
HOST=jormungandr4   IP=10.0.10.34        # jormungandr1-3: .31 .32 .33; brokkr01-03: .38 .39 .40
```

**A. mTLS is enforced (secure path).** This must succeed *without* `--insecure`:
```bash
talosctl --talosconfig $TC -n $IP version
```
If it fails, or the node is in maintenance mode, **stop**: topf would use its insecure client.

**B. Dry-run.** Exit code is the signal: `0` no changes, `2` changes (diff printed), anything
else is an error.
```bash
(cd talos && ../.bin/topf --nodes-filter "^${HOST}\$" apply --dry-run </dev/null); echo "exit=$?"
```

**C. Decide.**

| result | meaning | do |
|---|---|---|
| `exit=0` | topf's config equals what the node runs | **Done for this node.** Record it and go to the next. |
| `exit=2` | a difference exists | Read the diff (not into a log). Classify below. |
| other | pre-flight failure, render error, unreachable | Fix the cause. Do **not** add `--skip-problematic-nodes` or `--allow-not-ready` to get past it. |

Classifying an `exit=2` diff:

| diff shows | likely cause | do |
|---|---|---|
| a field you know you hand-applied to that node | drift | Decide: encode it in `talos/patches/` (then re-run `verify-real.sh` and re-baseline), or accept topf reverting it. |
| something under the tailscale `ExtensionServiceConfig` env | the stored key differs from the running one | **Stop.** See "Tailscale key" below. |
| LUKS / `UserVolumeConfig` encryption | passphrase differs | **Stop.** Do not apply. The live disk key may not be what `talenv` holds. |
| anything else you cannot explain | generator difference | **Stop** and investigate; do not apply "to see what happens". |

**D. Apply only an accepted diff**, with confirmation on and no reboot permitted:
```bash
(cd talos && ../.bin/topf --nodes-filter "^${HOST}\$" apply --mode no-reboot)   # shows the diff, asks y/n
```
`--mode no-reboot` refuses a change that needs a reboot instead of silently rebooting. If it
refuses, that is a decision for you (schedule a reboot window, or `--mode staged`), not a
reason to retry with `auto`.

**E. After any apply, and for jormungandr4 even after a clean dry-run:**
```bash
(cd talos && ../.bin/topf --nodes-filter "^${HOST}\$" nodes)      # Ready ✓, Running
kubectl get node $HOST
talosctl --talosconfig $TC -n $IP service ext-tailscale            # Running
```
Wait a few minutes and re-check before starting the next node.

### Tailscale key (jormungandr4 first, then all)

The key in `talenv.sops.yaml` / `topf.yaml` `data.tsAuthKey` is **likely expired** (90-day
maximum). It was carried across unchanged on purpose: the running node keeps working on its
own node key, and a changed key would show in every dry-run. Expiry only bites when a node
**re-registers** (state wiped, reset, rebuilt).

- A clean dry-run means the stored key equals what the node has: nothing to do.
- If applying makes the tailscale extension restart and it tries to log in again with the
  expired key, `ext-tailscale` will not come back up cleanly. **Stop before the next node**,
  rotate the key (issue a new one; update `talenv.sops.yaml` *and* `topf.yaml`; re-run
  `verify-real.sh`), then continue.
- **Rotate the key before any node reset or rebuild**, whatever else happens.

## freyja01 (the only control plane): separate window

Everything above applies, plus:

**Extra preconditions**
- All 7 workers are done and healthy.
- Etcd snapshot taken (step 4 above) and `talos-s3-backup` recent.
- `kubectl get talosupgrade,kubernetesupgrade` idle, #1849 unmerged, no vault maintenance.
- You can reach freyja01's Talos API directly: `talosctl --talosconfig $TC -e 10.0.10.35 -n 10.0.10.35 version`.
  This is the path you would use to roll back if the Kubernetes API goes away.

**Dry-run first, then read it against these STOP conditions**, in order of severity:

| # | a diff here means | why |
|---|---|---|
| 1 | `Layer2VIPConfig` `10.0.10.30`, or the `LinkAliasConfig` MAC selector / DHCP for `ethSel0` | an **API outage**: 10.0.10.30 is the cluster endpoint |
| 2 | `HostnameConfig` (`auto: "off"`, hostname) | a hostname change breaks node and etcd identity |
| 3 | the PKI (`machine.ca`, `cluster.ca`, etcd/aggregator/service-account CAs) or `clusterName` | everything trusts these |
| 4 | the tailscale `ExtensionServiceConfig` env | an extension restart, and the second remote path to the node |
| 5 | `install.disk` or the installer image | only takes effect at the next upgrade, but a wrong one breaks it |

Any of 1-3: **do not apply.** 4-5: understand it first.

#### Stop conditions are about content, not position

A document from the table above appearing in the diff is not by itself a trigger — read
what actually changed. **A document that only moves position in the file, with
byte-identical content, is not a trigger; a genuine field or value change is.** This
came up for real on 2026-09-25: freyja01's diff showed `LinkConfig(ethSel0)` relocating
relative to `Layer2VIPConfig`/`DHCPv4Config`, which meant those two rows appeared to be
"touched" by a naive read of the diff. They were not: `Layer2VIPConfig`'s fields
(`name: 10.0.10.30`, `link: ethSel0`), the `LinkAliasConfig` MAC selector, and
`DHCPv4Config`'s fields never appear as an added or removed line — only as unchanged
context around the block that moved. Read the diff's `+`/`-` lines themselves, not just
which document *names* are near a hunk.

**If (and only if) the diff is empty or accepted:**
```bash
(cd talos && ../.bin/topf --nodes-filter '^freyja01$' apply --dry-run </dev/null); echo "exit=$?"
# apply only an accepted diff:
(cd talos && ../.bin/topf --nodes-filter '^freyja01$' apply --mode no-reboot --stabilization-duration 2m)
```

**Verify**
```bash
kubectl get --raw /readyz
talosctl --talosconfig $TC -n 10.0.10.35 etcd status
talosctl --talosconfig $TC -n 10.0.10.35 health --server=false
ping -c1 10.0.10.30 && kubectl get nodes
```

## Rollback

topf and talhelper produce the same config, and the original talhelper output is still on
disk, so the previous state is always recoverable:

```bash
# per node; keep --mode no-reboot unless you know a reboot is required
talosctl --talosconfig $TC -e 10.0.10.35 -n <ip> apply-config \
  -f ~/Repositories/flux-talos/talos/clusterconfig/home-kubernetes-<host>.yaml --mode no-reboot
```

`-m try` applies a config and **rolls it back automatically after `--timeout`** (default 1m)
if you do not confirm; useful for a network change you are unsure about. topf's own `--mode try`
exists but its interaction with topf's post-apply checks is **not verified**, so for a
risky freyja01 change prefer `talosctl apply-config -m try` directly.

If freyja01's Kubernetes API is down but `10.0.10.35:50000` answers, roll back through the
Talos API as above. If the node is unreachable altogether, follow
[`controlplane-migration-to-vault-vm.md`](controlplane-migration-to-vault-vm.md) (etcd restore
from the `talos-s3-backup` snapshot).

## Known unknowns (from the spec)

- Whether `topf apply` **aborts on a render error** or applies the nodes that rendered. A
  failed render (for example the guard in `patches/all/00-guard.yaml.tpl`) still writes the
  others. Always render or dry-run first, and never rely on it.
- Whether the **document-order** difference shows up as a change on a live node (expected: no).
- Whether the **Tailscale** extension re-registers on an apply (watch jormungandr4).
- topf's `--mode try`; see Rollback.

## When it is done

1. ~~Record per-node results (exit codes, anything accepted) in the spec's Phase 5
   section.~~ Done — see [Results](#results-2026-09-25) above and the design spec.
2. Now unblockable: Renovate #1849 (decide whether its `talosctl` 1.14.1 image belongs in
   the same PR as the installer bump), and Phases 6-7 (a Renovate group that bumps
   `talosVersion`, the tuppr CR and the `etcd-defrag` image together; retire `talconfig.yaml`,
   `talenv.sops.yaml`, `talsecret.sops.yaml`, the `just` recipes and `talos/tools/`).
   Also still open: a `just talos install-topf` recipe (there is none today — every fresh
   checkout needs `go install .../topf@v0.6.0` by hand), and the deferred jormungandr1-4
   convergence.
3. **Keep `talos/clusterconfig/` and `talconfig.yaml` until the cluster has been healthy on
   topf-generated config through one tuppr upgrade cycle**, the first event that would expose
   a latent difference.
