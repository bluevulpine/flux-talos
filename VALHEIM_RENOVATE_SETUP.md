# Valheim Mod Updates with Renovate

## Overview

This document explains the custom Renovate configuration implemented to automatically track and update Valheim mods from Thunderstore.

## What Was Implemented

### 1. Custom Datasource: `thunderstore-valheim`

```json5
customDatasources: {
  'thunderstore-valheim': {
    defaultRegistryUrlTemplate: 'https://valheim.thunderstore.io/api/v1/package/',
    format: 'json',
    transformTemplates: [
      '{ "releases": $map($[full_name="{{packageName}}"].versions, function($v) { { "version": $v.version_number, "releaseTimestamp": $v.date_created } }) }',
    ],
  },
}
```

**How it works:**
- Queries the Thunderstore Valheim API for all packages
- Uses JSONata to transform the response into Renovate's expected format
- Finds packages by their `full_name` (e.g., "Advize-PlantEasily")
- Extracts version numbers and release timestamps

### 2. Custom Manager for MODS Environment Variable

```json5
{
  customType: 'regex',
  description: ['Process Valheim mods from Thunderstore'],
  managerFilePatterns: ['**/valheim/**/helmrelease.yaml'],
  matchStrings: ['^\\s+(?<depName>[^-]+-[^-]+)-(?<currentValue>[^\\s\\n]+)'],
  datasourceTemplate: 'custom.thunderstore-valheim',
  extractVersionTemplate: '^(?<version>.*)$',
}
```

**How it works:**
- Scans Valheim helmrelease.yaml files
- Uses regex to parse the MODS environment variable format
- Extracts dependency names (e.g., "Advize-PlantEasily") and current versions
- Links to the custom Thunderstore datasource

### 3. Package Rules for Valheim Mods

```json5
{
  matchDatasources: ['custom.thunderstore-valheim'],
  addLabels: ['renovate/valheim-mod'],
  groupName: 'Valheim mods',
  schedule: ['on saturday'],
}
```

**Benefits:**
- Groups all Valheim mod updates into a single PR
- Adds clear labeling for easy identification
- Schedules updates for Saturdays only (less disruptive)

## Current Valheim Mods Being Tracked

The following mods in your `kubernetes/apps/games/valheim/app/helmrelease.yaml` will now be tracked:

- `Advize-PlantEasily-2.0.3`
- `Advize-PlantEverything-1.19.1`
- `ValheimModding-Jotunn-2.26.1`
- `ValheimModding-HookGenPatcher-0.0.4`
- `Numenos-InfinityTools-1.0.0`
- `shudnal-ExtraSlots-1.0.33`
- `blacks7ar-OdinsHares-1.2.9`
- `ValheimModding-YamlDotNet-16.3.1`

## How Updates Will Work

1. **Weekly Schedule**: Renovate will check for mod updates every Saturday
2. **Grouped Updates**: All mod updates will be combined into a single PR titled "Update Valheim mods"
3. **Version Detection**: Renovate will detect when new versions are available on Thunderstore
4. **Automatic PRs**: PRs will be created with the updated mod versions
5. **Manual Review**: You can review and test the updates before merging

## Expected PR Format

When updates are available, you'll see PRs like:

```
Update Valheim mods

- Update Advize-PlantEasily from 2.0.3 to 2.0.4
- Update shudnal-ExtraSlots from 1.0.33 to 1.0.34
```

## Troubleshooting

### If Updates Don't Appear

1. **Check Renovate logs** for any API errors
2. **Verify mod names** match exactly with Thunderstore (case-sensitive)
3. **Confirm API accessibility** - Thunderstore API might have rate limits

### If Regex Doesn't Match

The regex pattern expects this exact format:
```yaml
MODS: |
  Author-ModName-Version
  AnotherAuthor-AnotherMod-Version
```

### Manual Testing

You can test the Thunderstore API manually:
```bash
curl "https://valheim.thunderstore.io/api/v1/package/" | jq '.[] | select(.full_name=="Advize-PlantEasily") | .versions[0]'
```

## Benefits of This Setup

1. **Automated Tracking**: No more manual checking for mod updates
2. **Grouped Updates**: All mods updated together for compatibility
3. **Scheduled Updates**: Updates happen on a predictable schedule
4. **Version Control**: All changes tracked in Git with proper commit messages
5. **Review Process**: You can test updates before applying them to your server

## Next Steps

1. Wait for the next Saturday for Renovate to run
2. Review any PRs that are created
3. Test mod updates in a staging environment if possible
4. Merge PRs when ready to update your Valheim server
