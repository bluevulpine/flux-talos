---
name: new-app
description: The layout and conventions for adding an application under kubernetes/apps/<namespace>/<app>/ in this repo: namespace and kustomization files, the HelmRelease shape (OCIRepository ref, &app anchor, no strategy blocks because cluster-apps injects them), ExternalSecret wiring to OpenBao and its field naming, and how to verify a yaml-language-server schema URL. Use when adding a new app or copying one app's manifests to make another.
---

# Adding a new application

Follow the existing layout under `kubernetes/apps/<namespace>/<app>/`:
- `namespace.yaml` + `kustomization.yaml` at the namespace level
- `app/helmrelease.yaml` using an OCIRepository ref and an `&app` name anchor. **Do not add
  `install.strategy` / `upgrade.strategy`** — the `cluster-apps` patch injects
  `strategy: {name: RetryOnFailure}` into every HelmRelease, the same mechanism as the
  `crds: CreateReplace` rule in CLAUDE.md. No manifest in the repo declares it (0 of 113).
  An explicit `install.remediation.retries` / `upgrade.cleanupOnFail` /
  `upgrade.remediation.strategy: rollback` block is **optional**, not standard: 58 of 113
  HelmReleases carry one, and the `app-template` web apps a new app usually patterns itself on
  (mosquitto, homebox, vaultwarden) do not.
- `app/externalsecret.yaml` if runtime secrets are needed (pull from OpenBao via External Secrets Operator — `secretStoreRef: openbao`)
- Include `# yaml-language-server: $schema=...` at the top of every Kubernetes manifest.
  **Confirm the URL returns JSON before copying one from a neighbouring file.**
  `kubernetes-schemas.pages.dev` answers **`200` with an HTML page** for any group it does not
  host — indistinguishable from a live schema by status code alone — and it does not host
  `image.toolkit.fluxcd.io` at all. For those kinds use
  `https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/<kind>-image-v1.json`.

Secrets come exclusively from OpenBao via `ExternalSecret` (`secretStoreRef` → `openbao` / `ClusterSecretStore`, `engineVersion: v2`). OpenBao field naming is PascalCase double-underscore: `App__Category__Field` (e.g. `Frigate__Mqtt__User`). Never commit secret values.

If the app needs a Postgres database, also invoke the `postgres-init` skill.
