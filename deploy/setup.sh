#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

INSTALL_DIR="${INSTALL_DIR:-/opt/rmm}"
IMAGE="ghcr.io/aimiratech/rmm-service:latest"

print_header "rmm-service" "SETUP"

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

# [3] Create install directory
step_start "Create install directory"
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$USER:$USER" "$INSTALL_DIR"
step_ok "Create install directory"
info "$INSTALL_DIR"

# [4] Pull config image (docker pull is a no-op if digest unchanged)
step_start "Pull config image"
pull_output=$(docker pull "$IMAGE" 2>"$ERR_LOG")
if echo "$pull_output" | grep -q "up to date"; then
    step_skip "Pull config image" "already up to date"
else
    step_ok "Pull config image"
fi
info "$IMAGE"

# [5] Extract configs
step_start "Extract configs to $INSTALL_DIR"
docker run --rm -v "$INSTALL_DIR:/out" "$IMAGE" cp -r /app/. /out/ 2>"$ERR_LOG"
step_ok "Extract configs to $INSTALL_DIR"

# [6] Create runtime directories (mkdir -p is idempotent)
step_start "Create runtime directories"
mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/secrets" "$INSTALL_DIR/backups"
step_ok "Create runtime directories"
info "data/ secrets/ backups/"

# [7] Initialize .env (never overwrites existing)
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
printf "    ${CYAN}1.${RESET} cd %s\n" "$INSTALL_DIR"
printf "    ${CYAN}2.${RESET} nano .env              ${DIM}# DOMAIN, RELAY_HOST, TLS_EMAIL${RESET}\n"
printf "    ${CYAN}3.${RESET} make up-d              ${DIM}# start services${RESET}\n"
printf "    ${CYAN}4.${RESET} make status            ${DIM}# verify health${RESET}\n"
printf "    ${CYAN}5.${RESET} make keys-extract      ${DIM}# copy keys to secrets/${RESET}\n"
printf "    ${CYAN}6.${RESET} make backup            ${DIM}# first backup${RESET}\n"
printf "    ${CYAN}7.${RESET} make keys-show         ${DIM}# public key for clients${RESET}\n"
echo ""
