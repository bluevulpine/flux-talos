# Scrypted → UniFi Protect → Apple Home (HKSV) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Scrypted in-cluster under Flux, bridging UniFi Protect cameras to
Apple Home with HomeKit Secure Video so Protect's smart-detection events produce
rich notifications on Apple devices.

**Architecture:** A bjw-s `app-template` HelmRelease deploys a single-replica
Scrypted Deployment, pinned to the amd64 `brokkr` workers and attached to VLAN 30
(the HomeKit L2) via a Multus macvlan interface with a static IP and pinned MAC.
Config lives on a `longhorn-1-replica-local` PVC provisioned and backed up by the
shared VolSync component (hourly local + daily R2 Kopia snapshots). Protect and
HomeKit plugins are configured once in the Scrypted UI; their state persists on the
backed-up PVC.

**Tech Stack:** Talos Kubernetes, Flux (Kustomization + OCIRepository +
HelmRelease), bjw-s app-template chart 5.0.1, Multus/macvlan CNI, Cilium, Longhorn,
VolSync + Kopia, Scrypted (`ghcr.io/koush/scrypted`).

## Global Constraints

Copied verbatim from repo conventions (`CLAUDE.md`) and the design spec — every
task inherits these:

- Every Kubernetes manifest starts with a `# yaml-language-server: $schema=...`
  header.
- All `.yaml` files except `*.sops.yaml` must pass `yamlfmt`: block-style arrays,
  `---` document start, LF line endings. Enforced by Lefthook pre-commit — never
  skip hooks.
- Do **not** add `crds: CreateReplace` to the HelmRelease; it is injected globally
  by the `cluster-apps` Flux patch.
- Image tags Renovate should track get a `# renovate: datasource=docker
  depName=...` annotation (see existing entries for the pattern).
- Secrets never committed to git (gitleaks runs on every pre-commit). This app
  defines **no Secret/ExternalSecret and no OpenBao key at all**: Scrypted's plugin
  credentials (the UniFi Protect account and the HomeKit pairing identity) are
  entered in the UI and stored in Scrypted's DB on the VolSync-backed PVC, so
  backups already cover them (see Task 1 rationale).
- `talos/clusterconfig/` is generated — never edited here (not touched by this plan).
- **Pushing to `main` auto-reconciles** via the Flux GitHub webhook. Do not run
  `flux reconcile` after a push; wait and verify. Manual apply for pre-merge
  testing uses `just kube apply-ks`.
- Fixed network identity for the Scrypted pod: IP `192.168.30.12/24` on `vlan-30`,
  MAC `de:ad:be:ef:30:12`.

---

## File Structure

Files created/modified, all under `kubernetes/apps/home/scrypted/` unless noted:

- `ks.yaml` — Flux Kustomization: path, `dependsOn: multus-networks`, and the
  `postBuild.substitute` block (APP/NS + all `VOLSYNC_*` vars).
- `app/kustomization.yaml` — Kustomize: lists `ocirepository.yaml` +
  `helmrelease.yaml`, and pulls in the shared `../../../../components/volsync`
  component (which supplies the `${APP}` PVC and both ReplicationSources).
- `app/ocirepository.yaml` — points at the bjw-s `app-template` chart 5.0.1.
- `app/helmrelease.yaml` — the whole workload: controller, Multus pod annotation,
  brokkr nodeAffinity, container image, securityContext, probes, resources,
  Service, HTTPRoute, and `persistence.config` bound to the VolSync `${APP}` PVC.
- `kubernetes/apps/home/kustomization.yaml` — **modify**: register
  `./scrypted/ks.yaml`.

No `externalsecret.yaml` (Scrypted plugin creds are entered in-app; see Task 1).

---

### Task 1: Prerequisites (manual, out-of-repo)

These are one-time environmental steps that the manifests depend on. No git
changes. Do these first; the deploy is inert without them.

