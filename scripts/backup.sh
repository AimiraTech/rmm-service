#!/bin/sh
set -eu

# backup.sh — Atomic backup of RustDesk keys and SQLite database.
# Reads directly from ./data/ bind mount — no container dependency.
# Run from the repository root: make backup

BACKUP_DIR="${BACKUP_DIR:-/var/backups/rmm}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE_NAME="rmm-backup-${TIMESTAMP}.tar.gz"
TMPDIR=""

cleanup() {
    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT

# Verify data directory exists
if [ ! -d "./data" ]; then
    echo "ERROR: ./data directory not found. Run from repository root after 'make up-d'." >&2
    exit 1
fi

# Verify required files exist
for f in id_ed25519 id_ed25519.pub db_v2.sqlite3; do
    if [ ! -f "./data/$f" ]; then
        echo "ERROR: Required file ./data/$f not found. Has the service been started?" >&2
        exit 1
    fi
done

# Create backup directory if absent
mkdir -p "$BACKUP_DIR"

# Create temporary working directory
TMPDIR=$(mktemp -d)

# Copy required files
cp "./data/id_ed25519"     "$TMPDIR/id_ed25519"
cp "./data/id_ed25519.pub" "$TMPDIR/id_ed25519.pub"
cp "./data/db_v2.sqlite3"  "$TMPDIR/db_v2.sqlite3"

# Copy optional WAL/SHM files if present
cp "./data/db_v2.sqlite3-wal" "$TMPDIR/db_v2.sqlite3-wal" 2>/dev/null || true
cp "./data/db_v2.sqlite3-shm" "$TMPDIR/db_v2.sqlite3-shm" 2>/dev/null || true

# Create archive in temp location then atomically move to BACKUP_DIR
ARCHIVE_TMP="$(mktemp)"
tar czf "$ARCHIVE_TMP" -C "$TMPDIR" .
mv "$ARCHIVE_TMP" "${BACKUP_DIR}/${ARCHIVE_NAME}"

# Remove temp dir (also done by trap, but explicit here)
rm -rf "$TMPDIR"
TMPDIR=""

# Prune archives older than BACKUP_RETENTION_DAYS
find "$BACKUP_DIR" -name 'rmm-backup-*.tar.gz' -mtime "+${BACKUP_RETENTION_DAYS}" -delete

# Print success
ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"
ARCHIVE_SIZE=$(du -sh "$ARCHIVE_PATH" | cut -f1)
echo "Backup complete: ${ARCHIVE_PATH} (${ARCHIVE_SIZE})"
