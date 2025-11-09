# Kubernetes/Flux Repository Rules & Guidelines

## Environment & Platform Considerations

### Current Environment
- **OS**: Linux
- **Shell**: bash
- **Package Manager**: Homebrew (installed at `/home/linuxbrew/.linuxbrew/`)
- **kubectl**: Available via `eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && kubectl`

### Cross-Platform Command Variations

#### Homebrew Paths
- **Linux**: `/home/linuxbrew/.linuxbrew/bin/brew`
- **macOS**: `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`

#### Shell Environment Setup
```bash
# Linux (current environment)
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# macOS
eval "$(/opt/homebrew/bin/brew shellenv)"  # Apple Silicon
eval "$(/usr/local/bin/brew shellenv)"     # Intel
```

#### Common Command Patterns
```bash
# Always use full brew path in this environment
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && kubectl get pods

# Alternative for repeated commands
export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
kubectl get pods
```

## Schema Validation Requirements

### Critical Rule: Always Check Official Schemas
**NEVER guess schema formats. Always reference official sources.**

### Key Schema Sources for This Repository

#### App-Template Chart (bjw-s)
- **Values Schema**: `https://raw.githubusercontent.com/bjw-s-labs/helm-charts/common-{VERSION}/charts/library/common/values.schema.json`
- **HelmRelease Schema**: `https://raw.githubusercontent.com/bjw-s/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2beta2.schema.json`
- **Current Version**: 4.4.0 (check OCIRepository tags for updates)

#### Flux Schemas
- **HelmRelease**: `https://kubernetes-schemas.pages.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json`
- **Kustomization**: `https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json`

#### Kubernetes Schemas
- **General**: `https://kubernetes-schemas.pages.dev/`
- **CRDs**: Check specific operator documentation

### Schema Validation Process
1. **Identify the resource type and version**
2. **Fetch the official schema from upstream**
3. **Compare current configuration against schema**
4. **Look for working examples in the same repository**
5. **Test changes incrementally**

## Repository-Specific Best Practices

### Kubernetes Manifest Troubleshooting

#### Standard Debugging Sequence
1. **Check HelmRelease status**: `kubectl get helmrelease -A`
2. **Describe failing resources**: `kubectl describe helmrelease <name> -n <namespace>`
3. **Check pod status**: `kubectl get pods -n <namespace> -l app.kubernetes.io/instance=<name>`
4. **Review logs**: `kubectl logs -n <namespace> <pod-name> -c <container>`
5. **Validate YAML syntax**: Use `yamllint` or similar tools

#### Common Failure Patterns
- **Schema validation errors**: Check official schemas (see above)
- **RBAC issues**: Verify ServiceAccount, ClusterRole, ClusterRoleBinding
- **Resource conflicts**: Check for duplicate names, immutable fields
- **Storage issues**: Verify PVC status, storage class availability

### Helm Chart Upgrade Procedures

#### App-Template Specific Gotchas
- **v4.4.0 Breaking Changes**:
  - ServiceAccount format changed from `{create: true, name: "name"}` to `{name: {enabled: true}}`
  - Controller type must be explicitly specified: `type: deployment`
  - Some pod-level configurations moved or became restricted

#### Safe Upgrade Process
1. **Check current chart version**: `kubectl get helmrelease <name> -o yaml | grep chartVersion`
2. **Review upstream changelog**: Check GitHub releases for breaking changes
3. **Find working examples**: Look for similar apps already using the target version
4. **Test in staging**: If available, test changes in non-production environment
5. **Backup critical data**: Ensure backups are current before major upgrades
6. **Monitor during rollout**: Watch pod status and logs during upgrade

### FluxCD Reconciliation Patterns

