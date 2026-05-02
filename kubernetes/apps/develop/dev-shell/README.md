# dev-shell

A persistent Alpine-based SSH development environment, exposed to the Tailscale network as `dev-shell`.

## Access

Default credentials: `bluevulpine` / `dev` — change on first login with `passwd`.

```bash
# Via Tailscale (preferred)
ssh bluevulpine@dev-shell -p 2222

# Via port-forward
kubectl port-forward -n develop dev-shell-0 2222:2222
ssh bluevulpine@localhost -p 2222
```

## First start

The init script (`init-configmap.yaml`) runs before sshd on every pod start:

- **Every start (fast):** `apk add zsh git curl shadow`
- **Once (persisted to PVC):** oh-my-zsh → `~/.oh-my-zsh`, atuin → `~/.atuin`
- Sets zsh as the default shell and wires atuin into `.zshrc`

On first SSH in, run `atuin login` to connect shell history sync.

## Package management

This image is Alpine (musl libc). Homebrew is not compatible.

- `apk add <package>` — system packages, fast, **not persistent across pod restarts**
- Anything installed to `~/` persists (PVC-backed)
- Use `mise` for persistent version-managed dev tools (node, python, go, etc.):
  ```bash
  curl https://mise.run | sh
  mise use node@lts python@latest
  ```

## Storage

Single 50Gi `openebs-hostpath` PVC mounted at `/home/bluevulpine`. Everything under `~` persists — dotfiles, oh-my-zsh config, atuin history, mise toolchains, projects.
