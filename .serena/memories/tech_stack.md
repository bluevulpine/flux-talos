# Tech Stack — flux-talos

## OS / Kubernetes

- **Talos Linux** v1.13.2 — immutable, API-driven OS on all nodes
- **Kubernetes** v1.36.1
- Versions are Renovate-tracked via `# renovate: datasource=github-releases` comments in `talos/talconfig.yaml`

## GitOps

- **FluxCD v2** — HelmRelease (`helm.toolkit.fluxcd.io/v2`), Kustomization (`kustomize.toolkit.fluxcd.io/v1`), GitRepository, OCIRepository
- Flux watches `kubernetes/apps/`; global SOPS decryption injected via cluster-apps patch in `kubernetes/flux/cluster/ks.yaml`

## Key infrastructure components

| Component | Purpose |
|-----------|---------|
| Cilium | CNI, LB-IPAM, BGP, direct routing (no VXLAN) |
| Envoy Gateway | Kubernetes Gateway API |
| cert-manager | TLS via Let's Encrypt + Cloudflare DNS |
| external-dns | Sync ingress → DNS |
| Tailscale Operator | Pod/service Tailscale access |
| External Secrets Operator | Pull secrets from Bitwarden Secrets Manager |
| SOPS + AGE | Git-encrypted secrets |
| Volsync | PVC backup/restore |
| Longhorn | Replicated block storage |
| OpenEBS | Local hostpath storage |
| democratic-csi | NFS/iSCSI from TrueNAS |
| Garage | Self-hosted S3 on TrueNAS |
| spegel | Local OCI registry mirror |
| actions-runner-controller | Self-hosted GitHub runners |

## Toolchain (managed via mise)

- `uv` — Python venv / package management
- `pipx:flux-local` — local Flux plan/diff validation
- `just` — task runner (modules: `bootstrap`, `kube`, `talos`)
- `talosctl`, `talhelper` — Talos management
- `kubectl`, `flux` — Kubernetes/FluxCD CLI
- `sops`, `age` — secret encryption
- `minijinja-cli` — template rendering (+ `op inject` for 1Password)
- `gum` — interactive prompts in just recipes
- `yq` — YAML processing
- `lefthook` — pre-commit hooks

## Config files

- `.mise.toml` — tool versions + env vars
- `.envrc` — direnv environment (KUBECONFIG, SOPS_AGE_KEY_FILE, TALOSCONFIG, Python venv)
- `.minijinja.toml` — template config