#### Force Reconciliation
```bash
# HelmRelease
kubectl annotate helmrelease <name> -n <namespace> reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# Kustomization  
kubectl annotate kustomization <name> -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

#### Debugging Flux Issues
1. **Check Flux system health**: `flux check`
2. **Review source status**: `kubectl get gitrepository,ocirepository -A`
3. **Check reconciliation status**: `flux get all`
4. **Review Flux logs**: `kubectl logs -n flux-system -l app=source-controller`

### Git Workflow Patterns

#### Commit Message Format
- **fix**: Bug fixes, schema corrections, immediate issues
- **feat**: New applications, features, enhancements  
- **chore**: Maintenance, updates, cleanup
- **docs**: Documentation updates

#### Change Validation Process
1. **Validate YAML syntax**: `yamllint kubernetes/`
2. **Check for secrets**: Ensure no sensitive data in commits
3. **Test locally**: Use `kubectl --dry-run=client` when possible
4. **Incremental changes**: Make small, focused commits
5. **Monitor after push**: Watch Flux reconciliation after pushing

## Tool Usage Guidelines

### kubectl vs flux Commands

#### Use kubectl for:
- **Resource inspection**: `kubectl get`, `kubectl describe`
- **Debugging**: `kubectl logs`, `kubectl exec`
- **Manual operations**: `kubectl delete`, `kubectl patch`
- **Status checking**: `kubectl get helmrelease`, `kubectl get pods`

#### Use flux for:
- **System health**: `flux check`
- **Reconciliation**: `flux reconcile`
- **Source management**: `flux get sources`
- **Suspension**: `flux suspend`, `flux resume`

### HelmRelease Debugging Sequence

#### Step-by-Step Process
1. **Check HelmRelease status**:
   ```bash
   kubectl get helmrelease <name> -n <namespace>
   ```

2. **Get detailed error information**:
   ```bash
   kubectl describe helmrelease <name> -n <namespace> | grep -A 15 "Message:"
   ```

3. **Check for stuck deployments**:
   ```bash
   kubectl get deployment <name> -n <namespace>
   kubectl get pods -n <namespace> -l app.kubernetes.io/instance=<name>
   ```

4. **Review pod logs for application issues**:
   ```bash
   kubectl logs -n <namespace> <pod-name> -c <container-name>
   ```

5. **Force cleanup if needed**:
   ```bash
   kubectl delete deployment <name> -n <namespace>  # If immutable field issues
   kubectl annotate helmrelease <name> -n <namespace> reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
   ```

### YAML Validation Before Committing

#### Pre-commit Checks
```bash
# Syntax validation
yamllint kubernetes/

# Kubernetes resource validation (dry-run)
kubectl apply --dry-run=client -f kubernetes/apps/path/to/resource.yaml

# Check for common issues
grep -r "TODO\|FIXME\|XXX" kubernetes/
```

## Common Gotchas & Lessons Learned

### App-Template Chart Issues

#### Version Compatibility Matrix
- **v3.x**: Legacy format, avoid for new deployments
- **v4.0-4.3**: Transitional versions, some breaking changes
- **v4.4.0+**: Current stable, new schema format required

#### ServiceAccount Configuration Evolution
```yaml
# OLD FORMAT (pre-v4.4.0) - DO NOT USE
serviceAccount:
  create: true
  name: myapp

# NEW FORMAT (v4.4.0+) - CORRECT
serviceAccount:
  myapp:
    enabled: true
```

#### Controller Type Requirement
```yaml
# REQUIRED in v4.4.0+
controllers:
  myapp:
    type: deployment  # Must be explicitly specified
    # ... rest of configuration
```

### Storage and Backup Issues

#### Valheim-Specific Lessons
- **Backup frequency**: Every 15 minutes was too aggressive, caused disk space issues
- **Storage sizing**: 30Gi insufficient for game data + backups, increased to 50Gi
- **Cleanup configuration**: `AUTO_BACKUP_REMOVE_OLD: 1` and `AUTO_BACKUP_DAYS_TO_LIVE: 2` essential

#### General Storage Best Practices
- **Monitor disk usage**: Set up alerts for PVC usage > 80%
- **Backup retention**: Balance between safety and storage costs
- **Volume expansion**: Verify storage class supports `allowVolumeExpansion: true`

### RBAC and Security

#### ServiceAccount Best Practices
- **Principle of least privilege**: Only grant necessary permissions
- **Namespace isolation**: Use namespaced roles when possible
- **Regular audits**: Review ClusterRoles and ClusterRoleBindings periodically

#### Common RBAC Issues
- **Missing ServiceAccount**: Pods default to `default` ServiceAccount
- **Incorrect namespace**: ClusterRoleBinding subjects must specify correct namespace
- **Overly broad permissions**: Avoid `cluster-admin` unless absolutely necessary

### Debugging Methodology

#### Always Start With Working Examples
1. **Find similar working apps** in the repository
2. **Compare configurations** side-by-side
3. **Identify differences** systematically
4. **Apply changes incrementally**
5. **Test each change** before proceeding

#### Schema-First Approach
1. **Identify the exact version** of charts/operators in use
2. **Fetch official schemas** from upstream sources
3. **Validate configuration** against schema
4. **Check for version-specific breaking changes**
5. **Reference official documentation** for migration guides

## Emergency Procedures

### Cluster Recovery
- **Flux system issues**: Check `flux-system` namespace health first
- **Storage problems**: Verify Longhorn/OpenEBS status
- **Network issues**: Check Cilium and CoreDNS status
- **Certificate problems**: Verify cert-manager and certificates

### Rollback Procedures
```bash
# HelmRelease rollback
kubectl patch helmrelease <name> -n <namespace> --type='merge' -p='{"spec":{"suspend":true}}'
# Manual intervention, then resume
kubectl patch helmrelease <name> -n <namespace> --type='merge' -p='{"spec":{"suspend":false}}'

