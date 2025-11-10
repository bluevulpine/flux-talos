# Ubuntu Development Pod

A persistent Ubuntu development environment with SSH access via Tailscale network, providing a full-featured development workspace in Kubernetes.

## ✅ **Deployment Status: SUCCESSFUL**

The Ubuntu development pod is successfully deployed and ready for use!

## 🎯 **Features**

- **LinuxServer OpenSSH Server** - Reliable SSH access with user management
- **Persistent Storage** - 50GB persistent volume for development work
- **Tailscale Integration** - Network access via Tailscale annotations
- **Development Ready** - Ubuntu base with development tools support
- **Secure Access** - SSH with password/key authentication
- **GitOps Managed** - Deployed and managed via Flux

## 🏗️ **Architecture**

- **StatefulSet**: Ensures stable network identity and persistent storage
- **Tailscale Integration**: Uses Tailscale operator annotations for network access
- **Persistent Volume**: 50GB openebs-hostpath storage
- **Security**: Configured user with sudo privileges
- **Service**: ClusterIP service for internal access

## 📋 **Connection Information**

### **Pod Details**
- **Pod Name**: `dev-ubuntu-0`
- **Namespace**: `default`
- **SSH Port**: `2222`
- **Username**: `dev`
- **Default Password**: `dev` (⚠️ **Change immediately after first login**)

### **Access Methods**

#### **1. Port Forward (Immediate Access)**
```bash
# Forward local port to pod SSH
kubectl port-forward -n default dev-ubuntu-0 2222:2222

# SSH via port forward
ssh dev@localhost -p 2222
# Password: dev
```

#### **2. Tailscale Access (Once Configured)**
```bash
# Check Tailscale admin console for device named "dev-ubuntu"
# SSH directly via Tailscale IP
ssh dev@<tailscale-ip> -p 2222
```

## 🚀 **Quick Start Guide**

### **1. Verify Deployment**
```bash
# Check pod status
kubectl get pods -n default dev-ubuntu-0

# Check persistent volume
kubectl get pvc -n default

# View pod logs
kubectl logs -n default dev-ubuntu-0
```

### **2. First Connection**
```bash
# Start port forwarding
kubectl port-forward -n default dev-ubuntu-0 2222:2222 &

# Connect via SSH
ssh dev@localhost -p 2222
# Enter password: dev
```

### **3. Initial Security Setup**
```bash
# IMMEDIATELY change the default password
passwd

# Update system packages
sudo apt update && sudo apt upgrade -y
```

## 🔧 **Development Environment Setup**

### **Install ZSH and Oh My Zsh**
```bash
# Install ZSH
sudo apt install zsh -y

# Install Oh My Zsh
sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

# Set ZSH as default shell
sudo chsh -s /bin/zsh dev

# Configure theme (edit ~/.zshrc)
sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="agnoster"/' ~/.zshrc
```

### **Install Homebrew**
```bash
# Install Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Add to shell profile
echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> ~/.zshrc
source ~/.zshrc

# Verify installation
brew --version
```

### **Essential Development Tools**
```bash
# Install core development tools
brew install \
  git \
  curl \
  wget \
  jq \
  yq \
  kubectl \
  helm \
  gh

# Install programming languages
brew install \
  node \
  python \
  go \
  rust

# Install modern CLI tools
brew install \
  fzf \
  ripgrep \
  bat \
  exa \
  fd \
  delta \
  lazygit \
  neovim

# Configure Git
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

## 📁 **Storage and Persistence**

### **Storage Configuration**
- **Volume Size**: 50GB
- **Storage Class**: `openebs-hostpath`
- **Mount Path**: `/home/dev` (user home directory)
- **Persistence**: All files in `/home/dev` persist across pod restarts

### **Directory Structure**
```
/home/dev/              # User home directory (persistent)
├── .zshrc              # ZSH configuration
├── .oh-my-zsh/         # Oh My Zsh installation
├── .gitconfig          # Git configuration
├── .ssh/               # SSH keys and config
├── projects/           # Development projects
├── backups/            # Environment backups
└── .local/             # Local binaries and data
```

### **Resource Allocation**
- **CPU**: 500m request, 2000m limit
- **Memory**: 1Gi request, 4Gi limit
- **Storage**: 50Gi persistent volume
- **Network**: Tailscale integration for external access

## 🔄 **Development Workflow**

### **Project Management**
```bash
# Create project directory
mkdir -p ~/projects/my-project
cd ~/projects/my-project

# Initialize git repository
git init

# Start development work
# All files are automatically persistent
```

### **Package Management**
```bash
# System packages via apt
sudo apt update && sudo apt install <package>

# Development tools via Homebrew (recommended)
brew install <package>

# Language-specific package managers
npm install <package>          # Node.js
pip install <package>           # Python
cargo install <package>         # Rust
go install <package>            # Go
```

### **Environment Backup**
```bash
# Create manual backup
tar -czf ~/backups/dev-env-$(date +%Y%m%d).tar.gz \
  ~/.zshrc \
  ~/.gitconfig \
  ~/.ssh/ \
  ~/projects/

# Automated backup script (create as needed)
cat > ~/backup.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="$HOME/backups/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp ~/.zshrc ~/.gitconfig "$BACKUP_DIR/"
tar -czf "$HOME/backups/dev-env-$(date +%Y%m%d_%H%M%S).tar.gz" -C "$BACKUP_DIR" .
echo "Backup created: $HOME/backups/dev-env-$(date +%Y%m%d_%H%M%S).tar.gz"
EOF
chmod +x ~/backup.sh
```

## 🔧 **Troubleshooting**

### **SSH Connection Issues**
```bash
# Check pod status
kubectl get pods -n default dev-ubuntu-0

