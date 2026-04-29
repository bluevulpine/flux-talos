# dev-ubuntu

A persistent Ubuntu development environment with SSH access, exposed to the Tailscale network via Tailscale Operator annotations.

## Access

Default credentials: `dev` / `dev` — change immediately after first login.

```bash
# Via Tailscale (preferred — find "dev-ubuntu" in the Tailscale admin console)
ssh dev@dev-ubuntu -p 2222

# Via port-forward
kubectl port-forward -n develop dev-ubuntu-0 2222:2222

ssh dev@localhost -p 2222
```

## Storage

A single 50Gi `openebs-hostpath` PVC is split into two subPaths:
- `/home/dev` — user home directory
- `/home/linuxbrew` — Homebrew installation (persisted separately so brew doesn't need to be reinstalled after image updates)
