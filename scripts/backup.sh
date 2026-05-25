#!/bin/sh
set -eu

# backup.sh — Backup MeshCentral named volumes via transient Alpine container.
# Backs up meshcentral-data and meshcentral-files volumes.
# Does NOT require the MeshCentral container to be running.
# Run from the repository root: make backup

BACKUP_DIR="${BACKUP_DIR:-/home/aimiratech/rmm-service/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE_NAME="rmm-backup-${TIMESTAMP}.tar.gz"

# Create backup directory if absent
mkdir -p "$BACKUP_DIR"

# Backup named volumes via transient Alpine container
docker run --rm \
  -v meshcentral-data:/data:ro \
  -v meshcentral-files:/files:ro \
  -v "${BACKUP_DIR}:/backup" \
  alpine tar czf "/backup/${ARCHIVE_NAME}" -C / data files

# Prune archives older than BACKUP_RETENTION_DAYS
find "$BACKUP_DIR" -name 'rmm-backup-*.tar.gz' -mtime "+${BACKUP_RETENTION_DAYS}" -delete

# Print success
ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"
ARCHIVE_SIZE=$(du -sh "$ARCHIVE_PATH" | cut -f1)
echo "Backup complete: ${ARCHIVE_PATH} (${ARCHIVE_SIZE})"
