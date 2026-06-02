# Conventions — flux-talos

## YAML formatting (enforced by yamlfmt + lefthook)

- Block-style arrays (`force_array_style: block`)
- LF line endings
- `---` document start required (`include_document_start: true`)
- No trailing whitespace; single blank lines preserved
- `*.sops.yaml` files excluded from yamlfmt

## Schema comments

Most YAML files open with a json-schema hint:
```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/<crd>_<version>.json
```

## HelmRelease structure

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: &app <name>     # anchor &app reused in labels/selectors
spec:
  interval: 30m
  chartRef:
    kind: OCIRepository
    name: <chart>
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      strategy: rollback
      retries: 3
```
- `crds: CreateReplace` is injected globally via `cluster-apps` patch — no need to repeat per HR.

## Secrets in manifests

- Kubernetes secrets: SOPS-encrypt whole file as `.sops.yaml`; only `data`/`stringData` keys are encrypted (`encrypted_regex`).
- ExternalSecret CRDs: pull from Bitwarden Secrets Manager at runtime.
- Never commit plaintext secrets; gitleaks runs in pre-commit.

## Renovate

- Semantic commits enforced (`.renovate/semanticCommits.json5`)
- Patch updates auto-merge; major updates open PRs
- Ignore paths: `**/*.sops.*`, `**/resources/**`
- Chart versions tracked in HelmRelease via `# renovate:` comments or standard Helm datasource

## App directory layout

Each app under `kubernetes/apps/<namespace>/<app>/` typically contains:
```
app/
  helmrelease.yaml
  kustomization.yaml
  [externalsecret.yaml]
  [configmap.yaml]
kustomization.yaml     # namespace-level aggregator
namespace.yaml
```

## Just files

- Root `.justfile` delegates to modules: `mod bootstrap`, `mod kube`, `mod talos`
- Module files: `bootstrap/mod.just`, `kubernetes/mod.just`, `talos/mod.just`
- `set shell := ['bash', '-euo', 'pipefail', '-c']` on all just files
- Format with `just --fmt --unstable` (enforced by lefthook)
