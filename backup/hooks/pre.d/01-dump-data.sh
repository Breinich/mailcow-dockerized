#!/usr/bin/with-contenv bash
# shellcheck shell=bash

source /etc/s6-overlay/s6-rc.d/setup_check/run_include

echo "Starting Mailcow consistent backup..."

MAILCOW_BACKUP_LOCATION=/backups/data /backups/config/helper-scripts/backup_and_restore.sh backup all