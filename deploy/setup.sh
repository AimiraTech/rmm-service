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

# [4] Extract configs (overwrites compose, Makefile, scripts, config — preserves .env)
step_start "Extract configs"
docker run --rm -v "$INSTALL_DIR:/out" "$IMAGE" cp -r /app/. /out/ 2>"$ERR_LOG"
step_ok "Extract configs"
info "Overwrites compose, Makefile, scripts/, config/ — preserves .env"

# [5] Create backups directory (idempotent)
step_start "Create runtime directories"
BACKUP_DIR="${BACKUP_DIR:-/home/aimiratech/rmm-service/backups}"
mkdir -p "$BACKUP_DIR"
step_ok "Create runtime directories"
info "backups: $BACKUP_DIR"

# [6] Initialize .env (never overwrites existing)
step_start "Initialize environment config"
if [ -f "$INSTALL_DIR/.env" ]; then
    step_skip "Initialize environment config" ".env already exists"
else
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    # Generate a random session key
    SESSION_KEY="$(openssl rand -hex 32)"
    # Replace the placeholder value in .env
    sed -i "s/change-me-to-random-64-chars/${SESSION_KEY}/" "$INSTALL_DIR/.env"
    step_ok "Initialize environment config"
    info "Created .env with random MESHCENTRAL_SESSION_KEY"
    info "Edit .env to set MESHCENTRAL_HOSTNAME before starting"
fi

# [7] Pull MeshCentral service image (pre-pull so first 'make up-d' is fast)
step_start "Pull MeshCentral image"
cd "$INSTALL_DIR"
docker compose pull 2>"$ERR_LOG"
step_ok "Pull MeshCentral image"

print_footer "ok" "SETUP"

echo "  Next steps:"
echo ""
printf "    ${CYAN}1.${RESET} nano .env              ${DIM}# set MESHCENTRAL_HOSTNAME${RESET}\n"
printf "    ${CYAN}2.${RESET} make up-d              ${DIM}# start MeshCentral${RESET}\n"
printf "    ${CYAN}3.${RESET} make status            ${DIM}# verify health${RESET}\n"
printf "    ${CYAN}4.${RESET} make admin-create      ${DIM}# create first admin account${RESET}\n"
printf "    ${CYAN}5.${RESET} make backup            ${DIM}# first backup${RESET}\n"
echo ""
