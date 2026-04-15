#!/usr/bin/with-contenv bash
# shellcheck shell=bash

source /etc/s6-overlay/s6-rc.d/setup_check/run_include

echo "Cleaning up local dumps..."

rm -rf /backup/data/*

echo "Cleanup complete."