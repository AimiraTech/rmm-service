#!/bin/sh
set -eu

# restore.sh — Restore MeshCentral volumes from a backup archive.
# Usage: scripts/restore.sh <path/to/rmm-backup-*.tar.gz>
# Run from the repository root: make restore FILE=<archive>
# NOTE: Does NOT restart the container. Run 'make up-d' after restore.

ARCHIVE="${1:-}"

if [ -z "$ARCHIVE" ]; then
    echo "Usage: $0 <backup-archive.tar.gz>" >&2
    exit 1
fi

# Verify archive exists and is readable
if [ ! -f "$ARCHIVE" ]; then
    echo "ERROR: Archive not found: $ARCHIVE" >&2
    exit 1
fi

if [ ! -r "$ARCHIVE" ]; then
    echo "ERROR: Archive is not readable: $ARCHIVE" >&2
    exit 1
fi

# Verify archive integrity BEFORE touching anything
echo "Verifying archive integrity..."
if ! tar -tzf "$ARCHIVE" > /dev/null 2>&1; then
    echo "ERROR: Archive is corrupt or not a valid tar.gz: $ARCHIVE" >&2
    exit 1
fi
echo "Archive integrity OK."

# Stop MeshCentral container
echo "Stopping meshcentral container..."
docker compose stop meshcentral

# Extract archive contents into named volumes via transient Alpine container
ARCHIVE_DIR="$(cd "$(dirname "$ARCHIVE")" && pwd)"
ARCHIVE_FILE="$(basename "$ARCHIVE")"

docker run --rm \
  -v meshcentral-data:/data \
  -v meshcentral-files:/files \
  -v "${ARCHIVE_DIR}:/backup:ro" \
  alpine sh -c "rm -rf /data/* /files/* && tar xzf /backup/${ARCHIVE_FILE} -C /"

echo ""
echo "Restore complete."
echo "Run 'make up-d' to start MeshCentral with restored data."
