# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A GitOps mono-repo for a home Kubernetes cluster. [Talos Linux](https://www.talos.dev) runs Kubernetes on the nodes, [Flux](https://github.com/fluxcd/flux2) continuously reconciles the cluster state from `kubernetes/`, and [Renovate](https://github.com/renovatebot/renovate) opens dependency-update PRs. There is no application source code to compile here — the "code" is declarative YAML (Flux Kustomizations, HelmReleases, Talos machine configs) that gets applied to a live cluster. Baseline derived from onedr0p's [cluster-template](https://github.com/onedr0p/cluster-template).

## Tooling and environment

Tasks are driven by **`just`** recipes, not raw scripts. The root `.justfile` imports three modules:
- `just kube …` → `kubernetes/mod.just` (cluster operations)
- `just talos …` → `talos/mod.just` (node/OS lifecycle)
- `just bootstrap …` → `bootstrap/mod.just` (initial cluster bring-up)

Run `just` (or `just -l`) to list recipes. `JUST_UNSTABLE=1` is required (set via mise) because recipe modules are used.

Environment is managed by **`mise`** (`.mise.toml`) and/or **`direnv`** (`.envrc`), which set `KUBECONFIG`, `TALOSCONFIG`, `SOPS_AGE_KEY_FILE`, `MINIJINJA_CONFIG_FILE`, and load secrets from `.secrets.env` / `.bws_access_token`. Required CLIs include: `kubectl`, `flux`, `flux-local`, `talosctl`, `talhelper`, `helmfile`, `sops`, `yq`, `minijinja-cli`, `gum`, `kustomize`. `flux-local` is installed via `mise`/`pipx`.

## Validation — there are no unit tests

Changes are validated by **`flux-local`**, which renders Kustomizations/HelmReleases locally the same way CI does. Always run this before committing changes under `kubernetes/`:

```sh
# Render a single app's Kustomization (mirrors what Flux will build)
just kube render-local-ks <namespace-dir> <ks-name>   # e.g. just kube render-local-ks media sonarr

# Full test (what CI runs on PRs)
flux-local test --all-namespaces --enable-helm --path kubernetes/flux/cluster --sources home-kubernetes

# See the diff a change will produce vs. main (CI posts this to the PR)
flux-local diff helmrelease   --path kubernetes/flux/cluster --sources home-kubernetes
flux-local diff kustomization --path kubernetes/flux/cluster --sources home-kubernetes
```

CI (`.github/workflows/flux-local.yaml`) runs `flux-local test` and `diff` on every PR touching `kubernetes/**` and posts the rendered diff as a sticky PR comment. A PR is green when the `Flux Local - Success` job passes.

`pre-commit` hooks run via **lefthook** (`.lefthook.toml`): `yamlfmt`, `just --fmt`, and `gitleaks` secret scanning. `.sops.yaml`-encrypted files (`*.sops.yaml`) are excluded from formatting and secret scanning. Respect `.editorconfig`/`.yamlfmt.yaml` (2-space YAML indent, block array style, document start `---`).

## How Flux reconciliation works (the big picture)

1. `kubernetes/flux/cluster/ks.yaml` defines the root `cluster-apps` Kustomization pointing at `./kubernetes/apps`. **Read this file first** — it applies cluster-wide patches to *every* child Kustomization:
   - SOPS decryption is injected automatically.
   - HelmRelease install/upgrade defaults (`crds: CreateReplace`, `RetryOnFailure`) are injected.
   - `postBuild.substituteFrom` is wired to the `cluster-settings` ConfigMap and `cluster-secrets` Secret, so `${VARIABLE}` references resolve in any manifest.
   - These patches are skipped on resources labeled `substitution.flux.home.arpa/disabled: "true"`.
