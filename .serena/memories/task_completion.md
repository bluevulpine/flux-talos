# Task Completion — flux-talos

This is a GitOps repo — there is no test suite. "Done" means manifests are valid and reconcile cleanly.

## Pre-commit (runs automatically via lefthook)

```bash
yamlfmt {staged_files}           # format YAML (skip *.sops.yaml)
just --fmt --unstable            # format .just files
gitleaks protect --staged        # secret scan
```

Run manually: `lefthook run pre-commit`

## Local Flux validation (CI equivalent)

```bash
flux-local test                  # validate all Kustomizations and HelmReleases locally
```
This is what the `flux-local.yaml` GitHub Actions workflow runs on PRs.

## Apply and verify

```bash
just kube apply-ks kubernetes/apps/<namespace>/<app>
kubectl get hr -n <namespace>    # check READY status
kubectl get ks -A                # check Kustomization status
flux get all -A                  # broad reconciliation health
```

## Schema validation

CI (`schemas.yaml` workflow) validates YAML against published CRD schemas. If adding new CRD types, ensure the schema URL is set via `# yaml-language-server: $schema=` comment.

## Secrets

After editing a `.sops.yaml` file, verify decryption works:
```bash
sops -d <file.sops.yaml>
```
