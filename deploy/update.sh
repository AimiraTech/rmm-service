#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
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

# [1] Pre-update backup (skip if no data yet)
step_start "Pre-update backup"
if [ -d "./data" ] && [ -f "./data/id_ed25519" ]; then
    make backup 2>"$ERR_LOG" >/dev/null
    step_ok "Pre-update backup"
    info "$(ls -t backups/rmm-backup-*.tar.gz 2>/dev/null | head -1 || echo 'archive created')"
else
    step_skip "Pre-update backup" "no data to backup yet"
fi

# [2] Pull upstream service images — detect if changed
step_start "Pull service images"
digests_before=$(docker compose images -q 2>/dev/null | sort || echo "none")
docker compose pull 2>"$ERR_LOG"
digests_after=$(docker compose images -q 2>/dev/null | sort || echo "none")
images_changed=false
if [ "$digests_before" != "$digests_after" ]; then
    images_changed=true
    step_ok "Pull service images" "new images available"
else
    step_skip "Pull service images" "all images up to date"
fi

# [3] Recreate containers (only if images changed)
step_start "Recreate containers"
if [ "$images_changed" = true ]; then
    docker compose up -d --force-recreate 2>"$ERR_LOG"
    step_ok "Recreate containers"
else
    step_skip "Recreate containers" "nothing changed"
fi

# [4] Health check
step_start "Health check"
if [ "$images_changed" = true ]; then
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
else
    status=$(docker inspect --format='{{.State.Health.Status}}' rustdesk 2>/dev/null || echo "not running")
    if [ "$status" = "healthy" ]; then
        step_skip "Health check" "already healthy"
    else
        step_ok "Health check" "status: $status"
    fi
fi

# [5] Prune old images
step_start "Prune old images"
pruned=$(docker image prune -f 2>"$ERR_LOG" | grep "Total reclaimed" || echo "nothing to prune")
if echo "$pruned" | grep -q "0B\|nothing"; then
    step_skip "Prune old images" "nothing to reclaim"
else
    step_ok "Prune old images"
    info "$pruned"
fi

if [ "$images_changed" = true ]; then
    print_footer "ok" "UPDATE"
else
    print_footer "skip"
fi
