#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="ghcr.io/aimiratech/rmm-service:latest"

print_header "rmm-service" "SETUP"
info "Install directory: $INSTALL_DIR"

# [1] Check Docker
step_start "Check Docker installation"
if ! command -v docker >/dev/null 2>&1; then
    step_skip "Check Docker installation" "not installed, installing..."
    curl -fsSL https://get.docker.com | sh 2>"$ERR_LOG"
    sudo usermod -aG docker "$USER"
    info "Docker installed. Log out and back in, then re-run this script."
    print_footer "ok" "SETUP"
    exit 0
fi
step_ok "Check Docker installation"
info "$(docker --version)"

# [2] Check Docker Compose v2
step_start "Check Docker Compose v2"
if ! docker compose version >/dev/null 2>&1; then
    step_fail "Check Docker Compose v2" "not found — install Docker Engine 24+"
    print_footer "fail" "SETUP"
    exit 1
fi
step_ok "Check Docker Compose v2"
info "$(docker compose version)"

# [3] Pull config image
step_start "Pull config image"
pull_output=$(docker pull "$IMAGE" 2>"$ERR_LOG")
if echo "$pull_output" | grep -q "up to date"; then
    step_skip "Pull config image" "already up to date"
else
    step_ok "Pull config image"
fi
info "$IMAGE"

# [4] Extract configs (overwrites compose, Makefile, scripts — preserves .env, data/, secrets/)
step_start "Extract configs"
docker run --rm -v "$INSTALL_DIR:/out" "$IMAGE" cp -r /app/. /out/ 2>"$ERR_LOG"
step_ok "Extract configs"

# [5] Create runtime directories (mkdir -p is idempotent)
step_start "Create runtime directories"
mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/secrets" "$INSTALL_DIR/backups"
step_ok "Create runtime directories"
info "data/ secrets/ backups/"

# [6] Bootstrap Ed25519 keys (skip if already populated)
step_start "Bootstrap Ed25519 keys"
RUSTDESK_IMAGE="rustdesk/rustdesk-server-s6:${RUSTDESK_IMAGE_TAG:-1.1.15}"
if [ -s "$INSTALL_DIR/secrets/key_pub" ] && [ -s "$INSTALL_DIR/secrets/key_priv" ]; then
    step_skip "Bootstrap Ed25519 keys" "already present"
else
    : >"$INSTALL_DIR/secrets/key_pub"
    : >"$INSTALL_DIR/secrets/key_priv"
    docker run --rm -v "$INSTALL_DIR/data:/data" "$RUSTDESK_IMAGE" sleep 10 2>"$ERR_LOG" || true
    if [ -f "$INSTALL_DIR/data/id_ed25519.pub" ] && [ -f "$INSTALL_DIR/data/id_ed25519" ]; then
        cp "$INSTALL_DIR/data/id_ed25519.pub" "$INSTALL_DIR/secrets/key_pub"
        cp "$INSTALL_DIR/data/id_ed25519" "$INSTALL_DIR/secrets/key_priv"
        chmod 600 "$INSTALL_DIR/secrets/key_priv"
        step_ok "Bootstrap Ed25519 keys"
        info "Keys written to secrets/key_pub and secrets/key_priv"
    else
        step_fail "Bootstrap Ed25519 keys" "keys not generated — check $ERR_LOG"
        print_footer "fail" "SETUP"
        exit 1
    fi
fi

# [7] Pull service images (pre-pull so first 'make up-d' is fast)
step_start "Pull service images"
cd "$INSTALL_DIR"
docker compose pull 2>"$ERR_LOG"
step_ok "Pull service images"

# [8] Initialize .env (never overwrites existing)
step_start "Initialize environment config"
if [ -f "$INSTALL_DIR/.env" ]; then
    step_skip "Initialize environment config" ".env already exists"
else
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    step_ok "Initialize environment config"
    info "Created .env from template — edit before starting"
fi

print_footer "ok" "SETUP"

echo "  Next steps:"
echo ""
printf "    ${CYAN}1.${RESET} nano .env              ${DIM}# DOMAIN, RELAY_HOST${RESET}\n"
printf "    ${CYAN}2.${RESET} make up-d              ${DIM}# start services${RESET}\n"
printf "    ${CYAN}3.${RESET} make status            ${DIM}# verify health${RESET}\n"
printf "    ${CYAN}4.${RESET} make backup            ${DIM}# first backup${RESET}\n"
printf "    ${CYAN}5.${RESET} make keys-show         ${DIM}# public key for clients${RESET}\n"
echo ""
