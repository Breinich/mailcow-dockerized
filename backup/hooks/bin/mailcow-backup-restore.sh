#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

BACKUP_IMAGE="${DEBIAN_DOCKER_IMAGE:-ghcr.io/mailcow/backup:latest}"
BACKUP_LOCATION="${MAILCOW_BACKUP_LOCATION:-/backups/data}"
THREADS="${THREADS:-1}"
PROJECT_NAME="${MAILCOW_PROJECT_NAME:-}"

usage() {
  echo "Usage: $0 backup [all|vmail|crypt|redis|rspamd|postfix|mysql]"
  echo "       $0 restore <snapshot-dir> [all|vmail|crypt|redis|rspamd|postfix|mysql]"
  exit 1
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Error: required command not found: ${cmd}"
    exit 1
  fi
}

sanitize_project_name() {
  echo "$1" | tr -cd '[:alnum:]_-'
}

detect_project_name() {
  local volume_name
  volume_name="$(docker volume ls --format '{{.Name}}' | grep -m1 -E '_(vmail|mysql|redis|rspamd|postfix|crypt)-vol-1$' || true)"
  if [ -n "${volume_name}" ]; then
    echo "${volume_name}" | sed -E 's#_(vmail|mysql|redis|rspamd|postfix|crypt)-vol-1$##'
    return 0
  fi
  return 1
}

volume_name() {
  local suffix="$1"
  docker volume ls --format '{{.Name}}' | grep -m1 -E "^${PROJECT_NAME}_${suffix}$" || true
}

container_by_volume() {
  local vol="$1"
  [ -n "${vol}" ] || return 0
  docker ps --filter "volume=${vol}" --format '{{.Names}}' | head -n1
}

env_from_container() {
  local container="$1"
  local key="$2"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${container}" 2>/dev/null | grep -m1 "^${key}=" | cut -d= -f2-
}

resolve_state() {
  if [ -z "${PROJECT_NAME}" ]; then
    PROJECT_NAME="$(detect_project_name || true)"
  fi
  PROJECT_NAME="$(sanitize_project_name "${PROJECT_NAME}")"
  if [ -z "${PROJECT_NAME}" ]; then
    echo "Error: could not determine Mailcow project name (set MAILCOW_PROJECT_NAME)."
    exit 1
  fi

  VMAIL_VOL="$(volume_name vmail-vol-1)"
  CRYPT_VOL="$(volume_name crypt-vol-1)"
  REDIS_VOL="$(volume_name redis-vol-1)"
  RSPAMD_VOL="$(volume_name rspamd-vol-1)"
  POSTFIX_VOL="$(volume_name postfix-vol-1)"
  MYSQL_VOL="$(volume_name mysql-vol-1)"

  REDIS_CTR="$(container_by_volume "${REDIS_VOL}")"
  MYSQL_CTR="$(container_by_volume "${MYSQL_VOL}")"

  DBROOT_VAL="${DBROOT:-}"
  REDISPASS_VAL="${REDISPASS:-}"

  if [ -z "${DBROOT_VAL}" ] && [ -n "${MYSQL_CTR}" ]; then
    DBROOT_VAL="$(env_from_container "${MYSQL_CTR}" DBROOT || true)"
  fi
  if [ -z "${REDISPASS_VAL}" ] && [ -n "${REDIS_CTR}" ]; then
    REDISPASS_VAL="$(env_from_container "${REDIS_CTR}" REDISPASS || true)"
  fi
}

ensure_backup_image() {
  echo "Ensuring backup image exists: ${BACKUP_IMAGE}"
  if docker image inspect "${BACKUP_IMAGE}" >/dev/null 2>&1; then
    return
  fi

  local attempt
  for attempt in 1 2 3; do
    echo "Pull attempt ${attempt}/3: ${BACKUP_IMAGE}"
    if docker pull "${BACKUP_IMAGE}"; then
      return
    fi
    if [ "${attempt}" -eq 3 ]; then
      echo "Error: unable to pull ${BACKUP_IMAGE}"
      exit 1
    fi
    sleep 5
  done
}

ensure_snapshot_dir() {
  SNAPSHOT_DATE="$(date +"%Y-%m-%d-%H-%M-%S")"
  SNAPSHOT_DIR="${BACKUP_LOCATION}/mailcow-${SNAPSHOT_DATE}"
  mkdir -p "${SNAPSHOT_DIR}"
  chmod 755 "${SNAPSHOT_DIR}"
  touch "${SNAPSHOT_DIR}/.$(uname -m)"
}

