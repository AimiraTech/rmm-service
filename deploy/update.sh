#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="ghcr.io/aimiratech/rmm-service:latest"
LOCK_FILE="/tmp/deploy-rmm-service.lock"

# Concurrency guard
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Another update is already running. Exiting."
    exit 0
fi

print_header "rmm-service" "UPDATE"
info "Install directory: $INSTALL_DIR"

cd "$INSTALL_DIR"

# [1] Pre-update backup (skip if volumes don't exist yet)
step_start "Pre-update backup"
if docker volume inspect meshcentral-data >/dev/null 2>&1; then
    make backup 2>"$ERR_LOG" >/dev/null
    step_ok "Pre-update backup"
    BACKUP_DIR="${BACKUP_DIR:-/home/aimiratech/rmm-service/backups}"
    info "$(ls -t "${BACKUP_DIR}/rmm-backup-"*.tar.gz 2>/dev/null | head -1 || echo 'archive created')"
else
    step_skip "Pre-update backup" "no data volume yet"
fi

# [2] Pull config image — detect if changed
step_start "Pull config image"
digest_before=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || echo "none")
docker pull "$IMAGE" 2>"$ERR_LOG" >/dev/null
digest_after=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || echo "none")
config_changed=false
if [ "$digest_before" != "$digest_after" ]; then
    config_changed=true
    step_ok "Pull config image" "new version"
else
    step_skip "Pull config image" "already up to date"
fi
info "$IMAGE"

# [3] Extract new configs (only if config image changed)
step_start "Extract configs"
if [ "$config_changed" = true ]; then
    docker run --rm -v "$INSTALL_DIR:/out" "$IMAGE" cp -r /app/. /out/ 2>"$ERR_LOG"
    step_ok "Extract configs"
    info "Overwrites compose, Makefile, scripts/, config/ — preserves .env"
else
    step_skip "Extract configs" "config image unchanged — skipping"
fi

# [4] Pull upstream service images — detect if changed
step_start "Pull service images"
digests_before=$(docker compose images -q 2>/dev/null | sort || echo "none")
docker compose pull 2>"$ERR_LOG"
digests_after=$(docker compose images -q 2>/dev/null | sort || echo "none")
services_changed=false
if [ "$digests_before" != "$digests_after" ]; then
    services_changed=true
    step_ok "Pull service images" "new images available"
else
    step_skip "Pull service images" "all images up to date"
fi

# [5] Recreate containers (only if something changed)
step_start "Recreate containers"
if [ "$config_changed" = true ] || [ "$services_changed" = true ]; then
    docker compose up -d --force-recreate 2>"$ERR_LOG"
    step_ok "Recreate containers"
else
    step_skip "Recreate containers" "nothing changed"
fi

# [6] Health check
step_start "Health check"
if [ "$config_changed" = true ] || [ "$services_changed" = true ]; then
    retries=0
    max_retries=30
    healthy=false
    while [ "$retries" -lt "$max_retries" ]; do
        status=$(docker inspect --format='{{.State.Health.Status}}' meshcentral 2>/dev/null || echo "starting")
        if [ "$status" = "healthy" ]; then
            healthy=true
            break
        fi
        retries=$((retries + 1))
        sleep 2
    done

    if [ "$healthy" = true ]; then
        step_ok "Health check" "meshcentral healthy"
    else
        step_fail "Health check" "meshcentral not healthy after 60s"
        info "Run 'make logs' to investigate"
        print_footer "fail" "UPDATE"
        exit 1
    fi
else
    status=$(docker inspect --format='{{.State.Health.Status}}' meshcentral 2>/dev/null || echo "not running")
    if [ "$status" = "healthy" ]; then
        step_skip "Health check" "already healthy"
    else
        step_ok "Health check" "status: $status"
    fi
fi

# [7] Prune old images
step_start "Prune old images"
pruned=$(docker image prune -f 2>"$ERR_LOG" | grep "Total reclaimed" || echo "nothing to prune")
if echo "$pruned" | grep -q "0B\|nothing"; then
    step_skip "Prune old images" "nothing to reclaim"
else
    step_ok "Prune old images"
    info "$pruned"
fi

if [ "$config_changed" = true ] || [ "$services_changed" = true ]; then
    print_footer "ok" "UPDATE"
else
    print_footer "skip"
fi