# Git-based rollback
git revert <commit-hash>
git push origin main
```

## Repository Structure & Patterns

### Directory Organization
```
kubernetes/
├── apps/                    # Application deployments
│   ├── games/              # Game servers (valheim, satisfactory)
│   ├── observability/      # Monitoring (gatus, vector, grafana)
│   ├── media/              # Media services (plex, tautulli)
│   └── infrastructure/     # Core services (smtp-relay)
├── bootstrap/              # Initial cluster setup
├── components/             # Reusable kustomize components
│   ├── volsync/           # Backup/restore patterns
│   └── gatus-guarded/     # Monitoring patterns
├── flux/                   # Flux system configuration
└── templates/              # Reusable templates
```

### Common File Patterns
- **HelmRelease**: `helmrelease.yaml`
- **Kustomization**: `kustomization.yaml`
- **External Secrets**: `externalsecret.yaml`
- **RBAC**: `rbac.yaml`
- **Storage**: `pvc.yaml`
- **Networking**: `httproute.yaml`, `dnsendpoint.yaml`

### Naming Conventions
- **Resources**: Use app name consistently across all resources
- **Namespaces**: Group by function (games, observability, media, etc.)
- **Labels**: Include `app.kubernetes.io/name` and `app.kubernetes.io/instance`

## Specific Technology Patterns

### App-Template (bjw-s) Usage Patterns

#### Standard Application Structure
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: &app myapp
spec:
  chartRef:
    kind: OCIRepository
    name: myapp
  values:
    controllers:
      myapp:
        type: deployment
        annotations:
          reloader.stakater.com/auto: "true"
        containers:
          app:
            image:
              repository: ghcr.io/example/myapp
              tag: v1.0.0
            env:
              TZ: "${TIMEZONE}"
            probes:
              liveness: &probes
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /health
                    port: 80
              readiness: *probes
    service:
      app:
        controller: myapp
        ports:
          http:
            port: 80
    persistence:
      config:
        existingClaim: *app
        globalMounts:
          - path: /config
```

#### Common Patterns by App Type

##### Web Applications
- **Probes**: Always include liveness/readiness probes
- **Service**: Use consistent port naming (http, https)
- **Ingress**: Use HTTPRoute for Gateway API
- **Persistence**: Separate config and data volumes

##### Game Servers
- **Service Type**: LoadBalancer with external IP
- **Persistence**: Large storage for game data and backups
- **Resources**: Higher CPU/memory limits
- **Networking**: UDP ports for game traffic

##### Monitoring/Observability
- **ServiceMonitor**: Include Prometheus scraping config
- **RBAC**: Often needs cluster-wide permissions
- **Persistence**: Time-series data storage considerations

### VolSync Backup Patterns

#### Standard VolSync Setup
```yaml
# In ks.yaml
postBuild:
  substitute:
    VOLSYNC_CAPACITY: 30Gi
    VOLSYNC_STORAGECLASS: longhorn
    VOLSYNC_SNAPSHOTCLASS: longhorn-snapclass

# In kustomization.yaml
components:
  - ../../../../components/volsync
```

#### Backup Schedule Considerations
- **Frequency**: Balance between data protection and storage costs
- **Retention**: Configure appropriate retention policies
- **Storage**: Ensure sufficient space for snapshots

### External Secrets Patterns

#### Bitwarden Integration
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: &name myapp-secret
spec:
  secretStoreRef:
    name: bitwarden-secrets-manager
    kind: ClusterSecretStore
  target:
    name: *name
    template:
      engineVersion: v2
      data:
        USERNAME: "{{ .MyApp__Username }}"
        PASSWORD: "{{ .MyApp__Password }}"
  dataFrom:
    - extract:
        key: myapp
