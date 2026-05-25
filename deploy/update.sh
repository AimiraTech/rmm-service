#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

INSTALL_DIR="${INSTALL_DIR:-/opt/rmm}"
IMAGE="ghcr.io/aimiratech/rmm-service:latest"
LOCK_FILE="/tmp/deploy-rmm-service.lock"

# Concurrency guard
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Another update is already running. Exiting."
    exit 0
fi

print_header "rmm-service" "UPDATE"

cd "$INSTALL_DIR"

# [1] Pre-update backup
step_start "Pre-update backup"
make backup 2>"$ERR_LOG" >/dev/null
step_ok "Pre-update backup"
info "$(ls -t backups/rmm-backup-*.tar.gz 2>/dev/null | head -1 || echo 'archive created')"

# [2] Pull config image
step_start "Pull config image"
docker pull "$IMAGE" 2>"$ERR_LOG" | tail -1
step_ok "Pull config image"
info "$IMAGE"

# [3] Extract new configs
step_start "Extract configs"
docker run --rm -v "$INSTALL_DIR:/out" "$IMAGE" cp -r /app/. /out/ 2>"$ERR_LOG"
step_ok "Extract configs"
info "Overwrites compose, Makefile, Caddyfile, scripts — preserves .env, data/, secrets/"

# [4] Pull upstream service images
step_start "Pull service images"
docker compose pull 2>"$ERR_LOG"
step_ok "Pull service images"

# [5] Recreate containers
step_start "Recreate containers"
docker compose up -d --force-recreate 2>"$ERR_LOG"
step_ok "Recreate containers"

# [6] Health check
step_start "Health check"
retries=0
max_retries=30
healthy=false
while [ "$retries" -lt "$max_retries" ]; do
    status=$(docker inspect --format='{{.State.Health.Status}}' rustdesk 2>/dev/null || echo "starting")
    if [ "$status" = "healthy" ]; then
        healthy=true
        break
    fi
    retries=$((retries + 1))
    sleep 2
done

if [ "$healthy" = true ]; then
    step_ok "Health check" "rustdesk healthy"
else
    step_fail "Health check" "rustdesk not healthy after 60s"
    info "Run 'make logs' to investigate"
    print_footer "fail" "UPDATE"
    exit 1
fi

# [7] Prune old images
step_start "Prune old images"
docker image prune -f 2>"$ERR_LOG" >/dev/null
step_ok "Prune old images"

print_footer "ok" "UPDATE"
