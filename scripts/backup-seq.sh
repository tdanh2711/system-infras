#!/bin/bash
# =============================================================================
# Seq Backup Script
# =============================================================================
# Backs up Seq data directory to a timestamped zip file
# Usage: ./backup-seq.sh [--keep N]
#   --keep N  Keep only N most recent backups (default: 7)
# =============================================================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SEQ_DATA_DIR="$PROJECT_ROOT/logging/seq/data"
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_ROOT/backups/seq}"
KEEP_COUNT="${1:-7}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --keep)
            KEEP_COUNT="$2"
            shift 2
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate source directory
if [[ ! -d "$SEQ_DATA_DIR" ]]; then
    log_error "Seq data directory not found: $SEQ_DATA_DIR"
    exit 1
fi

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Generate timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/seq_backup_$TIMESTAMP.zip"

log_info "Starting Seq backup..."
log_info "Source: $SEQ_DATA_DIR"
log_info "Destination: $BACKUP_FILE"

# Create backup
cd "$SEQ_DATA_DIR"
zip -r "$BACKUP_FILE" . -x "*.lock" 2>/dev/null || {
    log_warn "Some files could not be backed up (possibly locked)"
}

# Verify backup was created
if [[ -f "$BACKUP_FILE" ]]; then
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    log_info "Backup created successfully: $BACKUP_FILE ($BACKUP_SIZE)"
else
    log_error "Backup creation failed"
    exit 1
fi

# Cleanup old backups
log_info "Cleaning up old backups (keeping $KEEP_COUNT most recent)..."

# Get list of backup files sorted by modification time (newest first)
BACKUPS=($(ls -t "$BACKUP_DIR"/seq_backup_*.zip 2>/dev/null || true))

# Remove old backups beyond KEEP_COUNT
if [[ ${#BACKUPS[@]} -gt $KEEP_COUNT ]]; then
    for ((i=KEEP_COUNT; i<${#BACKUPS[@]}; i++)); do
        OLD_BACKUP="${BACKUPS[$i]}"
        log_info "Removing old backup: $OLD_BACKUP"
        rm -f "$OLD_BACKUP"
    done
fi

log_info "Backup completed successfully!"
log_info "Total backups: ${#BACKUPS[@]}"

# Print list of current backups
log_info "Current backups:"
ls -lh "$BACKUP_DIR"/seq_backup_*.zip 2>/dev/null || log_info "No backups found"

exit 0
