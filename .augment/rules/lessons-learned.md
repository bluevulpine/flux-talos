# Lessons Learned from Troubleshooting Sessions

## App-Template v4.4.0 Migration Issues

### The Problem
Multiple applications failed to upgrade to app-template v4.4.0 due to breaking schema changes that were not well documented.

### Root Cause
The serviceAccount configuration format completely changed between versions:
- **Old format**: `serviceAccount: {create: true, name: "myapp"}`
- **New format**: `serviceAccount: {myapp: {enabled: true}}`

### Key Lesson
**ALWAYS check the official schema when upgrading chart versions**, especially for major version bumps. Don't rely on examples from other repositories or documentation that might be outdated.

### Solution Process
1. **Identified the pattern**: Multiple apps failing with similar schema validation errors
2. **Found working example**: vector-agent was working, but investigation showed it might have been deployed before the breaking change
3. **Checked official schema**: Used `web-fetch` to get the actual schema from upstream
4. **Applied correct format**: Fixed all affected applications

### Prevention
- Add schema validation to CI/CD pipeline
- Create upgrade checklists for major chart version changes
- Maintain a test environment for validating changes

## Valheim Backup Storage Crisis

### The Problem
Valheim server was in CrashLoopBackOff due to "No space left on device" during backup operations.

### Root Cause Analysis
1. **Backup frequency too high**: Every 15 minutes was excessive
2. **Insufficient storage**: 30Gi was not enough for game data + backups
3. **Cleanup not working**: Old backups weren't being removed properly

### Solution Applied
1. **Increased storage**: Expanded PVC from 30Gi to 50Gi using Longhorn's volume expansion
2. **Optimized backup schedule**: Reduced frequency from every 15 minutes to every 2 hours
3. **Improved retention**: Reduced retention from 3 days to 2 days
4. **Verified cleanup**: Ensured `AUTO_BACKUP_REMOVE_OLD: 1` was working

### Key Lessons
- **Monitor storage usage**: Set up alerts for PVC usage > 80%
- **Balance backup frequency vs storage**: More frequent != better if it causes outages
- **Test backup cleanup**: Verify that old backups are actually being removed
- **Plan for growth**: Game servers can generate large amounts of data quickly

## RBAC and ServiceAccount Confusion

### The Problem
Gatus init containers were failing with 403 Forbidden errors when trying to list ConfigMaps across all namespaces.

### Root Cause
The ServiceAccount configuration wasn't working due to schema changes, causing pods to use the `default` ServiceAccount which lacked necessary permissions.

### Investigation Process
1. **Checked pod ServiceAccount**: Confirmed it was using `default` instead of `gatus`
2. **Verified RBAC exists**: ClusterRole and ClusterRoleBinding were correctly configured
3. **Identified schema issue**: ServiceAccount wasn't being created due to format error
4. **Fixed schema format**: Applied correct app-template v4.4.0 format

### Key Lessons
- **RBAC debugging sequence**: Check ServiceAccount → ClusterRole → ClusterRoleBinding
- **Verify actual pod configuration**: Don't assume configuration is applied correctly
- **Test RBAC changes**: Use `kubectl auth can-i` to verify permissions
- **Document RBAC requirements**: Clearly document why specific permissions are needed

## Schema Validation Best Practices

### What We Learned
1. **Official sources are authoritative**: Always check upstream schemas, not examples
2. **Version-specific changes**: Breaking changes often happen in major version bumps
3. **Working examples can be misleading**: They might have been deployed before breaking changes
4. **Schema evolution**: Chart maintainers can make significant format changes

### Recommended Approach
1. **Identify exact versions**: Check OCIRepository or chart version in use
2. **Fetch official schema**: Use direct URLs to schema files
3. **Compare systematically**: Use diff tools to compare old vs new format
4. **Test incrementally**: Apply changes to one application first
5. **Document changes**: Record what changed and why for future reference

## Debugging Methodology Improvements

### What Worked Well
1. **Systematic approach**: Following a consistent debugging sequence
2. **Pattern recognition**: Identifying similar failures across multiple applications
3. **Official documentation**: Checking upstream sources for authoritative information
4. **Incremental fixes**: Making small, testable changes

### What Could Be Improved
1. **Earlier schema validation**: Should have checked schemas before assuming format
2. **Better monitoring**: Storage alerts could have prevented the Valheim crisis
3. **Documentation**: Need better internal docs on chart upgrade procedures
4. **Testing**: Need staging environment for validating major changes

## Repository-Specific Patterns

### Successful Patterns
- **Consistent naming**: Using `&app` references throughout HelmRelease
- **Component reuse**: VolSync and Gatus components work well
- **External Secrets**: Bitwarden integration is reliable
- **Monitoring**: Gatus provides good visibility into service health

### Areas for Improvement
- **Storage monitoring**: Need better alerts for PVC usage
- **Backup validation**: Need to verify backup integrity, not just creation
- **Resource limits**: Some applications need better resource management
- **Documentation**: Need better runbooks for common operations

## Future Prevention Strategies

### Proactive Measures
1. **Schema validation in CI**: Add automated schema checking
2. **Staging environment**: Test changes before production
3. **Monitoring improvements**: Better alerts for storage, RBAC, and application health
4. **Documentation**: Maintain upgrade guides and troubleshooting runbooks

### Reactive Improvements
1. **Faster debugging**: Use these lessons to debug similar issues more quickly
2. **Better rollback procedures**: Document how to quickly revert problematic changes
3. **Communication**: Better alerts and notifications for service disruptions

---

**Key Takeaway**: The combination of checking official schemas and finding working examples in the same repository is the most reliable troubleshooting approach. When these two sources conflict, always trust the official schema and investigate why the working example might be outdated or deployed differently.