backup_volume_tar() {
  local vol="$1"
  local mount_point="$2"
  local archive="$3"

  [ -n "${vol}" ] || return 0

  docker run --name mailcow-backup --rm \
    -v "${SNAPSHOT_DIR}:/backup:z" \
    -v "${vol}:${mount_point}:ro,z" \
    "${BACKUP_IMAGE}" /bin/tar \
    --warning='no-file-ignored' \
    --use-compress-program="zstd --rsyncable -T${THREADS}" \
    -Pcvpf "/backup/${archive}" "${mount_point}"
}

backup_mysql() {
  [ -n "${MYSQL_CTR}" ] || { echo "Skipping mysql: container not found"; return 0; }
  [ -n "${MYSQL_VOL}" ] || { echo "Skipping mysql: volume not found"; return 0; }
  [ -n "${DBROOT_VAL}" ] || { echo "Error: DBROOT not found (set DBROOT env var)."; exit 1; }

  local mysql_image mysql_network mysql_host
  mysql_image="$(docker inspect -f '{{.Config.Image}}' "${MYSQL_CTR}")"
  mysql_network="$(docker inspect -f '{{range $n, $v := .NetworkSettings.Networks}}{{println $n}}{{end}}' "${MYSQL_CTR}" | head -n1)"
  mysql_host="mysql"

  docker run --name mailcow-backup --rm \
    --network "${mysql_network}" \
    -v "${MYSQL_VOL}:/var/lib/mysql/:ro,z" \
    -t --entrypoint= \
    --sysctl net.ipv6.conf.all.disable_ipv6=1 \
    -e DBROOT="${DBROOT_VAL}" \
    -e MYSQL_HOST="${mysql_host}" \
    -v "${SNAPSHOT_DIR}:/backup:z" \
    "${mysql_image}" /bin/sh -c "set -eu; mariabackup --host \\\"\\$MYSQL_HOST\\\" --user root --password \\\"\\$DBROOT\\\" --backup --target-dir=/backup_mariadb; mariabackup --prepare --target-dir=/backup_mariadb; chown -R 999:999 /backup_mariadb; /bin/tar --warning='no-file-ignored' --use-compress-program='zstd --rsyncable' -Pcvpf /backup/backup_mariadb.tar.zst /backup_mariadb"
}

archive_and_decompressor() {
  local snapshot="$1"
  local base="$2"
  if [ -f "${snapshot}/${base}.tar.zst" ]; then
    echo "${base}.tar.zst|zstd -d -T${THREADS}"
    return
  fi
  if [ -f "${snapshot}/${base}.tar.gz" ]; then
    echo "${base}.tar.gz|pigz -d -p ${THREADS}"
    return
  fi
  echo ""
}

restore_volume_tar() {
  local vol="$1"
  local mount_point="$2"
  local snapshot="$3"
  local base="$4"

  [ -n "${vol}" ] || { echo "Skipping ${base}: volume not found"; return 0; }

  local info archive decomp
  info="$(archive_and_decompressor "${snapshot}" "${base}")"
  [ -n "${info}" ] || { echo "Skipping ${base}: archive not found"; return 0; }

  archive="${info%%|*}"
  decomp="${info#*|}"

  docker run -i --name mailcow-backup --rm \
    -v "${snapshot}:/backup:z" \
    -v "${vol}:${mount_point}:z" \
    "${BACKUP_IMAGE}" /bin/tar --use-compress-program="${decomp}" -Pxvf "/backup/${archive}"
}

restore_mysql() {
  local snapshot="$1"
  [ -n "${MYSQL_CTR}" ] || { echo "Skipping mysql restore: container not found"; return 0; }
  [ -n "${MYSQL_VOL}" ] || { echo "Skipping mysql restore: volume not found"; return 0; }

  local info archive decomp mysql_image
  info="$(archive_and_decompressor "${snapshot}" "backup_mariadb")"
  [ -n "${info}" ] || { echo "Skipping mysql restore: backup_mariadb archive not found"; return 0; }

  archive="${info%%|*}"
  decomp="${info#*|}"
  mysql_image="$(docker inspect -f '{{.Config.Image}}' "${MYSQL_CTR}")"

  docker stop "${MYSQL_CTR}" >/dev/null 2>&1 || true
  docker run --name mailcow-backup --rm \
    -v "${MYSQL_VOL}:/var/lib/mysql/:rw,z" \
    --entrypoint= \
    -v "${snapshot}:/restore:z" \
    "${mysql_image}" /bin/bash -c "set -e; mkdir -p /restore_work; rm -rf /restore_work/*; tar --use-compress-program='${decomp}' -Pxvf /restore/${archive}; shopt -s dotglob; rm -rf /var/lib/mysql/*; rsync -a /backup_mariadb/ /var/lib/mysql/; chown -R 999:999 /var/lib/mysql/"
  docker start "${MYSQL_CTR}" >/dev/null 2>&1 || true
}

