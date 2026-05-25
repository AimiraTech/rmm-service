#!/bin/sh
set -eu

# restore.sh — Restore RustDesk keys and database from a backup archive.
# Usage: scripts/restore.sh <path/to/rmm-backup-*.tar.gz>
# Run from the repository root: make restore FILE=<archive>
# NOTE: Does NOT auto-start containers. Run 'make up-d' after restore.

ARCHIVE="${1:-}"

if [ -z "$ARCHIVE" ]; then
    echo "Usage: $0 <backup-archive.tar.gz>" >&2
    exit 1
fi

TMPDIR=""

cleanup() {
    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT

# Verify archive exists and is readable
if [ ! -f "$ARCHIVE" ]; then
    echo "ERROR: Archive not found: $ARCHIVE" >&2
    exit 1
fi

if [ ! -r "$ARCHIVE" ]; then
    echo "ERROR: Archive is not readable: $ARCHIVE" >&2
    exit 1
fi

# Verify archive integrity before touching anything
echo "Verifying archive integrity..."
if ! tar -tzf "$ARCHIVE" > /dev/null 2>&1; then
    echo "ERROR: Archive is corrupt or not a valid tar.gz: $ARCHIVE" >&2
    exit 1
fi

# Verify required files are present in archive
ARCHIVE_FILES=$(tar -tzf "$ARCHIVE")
for f in id_ed25519 id_ed25519.pub db_v2.sqlite3; do
    if ! echo "$ARCHIVE_FILES" | grep -q "^\./$f$\|^$f$"; then
        echo "ERROR: Required file '$f' not found in archive." >&2
        exit 1
    fi
done
echo "Archive integrity OK."

# Show current public key fingerprint for operator comparison
if [ -f "secrets/key_pub" ]; then
    echo "Current public key (before restore):"
    cat "secrets/key_pub"
    echo ""
else
    echo "No current public key found in secrets/."
fi

# Stop rustdesk only if running
if docker compose ps rustdesk 2>/dev/null | grep -q "running"; then
    echo "Stopping rustdesk container..."
    docker compose stop rustdesk
else
    echo "rustdesk container not running, skipping stop."
fi

# Extract archive to temp directory
TMPDIR=$(mktemp -d)
tar -xzf "$ARCHIVE" -C "$TMPDIR"

# Create target directories if needed (mkdir -p is idempotent)
mkdir -p secrets data

# Copy keys to secrets/
cp "$TMPDIR/id_ed25519"     "secrets/key_priv"
cp "$TMPDIR/id_ed25519.pub" "secrets/key_pub"
chmod 600 "secrets/key_priv"

# Copy keys to data/ (so make keys-show works immediately)
cp "$TMPDIR/id_ed25519"     "data/id_ed25519"
cp "$TMPDIR/id_ed25519.pub" "data/id_ed25519.pub"

# Copy data files to data/
cp "$TMPDIR/db_v2.sqlite3" "data/db_v2.sqlite3"
cp "$TMPDIR/db_v2.sqlite3-wal" "data/db_v2.sqlite3-wal" 2>/dev/null || true
cp "$TMPDIR/db_v2.sqlite3-shm" "data/db_v2.sqlite3-shm" 2>/dev/null || true

# Remove temp dir (also handled by trap)
rm -rf "$TMPDIR"
TMPDIR=""

echo ""
echo "Restore complete."
echo "Restored public key:"
cat "secrets/key_pub"
echo ""
echo "Run 'make up-d' to start services with restored data."