2. `kubernetes/apps/<namespace>/kustomization.yaml` is the per-namespace aggregator: it sets the namespace, pulls in `components/common`, and lists each app's `ks.yaml` plus `namespace.yaml`.
3. Each app directory (`kubernetes/apps/<namespace>/<app>/`) contains a **`ks.yaml`** (a Flux `Kustomization` pointing at the app's `app/` subdir, declaring `dependsOn`, `targetNamespace`, and `postBuild.substitute` vars) and an **`app/`** folder with the actual resources.

So the chain is: root `cluster-apps` → namespace `kustomization.yaml` → app `ks.yaml` → app `app/kustomization.yaml` → resources.

## Adding or modifying an application

Follow the existing convention exactly (see `kubernetes/apps/media/sonarr/` as the canonical example). A typical app has:

```
kubernetes/apps/<namespace>/<app>/
├── ks.yaml                      # Flux Kustomization: name (&app anchor), dependsOn, targetNamespace, postBuild.substitute
└── app/
    ├── kustomization.yaml       # lists resources + pulls in components (e.g. ../../../../components/volsync)
    ├── ocirepository.yaml       # OCIRepository for the Helm chart (usually bjw-s app-template)
    ├── helmrelease.yaml         # HelmRelease referencing the OCIRepository via chartRef
    └── externalsecret.yaml      # ExternalSecret (secrets come from the external secret store, never inline)
```

Conventions:
- HelmReleases almost always use the **bjw-s `app-template`** chart, sourced via an `OCIRepository` (`oci://ghcr.io/bjw-s-labs/helm/app-template`) and referenced with `chartRef`.
- Use YAML anchors `&app` / `*app` for the app name; reuse `${TIMEZONE}`, `${SECRET_*}`, and other cluster vars rather than hardcoding.
- When adding a new app, register its `ks.yaml` in the parent namespace `kustomization.yaml` `resources:` list.
- Reusable building blocks live in `kubernetes/components/` (e.g. `common`, `volsync`, `volsync-r2-restore`, `nfs-scaler`, `gatus` alerts) and are attached via `components:` in a kustomization. `components/common` is applied to every namespace and brings alerting, authentik forward-auth, cluster-config, and sops-age.
- Persistent-volume backup is opt-in via the `volsync` component plus `VOLSYNC_*` substitution vars in `ks.yaml` (local snapshots to Garage + daily R2 offsite).

## Secrets

- Secrets committed to Git are SOPS-encrypted as `*.sops.yaml`. Encryption rules and the age recipient are in `.sops.yaml`: the `talos/` tree encrypts the whole file; the `kubernetes/` tree only encrypts `data`/`stringData`. Decryption uses the age key at `$SOPS_AGE_KEY_FILE` (`age.key`).
- Runtime app secrets are pulled from an external store via **External Secrets** (`ExternalSecret` resources), backed by Bitwarden Secrets Manager — not committed inline.
- Never write a plaintext secret to a non-`.sops.yaml` file; gitleaks will block the commit and the file would be unencrypted in Git.

## Common cluster operations (`just kube …`)

- `just kube apply-ks <dir> <ks>` / `delete-ks` — render and apply/delete a Kustomization locally (server-side apply as `kustomize-controller`).
- `just kube sync-git | sync-ks | sync-hr | sync-es | sync-oci` — force Flux reconciliation by annotating resources cluster-wide.
- `just kube node-shell <node>` / `browse-pvc <ns> <claim>` / `view-secret <ns> <secret>` / `prune-pods` / `snapshot` / `volsync <suspend|resume>`.

## Talos / node lifecycle (`just talos …`)

Machine configs are generated by **talhelper** from `talos/talconfig.yaml` (+ encrypted `talenv.sops.yaml` / `talsecret.sops.yaml`) into `talos/clusterconfig/`. Key recipes:
- `just talos gen-config` — regenerate machine configs (run after editing `talconfig.yaml`); `gen-secrets` for new secrets.
- `just talos apply-generated <node>` / `upgrade-node <node>` / `upgrade-k8s <version>`.
- `reboot-node` / `shutdown-node` / `reset-node` (all gated by `gum confirm`).
- Destructive whole-cluster flows: `reset-all`, `bootstrap-cluster`, `rebuild` — these wipe/rebuild the cluster and are confirmation-gated; do not run them unless explicitly asked.

Talos and Kubernetes versions are pinned in `talconfig.yaml` (with `# renovate:` comments so Renovate tracks them).

## Initial cluster bring-up (`just bootstrap`)

`just bootstrap` runs the full sequence: apply Talos config → bootstrap Kubernetes → fetch kubeconfig → wait for nodes → create namespaces → apply resources → install CRDs and core apps via `helmfile` (`bootstrap/helmfile.d/00-crds.yaml`, `01-apps.yaml`) → Flux takes over. `bootstrap/resources.yaml.j2` is a minijinja template rendered with `op inject` (1Password).

## Commits, branches, and Renovate

- Uses **Conventional Commits** (`feat`, `fix`, `chore`, `ci`). Renovate (`.renovaterc.json5`, `.renovate/*.json5`) generates commits with scopes like `feat(helm)`, `fix(container)`, `chore(github-action)`. Match this style for manual commits.
- Renovate scans `*.yaml`/`*.yaml.j2` for Flux/Kubernetes/Helm/Docker/GitHub-release dependencies; it ignores `*.sops.*` and `**/resources/**`.
- The `schemas.yaml` workflow runs on a self-hosted ARC runner to extract live CRD schemas (used for editor/`flux-local` validation).

## Postgres bootstrap: the `postgres-init` init container

Apps that need a Postgres database on the CloudNativePG `postgres16` cluster do
**not** hand-create the database or role. Instead they run the
[`ghcr.io/home-operations/postgres-init`](https://github.com/home-operations/containers/tree/main/apps/postgres-init)
image as an init container. On every start it idempotently connects as the
superuser and ensures the app's role **and** database(s) exist (creating them,
and granting the role ownership/access, if missing). It is safe to re-run.

It is driven entirely by `INIT_POSTGRES_*` env, sourced from the app's secret:

| Env var | Meaning |
| --- | --- |
| `INIT_POSTGRES_HOST` | `postgres16-rw.database.svc.cluster.local` (RW service) |
| `INIT_POSTGRES_USER` | app role to create/own the database(s) |
| `INIT_POSTGRES_PASS` | password for that app role |
| `INIT_POSTGRES_DBNAME` | database name — **space-separate for multiple** (see below) |
| `INIT_POSTGRES_SUPER_PASS` | superuser password, used only to bootstrap |

The superuser password is **not** stored per-app. It is reused from the shared
`cloudnative-pg` secret key via a second `dataFrom.extract` block, exposed as
the template field `{{ .Postgres__SuperPassword }}`. This keeps the super
password in exactly one place.

### Wiring (HelmRelease + ExternalSecret)

In the HelmRelease, declare it as an init container that loads the app secret —
it runs to completion before the app container starts:

```yaml
initContainers:
  01-init-db:
    image:
      repository: ghcr.io/home-operations/postgres-init
      tag: rolling
    envFrom:
      - secretRef:
          name: <app>-secret
```

In the ExternalSecret, pull the app's own creds from its key and the superuser
from the shared `cloudnative-pg` key:

```yaml
  target:
    template:
      engineVersion: v2
      data:
        INIT_POSTGRES_HOST: &dbHost postgres16-rw.database.svc.cluster.local
        INIT_POSTGRES_USER: &dbUser "{{ .App__Postgres__User }}"
        INIT_POSTGRES_PASS: &dbPass "{{ .App__Postgres__Password }}"
        INIT_POSTGRES_DBNAME: app_db
        INIT_POSTGRES_SUPER_PASS: "{{ .Postgres__SuperPassword }}"
  dataFrom:
    - extract:
        key: app                # the app's own secret-store key
    - extract:
        key: cloudnative-pg     # shared superuser → Postgres__SuperPassword
```

The `ks.yaml` should `dependsOn` the cluster so ordering is correct:

```yaml
  dependsOn:
    - name: cloudnative-pg-cluster
      namespace: database
    - name: external-secrets-stores
      namespace: external-secrets
```

### One user, one database

The common case — a single role owning a single database. Example:
`kubernetes/apps/home/frigate/app/externalsecret.yaml`
(`INIT_POSTGRES_DBNAME: frigate`).

### One user, multiple databases

`INIT_POSTGRES_DBNAME` accepts a **space-separated** list; the one app role is
granted access to every database in it. Example:
`kubernetes/apps/media/lidarr/app/externalsecret.yaml`:

```yaml
        LIDARR__POSTGRES__MAINDB: lidarr_main
        LIDARR__POSTGRES__LOGDB: lidarr_log
        ...
        INIT_POSTGRES_USER: *dbUser
        INIT_POSTGRES_DBNAME: lidarr_main lidarr_log   # two DBs, one role
```

(Lidarr also shows chaining a second init container `02-init-metadata` after the
DB bootstrap for app-specific post-create SQL — a useful pattern when you need to
seed or patch config once the databases exist.)

### Reference implementations in this repo

- Single DB: `kubernetes/apps/home/frigate/app/` (also consumes MQTT creds),
  `kubernetes/apps/productivity/n8n/app/`.
- Multiple DBs: `kubernetes/apps/media/lidarr/app/`.
- DB + MQTT + JSONB archival: `kubernetes/apps/home/helium-archiver/app/`.