# Check SSH service in pod
kubectl exec -n default dev-ubuntu-0 -- ps aux | grep sshd

# Test port forwarding
kubectl port-forward -n default dev-ubuntu-0 2222:2222 &
telnet localhost 2222

# Check pod logs
kubectl logs -n default dev-ubuntu-0 --tail=20
```

### **Tailscale Issues**
```bash
# Check Tailscale operator
kubectl get pods -n network | grep tailscale

# Check pod annotations
kubectl get pod -n default dev-ubuntu-0 -o yaml | grep tailscale

# Check Tailscale admin console
# Look for device named "dev-ubuntu" with tag "k8s"
```

### **Storage Issues**
```bash
# Check disk usage
kubectl exec -n default dev-ubuntu-0 -- df -h

# Check PVC status
kubectl get pvc -n default

# Check storage class
kubectl get storageclass
```

### **Pod Issues**
```bash
# Check pod events
kubectl describe pod -n default dev-ubuntu-0

# Restart pod if needed
kubectl delete pod -n default dev-ubuntu-0
# StatefulSet will recreate it automatically

# Check resource usage
kubectl top pod -n default dev-ubuntu-0
```

## 🔒 **Security Best Practices**

### **Immediate Security Steps**
```bash
# 1. Change default password (CRITICAL)
passwd

# 2. Create SSH key pair
ssh-keygen -t ed25519 -C "your.email@example.com"

# 3. Add SSH key to authorized_keys
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
chmod 700 ~/.ssh

# 4. Disable password authentication (optional)
# Note: Only do this after confirming SSH key access works
```

### **SSH Key Configuration**
```bash
# Generate SSH key
ssh-keygen -t ed25519 -C "dev-ubuntu-key"

# Copy public key to your local machine
kubectl exec -n default dev-ubuntu-0 -- cat /home/dev/.ssh/id_ed25519.pub

# Add your local public key to the pod
echo "your-local-public-key" | kubectl exec -i -n default dev-ubuntu-0 -- tee -a /home/dev/.ssh/authorized_keys
```

### **Regular Maintenance**
```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Update Homebrew and packages
brew update && brew upgrade

# Clean up old packages
brew cleanup
sudo apt autoremove -y

# Check security updates
sudo apt list --upgradable
```

## 📊 **Monitoring and Maintenance**

### **Resource Monitoring**
```bash
# Check resource usage
kubectl top pod -n default dev-ubuntu-0

# Check disk usage inside pod
kubectl exec -n default dev-ubuntu-0 -- df -h

# Monitor pod logs
kubectl logs -n default dev-ubuntu-0 -f
```

### **Health Checks**
```bash
# Verify SSH is running
kubectl exec -n default dev-ubuntu-0 -- ps aux | grep sshd

# Test SSH connectivity
kubectl port-forward -n default dev-ubuntu-0 2222:2222 &
ssh dev@localhost -p 2222 "echo 'SSH working'"

# Check Tailscale status
kubectl describe pod -n default dev-ubuntu-0 | grep tailscale
```

## 🚀 **Advanced Usage**

### **Custom Development Environment**
```bash
# Install additional development tools
brew install \
  terraform \
  ansible \
  docker \
  docker-compose \
  minikube

# Install language-specific tools
brew install \
  nvm \
  pyenv \
  rbenv

# Configure development environment
echo 'export EDITOR=nvim' >> ~/.zshrc
echo 'alias k=kubectl' >> ~/.zshrc
echo 'alias ll="exa -la"' >> ~/.zshrc
```

### **Integration with Local Development**
```bash
# Mount local code via kubectl cp
kubectl cp ./local-project dev-ubuntu-0:/home/dev/projects/

# Sync files using rsync (via port forward)
kubectl port-forward -n default dev-ubuntu-0 2222:2222 &
rsync -avz -e "ssh -p 2222" ./local-project/ dev@localhost:/home/dev/projects/
```

## 📋 **Technical Specifications**

### **Container Configuration**
- **Base Image**: `lscr.io/linuxserver/openssh-server:latest`
- **User**: `dev` (UID 1000, GID 1000)
- **SSH Port**: `2222`
- **Security Context**: Non-privileged with sudo access

### **Kubernetes Resources**
- **Type**: StatefulSet
- **Replicas**: 1
- **Service**: ClusterIP on port 2222
- **Storage**: 50Gi PVC with openebs-hostpath
- **Namespace**: default

### **Network Configuration**
- **Tailscale Annotations**:
  - `tailscale.com/expose: "true"`
  - `tailscale.com/hostname: "dev-ubuntu"`
  - `tailscale.com/tags: "tag:k8s"`

## 🎯 **Next Steps**

1. **✅ Connect**: Use port forwarding for immediate access
2. **🔒 Secure**: Change default password and set up SSH keys
3. **🛠️ Customize**: Install your preferred development tools
4. **🌐 Network**: Configure Tailscale for direct access
5. **💾 Backup**: Set up regular backups of your work
6. **🚀 Develop**: Start your development projects

---

**Your persistent Ubuntu development environment is ready!** 🎉

This pod provides a full-featured development workspace with persistent storage, secure SSH access, and network connectivity via Tailscale. All your development work, configurations, and installed tools will persist across pod restarts.
