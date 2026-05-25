#!/bin/sh
set -eu

# RMM Service — EC2 Bootstrap Script
# Run once on a fresh EC2 instance to set up the RustDesk server stack.
# Usage: curl -fsSL <raw-url>/deploy/setup.sh | sh

INSTALL_DIR="${INSTALL_DIR:-/opt/rmm}"
IMAGE="ghcr.io/aimiratech/rmm-service:latest"

echo "=== RMM Service Setup ==="

# Install Docker if not present
if ! command -v docker >/dev/null 2>&1; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    echo "Docker installed. Log out and back in, then re-run this script."
    exit 0
fi

# Verify docker compose v2
if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: docker compose v2 not found. Install Docker Engine 24+." >&2
    exit 1
fi

# Create install directory
echo "Setting up $INSTALL_DIR..."
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$USER:$USER" "$INSTALL_DIR"

# Pull and extract config image
echo "Pulling config image..."
docker pull "$IMAGE"
docker run --rm -v "$INSTALL_DIR:/out" "$IMAGE" cp -r /app/. /out/

# Create runtime directories
mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/secrets" "$INSTALL_DIR/backups"

# Create .env from template if it doesn't exist
if [ ! -f "$INSTALL_DIR/.env" ]; then
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    echo ""
    echo "=== ACTION REQUIRED ==="
    echo "Edit $INSTALL_DIR/.env and fill in:"
    echo "  DOMAIN       — your public DNS name"
    echo "  RELAY_HOST   — same as DOMAIN for single-server"
    echo "  TLS_EMAIL    — for Let's Encrypt notifications"
    echo ""
    echo "Then run:"
    echo "  cd $INSTALL_DIR && make up-d"
else
    echo ".env already exists, skipping."
fi

echo ""
echo "=== Setup complete ==="
echo "Next steps:"
echo "  1. cd $INSTALL_DIR"
echo "  2. nano .env              # configure DOMAIN, RELAY_HOST, TLS_EMAIL"
echo "  3. make up-d              # start services"
echo "  4. make status            # verify health"
echo "  5. make keys-extract      # copy generated keys to secrets/"
echo "  6. make backup            # first backup"
echo "  7. make keys-show         # get public key for clients"
