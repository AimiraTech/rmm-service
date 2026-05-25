#!/bin/sh
set -eu

# RMM Service — Cron Backup
# Add to crontab: 0 3 * * * /opt/rmm/deploy/backup-cron.sh >> /var/log/rmm-backup.log 2>&1

INSTALL_DIR="${INSTALL_DIR:-/opt/rmm}"

cd "$INSTALL_DIR"
make backup
