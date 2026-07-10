# Scrypted → UniFi Protect → Apple Home (HomeKit Secure Video)

**Date:** 2026-07-10
**Status:** Design — approved, pending implementation plan
**Goal:** Get Apple Home (HomeKit) rich notifications for camera events from UniFi
Protect, by running Scrypted in-cluster under GitOps and bridging Protect cameras
to HomeKit Secure Video (HKSV).

## Motivation

UniFi Protect already runs the cameras and does its own AI smart-detection
(person / vehicle / package). What it does *not* do well is push those events to
Apple Home. Scrypted is the purpose-built bridge: its UniFi Protect plugin
consumes the cameras and their smart-detection events, and its HomeKit plugin
re-exposes each camera as a HomeKit camera **with HKSV**, so the Apple home hubs
(Apple TV / HomePod) record clips to iCloud and send rich, thumbnailed
notifications ("Person detected — Front Door").

We deliberately lean on Protect's existing AI rather than running Scrypted's own
object detection, so no Coral/GPU is needed for this workload.

## The controlling constraint: HomeKit is L2-local

HomeKit pairing and HKSV require the Scrypted server to sit on the **same L2
subnet** as the Apple home hubs and to advertise itself via mDNS/Bonjour there.
(Per Scrypted's own docs: host networking + same subnet + multicast reachable.)

### Network facts established during design

- All 7 Talos nodes are on a single subnet, VLAN 10 (`10.0.10.0/24`).
- The Apple ecosystem lives on **VLAN 30** (`192.168.30.0/24`). Confirmed by mDNS
  browse from a VLAN-30 host: AirPlay/companion-link hubs (Family Room, Living
  Room, Theater, Bedroom, Kitchen, HomePods) and existing `_hap._tcp` bridges
  (a Home Assistant "HASS Bridge", Lutron Smart Bridge 2, Ecobee, a HomePod
  sensor) are all visible on that L2.
- **Multus is installed cluster-wide** and a `vlan-30` NetworkAttachmentDefinition
  already exists (`master: bond0.30`, macvlan/bridge, static IPAM). `bond0.30` is
  present **only on the brokkr (amd64) workers**.
- The existing `esphome` app is a working precedent for the same pattern: it
  attaches to VLAN 50 via Multus macvlan with a static IP and is pinned to the
  brokkr workers.

Because a VLAN-30 macvlan interface is available, Scrypted can be a first-class L2
citizen on the HomeKit segment. This is strictly better than a `hostNetwork`
pod on VLAN 10 relying on the UniFi mDNS reflector: no reflector in the HKSV
path, and no re-advertisement churn when a pod reschedules.

## Approaches considered

- **A — Multus macvlan on VLAN 30, pinned to a brokkr worker. (CHOSEN)**
  Scrypted gets a real IP on the HomeKit L2, same segment as every hub. HKSV and
  pairing work natively. Mirrors the proven esphome-on-VLAN-50 pattern.
- **B — `hostNetwork` on VLAN 10 + mDNS reflector.** Works for basic pairing but
  HKSV is fussy across a reflector, and a rescheduled hostNetwork pod
  re-advertises from a new node IP → HomeKit flakiness. Rejected.
- **C — Scrypted off-cluster (HA host / dedicated box).** Simplest networking but
  abandons the GitOps goal. Rejected.

Also considered and rejected: routing Protect through the **existing HASS
Bridge**. Home Assistant's HomeKit camera / HKSV support is much weaker than
Scrypted's purpose-built implementation.

## Design

### Application layout

New app under `kubernetes/apps/home/scrypted/`, following the frigate/esphome
layout and repo conventions (`# yaml-language-server` schema headers,
bjw-s `app-template` HelmRelease via `OCIRepository`, standard remediation blocks:
retries 3, `cleanupOnFail`, rollback):

```
kubernetes/apps/home/scrypted/
  ks.yaml
  kustomization.yaml
  app/
    kustomization.yaml
    ocirepository.yaml
    helmrelease.yaml
    externalsecret.yaml
```

The app's `app/kustomization.yaml` includes the shared VolSync component
(`components: [ ../../../../components/volsync ]`); the `ks.yaml`
`postBuild.substitute` block supplies `APP`, `NS`, and the `VOLSYNC_*` vars (see
Storage + backup below). The namespace-level `kustomization.yaml` in
`kubernetes/apps/home/` gains the new app; `ks.yaml` should `dependsOn` the Multus
network Kustomization (`multus-networks`, as esphome does) and
`external-secrets-openbao-store`.

### Workload

- **Deployment**, single replica, strategy `Recreate` — Scrypted is a stateful
  "pet"; never run two, and don't rolling-update over itself.
- `nodeSelector` onto a **brokkr worker** (only these have `bond0.30`). Match the
  label esphome uses for the same purpose.
- Standard security context per repo norms; Scrypted needs a writable state
  volume (not read-only root). Keep it as tight as the image allows.

### Networking (the crux)

Pod annotation attaching the pre-existing `vlan-30` NAD with a **static IP and a
pinned MAC**:

```yaml
k8s.v1.cni.cncf.io/networks: |-
  [{
    "name": "vlan-30",
    "namespace": "kube-system",
    "ips": ["192.168.30.12/24"],
    "mac": "de:ad:be:ef:30:12"
  }]
```

- IP `192.168.30.12` verified free during design (no ping reply, incomplete ARP).
- **MAC is pinned** (unlike esphome). macvlan otherwise randomizes the MAC on
  every pod recreate, which would invalidate a DHCP reservation. `de:ad:be:ef:30:12`
  is a synthetic, locally-administered address (won't collide with any vendor
  OUI); the low octets are a mnemonic for VLAN30 / .12.
- The pod keeps its default cluster interface for egress to the Protect
  controller and for the admin UI Service; the VLAN-30 macvlan is the HomeKit
  advertisement interface. The NAD's `sbr` (source-based routing) plugin keeps
  VLAN-30 return traffic symmetric, same as esphome.

### Storage + backup

Scrypted's state directory (`/server/volume`) holds installed plugins, the
**HomeKit pairing identity**, and per-camera config. It is small (hundreds of MB)
but precious — losing it means re-pairing every camera in the Home app.

The PVC is provisioned and backed up by the shared VolSync Kustomize component,
exactly like `mosquitto` (same namespace) and `vaultwarden`/`qbittorrent`/etc.:

- App `kustomization.yaml` pulls in `components: [ ../../../../components/volsync ]`,
  which creates the `${APP}` PVC (restorable from its ReplicationDestination) plus
  a **local ReplicationSource** and an **R2 ReplicationSource**.
- **Backup cadence:** local Kopia snapshot on `VOLSYNC_LOCAL_SCHEDULE` (a low-churn
  config volume — hourly is plenty, e.g. `"45 * * * *"`), and a daily R2 (offsite)
  snapshot. Kopia retention is defined in the component (local: 48 latest / 96
  hourly / 30 daily…; R2: 7 daily / 4 weekly / 3 monthly).
- **Restore path:** the component's `${APP}-dst-local` ReplicationDestination lets
  a fresh PVC be seeded from the latest local snapshot on recreate; R2 restore is
  available via the `volsync-r2-restore` component for disaster recovery. This is
  what makes the pairing identity durable across a node loss.

**StorageClass decision — `longhorn-1-replica-local` (best-effort locality).**
The question raised: is a 1-replica, best-effort SC sensible here? Yes — and it's
the better fit for this workload:

- With VolSync (local every hour + daily R2) as the real durability guarantee,
  Longhorn's own 3× replication is redundant for a small, backed-up config volume.
  Running 1 replica is already the repo-wide norm for backed-up app config
  (mosquitto, vaultwarden, qbittorrent, influxdb, couchdb all use
  `longhorn-1-replica`).
- Because Scrypted is **pinned to one brokkr node**, `best-effort` data locality
  co-locates the single replica *on that same node* → local-disk latency and no
  cross-node replica I/O. There is no availability downside: if that node is down,
  the pinned pod can't run there anyway, so recovery is restore-from-VolSync onto
  another brokkr node in either case.
- Contrast with plain `longhorn-1-replica` (locality `disabled`): the lone replica
  may land on a *different* node, forcing every read across the network for no
  benefit to a node-pinned pet.

Trade-off to note: `longhorn-1-replica-local` is the newest SC in the cluster
(currently only `postgres18` uses it). The conservative, battle-tested fallback is
`longhorn-1-replica` (the mosquitto set). Recommendation stands with `-local`;
fall back if the newer SC shows any surprises.

Longhorn is block/RWO, so VolSync must use **Snapshot** copy (not the NFS default
`Direct`). The `ks.yaml` `postBuild.substitute` mirrors mosquitto, retargeted to
the local SC:

```yaml
VOLSYNC_CAPACITY: 10Gi
VOLSYNC_CACHE_CAPACITY: 10Gi
VOLSYNC_STORAGECLASS: longhorn-1-replica-local
VOLSYNC_CLONE_STORAGECLASS: longhorn-1-replica-local
VOLSYNC_CACHE_CLASS: longhorn-1-replica-local
VOLSYNC_SNAPSHOTCLASS: longhorn-snapclass
VOLSYNC_ACCESSMODES: ReadWriteOnce
VOLSYNC_COPYMETHOD: Snapshot
VOLSYNC_LOCAL_SCHEDULE: "45 * * * *"
```

The HelmRelease then mounts it via `persistence.config.existingClaim: scrypted`
(frigate-style), globalMount at `/server/volume`.

### Secrets

- **ExternalSecret** (`secretStoreRef` → `openbao` `ClusterSecretStore`,
  `engineVersion: v2`) exposing the UniFi Protect **local** account credentials
  to the Scrypted plugin. OpenBao key naming per repo convention (PascalCase
  double-underscore), e.g. `Scrypted__Protect__User` / `Scrypted__Protect__Password`.
- The Protect account must be a **local Protect user** (not Ubiquiti SSO), with
  at least live-view + smart-detect visibility on the target cameras.

### Admin UI

- Cluster `Service` for the Scrypted web UI, plus an internal `HTTPRoute` on the
  `internal` gateway (`network` namespace), hostname `scrypted.${SECRET_DOMAIN}`,
  behind Authentik (`labels: { auth: authentik }`) — same pattern as frigate's
  route. This lets us administer Scrypted without touching the VLAN-30 IP, and
  optionally surface a homepage tile.

### Data flow

```
UniFi Protect controller
    │  (unicast HTTPS/RTSP, routed via pod default cluster interface)
    ▼
Scrypted  ── UniFi Protect plugin: cameras + smart-detection events
    │
    │  Scrypted HomeKit plugin re-exposes each camera as a HomeKit
    │  camera WITH HKSV; advertises via mDNS on the VLAN-30 macvlan iface
    ▼
Apple home hubs (Apple TV / HomePod) on VLAN 30
    → record clips to iCloud, push rich notifications to devices
```

## GitOps boundary — what the manifests cannot do

These steps are inherently one-time and manual; they are documented, not
automated:

1. **UniFi DHCP reservation:** reserve `de:ad:be:ef:30:12 → 192.168.30.12` in
   UniFi so the DHCP server never leases `.12` to another device. (The IP is set
   statically by CNI; the reservation only protects it from collision.)
2. **Create the local UniFi Protect user** and store its credentials in OpenBao
   under the `scrypted` key.
3. **HomeKit pairing:** after first deploy, add the Scrypted bridge in the Apple
   Home app using the pairing code shown in Scrypted's HomeKit plugin.
4. **Enable HKSV per camera** in the Home app, and ensure an **iCloud+** plan is
   active (HKSV requires it). Cameras beyond the plan's HKSV limit still send
   notifications, just without iCloud recording.

## Success criteria

- Scrypted pod running on a brokkr worker, reachable at `192.168.30.12` on VLAN 30
  and at `scrypted.${SECRET_DOMAIN}` (behind Authentik).
- Scrypted's UniFi Protect plugin authenticated and enumerating cameras.
- Scrypted HomeKit bridge pairs successfully in the Apple Home app.
- Triggering a Protect person/vehicle/package detection produces a rich HomeKit
  notification on Apple devices, with an iCloud-recorded clip for HKSV-enabled
  cameras.
- Config survives a pod delete/reschedule (PVC + pinned MAC/IP hold; no re-pair).
- VolSync local + R2 ReplicationSources report healthy/`Synchronized`, and a test
  restore of the `${APP}` PVC from the latest snapshot reproduces the pairing
  identity (no re-pair after a simulated node-loss restore).

## Out of scope

- Scrypted's own object detection / NVR (we use Protect's AI and Protect's
  recordings).
- Migrating or touching the existing Home Assistant HASS Bridge.
- The `homeassistant.local` passwordless-SSH issue (unrelated to this work).

## Open items to resolve during implementation

- Confirm the exact `nodeSelector` label the brokkr workers carry for VLAN-30
  scheduling (reuse esphome's).
- Confirm the current Scrypted container image ref/tag and add the appropriate
  `# renovate:` annotation for version tracking.
- Confirm Scrypted's state path for the installed image (`/server/volume`) and any
  additional writable dirs (e.g. cache) needed.
- Decide which cameras to expose to HomeKit (runtime UI choice, not a manifest
  concern).
