#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Cron usage: 0 3 * * * /home/aimiratech/rmm-service/deploy/backup-cron.sh >> /var/log/rmm-backup.log 2>&1

print_header "rmm-service" "BACKUP"

cd "$INSTALL_DIR"

# [1] Run backup
step_start "Backup MeshCentral volumes"
make backup 2>"$ERR_LOG" >/dev/null
step_ok "Backup MeshCentral volumes"
BACKUP_DIR="${BACKUP_DIR:-/home/aimiratech/rmm-service/backups}"
info "$(ls -t "${BACKUP_DIR}/rmm-backup-"*.tar.gz 2>/dev/null | head -1 || echo 'archive created')"

# [2] Verify archive integrity
step_start "Verify archive integrity"
latest=$(ls -t "${BACKUP_DIR}/rmm-backup-"*.tar.gz 2>/dev/null | head -1)
if [ -n "$latest" ] && tar -tzf "$latest" >/dev/null 2>&1; then
    size=$(du -sh "$latest" | cut -f1)
    step_ok "Verify archive integrity"
    info "$latest ($size)"
else
    step_fail "Verify archive integrity" "backup integrity check failed"
    print_footer "fail" "BACKUP"
    exit 1
fi

print_footer "ok" "BACKUP"
