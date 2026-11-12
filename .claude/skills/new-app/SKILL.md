---
name: new-app
description: "The layout and conventions for adding an application under kubernetes/apps/<namespace>/<app>/ in this repo: namespace and kustomization files, the HelmRelease shape (OCIRepository ref, &app anchor, no strategy blocks because cluster-apps injects them), ExternalSecret wiring to OpenBao and its field naming, and how to verify a yaml-language-server schema URL. Use when adding a new app or copying one app's manifests to make another."
---

# Adding a new application

Follow the existing layout under `kubernetes/apps/<namespace>/<app>/`:
- `namespace.yaml` + `kustomization.yaml` at the namespace level
- `app/helmrelease.yaml` using an OCIRepository ref and an `&app` name anchor. **Do not add
  `install.strategy` / `upgrade.strategy`** — the `cluster-apps` patch injects
  `strategy: {name: RetryOnFailure}` into every HelmRelease, the same mechanism as the
  `crds: CreateReplace` rule in CLAUDE.md. No manifest in the repo declares it.
  An explicit `install.remediation.retries` / `upgrade.cleanupOnFail` /
  `upgrade.remediation.strategy: rollback` block is **optional**, not standard: about half the
  HelmReleases carry one, and the `app-template` web apps a new app usually patterns itself on
  (mosquitto, homebox, vaultwarden) do not.
- Backups: a new app that has a data PVC gets `components/kopiur` plus `components/kopiur-claim`
  (the PVC, restored from the latest backup whenever it is created; empty on first deploy).
  Size it with `CLAIM_CAPACITY` / `CLAIM_STORAGECLASS` / `CLAIM_ACCESSMODES` in `ks.yaml`
  (the same names `volsync-claim` reads, so a later swap renames nothing) and add `dependsOn: kopiur-repositories`. Usage
  and checks: `docs/runbooks/kopiur-claim.md`. Do not add `components/volsync-claim` or a plain
  `pvc.yaml` to a new app. `volsync-claim` persists on most existing apps because it is the
  only manifest that creates their PVC: never remove it from one outside that runbook's
  recreate procedure.
- `app/externalsecret.yaml` if runtime secrets are needed (pull from OpenBao via External Secrets Operator — `secretStoreRef: openbao`)
- Include `# yaml-language-server: $schema=...` at the top of every Kubernetes manifest.
  **Confirm the URL returns JSON before copying one from a neighbouring file.**
  - For **new** manifests prefer `https://k8s-schemas.home-operations.com/<group>/<kind>_<version>.json`,
    the maintained source (home-operations' own `k8s-schemas` repo, Renovate-driven). It covers
    every CRD kind this repo's pages.dev headers use except `volsync.backube`'s
    `kopiamaintenance_v1alpha1` (VolSync is removed, so a new manifest never needs it), and answers an honest `404` for what it lacks. It also hosts
    `image.toolkit.fluxcd.io`; CLAUDE.md's
    `fluxcd-community/flux2-schemas/main/<kind>-image-v1.json` URL works too.
  - Most existing headers still point at `kubernetes-schemas.pages.dev`, a community mirror
    with no one accountable for it. It answers **`200` with an HTML page** for any group it does
    not host, indistinguishable from a live schema by status code alone, and it does not host
    `image.toolkit.fluxcd.io` at all. Don't copy new headers from it.
  - Neither host has core `v1` kinds (`configmap`, `secret`, `persistentvolumeclaim`, ...). For
    those use `https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/<kubernetesVersion>-standalone-strict/<kind>-v1.json`,
    as existing core manifests here do.
  - Check by body, not by status or content type: `curl -s <url> | head -c 1` must print `{`.
    An HTML page starts with `<`, and raw.githubusercontent.com serves real schemas as
    `text/plain`. (Hosts as described here were checked 2026-11-05.)

Secrets come exclusively from OpenBao via `ExternalSecret` (`secretStoreRef` → `openbao` / `ClusterSecretStore`, `engineVersion: v2`). OpenBao field naming is PascalCase double-underscore: `App__Category__Field` (e.g. `Frigate__Mqtt__User`). Never commit secret values.

If the app needs a Postgres database, also invoke the `postgres-init` skill.
