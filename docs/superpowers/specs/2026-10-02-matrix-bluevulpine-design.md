# Second Matrix homeserver for bluevulpine.net

Date: 2026-10-02 · Status: design approved, not yet built

## Intent

Two Matrix identities with different jobs:

- **derekjacobs.dev** (existing, `kubernetes/apps/matrix/matrix-stack`) stays the
  agent / A2A space: chat with and between project agents, managed by Derek.
- **bluevulpine.net** (new) becomes Derek's external identity, `@bluevulpine:bluevulpine.net`,
  the one used for federation. It matches the blog.

A Synapse process serves exactly one `server_name`, permanently, and MAS is bound
to the same one. `.well-known` delegation only re-routes an existing name. So a
second identity domain needs a second Synapse + MAS deployment.

Success: Derek signs in at `chat.bluevulpine.net` as `@bluevulpine:bluevulpine.net`
through Authentik, `bluevulpine.net` passes federationtester, and nothing about
derekjacobs.dev regresses.

## Decisions

| Topic | Decision | Why |
| --- | --- | --- |
| Shape | Second `matrix-stack` release in its own namespace `matrix-bluevulpine` | Copies a proven layout one-for-one. Each identity keeps its own secrets and policy scope. A shared base with overlays is premature with two instances. |
| Accounts | Derek + select others; **no open registration**; Authentik is the only way in (`passwords.enabled: false`) | Same model as derekjacobs.dev. |
| Element Web | **One shared instance** (the existing release's) answers on both `chat.derekjacobs.dev` and `chat.bluevulpine.net`, defaulting each to its own homeserver | Element Web looks up `config.<hostname>.json` before `config.json`. |
| Storage | `longhorn-2-replica` for the media PVC; clone/cache classes stay `longhorn-1-replica` | Cheap to choose at creation, costly to change later (re-bind procedure). Matrix is not on the agreed 1→2 replica list; this is a fresh choice, not that migration. |
| Backups | **kopiur** (`components/kopiur`), not VolSync | Migration is well under way (21 apps kopiur-only, 10 running both in parallel, 16 still VolSync-only). A new app should not be born on the engine being migrated away from. |
| SSO host | Stays `sso.derekjacobs.dev` | `sso.bluevulpine.net` belongs to the Authentik hygiene project. |
| Matrix localpart | `bluevulpine` (from the Authentik username) | Permanent; Matrix IDs cannot be renamed. |

## 1. The bluevulpine.net homeserver

New tree `kubernetes/apps/matrix-bluevulpine/`, mirroring `kubernetes/apps/matrix/`:

```
matrix-bluevulpine/
  namespace.yaml            # labels copied from the matrix namespace, PLUS the
                            # kopiur + volsync privileged-movers annotations (see kopiur below)
  kustomization.yaml
  matrix-stack/
    ks.yaml                 # matrix-stack-db (wait: true) -> matrix-stack
    README.md
    db/                     # postgres-init Job + its ExternalSecret
    app/                    # HelmRelease, ExternalSecret, HTTPRoutes, DNSEndpoint,
                            # OCIRepository, media PVC
```

- **Chart:** same `OCIRepository` and tag as the existing release. Renovate sees the
  same depName/version in both files and bumps them in **one** PR by default.
- **Identity:** `serverName: ${SECRET_DOMAIN_BLOG}`. Synapse at
  `matrix.${SECRET_DOMAIN_BLOG}`, MAS at `account.${SECRET_DOMAIN_BLOG}`.
- **Postgres (deviation):** the existing Job hard-codes roles and databases `synapse`
  and `mas`, which would collide on the shared `postgres18`. The new instance uses
  **`synapse_bluevulpine`** and **`mas_bluevulpine`**. Every literal that must change
  when copying the existing tree:
  - db Job: `INIT_POSTGRES_USER` and `INIT_POSTGRES_DBNAME` (two each), the
    assertion's `datname = '…'`, its echo text, and the `DROP/CREATE DATABASE`
    recovery comment.
  - HelmRelease: `synapse.postgres.user/database` and
    `matrixAuthenticationService.postgres.user/database`.
  - **Both** ExternalSecrets (`db/` and `app/`): `dataFrom.extract.key: matrix` →
    `matrix-bluevulpine`. **Critical:** if the app one is missed, the new Synapse
    silently gets derekjacobs.dev's signing key and secrets.
- **Secrets:** OpenBao key `secret/matrix-bluevulpine`, with the same field names as
  `secret/matrix`. `scripts/matrix-generate-secrets.sh` gains an optional positional
  path argument, parsed as `[--dry-run] [path]` in either order. The default stays
  `secret/matrix`, so existing usage is unchanged. Today `$1` is only checked for
  `--dry-run`, so a naive `${1:-…}` would treat `--dry-run` as the path.
- **Media PVC (deviation):** `components/volsync-claim` always sets a `dataSourceRef`
  to a VolSync `ReplicationDestination`, which a kopiur-only app never creates.
  That would leave the PVC Pending, or populate it with nothing. The new app
  defines its own plain `synapse-media` PVC (20Gi, `ReadWriteOnce`,
  `longhorn-2-replica`, **no `dataSourceRef`**), plus `components/kopiur` for
  backups. A comment records why it doesn't use `volsync-claim`: that component
  exists to keep migrating PVCs byte-identical, and a new PVC has nothing to
  migrate. The kopiur `ks.yaml` copies `kubernetes/apps/download/qbittorrent/ks.yaml`'s
  shape (`dependsOn: kopiur-repositories`). The `postBuild.substitute` vars must be
  set explicitly, because kopiur's defaults are wrong here (`COPYMETHOD` defaults to
  `Direct`, `SNAPSHOTCLASS` to `tns-csi-nfs-snapshot`, run-as to 0, and `hostname:
  ${NS}` has no default):
  `APP: synapse-media`, `NS: matrix-bluevulpine`, `KOPIUR_COPYMETHOD: Snapshot`
  (Synapse holds the RWO volume), `KOPIUR_SNAPSHOTCLASS: longhorn-snapclass`,
  `KOPIUR_RUN_AS_USER`/`KOPIUR_RUN_AS_GROUP`/`KOPIUR_FS_GROUP: "10091"` (Synapse's
  uid/gid), and `KOPIUR_LOCAL_CRON`/`KOPIUR_R2_CRON` (`H` minutes; hours picked from
  free slots when planning). The `VOLSYNC_RUN_AS_*` names used by the existing
  instance do nothing for kopiur.
