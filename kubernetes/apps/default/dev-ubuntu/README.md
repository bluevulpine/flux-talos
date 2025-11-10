# Ubuntu Development Pod

A persistent Ubuntu development environment with SSH access via Tailscale, ZSH shell, and Homebrew package manager.

## Features

- **Ubuntu 24.04 LTS** base image
- **Persistent storage** (50GB) for development work
- **SSH access** via Tailscale network
- **ZSH shell** with Oh My Zsh and agnoster theme
- **Homebrew** package manager pre-installed
- **Development tools** ready for installation
- **Automatic backups** via included scripts

## Architecture

- **StatefulSet**: Ensures stable network identity and persistent storage
- **Tailscale Integration**: Uses Tailscale operator annotations for network access
- **Persistent Volume**: 50GB storage for home directory and Homebrew
- **Security**: Runs as non-root user (UID 1000) with sudo privileges

## Quick Start

### 1. Deploy the Pod

The pod will be automatically deployed via Flux GitOps. Monitor deployment:

```bash
# Watch pod startup
kubectl get pods -l app.kubernetes.io/name=dev-ubuntu -w

# Check pod logs
kubectl logs dev-ubuntu-0 -f

# Verify Tailscale connection
kubectl describe pod dev-ubuntu-0 | grep tailscale
```

### 2. Find Tailscale IP

```bash
# Get Tailscale IP from pod
kubectl exec dev-ubuntu-0 -- ip addr show tailscale0

# Or check Tailscale admin console
# The device will appear as "dev-ubuntu" with tag "k8s"
```

### 3. SSH Access

```bash
# SSH to the development pod
ssh dev@<tailscale-ip>

# Default password: "dev"
# Change password immediately after first login
```

### 4. Initial Setup

After first SSH login:

```bash
# Change default password
passwd

# Run additional development tools setup
bash /home/dev/setup-dev-tools.sh

# Verify Homebrew installation
brew --version

# Install additional tools as needed
brew install <package-name>
```

## Configuration Details

### User Account
- **Username**: `dev`
- **Default Password**: `dev` (change immediately)
- **Shell**: ZSH with Oh My Zsh
- **Sudo**: Passwordless sudo access
- **Home Directory**: `/home/dev` (persistent)

### Installed Software
- **Base**: Ubuntu 24.04 LTS with essential development tools
- **Shell**: ZSH with Oh My Zsh (agnoster theme)
- **Package Manager**: Homebrew (Linux)
- **Tools**: git, curl, wget, vim, nano, htop, tree, build-essential

### Storage Layout
```
/home/dev/          # User home directory (persistent)
├── .zshrc          # ZSH configuration
├── .oh-my-zsh/     # Oh My Zsh installation
├── backups/        # Environment backups
└── projects/       # Development projects

/home/linuxbrew/    # Homebrew installation (persistent)
└── .linuxbrew/     # Homebrew packages and cache
```

### Resource Allocation
- **CPU**: 500m request, 2000m limit
- **Memory**: 1Gi request, 4Gi limit
- **Storage**: 50Gi persistent volume

## Development Workflow

### Installing Tools

```bash
# Via Homebrew (recommended)
brew install kubectl helm terraform

# Via apt (system packages)
sudo apt update && sudo apt install <package>

# Language-specific tools
brew install node python go rust
```

### Project Management

```bash
# Create project directory
mkdir -p ~/projects/my-project
cd ~/projects/my-project

# Initialize git repository
git init
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

### Backup and Restore

```bash
# Create backup
bash /home/dev/backup-dev-env.sh

# List backups
ls -la ~/backups/

# Restore from backup (manual process)
tar -xzf ~/backups/dev-env-YYYYMMDD_HHMMSS.tar.gz
```

## Troubleshooting

### SSH Connection Issues

```bash
# Check pod status
kubectl get pod dev-ubuntu-0

# Check SSH service
kubectl exec dev-ubuntu-0 -- systemctl status ssh

# Check Tailscale connectivity
kubectl exec dev-ubuntu-0 -- tailscale status
```

### Storage Issues

```bash
# Check disk usage
kubectl exec dev-ubuntu-0 -- df -h

# Check PVC status
kubectl get pvc -l app.kubernetes.io/name=dev-ubuntu
```

### Homebrew Issues

```bash
# Reinstall Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Fix permissions
sudo chown -R dev:dev /home/linuxbrew/.linuxbrew
```

## Security Considerations

- **Change default password** immediately after deployment
- **Configure SSH keys** instead of password authentication
- **Regular backups** of development work
- **Monitor Tailscale access** via admin console
- **Update packages** regularly for security patches

## Customization

### Adding SSH Keys

```bash
# Create SSH directory
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Add your public key
echo "your-public-key" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Disable password authentication (optional)
sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

### Custom ZSH Configuration

```bash
# Edit ZSH configuration
nano ~/.zshrc

# Add custom aliases
echo 'alias k="kubectl"' >> ~/.zshrc
echo 'alias ll="ls -la"' >> ~/.zshrc

# Reload configuration
source ~/.zshrc
```

## Maintenance

### Regular Updates

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Update Homebrew and packages
brew update && brew upgrade

# Clean up old packages
brew cleanup
sudo apt autoremove -y
```

### Monitoring

```bash
# Check resource usage
htop

# Check disk usage
df -h

# Check network connectivity
tailscale status
```
