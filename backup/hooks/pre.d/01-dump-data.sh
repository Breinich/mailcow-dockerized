#!/usr/bin/with-contenv bash
# shellcheck shell=bash

source /etc/s6-overlay/s6-rc.d/setup_check/run_include

echo "Starting Mailcow consistent backup..."

/hooks/bin/mailcow-backup-restore.sh backup all