run_backup() {
  local target="${1:-all}"
  ensure_backup_image
  resolve_state
  ensure_snapshot_dir

  echo "Using project: ${PROJECT_NAME}"
  echo "Snapshot: ${SNAPSHOT_DIR}"

  case "${target}" in
    all)
      backup_volume_tar "${VMAIL_VOL}" "/vmail" "backup_vmail.tar.zst"
      backup_volume_tar "${CRYPT_VOL}" "/crypt" "backup_crypt.tar.zst"
      if [ -n "${REDIS_CTR}" ] && [ -n "${REDIS_VOL}" ] && [ -n "${REDISPASS_VAL}" ]; then
        docker exec "${REDIS_CTR}" redis-cli -a "${REDISPASS_VAL}" --no-auth-warning save
        backup_volume_tar "${REDIS_VOL}" "/redis" "backup_redis.tar.zst"
      else
        echo "Skipping redis: container/volume/password missing"
      fi
      backup_volume_tar "${RSPAMD_VOL}" "/rspamd" "backup_rspamd.tar.zst"
      backup_volume_tar "${POSTFIX_VOL}" "/postfix" "backup_postfix.tar.zst"
      backup_mysql
      ;;
    vmail) backup_volume_tar "${VMAIL_VOL}" "/vmail" "backup_vmail.tar.zst" ;;
    crypt) backup_volume_tar "${CRYPT_VOL}" "/crypt" "backup_crypt.tar.zst" ;;
    redis)
      if [ -n "${REDIS_CTR}" ] && [ -n "${REDIS_VOL}" ] && [ -n "${REDISPASS_VAL}" ]; then
        docker exec "${REDIS_CTR}" redis-cli -a "${REDISPASS_VAL}" --no-auth-warning save
        backup_volume_tar "${REDIS_VOL}" "/redis" "backup_redis.tar.zst"
      else
        echo "Error: redis container/volume/password missing"
        exit 1
      fi
      ;;
    rspamd) backup_volume_tar "${RSPAMD_VOL}" "/rspamd" "backup_rspamd.tar.zst" ;;
    postfix) backup_volume_tar "${POSTFIX_VOL}" "/postfix" "backup_postfix.tar.zst" ;;
    mysql) backup_mysql ;;
    *) usage ;;
  esac
}

run_restore() {
  local snapshot="${1:-}"
  local target="${2:-all}"
  [ -n "${snapshot}" ] || usage
  [ -d "${snapshot}" ] || { echo "Error: snapshot directory not found: ${snapshot}"; exit 1; }

  ensure_backup_image
  resolve_state

  case "${target}" in
    all)
      restore_volume_tar "${VMAIL_VOL}" "/vmail" "${snapshot}" "backup_vmail"
      restore_volume_tar "${CRYPT_VOL}" "/crypt" "${snapshot}" "backup_crypt"
      restore_volume_tar "${REDIS_VOL}" "/redis" "${snapshot}" "backup_redis"
      restore_volume_tar "${RSPAMD_VOL}" "/rspamd" "${snapshot}" "backup_rspamd"
      restore_volume_tar "${POSTFIX_VOL}" "/postfix" "${snapshot}" "backup_postfix"
      restore_mysql "${snapshot}"
      ;;
    vmail) restore_volume_tar "${VMAIL_VOL}" "/vmail" "${snapshot}" "backup_vmail" ;;
    crypt) restore_volume_tar "${CRYPT_VOL}" "/crypt" "${snapshot}" "backup_crypt" ;;
    redis) restore_volume_tar "${REDIS_VOL}" "/redis" "${snapshot}" "backup_redis" ;;
    rspamd) restore_volume_tar "${RSPAMD_VOL}" "/rspamd" "${snapshot}" "backup_rspamd" ;;
    postfix) restore_volume_tar "${POSTFIX_VOL}" "/postfix" "${snapshot}" "backup_postfix" ;;
    mysql) restore_mysql "${snapshot}" ;;
    *) usage ;;
  esac
}

main() {
  require_cmd docker

  if ! [[ "${THREADS}" =~ ^[1-9][0-9]?$ ]]; then
    echo "Error: THREADS must be a number between 1 and 99"
    exit 1
  fi

  if [[ ! "${BACKUP_LOCATION}" =~ ^/ ]]; then
    echo "Error: MAILCOW_BACKUP_LOCATION must be an absolute path"
    exit 1
  fi
  mkdir -p "${BACKUP_LOCATION}"

  local action="${1:-}"
  case "${action}" in
    backup)
      run_backup "${2:-all}"
      ;;
    restore)
      run_restore "${2:-}" "${3:-all}"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