**Rationale — why no ExternalSecret and no OpenBao key:** Scrypted stores plugin
configuration (including the UniFi Protect account and the HomeKit pairing
identity) in its own database under `/server/volume`. There is no supported path
to inject Protect credentials via environment variables, so an ExternalSecret
projecting them would be inert — and a standalone OpenBao key that nothing
references is just maintenance debt. The credentials are entered once in the
Scrypted UI (Task 4) and persist on the VolSync-backed PVC, so backups already
cover them for disaster recovery. This app creates no k8s Secret and no OpenBao
key.

- [ ] **Step 1: Create a dedicated local UniFi Protect user**

In UniFi Protect → Settings → Users, create a **local** account (not Ubiquiti
SSO) for Scrypted with at least live-view + smart-detection visibility on the
target cameras. Record the username/password (you'll enter these directly in the
Scrypted UI in Task 4 — nowhere else).

- [ ] **Step 2: Reserve the static IP in UniFi**

In the UniFi network controller, create a fixed-IP/DHCP reservation mapping MAC
`de:ad:be:ef:30:12` → `192.168.30.12` on VLAN 30, so the DHCP server never leases
`.12` to another device. (The IP is assigned statically by CNI; the reservation
only protects it from collision.)

- [ ] **Step 3: Verify the IP is still free**

Run (from a VLAN-30 host): `ping -c 3 -W 1000 192.168.30.12`
Expected: `100.0% packet loss` (no reply → address unused).

---

### Task 2: Author the Scrypted app manifests

**Files:**
- Create: `kubernetes/apps/home/scrypted/app/ocirepository.yaml`
- Create: `kubernetes/apps/home/scrypted/app/helmrelease.yaml`
- Create: `kubernetes/apps/home/scrypted/app/kustomization.yaml`
- Create: `kubernetes/apps/home/scrypted/ks.yaml`
- Modify: `kubernetes/apps/home/kustomization.yaml` (register the app)

**Interfaces:**
- Consumes: the shared VolSync component at
  `kubernetes/components/volsync/` — it creates a PVC named `${APP}` (here
  `scrypted`) and the local/R2 `ReplicationSource`s, all driven by the
  `postBuild.substitute` vars set in `ks.yaml`.
- Consumes: cluster-wide substitutions `${SECRET_DOMAIN}` and `${TIMEZONE}`.
- Consumes: the pre-existing `vlan-30` NetworkAttachmentDefinition in `kube-system`
  (`master: bond0.30`, static IPAM).
- Produces: the `scrypted` Deployment/Service/HTTPRoute and the `scrypted` PVC.

- [ ] **Step 1: Create the OCIRepository**

`kubernetes/apps/home/scrypted/app/ocirepository.yaml`:

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: scrypted
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 5.0.1
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

- [ ] **Step 2: Create the HelmRelease**