- **Staging class:** kopiur staging volumes inherit the source PVC's class, so each
  of the ~12 daily local runs would clone a 20Gi **2-replica** volume. An app-level
  patch sets `spec.staging.storageClassName: longhorn-1-replica` on both
  SnapshotPolicies (the component's own hermes comment calls this "replica churn on
  a throwaway volume").
- **Disaster recovery:** with no `dataSourceRef`, a deleted-and-recreated PVC comes up
  **empty**; recovery is a manual kopiur `Restore`. The README says so. The runbook's
  planned `components/kopiur-claim` is the eventual automatic fix.
- **kopiur namespace opt-in (also in PR A):** kopiur is opt-in per namespace. In
  `kubernetes/apps/kopiur-system/repositories/app/`, add `matrix-bluevulpine` to
  `allowedNamespaces` in **both** `clusterrepository-local.yaml` and
  `clusterrepository-r2.yaml`. Then add the namespace's pair of ExternalSecrets
  (`kopiur-local`, `kopiur-r2`) to `externalsecrets.yaml`, copying an existing pair
  and updating the "N namespaces x 2 legs" header. Without these, the fail-closed
  webhook rejects the app's SnapshotPolicies, and movers would find no credential
  in the namespace. The app `ks.yaml`'s `dependsOn: kopiur-repositories` orders
  this within the single PR.
- **Privileged-movers annotation (MAJOR if missed):** the namespace must carry
  `kopiur.home-operations.com/privileged-movers: "true"`, plus
  `volsync.backube/privileged-movers: "true"` for parity with the 8 existing kopiur
  namespaces. The component always adds `DAC_OVERRIDE`, and added caps count as
  elevation even for a non-root uid (`docs/runbooks/kopiur-migration.md`, traps
  section). Without it, every Snapshot sits `Pending` (`PrivilegedMoverNotPermitted`),
  `concurrencyPolicy: Forbid` skips every later slot, and **nothing alerts**. The
  runbook: "A namespace added to `allowedNamespaces` later needs both."
- **Off from day one:** password login/registration, `matrixRTC` (Element Call),
  `elementAdmin`, and the chart's own `elementWeb` (the shared one serves this domain).
- **Kept from the existing HelmRelease:** the Ingress-deleting `postRenderer` and the
  Reloader annotations on Synapse and MAS (`secret.reloader.stakater.com/reload`),
  for the same secret-rotation reason.
- **MAS upstream provider:** the same `mas-upstream-authentik.yaml` shape inside the
  ExternalSecret. Issuer is `https://sso.${SECRET_DOMAIN}/application/o/matrix-bluevulpine/`.
  The `id` is a **new fixed ULID, generated once and never changed**, because it is
  part of the redirect URI registered in Authentik.

## 2. Shared Element Web (changes the existing derekjacobs.dev release)

- The existing `chat` HTTPRoute gets a second hostname `chat.${SECRET_DOMAIN_BLOG}`
  on the same `internal` + `external-pangolin` parents. The existing app's
  `dnsendpoint.yaml` gains a DNS-only CNAME to `pangolin.${SECRET_DOMAIN_BLOG}`.
- A new ConfigMap carries `config.chat.${SECRET_DOMAIN_BLOG}.json`: the current
  `config.json` with `default_server_config` pointed at
  `https://matrix.${SECRET_DOMAIN_BLOG}` / `${SECRET_DOMAIN_BLOG}`.
- A **fourth** `postRenderer` patch (after the Ingress delete and the two Reloader
  patches) on Deployment `matrix-stack-element-web` adds a `volumes` entry and a
  `volumeMounts` entry on container `element-web`, mounting the file at
  `/app/config.chat.<blog-domain>.json` with `subPath`. If the ConfigMap comes from
  a `configMapGenerator`, set `disableNameSuffixHash: true`: the patch refers to it
  by a literal name that kustomize won't rewrite.
- The same patch adds a Reloader annotation (`configmap.reloader.stakater.com/reload`).
  The image entrypoint copies `/app/config*.json` into `/tmp/element-web-config/`
  **once at start**, and nginx serves `/config*` from there. So **no** kind of mount
  picks up edits without a restart; without Reloader they'd be silently ignored.
- **Drift:** Element Web uses the per-host file instead of `config.json`, not merged
  on top. A comment next to it says to re-diff it against the chart's rendered
  `config.json` on chart upgrades, the same convention as the HTTPRoute paths note.
- Sign-in needs nothing extra: Element Web registers itself with
  `account.bluevulpine.net` by dynamic client registration, as it already does
  on derekjacobs.dev.

## 3. DNS, Pangolin, federation

- `matrix.` and `account.${SECRET_DOMAIN_BLOG}`: DNS-only CNAMEs to
  `pangolin.${SECRET_DOMAIN_BLOG}` (`cloudflare-proxied: "false"`, mandatory, as in
  the existing `dnsendpoint.yaml`). The HTTPRoutes copy the existing set one-for-one,
  including the deliberate splits: only `/_synapse/client` is public, and the
  Synapse admin API and MAS `/api/admin` stay LAN-only.
- **Apex `.well-known`:** a `matrix-well-known` route on `${SECRET_DOMAIN_BLOG}`
  matching only `PathPrefix: /.well-known/matrix`. The blog's catch-all route on
  the apex is untouched; Gateway API picks the more specific match. No apex DNS
  change. Publishes `m.server: matrix.bluevulpine.net:443` and
  `m.homeserver.base_url: https://matrix.bluevulpine.net`.
  - **Deviation:** parents are `external` **and** `internal`, matching the blog's
    apex route. The derekjacobs.dev well-known route is `external`-only. Because the
    blog apex is also on `internal`, LAN clients resolving `bluevulpine.net` would
    hit the internal gateway, where an external-only route falls through to the
    blog and 404s (on the LAN, `bluevulpine.net` resolves to 172.16.8.2, the
    internal gateway, and returns 404 there today). derekjacobs.dev has no such gap:
    its apex resolves to Cloudflare even on the LAN and its well-known returns 200,
    so it stays as is.
- **Pangolin (manual):** HTTP resources for `matrix.`, `account.` and
  `chat.bluevulpine.net` targeting the `external-pangolin` gateway, created **only
  after their CNAMEs resolve publicly**. Otherwise Traefik's HTTP-01 order fails,
  and it serves `TRAEFIK DEFAULT CERT` until restarted (seen 2026-09-25). If a
  US-only geo rule is applied to `matrix.`, it must exempt `/_matrix/federation/*`
  and `/_matrix/key/*` (runbook, #1958).

## 4. Authentik

All done by hand in the UI (nothing in Authentik is config-as-code today), with
each step recorded in the new README.

- **New provider + application:** "Provider for Matrix (bluevulpine.net)", app slug
  `matrix-bluevulpine`, confidential client, same flows, scopes and property
  mappings as the existing "Provider for Matrix". Redirect URI
  `https://account.bluevulpine.net/upstream/callback/<new ULID>`.
- **Gating:** new group `matrix-bluevulpine-users`, bound to the new application,
  with only Derek in it at first. Adding a person later is a group-membership
  change, not a repo change.
- **Existing open door:** the existing `matrix` application has **zero bindings**,
  so every Authentik user can reach derekjacobs.dev (all eleven applications are
  like this). Fix for Matrix only: add Derek to the existing, unused `matrix-users`
  group **first**, **then** bind it to `matrix`. The other order locks everyone out
  for a moment.
- **Client secret:** Derek writes `Mas__Authentik__ClientId/ClientSecret` into
  `secret/matrix-bluevulpine` (the sandbox blocks agent writes to OpenBao). The
  check happens in **two** stages, each comparing SHA-256 hashes with no plaintext
  printed:
  1. **Step 2, before merge:** OpenBao's field against Authentik's provider
     secret. At this point there is no rendered Secret to hash; `matrix-stack-secret`
     doesn't exist until PR A creates the namespace.
  2. **Step 3, after merge:** the rendered `matrix-stack-secret` against Authentik
     again. When extracting, match **only** `^\s*client_secret:`. A plain
     `grep client_secret` also matches `token_endpoint_auth_method:
     client_secret_basic` and gives a false mismatch (happened 2026-09-26).
- **Current state (checked via the Authentik API, 2026-10-01):** all 11 applications
  have zero bindings. In Authentik, zero bindings means any authenticated user gets
  in, and a single group binding under the default `any` engine mode limits access
  to that group. `matrix-users` exists with 0 members, which is why the
  member-first ordering matters.

## 5. Rollout

Rule: secrets and external prerequisites exist before the manifests that consume them merge.

0. **Merge #2002** (chart 26.9.3 → 26.9.4) so the new instance starts on current.
1. **PR A** (nothing live): script path argument + the whole `matrix-bluevulpine/`
   tree, incl. README + kopiur namespace opt-in. Opened, **not merged**.
2. **Prerequisites** (Derek, each verified by the agent):
   `scripts/matrix-generate-secrets.sh secret/matrix-bluevulpine` from the PR branch;
   Authentik group → membership → provider/app → binding; `bao kv patch` client
   ID/secret; hash check 1 (OpenBao vs Authentik).
3. **Merge PR A.** Expect a short transient: `kopiur-repositories` applies its
   ExternalSecrets into `matrix-bluevulpine` while `cluster-apps` is still creating
   the namespace. Its apply can fail once (1m retry), and while it's NotReady every
   app that depends on it waits. Re-check rather than debug. Then verify: db Job
   complete (incl. collation assert), pods Ready, ExternalSecrets synced (app + both
   kopiur legs), hash check 2 (rendered Secret vs Authentik), apex `.well-known`
   answering on LAN and public. **kopiur gate:** the first Snapshot of **each** leg
   is `Succeeded`, not just "a Snapshot exists" (runbook: refused Snapshots sit
   `Pending` silently).
4. **Pangolin resources** for `matrix.` and `account.` after their CNAMEs resolve;
   verify real per-host certs (not `TRAEFIK DEFAULT CERT`); README verify block.
5. **PR B** (touches the live derekjacobs.dev release): second `chat` hostname,
   per-host config, mount + Reloader patch, CNAME. After merge: the Pangolin
   resource for `chat.`, then Derek signs in end to end at `chat.bluevulpine.net`,
   creating `@bluevulpine:bluevulpine.net`.
6. **Close derekjacobs.dev's open door** (membership, then binding). Last on purpose,
   so a lockout can't be confused with new-instance debugging. Verify Derek can still
   sign in there.
7. **Federation:** federationtester for `bluevulpine.net`; join a small room first.

Rollback:
- **PR A:** revert the PR. Deleting the Kustomizations by hand doesn't stick,
  because `cluster-apps` recreates them from git. Pruning **deletes the
  `synapse-media` PVC, and its data with it**, since every Longhorn class is
  `reclaimPolicy: Delete`. What survives:
  - kopia snapshots (`onPolicyDelete` resolves to `Retain`)
  - the Postgres databases
  - the OpenBao key
  - the namespace (`prune: disabled`)
- **PR B:** reverts cleanly. The new homeserver keeps working, but has no web
  client until PR B is re-applied.

## Review

Adversarially reviewed 2026-10-02 (read-only; `helm template` of chart 26.9.4 with
these values, upstream element-web v1.12.29 source, live read-only cluster state).
That produced one MAJOR finding (the privileged-movers annotation) and eleven MINOR
ones, all folded in above.

Confirmed by that review:
- The chart renders cleanly with these values, and every object is namespaced.
- Element Web loads `config.<hostname>.json`, and nginx serves it.
- MAS's `allow_host_mismatch: false` is satisfied by Element on `chat.bluevulpine.net`.
- All gateway listeners allow routes from all namespaces (no ReferenceGrant needed),
  and the CF tunnel routes the apex.
- Cloudflare doesn't cache `/.well-known/matrix`.
- Postgres places no restrictions on the role names.
- The Authentik issuer URL form is right.
- `@bluevulpine:derekjacobs.dev` is the only Matrix user today.

Still unverified, and checked during the build:
- whether the ESO OpenBao policy allows `secret/matrix-bluevulpine`
- whether CF challenges federation fetches from datacenter IPs
- whether bluevulpine.net is already a Pangolin domain

## Out of scope (follow-ups)

- **Bot / agent accounts** on either homeserver. With registration closed and
  Authentik as the only way in, this needs its own design (MAS has several routes:
  `mas-cli` user provisioning, personal access tokens, appservices).
- **Authentik hygiene project:** bindings for every application, a role model, moving
  to blueprints, and `sso.bluevulpine.net` with its own brand.
- Moving derekjacobs.dev's `synapse-media` to 2 replicas and/or kopiur (on the
  replica session's queue if wanted).
- Element Call (`matrixRTC`) for either instance.
- The QR-login rotation flakiness in Element Web (documented in Hindsight; upstream).
