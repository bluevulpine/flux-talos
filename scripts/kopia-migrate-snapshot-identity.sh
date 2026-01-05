#!/usr/bin/env bash
#
# kopia-migrate-snapshot-identity.sh
#
# Migrates Kopia snapshot history from old naming convention to unified naming.
# Old: app-local@namespace or app-r2@namespace
# New: app@namespace
#
# This script uses 'kopia snapshot move-history' to rename snapshot sources.
# Data is NOT duplicated - only the snapshot manifest metadata is updated.
#
# Prerequisites:
# - kopia CLI installed
# - Repository already connected (or use --connect flag)
#
# Usage:
#   ./kopia-migrate-snapshot-identity.sh [options]
#
# Options:
#   --dry-run         Show what would be done without making changes
#   --connect-local   Connect to local repository before running
#   --connect-r2      Connect to R2 repository before running
#   --suffix SUFFIX   Suffix to remove (default: both -local and -r2)
#   --help            Show this help message
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

DRY_RUN=false
SUFFIX_FILTER=""

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

show_help() {
    head -30 "$0" | grep "^#" | sed 's/^# \?//'
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --connect-local)
            log_info "Connecting to local repository..."
            # User needs to provide these or source from environment
            if [[ -z "${KOPIA_LOCAL_ENDPOINT:-}" ]]; then
                log_error "KOPIA_LOCAL_ENDPOINT not set"
                exit 1
            fi
            kopia repository connect s3 \
                --endpoint="${KOPIA_LOCAL_ENDPOINT}" \
                --bucket="${KOPIA_LOCAL_BUCKET:-volsync}" \
                --access-key="${KOPIA_LOCAL_ACCESS_KEY}" \
                --secret-access-key="${KOPIA_LOCAL_SECRET_KEY}" \
                --password="${KOPIA_PASSWORD}" \
                --disable-tls
            shift
            ;;
        --connect-r2)
            log_info "Connecting to R2 repository..."
            if [[ -z "${KOPIA_R2_ENDPOINT:-}" ]]; then
                log_error "KOPIA_R2_ENDPOINT not set"
                exit 1
            fi
            kopia repository connect s3 \
                --endpoint="${KOPIA_R2_ENDPOINT}" \
                --bucket="${KOPIA_R2_BUCKET:-volsync}" \
                --access-key="${KOPIA_R2_ACCESS_KEY}" \
                --secret-access-key="${KOPIA_R2_SECRET_KEY}" \
                --password="${KOPIA_PASSWORD}"
            shift
            ;;
        --suffix)
            SUFFIX_FILTER="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            ;;
    esac
done

log_info "Listing current snapshot sources..."
echo ""

# Get all snapshot sources
SOURCES=$(kopia snapshot list --all --json 2>/dev/null | jq -r '.[].source | "\(.userName)@\(.host)"' | sort -u)

if [[ -z "$SOURCES" ]]; then
    log_warn "No snapshots found in repository"
    exit 0
fi

log_info "Found snapshot sources:"
echo "$SOURCES" | while read -r source; do
    echo "  - $source"
done
echo ""

# Find sources that need migration
MIGRATIONS=()
while IFS= read -r source; do
    username="${source%@*}"
    hostname="${source#*@}"
    
    # Check if username ends with -local or -r2
    if [[ "$username" =~ -local$ ]] || [[ "$username" =~ -r2$ ]]; then
        if [[ -n "$SUFFIX_FILTER" ]]; then
            # Only process specific suffix
            if [[ "$username" =~ ${SUFFIX_FILTER}$ ]]; then
                MIGRATIONS+=("$source")
            fi
        else
            MIGRATIONS+=("$source")
        fi
    fi
done <<< "$SOURCES"

if [[ ${#MIGRATIONS[@]} -eq 0 ]]; then
    log_info "No snapshots need migration - all sources already use unified naming"
    exit 0
fi

log_info "Snapshots to migrate:"
for source in "${MIGRATIONS[@]}"; do
    username="${source%@*}"
    hostname="${source#*@}"
    # Remove -local or -r2 suffix
    new_username="${username%-local}"
    new_username="${new_username%-r2}"
    echo "  $source -> ${new_username}@${hostname}"
done
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "Dry run mode - no changes will be made"
    exit 0
fi

# Confirm before proceeding
read -p "Proceed with migration? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Migration cancelled"
    exit 0
fi

# Perform migrations
for source in "${MIGRATIONS[@]}"; do
    username="${source%@*}"
    hostname="${source#*@}"
    new_username="${username%-local}"
    new_username="${new_username%-r2}"
    new_source="${new_username}@${hostname}"
    
    log_info "Migrating: $source -> $new_source"
    if kopia snapshot move-history "$source" "$new_source"; then
        log_info "  ✓ Success"
    else
        log_error "  ✗ Failed to migrate $source"
    fi
done

echo ""
log_info "Migration complete! New snapshot sources:"
kopia snapshot list --all --json 2>/dev/null | jq -r '.[].source | "\(.userName)@\(.host)"' | sort -u | while read -r source; do
    echo "  - $source"
done

