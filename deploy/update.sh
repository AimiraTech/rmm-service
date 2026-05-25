#!/bin/sh
set -eu

# RMM Service — Update Script
# Pulls latest config image, extracts new configs, and restarts services.
# Preserves .env, data/, secrets/, and backups/.

INSTALL_DIR="${INSTALL_DIR:-/opt/rmm}"
IMAGE="ghcr.io/aimiratech/rmm-service:latest"

echo "=== RMM Service Update ==="

cd "$INSTALL_DIR"

# Backup before anything
echo "Running pre-update backup..."
make backup

# Pull latest config image
echo "Pulling latest config image..."
docker pull "$IMAGE"

# Extract new configs (overwrites compose, Makefile, Caddyfile, scripts, etc.)
# Does NOT overwrite .env, data/, secrets/, backups/
docker run --rm -v "$INSTALL_DIR:/out" "$IMAGE" cp -r /app/. /out/

# Pull new upstream images and recreate containers
echo "Updating services..."
make update

echo ""
echo "=== Update complete ==="
make status
