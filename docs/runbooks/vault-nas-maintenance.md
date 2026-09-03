# Runbook: vault NAS maintenance restart

How to quiesce the cluster before rebooting the `vault` NAS (TrueNAS SCALE) for
software updates, and how to bring it back.

> **⚠️ This inventory is a point-in-time snapshot — last verified 2026-09-03.**
> It is *not* self-maintaining. Every new app that mounts a vault-backed volume
> must be added here, or it will be left running across the outage. Before every
> maintenance window, **re-run the discovery script in
> [§2](#2-regenerate-the-inventory-do-this-every-time)** and reconcile its output
> against [§3](#3-inventory-as-of-2026-09-03). Treat a diff as the source of
> truth and update this file in the same change.

---

## 1. What `vault` actually is

`vault.funb.us` = **10.0.10.10**. Critically, vault also holds **10.0.10.11** on
the same `br1` bridge:

```
$ ssh bluevulpine@10.0.10.10 'hostname; ip -4 -o addr show'
vault
br1  10.0.10.10/24
br1  10.0.10.11/24
```

**Both IPs die together.** This matters because config in this repo references
vault under three different spellings — `vault.funb.us`, `10.0.10.10`, and
`10.0.10.11` — and it is easy to conclude that a `10.0.10.11` endpoint is "some
other box". It is not. Anything pointed at either address is in the blast radius.

Vault serves the cluster through four independent paths:

| Path | Mechanism | Failure behaviour on restart |
| --- | --- | --- |
| **NFS** | in-tree `nfs` PVs + `tns-csi-nfs` + `vault-nfs` SCs | `hard` mounts block indefinitely, then recover. Data-safe; apps hang. |
| **iSCSI** | `tns-csi-iscsi` SC | Block device vanishes → XFS I/O errors → read-only remount. **Not data-safe.** |
| **NVMe-oF** | `tns-csi-nvmeof` SC (TCP :4420) | Same as iSCSI. **Not data-safe.** |
| **Garage S3** | external service, `:30188` on both IPs | Backup/metrics jobs error out. Data-safe, but jobs fail loudly. |

The Garage path is the one most often missed: Garage runs *outside* the cluster,
on vault, and is the backend for **Thanos**, **CloudNativePG barman backups**,
**talos-s3-backup**, and **every VolSync `*-local` ReplicationSource** — including
those for apps that have no vault-backed PVC at all.

---

## 2. Regenerate the inventory (do this every time)

```bash
cd ~/Repositories/flux-talos
export KUBECONFIG=./kubeconfig

# ⚠️ The default kubectl context (tso-talos.flyingfox-decibel.ts.net) resolves
# only over Tailscale. On the LAN — or with Tailscale stopped — it fails DNS.
# Use the LAN context explicitly for every command in this runbook.
alias kc='kubectl --context admin@home-kubernetes'

kc get pv -o json  > /tmp/pvs.json
kc get pods -A -o json > /tmp/pods.json

python3 - <<'PY'
import json, collections
pvs  = json.load(open('/tmp/pvs.json'))
pods = json.load(open('/tmp/pods.json'))

# (namespace, pvc) -> transport, for every PV that lands on vault
vault = {}
for i in pvs['items']:
    s = i['spec']; cr = s.get('claimRef', {})
    ns, cn = cr.get('namespace'), cr.get('name')
    if not ns:
        continue
    if 'nfs' in s and 'vault' in str(s['nfs'].get('server', '')):
        vault[(ns, cn)] = 'NFS (in-tree PV)'
    elif 'csi' in s and s['csi']['driver'] == 'tns.csi.io':
        vault[(ns, cn)] = {'tns-csi-nfs':    'NFS (tns-csi)',
                           'tns-csi-iscsi':  'iSCSI  ** BLOCK **',
                           'tns-csi-nvmeof': 'NVMe-oF ** BLOCK **',
                          }.get(s.get('storageClassName'), s.get('storageClassName'))
    elif 'csi' in s and s['csi']['driver'] == 'nfs.csi.k8s.io':
        vault[(ns, cn)] = 'NFS (csi-driver-nfs)'

owners = collections.defaultdict(lambda: collections.defaultdict(set))
inline = collections.defaultdict(set)
mounted = set()
for p in pods['items']:
    ns = p['metadata']['namespace']
    refs = p['metadata'].get('ownerReferences', [])
    owner = f"{refs[0]['kind']}/{refs[0]['name']}" if refs else 'Pod/' + p['metadata']['name']
    if owner.startswith('ReplicaSet/'):                       # collapse to Deployment
        owner = 'Deployment/' + owner.split('/')[1].rsplit('-', 1)[0]
    for v in p['spec'].get('volumes', []):
        if 'persistentVolumeClaim' in v:
            c = v['persistentVolumeClaim']['claimName']
            mounted.add((ns, c))
            if (ns, c) in vault:
                owners[ns][owner].add(vault[(ns, c)])
        if 'nfs' in v:                    # inline pod-spec NFS volume, has no PV
            inline[ns].add((owner, v['nfs'].get('server', '')))

print('=== RUNNING WORKLOADS ON VAULT-BACKED VOLUMES ===')
for ns in sorted(owners):
    print(f'\n[{ns}]')
    for o in sorted(owners[ns]):
        print('  %-46s %s' % (o, ', '.join(sorted(owners[ns][o]))))

print('\n=== INLINE pod-spec NFS volumes (no PV — easy to miss) ===')
if not inline:
    print('  (none)')
for ns in sorted(inline):
    for o, srv in sorted(inline[ns]):
        print(f'  {ns:<12} {o:<46} {srv}')

print('\n=== VAULT PVCs NOT mounted by any running pod (already idle) ===')
for k in sorted(vault):
    if k not in mounted:
        print(f'  {k[0]:<12} {k[1]:<42} {vault[k]}')
PY
```

Also re-check the S3/Garage consumers, which the script above does **not** see:

```bash
kc get replicationsources -A                     # every *-local writes to vault
kc get cronjobs -A
kc get scheduledbackup -A
kc -n database get objectstore -o custom-columns=NAME:.metadata.name,EP:.spec.configuration.endpointURL
kc -n observability get secret thanos-objstore-config \
   -o jsonpath='{.data.config}' | base64 -d | grep endpoint
```

---

## 3. Inventory as of 2026-09-03

### Tier 1 — block storage: **MUST** scale down

Losing the target under a mounted XFS filesystem causes I/O errors and a
read-only remount; writes in flight are lost and the filesystem may need repair.
These are non-negotiable.

| Namespace | Workload | Transport | Replicas |
| --- | --- | --- | --- |
| `games` | `Deployment/valheim` | NVMe-oF | 1 |
| `games` | `StatefulSet/satisfactory` | NVMe-oF | 1 |
| `games` | `Deployment/volsync-valheim-syncthing` | NVMe-oF | 1 |
| `home` | `Deployment/esphome` | NVMe-oF (+ NFS) | 1 |

> No workload currently uses `tns-csi-iscsi`, though the StorageClass is enabled.
> If an iSCSI PVC appears later it belongs in this tier.

### Tier 2 — NFS: should scale down

`hard` mounts block rather than error, so this tier is *data-safe* if left
running. Scale it down anyway: hung mounts produce failing health probes,
crash-loops, half-written imports in the `*arr`/download stack, and a noisy
alert storm that masks real problems during the window.

| Namespace | Workload | Transport | Replicas |
| --- | --- | --- | --- |
| `develop` | `Deployment/gitea` | NFS (tns-csi) | 1 |
| `download` | `Deployment/cross-seed` | NFS (in-tree PV) | 1 |
| `download` | `Deployment/qbittorrent` | NFS (in-tree PV) | 1 |
| `download` | `Deployment/sabnzbd` | NFS (in-tree PV) | 1 |
| `download` | `Deployment/unpackerr` | NFS (in-tree PV) | 1 |
| `media` | `Deployment/audiobookshelf` | NFS (in-tree PV) | 1 |
| `media` | `Deployment/bazarr` | NFS (in-tree PV) | 1 |
| `media` | `Deployment/calibre` | NFS (in-tree PV) | 1 |
| `media` | `Deployment/calibre-web` | NFS (in-tree PV) | 1 |
| `media` | `Deployment/immich` | NFS (in-tree PV) | 1 |
| `media` | `Deployment/immich-microservices` | NFS (in-tree PV) | 1 |
| `media` | `Deployment/jellyfin` | NFS (in-tree PV + tns-csi) | 1 |
| `media` | `Deployment/lidarr` | NFS (in-tree PV) | 1 |
| `media` | `Deployment/plex` | NFS (in-tree PV) | 1 |
| `media` | `Deployment/radarr` | NFS (in-tree PV) | 1 |
| `media` | `Deployment/readarr-audiobooks` | NFS (in-tree PV + tns-csi) | 1 |
| `media` | `Deployment/readarr-ebooks` | NFS (in-tree PV + tns-csi) | 1 |
| `media` | `Deployment/sonarr` | NFS (in-tree PV) | 1 |
| `media` | `Deployment/sportarr` | NFS (in-tree PV) | 1 |
| `media` | `Deployment/tdarr` | NFS (in-tree PV + tns-csi) | 1 |
| `productivity` | `Deployment/nextcloud` | NFS (in-tree PV) | 1 |

**Already idle — no action needed** (verify, don't assume):
`home/frigate` is at 0 replicas and has been since it was left unconfigured; its
`frigate`, `frigate-nfs` and `volsync-frigate-dst-local-dest` PVCs are unmounted.
`kube-system/csi-nfs-test-pvc` is an unbound test claim.

### Tier 3 — S3/Garage: suspend, do **not** scale

These do not hold a vault mount, so they survive the outage — they simply fail
whatever they attempt mid-window. Suspend them so the window stays quiet and no
backup is recorded as failed.

| What | Object | Cadence |
| --- | --- | --- |
| **All VolSync local backups** | every `*-local` ReplicationSource, **all namespaces** (~45) | hourly / 2h / 4h |
| Kopia repo maintenance | `volsync-system/kopia-maint-kopia-maintenance-local-*` | `0 */4 * * *` |
| Talos etcd snapshots → `s3://talos` | `kube-system/talos-s3-backup` | `10 0/6 * * *` |
| Postgres base backup → `s3://cnpg` | `database/postgres18` ScheduledBackup | `@daily` |
| Media jobs that walk the NFS library | `media/kometa`, `media/recyclarr`, `media/plex-image-cleanup` | daily / quarterly |

**Leave running:** the `*-r2` ReplicationSources and `kopia-maint-…-r2` target
Cloudflare R2, and `openbao/openbao-snapshot` targets R2 as well. All are
independent of vault. Thanos will error on object-store reads for the duration
and recover on its own — the Prometheus sidecar buffers locally, and with only
2d of local retention a short window loses nothing.

---

## 4. Procedure

### 4.1 Pre-flight

```bash
cd ~/Repositories/flux-talos && export KUBECONFIG=./kubeconfig
alias kc='kubectl --context admin@home-kubernetes'

# Re-run §2 and diff against §3. Update this file if anything moved.

# Snapshot current replica counts so restore is exact, not assumed.
kc get deploy,statefulset -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.kind}{" "}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' \
  > /tmp/vault-maint-replicas.txt
```

### 4.2 Suspend Flux — at the HelmRelease layer

**Suspending the parent `cluster-apps` Kustomization is NOT sufficient.** Two
independent reasons, both verified live 2026-09-03:

1. Child Kustomizations (`media/plex`, `games/valheim`, …) are standalone objects
   with their own 30m/1h intervals. Suspending the parent only stops it
   re-applying the *child definitions*; the children keep reconciling.
2. Even suspending every child would not cover it. Each HelmRelease uses
   `chartRef → OCIRepository`, polled every **15m**. A new chart revision makes
   helm-controller run an upgrade **with no Kustomization involved at all**.

**The HelmRelease is the layer that owns replicas, so that is the layer to
suspend.** Useful corollary: `driftDetection` is `disabled` on every HelmRelease
here except `database/cloudnative-pg`, which means routine reconciliation does
*not* revert a `kubectl scale`. Only an actual helm upgrade does. That makes a
scale-down stickier than it first appears — but a Renovate chart bump landing
mid-window is a real risk, which is exactly what suspending the HR removes.

```bash
printf '%s\n' \
 "develop gitea" \
 "download cross-seed" "download qbittorrent" "download sabnzbd" "download unpackerr" \
 "games valheim" "games satisfactory" \
 "home esphome" \
 "media audiobookshelf" "media bazarr" "media calibre" "media calibre-web" "media immich" \
 "media jellyfin" "media lidarr" "media plex" "media radarr" "media readarr-audiobooks" \
 "media readarr-ebooks" "media sonarr" "media sportarr" "media tdarr" \
 "productivity nextcloud" \
| while read -r ns name; do
    kc -n "$ns" patch hr "$name" --type=merge -p '{"spec":{"suspend":true}}'
  done

# Belt-and-braces: stops any git-driven change reaching anything. One command,
# but on its own it protects nothing — see above.
kc -n flux-system patch kustomization cluster-apps --type=merge -p '{"spec":{"suspend":true}}'
```

> zsh note: `kubectl` is aliased in this shell, so `k(){ kubectl …; }` fails with
> *"defining function based on alias"*. Use `alias kc='kubectl --context admin@home-kubernetes'`.
> zsh also does not word-split unquoted variables, so `set -- $pair` loops
> silently collapse to a single argument — use `while read -r` as above.

### 4.3 Suspend the scheduled work (Tier 3)

```bash
# Pause every LOCAL VolSync source plus the syncthing mover; leave *-r2 alone.
kc get replicationsources -A --no-headers -o custom-columns=NS:.metadata.namespace,N:.metadata.name \
  | awk '$2 ~ /-local$/ || $2 == "valheim-syncthing" {print $1, $2}' \
  | while read -r ns name; do
      kc -n "$ns" patch replicationsource "$name" --type=merge -p '{"spec":{"paused":true}}'
    done

for cj in volsync-system/kopia-maint-kopia-maintenance-local-e48224913bbde0dd \
          kube-system/talos-s3-backup \
          media/kometa media/recyclarr media/plex-image-cleanup; do
  kc -n "${cj%/*}" patch cronjob "${cj#*/}" -p '{"spec":{"suspend":true}}'
done

kc -n database patch scheduledbackup postgres18 --type=merge -p '{"spec":{"suspend":true}}'
```

Expect ~44 ReplicationSources paused (43 `*-local` + `valheim-syncthing`).

### 4.4 Scale down — Tier 2 first, then Tier 1

Quiesce the NFS readers/writers first so nothing is mid-import when the block
devices go, then drop the block-backed workloads.

```bash
# Tier 2 — NFS
kc -n develop      scale deploy gitea --replicas=0
kc -n download     scale deploy cross-seed qbittorrent sabnzbd unpackerr --replicas=0
kc -n media        scale deploy audiobookshelf bazarr calibre calibre-web immich \
                                immich-microservices jellyfin lidarr plex radarr \
                                readarr-audiobooks readarr-ebooks sonarr sportarr tdarr --replicas=0
kc -n productivity scale deploy nextcloud --replicas=0

# Tier 1 — block
kc -n games scale deploy valheim --replicas=0
kc -n games scale statefulset satisfactory --replicas=0
kc -n home  scale deploy esphome --replicas=0
```

#### 4.4a `volsync-valheim-syncthing` needs the VolSync controller stopped

This one does **not** respond to the steps above and is easy to declare done
prematurely. The syncthing mover is a *continuous* mover, so `spec.paused: true`
does not stop it — VolSync's controller recreates the Deployment within seconds
of any scale-to-0. It mounts **two** NVMe-oF PVCs (`valheim` and
`volsync-valheim-syncthing-config`), so leaving it up keeps block sessions open
and defeats the whole window.

> 🔴 **Do NOT "just delete the ReplicationSource".** The obvious fix is wrong and
> destructive: `games/volsync-valheim-syncthing-config` is owned by the RS with
> `blockOwnerDeletion: true`, so deleting the RS garbage-collects the syncthing
> **config PVC** — losing the syncthing device identity and peer config.
> Verified 2026-09-03: `kc -n games get pvc volsync-valheim-syncthing-config -o jsonpath='{.metadata.ownerReferences}'`

Stop the controller instead — reversible, and harmless because every other
VolSync source is already paused:

```bash
kc -n volsync-system patch hr volsync --type=merge -p '{"spec":{"suspend":true}}'
kc -n volsync-system scale deploy volsync-volsync-perfectra1n --replicas=0
sleep 8
kc -n games scale deploy volsync-valheim-syncthing --replicas=0
```

### 4.5 Verify quiesced — do not skip

`kubectl scale` returning success only means the API accepted it. **Re-run the §2
discovery script; the "RUNNING WORKLOADS" section must be completely empty.**
That is the single authoritative check — it catches exactly the syncthing-mover
class of miss, which a per-app spot-check does not.

```bash
kc get pv -o json > /tmp/pvs.json
kc get pods -A -o json > /tmp/pods.json
# ...then the §2 python block. Expect an empty "RUNNING WORKLOADS" section.
```

Pods with no vault volume may legitimately still be running and are fine to
leave — e.g. `network/ts-satisfactory-*`, a Tailscale proxy whose only volumes
are a config Secret and the SA token.

Only once that section is empty, do the TrueNAS update and reboot.

### 4.6 Bring back up

Reverse order: restore the controllers and block workloads, then unsuspend Flux
and let it restore the rest.

```bash
# Wait for vault to actually serve, not just answer ping.
until curl -sf -m3 -o /dev/null -w '%{http_code}' http://10.0.10.10:30188/ | grep -q 403; do
  echo "waiting for Garage on vault..."; sleep 10
done

# VolSync controller first (it owns the syncthing mover)
kc -n volsync-system scale deploy volsync-volsync-perfectra1n --replicas=1
kc -n volsync-system patch hr volsync --type=merge -p '{"spec":{"suspend":false}}'

# Tier 1 — block
kc -n games scale deploy valheim --replicas=1
kc -n games scale statefulset satisfactory --replicas=1
kc -n home  scale deploy esphome --replicas=1

# Resume the scheduled work
kc get replicationsources -A --no-headers -o custom-columns=NS:.metadata.namespace,N:.metadata.name \
  | awk '$2 ~ /-local$/ || $2 == "valheim-syncthing" {print $1, $2}' \
  | while read -r ns name; do
      kc -n "$ns" patch replicationsource "$name" --type=merge -p '{"spec":{"paused":false}}'
    done
for cj in volsync-system/kopia-maint-kopia-maintenance-local-e48224913bbde0dd \
          kube-system/talos-s3-backup \
          media/kometa media/recyclarr media/plex-image-cleanup; do
  kc -n "${cj%/*}" patch cronjob "${cj#*/}" -p '{"spec":{"suspend":false}}'
done
kc -n database patch scheduledbackup postgres18 --type=merge -p '{"spec":{"suspend":false}}'

# Resume Flux.
kc -n flux-system patch kustomization cluster-apps --type=merge -p '{"spec":{"suspend":false}}'
printf '%s\n' \
 "develop gitea" \
 "download cross-seed" "download qbittorrent" "download sabnzbd" "download unpackerr" \
 "games valheim" "games satisfactory" \
 "home esphome" \
 "media audiobookshelf" "media bazarr" "media calibre" "media calibre-web" "media immich" \
 "media jellyfin" "media lidarr" "media plex" "media radarr" "media readarr-audiobooks" \
 "media readarr-ebooks" "media sonarr" "media sportarr" "media tdarr" \
 "productivity nextcloud" \
| while read -r ns name; do
    kc -n "$ns" patch hr "$name" --type=merge -p '{"spec":{"suspend":false}}'
  done
```

#### 4.6a Tier 2 must be scaled back up BY HAND

🔴 **Unsuspending the HelmRelease does NOT bring Tier 2 back.** Verified the hard
way 2026-09-03: after resuming all 23 HRs and `cluster-apps`, every one of the 21
NFS Deployments was still at `replicas: 0`.

This is the mirror image of the §4.2 finding, and it follows from the same fact.
`driftDetection` is disabled, so helm-controller only re-applies manifests when
the *release* changes. Resuming a suspended HR whose chart and values are
identical is a no-op — helm sees nothing to do and never rewrites the Deployment.
The property that protected the scale-down also prevents the scale-up.

```bash
kc -n develop      scale deploy gitea --replicas=1
kc -n download     scale deploy cross-seed qbittorrent sabnzbd unpackerr --replicas=1
kc -n media        scale deploy audiobookshelf bazarr calibre calibre-web immich \
                                immich-microservices jellyfin lidarr plex radarr \
                                readarr-audiobooks readarr-ebooks sonarr sportarr tdarr --replicas=1
kc -n productivity scale deploy nextcloud --replicas=1
```

Use the pre-flight snapshot for the counts rather than assuming everything was 1 —
that is what it is for.

Cross-check against the pre-flight snapshot rather than assuming:

```bash
diff <(sort /tmp/vault-maint-replicas.txt) \
     <(kc get deploy,statefulset -A \
         -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.kind}{" "}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' | sort)
```

### 4.7 Post-check

```bash
kc get pods -A | grep -Ev 'Running|Completed'      # expect nothing lingering
kc get hr -A | grep -i suspend                      # expect none still suspended
kc get replicationsources -A                        # lastSyncTime should advance within the hour
kc -n database get scheduledbackup postgres18
flux --context admin@home-kubernetes get kustomizations -A --status-selector ready=false
```

Watch for stuck VolSync movers on the first post-restart cycle — see
[`volsync-mover-stuck.md`](volsync-mover-stuck.md). Recovery there needs a
**pause**, not just deleting the PVC and job.

---

## 5. Gotchas

- **`10.0.10.11` is vault too.** Second IP on `br1`. `truenas-exporter`,
  `storj-exporter`, the Garage admin-API scrape target, `openspeedtest`, and the
  VolSync Kopia endpoint all reference it. None of them are a separate host.
- **The default kubectl context fails DNS off-Tailscale.** Use
  `--context admin@home-kubernetes` everywhere, or the commands here silently
  target nothing.
- **Suspend HelmReleases, not just Kustomizations.** `cluster-apps` alone
  protects nothing; child Kustomizations run independently, and an OCIRepository
  chart bump reaches helm-controller without touching a Kustomization at all.
- **`kubectl scale` success ≠ quiesced.** Re-run the §2 script and require an
  empty "RUNNING WORKLOADS" section. A terminating pod still holds its NVMe-oF
  session, and the syncthing mover actively fights being scaled down.
- **Never delete a VolSync syncthing ReplicationSource to stop its mover** — it
  owns its config PVC via `blockOwnerDeletion` and takes it with it (§4.4a).
- **Scaling `develop/gitea` to 0 takes down the first-party container registry.**
  `gitea.derekjacobs.dev` serves every first-party image, so any pod that needs to
  *pull* one mid-window gets `503 Service Unavailable` → `ImagePullBackOff`. Hit
  `home/minnkota-collector` on 2026-09-03. It self-heals once Gitea is back (the
  next CronJob run pulls fine), but per [[flux-image-automation]] an
  ImagePullBackOff does **not** trip job-failure alerts — so it fails silently.
  Nodes with the image already cached are unaffected, which is why it looks
  intermittent. If a clean window matters, suspend the first-party collector
  CronJobs too, or simply expect a few failed runs.
- **Tier 2 is safe to leave running but noisy.** If the window must be short,
  Tier 1 + Tier 3 are the mandatory parts; NFS `hard` mounts will recover.
- **`tns-csi-nvmeof` is in production use.** Earlier notes described NVMe-oF as
  "scaffolded but unused" — that is stale as of 2026-09-03: `games` (3 workloads)
  and `home/esphome` are on it.
- **This list rots.** Anything added under `kubernetes/apps/` with a vault-backed
  PVC belongs here. Re-run §2 every window.

---

## 6. Version policy (TrueNAS)

**Stay on the stable train.** As of 2026-09-03 vault runs **25.10.7** (Goldeye),
upgraded from 25.10.2.1 during this window. That jump already picked up the two
fixes that matter most to this cluster:

- **NFS server kernel panic** — an NFSv4.1 client whose connection dropped twice
  in quick succession could deliver the same request twice; both threads read the
  session reply cache while one mutated it → NULL deref → **host crash**. This
  cluster runs ~21 NFSv4.2 workloads at `nconnect=8` across 7 nodes, which is a
  lot of connections available to drop. Squarely in our load shape.
- **iSCSI target unregistration crash.**

**Do not take the 26.0.0-BETA train** (the update prompt shows it as a beta;
26 is the next major after 25.10 — there is no "20.0"). Reasons specific to us:

- **OpenZFS 2.4 + kernel 6.18**, off the 6.12 LTS line. New pool feature flags
  (`physical_rewrite`, `dynamic_gang_header`, `block_cloning_endian`). Enabling
  them is a **one-way door** — no rollback — on the box holding all cluster
  storage *plus* the Postgres DR and Thanos history.
- **`auth.login_with_api_key` is deprecated** in favour of `auth.login_ex`. Both
  `tns-csi` and `truenas-exporter` authenticate by API key over
  `wss://…/api/current`. If that path regresses, CSI provisioning and every
  VolSync backup fail together.
- IX's own guidance: *"Do not use early-release software for critical tasks."*

The only genuinely relevant 26 item is **NAS-140266**, *"middleware now reliably
updates `nvmet` when target settings change"* — plausible for us since tns-csi
creates and destroys an NVMe-oF subsystem per volume, but it is a
config-propagation fix and nothing indicates it is currently biting.

Do **not** expect 26's SMART work (~50% fewer false positives, `smartctl` parse
fixes) to close the `tardis` telemetry gap — those drives report no SMART through
that path at all, and a parsing fix cannot invent data. See
[[project_nas_drive_health]].

### ⚠️ Blocker to clear before ever moving to 26: the REST API is REMOVED

TrueNAS alerts that the deprecated REST API was used to authenticate from
**10.0.10.39 = `brokkr02`**. Historically this was `democratic-csi`, which is why
it drove the move to `tns-csi` — but democratic-csi was removed 2026-06-24, so
something else is still on REST.

Repo audit (2026-09-03) found exactly one REST-era consumer left:
`kubernetes/apps/home/homepage/app/configmap.yaml` declares a
`widget: type: truenas` with an API key, and Homepage's TrueNAS widget speaks
REST `/api/v2.0`, not the WebSocket API. Homepage runs on `brokkr02`, which
matches the alert's source IP. `truenas-exporter` also runs on `brokkr02` but is
configured `wss://vault.funb.us/api/current`, and `tns-csi` likewise — both are
already on WebSocket.

Homepage is therefore the strong candidate, though this is inferred from config
plus the node match; it was not confirmed from Homepage's own logs (the widget
does not log its calls). Confirm before 26 — capture on the NAS side, e.g.
`sudo tcpdump -i br1 host 10.0.10.39 and port 443`, or watch the alert after
temporarily removing the widget.

---

## 7. Change log

- **2026-09-03** — Written, then exercised live. Corrections folded in from the
  real run: suspend at the HelmRelease layer (§4.2), Tier 2 needing a manual
  scale-up on restore (§4.6a), the syncthing-mover /
  VolSync-controller problem and its destructive non-fix (§4.4a), and the
  discovery script promoted to the authoritative quiesce check (§4.5).