`kubernetes/apps/home/scrypted/app/helmrelease.yaml`:

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: &app scrypted
spec:
  chartRef:
    kind: OCIRepository
    name: scrypted
  interval: 1h
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
      strategy: rollback
  values:
    controllers:
      scrypted:
        type: deployment
        # Stateful pet: never roll two copies over the same pairing identity.
        strategy: Recreate
        annotations:
          reloader.stakater.com/auto: "true"
        pod:
          annotations:
            # Attach directly to the HomeKit L2 (VLAN 30) via Multus macvlan.
            # Static IP + PINNED MAC so the UniFi DHCP reservation for
            # de:ad:be:ef:30:12 -> 192.168.30.12 stays valid across pod
            # recreates (macvlan otherwise randomizes the MAC each start).
            # This is the interface Scrypted advertises HomeKit over via mDNS;
            # the NAD's sbr plugin keeps VLAN-30 return traffic symmetric.
            k8s.v1.cni.cncf.io/networks: |-
              [{
                "name": "vlan-30",
                "namespace": "kube-system",
                "ips": ["192.168.30.12/24"],
                "mac": "de:ad:be:ef:30:12"
              }]
        containers:
          app:
            image:
              repository: ghcr.io/koush/scrypted
              # renovate: datasource=docker depName=ghcr.io/koush/scrypted
              tag: v0.143.0
            env:
              TZ: "${TIMEZONE}"
            probes:
              liveness: &probes
                enabled: true
                custom: true
                spec:
                  httpGet:
                    scheme: HTTPS
                    path: /
                    port: &port 10443
                  initialDelaySeconds: 30
                  periodSeconds: 10
                  timeoutSeconds: 5
                  failureThreshold: 5
              readiness: *probes
            securityContext:
              # Scrypted's plugin runtime manages node/python installs as root;
              # it does not drop to an app user. No privileged/host access is
              # needed for Protect + HomeKit once we are on VLAN 30 via macvlan.
              privileged: false
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: false
              capabilities:
                drop: ["ALL"]
            resources:
              requests:
                cpu: 200m
                memory: 512Mi
              limits:
                memory: 2Gi
    defaultPodOptions:
      securityContext:
        runAsNonRoot: false
        runAsUser: 0
        runAsGroup: 0
      # Only the brokkr (amd64) workers carry bond0.30 for the VLAN-30 macvlan.
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
                      - brokkr01
                      - brokkr02
                      - brokkr03
    service:
      app:
        controller: scrypted
        ports:
          https:
            port: *port
    route:
      app:
        annotations:
          gatus.home-operations.com/endpoint: |
            group: home
          gethomepage.dev/enabled: "true"
          gethomepage.dev/name: "Scrypted"
          gethomepage.dev/group: "Home"
          gethomepage.dev/icon: "scrypted.png"
          gethomepage.dev/description: "Camera bridge (Protect -> HomeKit)"
        labels:
          auth: authentik
        parentRefs:
          - name: internal
            namespace: network
            sectionName: https
        hostnames:
          - scrypted.${SECRET_DOMAIN}
        rules:
          - backendRefs:
              - name: *app
                port: *port
    persistence:
      config:
        existingClaim: *app
        globalMounts:
          - path: /server/volume
```

- [ ] **Step 3: Create the app Kustomization (with VolSync component)**

`kubernetes/apps/home/scrypted/app/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./ocirepository.yaml
  - ./helmrelease.yaml
components:
  - ../../../../components/volsync
```

- [ ] **Step 4: Create the Flux Kustomization (ks.yaml)**

`kubernetes/apps/home/scrypted/ks.yaml`. The `VOLSYNC_*` block mirrors mosquitto
but retargets the local best-effort SC and matches the design's backup cadence:

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app scrypted
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn:
    - name: multus-networks
      namespace: kube-system
  interval: 1h
  path: ./kubernetes/apps/home/scrypted/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: home-kubernetes
    namespace: flux-system
  targetNamespace: home
  wait: false
  postBuild:
    substitute:
      APP: *app
      NS: home
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

- [ ] **Step 5: Register the app in the home namespace Kustomization**

Modify `kubernetes/apps/home/kustomization.yaml` — add `./scrypted/ks.yaml` to the
`resources` list (keep it grouped with the other apps):

```yaml
resources:
  - ./namespace.yaml
  - ./esphome/ks.yaml
  - ./frigate/ks.yaml
  - ./helium-archiver/ks.yaml
  - ./homepage/ks.yaml
  - ./mosquitto/ks.yaml
  - ./scrypted/ks.yaml
  - ./kia-collector/ks.yaml
