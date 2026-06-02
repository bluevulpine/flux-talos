# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project knowledge

Serena is configured for this repo. At session start, activate the project and read `mem:core` for the source map and cluster topology. Follow references from there to `mem:tech_stack`, `mem:conventions`, `mem:suggested_commands`, and `mem:task_completion` as the task requires — do not load all memories up front.

## Critical rules

**SOPS-encrypted files** (`*.sops.yaml`): never write decrypted content to disk. Use `sops -d <file>` to view and `sops <file>` to open the editor. Plaintext secrets must not appear in any file tracked by git (gitleaks runs on every pre-commit).

**`talos/clusterconfig/`** is gitignored and contains generated machine configs. Do not edit these files directly; the source of truth is `talos/talconfig.yaml`. Regenerate with `just talos gen-config`.

**YAML formatting**: all `.yaml` files except `*.sops.yaml` must pass `yamlfmt`. Block-style arrays, `---` document start, LF line endings. Lefthook enforces this on pre-commit — do not skip hooks.

**`crds: CreateReplace`** is injected globally via the `cluster-apps` Flux patch; do not add it to individual HelmRelease manifests.

**Renovate version tracking**: when adding a chart or tool version that Renovate should update, annotate it with the appropriate `# renovate: datasource=...` comment (see existing entries in `talos/talconfig.yaml` for the pattern).

## Adding a new application

Follow the existing layout under `kubernetes/apps/<namespace>/<app>/`:
- `namespace.yaml` + `kustomization.yaml` at the namespace level
- `app/helmrelease.yaml` using an OCIRepository ref, `&app` name anchor, and standard remediation blocks (retries: 3, cleanupOnFail, rollback strategy)
- `app/externalsecret.yaml` if runtime secrets are needed (pull from Bitwarden via External Secrets Operator)
- Include `# yaml-language-server: $schema=...` at the top of every Kubernetes manifest

## Validating changes

Run `lefthook run pre-commit` before committing. For a broader local diff against the cluster:

```bash
flux-local test
```

To apply a single app's kustomization directly:

```bash
just kube apply-ks kubernetes/apps/<namespace>/<app>
```
