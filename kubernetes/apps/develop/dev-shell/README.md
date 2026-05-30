# dev-shell

A persistent Debian-based SSH development environment, exposed to the Tailscale
network as `dev-shell`. Login is **SSH key only** (no passwords).

## Access

```bash
# Via Tailscale (preferred)
ssh bluevulpine@dev-shell -p 2222

# Via port-forward
kubectl port-forward -n develop dev-shell-0 2222:2222
ssh bluevulpine@localhost -p 2222
```

Only the keys listed in `app/authorized-keys.yaml` may log in.

## Managing SSH keys

Public keys live in the `dev-shell-authorized-keys` ConfigMap
(`app/authorized-keys.yaml`) — they're public, so they're committed to git
rather than stored in OpenBao. To add or revoke access, edit the
`authorized_keys` block and let Flux reconcile. Stakater Reloader rolls the pod
automatically when the ConfigMap changes, so the new `authorized_keys` takes
effect without a manual restart.

## How it boots

The container runs `debian:bookworm-slim` and executes
`app/init-configmap.yaml`'s `entrypoint.sh` as root:

- **Every boot (fast, not persisted):** `apt-get install` of sshd, zsh, tmux,
  git, build tools, python, and friends; creates the `bluevulpine` user;
  configures key-only sshd on port 2222.
- **First boot only (persisted to PVC, runs in the background):**
  `user-setup.sh` installs `kubectl`, `flux`, `helm`, `mise`, `oh-my-zsh`,
  `atuin`, and Node LTS + Claude Code (via mise) into `~/.local`. Progress is
  logged to `/tmp/dev-shell-setup.log` inside the pod.

Because tooling installs in the background, sshd is reachable within seconds;
the first login may briefly precede some tools finishing. Watch progress with
`tail -f /tmp/dev-shell-setup.log`.

On first SSH in, run `atuin login` to connect shell history sync.

## Package management

This image is Debian (glibc), so most upstream installers work directly.

- `sudo apt-get install <pkg>` — system packages, **not persistent across pod
  restarts** (re-add via the boot script if you want them every boot).
- Anything under `~` persists (PVC-backed).
- Prefer `mise` for version-managed dev tools (node, python, go, …):
  ```bash
  mise use node@lts python@latest go@latest
  ```

## Storage

Single 50Gi `openebs-hostpath` PVC mounted at `/home/bluevulpine`. Everything
under `~` persists — dotfiles, oh-my-zsh, atuin history, mise toolchains, the
`~/.local/bin` CLIs, SSH host keys (`~/.dev-shell/ssh`), and projects.

## Flux note

`app/init-configmap.yaml` and `app/authorized-keys.yaml` both carry
`kustomize.toolkit.fluxcd.io/substitute: disabled`. They hold shell scripts and
key material full of `${VAR}` references; without that annotation Flux
post-build substitution would blank every `${VAR}` it doesn't recognize — the
original `usermod: user '' does not exist` failure. Keep the annotation if you
edit these files.

## Future: build the image in-cluster

For a faster cold start, the runtime `apt`/tooling install can be baked into a
pre-built image produced by the in-cluster Gitea + Drone + Nexus stack (build on
push, push to the Nexus Docker registry, pin the digest here). Not done yet —
this first pass trades a slower boot for zero build pipeline.