```

- [ ] **Step 6: Format and lint**

Run: `lefthook run pre-commit`
Expected: yamlfmt + gitleaks pass with no diff on the new files. If yamlfmt
rewrites anything, re-stage and re-run until clean.

- [ ] **Step 7: Validate the manifests render against the cluster**

Run: `flux-local test --path kubernetes/apps/home/scrypted --enable-helm`
Expected: the `scrypted` Kustomization builds; the HelmRelease renders; the
VolSync component expands to a `scrypted` PVC (storageClass
`longhorn-1-replica-local`) plus `scrypted-local` / `scrypted-r2`
ReplicationSources. No substitution errors for `VOLSYNC_*`, `SECRET_DOMAIN`,
`TIMEZONE`.

(If `flux-local` is not available locally, fall back to:
`kubectl kustomize kubernetes/apps/home/scrypted/app` and confirm the PVC +
ReplicationSources render; then `kubectl apply --dry-run=server -k
kubernetes/apps/home/scrypted/app`.)

- [ ] **Step 8: Commit** (only when the user asks — see Global Constraints)

```bash
git add kubernetes/apps/home/scrypted kubernetes/apps/home/kustomization.yaml \
        docs/superpowers/specs/2026-07-10-scrypted-unifi-protect-homekit-design.md \
        docs/superpowers/plans/2026-07-10-scrypted-unifi-protect-homekit.md
git commit -m "feat(scrypted): bridge UniFi Protect to Apple Home via HKSV"
```

---

### Task 3: Deploy and verify the infrastructure

Bring the app up (pre-merge apply, or push to main and let the webhook reconcile)
and prove the pod, network identity, storage, and UI are correct — before touching
Scrypted's own configuration.

**Interfaces:**
- Consumes: everything authored in Task 2.
- Produces: a running `scrypted` pod on a brokkr node with `net1` =
  `192.168.30.12` (MAC `de:ad:be:ef:30:12`) and a bound `scrypted` PVC.

- [ ] **Step 1: Apply the kustomization (pre-merge test)**

Run: `just kube apply-ks kubernetes/apps/home/scrypted`
Expected: the `scrypted` Kustomization reconciles; HelmRelease `scrypted` reaches
`Ready`. (Alternatively, once merged, push to `main` and wait for the webhook —
do not `flux reconcile`.)

- [ ] **Step 2: Verify the pod is Running on a brokkr node**

Run: `kubectl -n home get pods -l app.kubernetes.io/name=scrypted -o wide`
Expected: `1/1 Running`, `NODE` is `brokkr01|02|03`.

- [ ] **Step 3: Verify the VLAN-30 macvlan interface, IP, and pinned MAC**

Run:
```bash
kubectl -n home get pods -l app.kubernetes.io/name=scrypted \
  -o jsonpath='{.items[0].metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'; echo
POD=$(kubectl -n home get pod -l app.kubernetes.io/name=scrypted -o name)
kubectl -n home exec "$POD" -- ip -4 addr show net1
kubectl -n home exec "$POD" -- ip link show net1
```
Expected: `network-status` lists the `vlan-30` interface; `net1` has
`inet 192.168.30.12/24`; `link/ether de:ad:be:ef:30:12`.

- [ ] **Step 4: Verify the PVC is bound on the local SC**

Run: `kubectl -n home get pvc scrypted`
Expected: `Bound`, `STORAGECLASS` = `longhorn-1-replica-local`, capacity `10Gi`.

- [ ] **Step 5: Verify the Scrypted UI is reachable on VLAN 30**

From a VLAN-30 host: open `https://192.168.30.12:10443` (self-signed cert — accept
it). Expected: the Scrypted setup/login page loads. Complete the initial admin
account creation prompt here (this admin login is separate from HomeKit).

- [ ] **Step 6: Confirm Scrypted advertises on VLAN 30 via mDNS (baseline)**

From a VLAN-30 host: `perl -e 'alarm 7; exec @ARGV' dns-sd -B _hap._tcp local.`
Expected: after the HomeKit plugin is installed (Task 4) a new `_hap._tcp`
accessory for Scrypted appears here. At this point (pre-plugin) it is enough to
confirm the browse still returns the existing accessories from VLAN 30 — proving
the host↔pod L2 path is intact. (Re-run this in Task 4 to see the Scrypted bridge.)

---

