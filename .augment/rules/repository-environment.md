# Repository & Environment Context

## Repository Type

This is a **FluxCD-powered GitOps repository** that manages a Kubernetes cluster. All cluster configuration is defined declaratively in this repository, and FluxCD reconciles the desired state to the cluster.

### Key Technologies
- **FluxCD**: GitOps operator that continuously reconciles cluster state with this repository
- **Talos Linux**: The cluster runs on Talos Linux, an immutable Kubernetes OS
- **Talhelper**: Used to manage and generate Talos configuration files

### GitOps Workflow
1. Changes are committed to this repository
2. FluxCD detects changes and reconciles them to the cluster
3. The cluster state converges to match the repository definitions

## Tool Installation

Kubernetes-related CLI tools are installed via **Homebrew** (Linuxbrew on Linux).

### Tool Locations by Platform

| Platform | Homebrew Path |
|----------|---------------|
| Linux | `/home/linuxbrew/.linuxbrew/bin/` |
| macOS (Apple Silicon) | `/opt/homebrew/bin/` |
| macOS (Intel) | `/usr/local/bin/` |

### Available Tools
- `kubectl` - Kubernetes CLI
- `flux` - FluxCD CLI
- `helm` - Helm package manager
- `kustomize` - Kustomization tool
- `talosctl` - Talos Linux CLI
- Other Kubernetes ecosystem tools

## Environment Configuration via direnv

This repository uses **direnv** to automatically load environment variables when entering the repository directory.

### What `.envrc` Configures
- `KUBECONFIG` - Points to the cluster's kubeconfig file
- Homebrew shell environment setup
- Repository-specific environment variables

### How direnv Works
1. When you `cd` into the repository directory, direnv automatically loads `.envrc`
2. Environment variables are set without manual intervention
3. When you leave the directory, the environment is restored

## Usage Instructions

### Before Running Kubernetes Commands

1. **Ensure direnv is allowed** (first time or after `.envrc` changes):
   ```bash
   direnv allow
   ```

2. **Or manually set up the environment**:
   ```bash
   # Linux
   eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
   
   # macOS (Apple Silicon)
   eval "$(/opt/homebrew/bin/brew shellenv)"
   ```

3. **Verify environment is configured**:
   ```bash
   # Check KUBECONFIG is set
   echo $KUBECONFIG
   
   # Verify cluster connectivity
   kubectl cluster-info
   ```

## Implications for AI Assistant

### When Executing Kubernetes Commands

1. **Environment should be pre-configured**: If direnv is properly set up, the environment variables and tool paths should already be available.

2. **If commands fail due to missing tools**:
   - Check if direnv is loaded: `direnv status`
   - Manually source Homebrew: `eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"`

3. **If commands fail due to kubeconfig issues**:
   - Verify `KUBECONFIG` is set: `echo $KUBECONFIG`
   - Check the kubeconfig file exists at the specified path
   - Ensure the cluster is reachable

### Command Execution Pattern
```bash
# If direnv is working, simply run:
kubectl get pods -A

# If direnv is not loaded, prefix with environment setup:
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && kubectl get pods -A
```

### Troubleshooting Checklist
- [ ] Is direnv installed and hooked into the shell?
- [ ] Has `direnv allow` been run for this repository?
- [ ] Is the Homebrew environment loaded?
- [ ] Is `KUBECONFIG` pointing to a valid file?
- [ ] Is the Kubernetes cluster reachable?