```

## Troubleshooting Decision Trees

### HelmRelease Failure Decision Tree

```
HelmRelease Failed
├── Schema Validation Error?
│   ├── Yes → Check official schema, compare with working examples
│   └── No → Continue
├── Resource Already Exists?
│   ├── Yes → Check for immutable field changes, delete deployment if needed
│   └── No → Continue
├── RBAC/Permission Error?
│   ├── Yes → Verify ServiceAccount, ClusterRole, ClusterRoleBinding
│   └── No → Continue
├── Storage/PVC Issues?
│   ├── Yes → Check PVC status, storage class, available space
│   └── No → Continue
├── Image Pull Issues?
│   ├── Yes → Verify image tag, registry access, pull secrets
│   └── No → Continue
└── Application-Specific Issues
    └── Check application logs, configuration, dependencies
```

### Pod CrashLoopBackOff Decision Tree

```
Pod CrashLoopBackOff
├── Init Container Failure?
│   ├── Yes → Check init container logs, dependencies, permissions
│   └── No → Continue
├── Main Container Failure?
│   ├── Yes → Check application logs, configuration, environment variables
│   └── No → Continue
├── Resource Limits?
│   ├── Yes → Check memory/CPU limits vs usage
│   └── No → Continue
├── Storage Issues?
│   ├── Yes → Check PVC mounts, permissions, available space
│   └── No → Continue
└── Network/Service Issues
    └── Check service discovery, DNS, network policies
```

## Performance & Optimization

### Resource Management
- **Requests vs Limits**: Set appropriate requests for scheduling, limits for protection
- **QoS Classes**: Understand Guaranteed, Burstable, BestEffort
- **Node Affinity**: Use for specific hardware requirements

### Storage Optimization
- **Storage Classes**: Choose appropriate class for workload (fast SSD vs bulk storage)
- **Volume Expansion**: Plan for growth, verify expansion support
- **Backup Strategy**: Balance frequency, retention, and storage costs

### Network Optimization
- **Service Types**: ClusterIP for internal, LoadBalancer for external access
- **Ingress vs Gateway API**: Prefer Gateway API (HTTPRoute) for new deployments
- **DNS**: Use short names within namespace, FQDN across namespaces

## Security Best Practices

### RBAC Guidelines
- **Least Privilege**: Grant minimum necessary permissions
- **Namespace Isolation**: Use Role instead of ClusterRole when possible
- **Service Accounts**: Create dedicated ServiceAccounts for applications
- **Regular Audits**: Review and clean up unused RBAC resources

### Secret Management
- **External Secrets**: Use External Secrets Operator for all sensitive data
- **Secret Rotation**: Implement regular rotation for long-lived secrets
- **Access Control**: Limit secret access to necessary pods only
- **Encryption**: Ensure secrets are encrypted at rest and in transit

### Network Security
- **Network Policies**: Implement default-deny policies where appropriate
- **TLS**: Use TLS for all external communications
- **Service Mesh**: Consider for complex microservice communications
- **Ingress Security**: Implement proper authentication and authorization

## Monitoring & Alerting

### Key Metrics to Monitor
- **Cluster Health**: Node status, resource utilization
- **Application Health**: Pod status, restart counts, response times
- **Storage**: PVC usage, backup success/failure
- **Network**: Service availability, ingress response times

### Alert Thresholds
- **Pod Restarts**: > 5 restarts in 10 minutes
- **Storage Usage**: > 80% PVC utilization
- **Memory Usage**: > 90% of limits
- **Failed Backups**: Any backup failure

### Gatus Monitoring Patterns
```yaml
# In configmap with label gatus.io/enabled: "true"
endpoints:
  - name: "myapp"
    group: "production"
    url: "https://myapp.example.com"
    interval: 1m
    conditions:
      - "[STATUS] == 200"
      - "[RESPONSE_TIME] < 1000"
    alerts:
      - type: pushover
```

---

**Remember**: When in doubt, check the official schemas and look for working examples in this repository. The combination of schema validation and pattern matching from existing configurations is the most reliable approach to troubleshooting issues in this environment.

**Key Success Factors**:
1. **Schema-first approach**: Always validate against official schemas
2. **Pattern matching**: Use working examples as templates
3. **Incremental changes**: Make small, testable modifications
4. **Comprehensive monitoring**: Set up proper observability from the start
5. **Documentation**: Keep this guide updated with new learnings