### Task 4: Configure Scrypted (Protect + HomeKit) and pair

Runtime configuration in the Scrypted UI. This is inherently manual and one-time;
all of it persists on the VolSync-backed PVC.

**Interfaces:**
- Consumes: the running UI from Task 3; the Protect creds from Task 1.
- Produces: a paired HomeKit bridge advertising Protect cameras with HKSV.

- [ ] **Step 1: Install and configure the UniFi Protect plugin**

In the Scrypted UI → Plugins → install **UniFi Protect**. Open it and enter the
UniFi Protect controller URL/IP and the **local** Protect account from Task 1
(values recorded in OpenBao). Confirm cameras enumerate and go online.

- [ ] **Step 2: Install the HomeKit plugin and select the mDNS interface**

Install the **HomeKit** plugin. In its settings, if multiple advertiser
interfaces are offered, ensure it advertises on the VLAN-30 interface
(`192.168.30.12` / `net1`). Leave the advertiser default (Ciao) unless pairing
fails.

- [ ] **Step 3: Confirm the Scrypted HomeKit bridge is now visible via mDNS**

From a VLAN-30 host: `perl -e 'alarm 7; exec @ARGV' dns-sd -B _hap._tcp local.`
Expected: a new Scrypted `_hap._tcp` accessory appears alongside the existing ones.

- [ ] **Step 4: Pair Scrypted in the Apple Home app**

In the Home app → Add Accessory → scan the HomeKit pairing QR/code shown in
Scrypted's HomeKit plugin. Expected: the Scrypted bridge and its cameras are added
to the home.

- [ ] **Step 5: Enable HomeKit Secure Video per camera**

For each camera in the Home app: Settings → enable "Stream & Allow Recording"
(HKSV). Confirm an **iCloud+** plan is active (HKSV requires it). In Scrypted's
per-camera HomeKit settings, ensure the Protect smart-detection object types
(person/vehicle/package) are enabled as HomeKit motion/occupancy triggers.

- [ ] **Step 6: End-to-end verification**

Trigger a real detection (walk past a camera). Expected: an Apple Home
notification with a thumbnail ("Person detected — <camera>") on Apple devices, and
an iCloud-recorded clip visible in the Home app for HKSV-enabled cameras.

---

### Task 5: Verify backup and restore

Prove the durability story the SC choice depends on: the pairing identity survives
loss of the single Longhorn replica because VolSync has it.

**Interfaces:**
- Consumes: the `scrypted-local` / `scrypted-r2` ReplicationSources created by the
  VolSync component; the populated `/server/volume` from Task 4.

- [ ] **Step 1: Confirm both ReplicationSources are healthy**

Run: `kubectl -n home get replicationsource -l app.kubernetes.io/name=scrypted`
(or `kubectl -n home get replicationsource | grep scrypted`)
Expected: `scrypted-local` and `scrypted-r2` present; after the first scheduled
run, `LAST SYNC` is populated and status is not erroring.

- [ ] **Step 2: Force a local snapshot and confirm it completes**

Run:
```bash
kubectl -n home patch replicationsource scrypted-local --type merge \
  -p '{"spec":{"trigger":{"manual":"verify-1"}}}'
kubectl -n home get replicationsource scrypted-local -w
```
Expected: `LAST MANUAL SYNC` reaches `verify-1`; a `scrypted-local` mover job runs
to completion (`kubectl -n home get jobs | grep scrypted`).

- [ ] **Step 3: Confirm the Longhorn volume honors the local, single-replica SC**

Run: `kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.numberOfReplicas,LOCALITY:.spec.dataLocality \
  | grep -i scrypted` (or inspect via the Longhorn UI)
Expected: the Scrypted volume shows `numberOfReplicas: 1` and
`dataLocality: best-effort`, with its replica co-located on the pod's brokkr node.

- [ ] **Step 4: (Optional, destructive) Restore rehearsal**

