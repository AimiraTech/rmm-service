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

# [3] Pull service images (pre-pull so first 'make up-d' is fast)
step_start "Pull service images"
cd "$INSTALL_DIR"
if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    docker compose pull 2>"$ERR_LOG"
    step_ok "Pull service images"
else
    step_fail "Pull service images" "docker-compose.yml not found in $INSTALL_DIR"
    print_footer "fail" "SETUP"
    exit 1
fi

# [4] Create runtime directories (mkdir -p is idempotent)
step_start "Create runtime directories"
mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/secrets" "$INSTALL_DIR/backups"
step_ok "Create runtime directories"
info "data/ secrets/ backups/"

# [5] Initialize .env (never overwrites existing)
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
printf "    ${CYAN}1.${RESET} nano .env              ${DIM}# DOMAIN, RELAY_HOST, TLS_EMAIL${RESET}\n"
printf "    ${CYAN}2.${RESET} make up-d              ${DIM}# start services${RESET}\n"
printf "    ${CYAN}3.${RESET} make status            ${DIM}# verify health${RESET}\n"
printf "    ${CYAN}4.${RESET} make keys-extract      ${DIM}# copy keys to secrets/${RESET}\n"
printf "    ${CYAN}5.${RESET} make backup            ${DIM}# first backup${RESET}\n"
printf "    ${CYAN}6.${RESET} make keys-show         ${DIM}# public key for clients${RESET}\n"
echo ""