Only if you want full DR confidence: scale the deployment to 0, delete the
`scrypted` PVC, and let the VolSync `scrypted-dst-local` ReplicationDestination
reseed it from the latest snapshot (per the `volsync` component's restore path),
then scale back up. Expected: Scrypted returns **already paired** (no HomeKit
re-pair), proving the pairing identity restored from backup. Document the exact
restore command sequence from `kubernetes/components/volsync/` before running.

---

## Self-Review

**Spec coverage:**
- App layout / bjw-s app-template / OCIRepository → Task 2 Steps 1–5. ✓
- Deployment, 1 replica, `Recreate`, brokkr nodeAffinity → Task 2 Step 2. ✓
- Multus `vlan-30`, static IP `192.168.30.12`, pinned MAC → Task 2 Step 2; verified
  Task 3 Step 3. ✓
- Longhorn 1-replica-local PVC at `/server/volume` → Task 2 Steps 2/4; verified
  Task 3 Step 4. ✓
- VolSync backup (local hourly + R2 daily, Snapshot copy, longhorn-snapclass) →
  Task 2 Steps 3/4; verified Task 5. ✓
- Protect creds entered in-app, backed up via the PVC; no ExternalSecret, no
  OpenBao key → Task 1 rationale + Step 1. ✓ (Corrected from the spec's
  ExternalSecret assumption; flagged for the user.)
- Admin UI Service + internal Authentik HTTPRoute → Task 2 Step 2; UI reached
  directly Task 3 Step 5. ✓
- Lean on Protect smart detections; no Coral/GPU → no detection plugin; Task 4
  Step 5. ✓
- Manual pairing / HKSV / iCloud+ documented → Task 4 Steps 4–6. ✓
- Success criteria (pod/IP/UI, plugin enumerate, pair, detection→notification,
  survives reschedule, VolSync healthy + restore) → Tasks 3–5. ✓

**Placeholder scan:** No TBD/TODO. Every manifest step contains full file content;
every verification step has a concrete command + expected output. The one deferred
item (exact VolSync restore command sequence, Task 5 Step 4) is explicitly an
optional rehearsal and points at the component that defines it.

**Type/name consistency:** `&app scrypted` anchor, PVC `existingClaim: scrypted`,
`APP: scrypted` substitute, ReplicationSources `scrypted-local`/`scrypted-r2`,
port anchor `&port 10443` reused by probe + Service + route backend, MAC/IP
identical in the manifest (Task 2) and the verification (Task 3) — all aligned.

## Divergence from spec (flag for user)

The spec listed an `ExternalSecret` for Protect credentials. During planning it was
confirmed Scrypted has no env-based path to inject plugin credentials — they are
entered in the UI and stored on the PVC. The plan therefore defines **no
Secret/ExternalSecret resource and no OpenBao key** (both would be inert /
unreferenced), drops the now-unneeded `external-secrets-openbao-store` `dependsOn`,
and relies on the VolSync PVC backup to cover the credentials for DR. Everything
else matches the approved spec.

## Open items to confirm during execution

- Whether the current Scrypted image serves the UI/probe cleanly on HTTPS `10443`
  under the app-template probe (Task 2 Step 2 uses an HTTPS `httpGet` on 10443); if
  the self-signed cert or startup time trips the probe, extend
  `initialDelaySeconds` or switch the probe to a TCP socket check on 10443.
- Whether Renovate proposes Scrypted's variant-suffixed tags (e.g.
  `-18-bullseye-full`) instead of clean `vX.Y.Z`; if so, add `versioning=loose` or
  an `allowedVersions` regex to the annotation (coordinate with the
  `renovate-sweep` config).
- The HTTPRoute backend assumes Envoy speaks HTTP to Scrypted's HTTPS `10443`
  backend; if the gateway needs an explicit HTTPS/BackendTLS upstream, either add
  that policy or rely on the direct `https://192.168.30.12:10443` access (which is
  the guaranteed path from VLAN 30).
