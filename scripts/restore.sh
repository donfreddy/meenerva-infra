#!/usr/bin/env bash
# =============================================================================
# restore.sh :: guided restore from Backblaze B2.
# Run on a freshly bootstrapped node with that node's .env already recreated.
#
#   ./scripts/restore.sh {core|apps} full          restore volumes + all DBs from a chosen snapshot
#   ./scripts/restore.sh {core|apps} db <name>      restore a single database from a chosen snapshot
#   ./scripts/restore.sh {core|apps} list           list snapshots in B2 for that node
#   ./scripts/restore.sh                            same as: core full   (back-compat with `make restore`)
#
# This script is deliberately interactive and asks before destructive steps.
# =============================================================================
# shellcheck source=SCRIPTDIR/lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker aws gpg

if [ "$#" -eq 0 ]; then
  NODE=core
  ACTION=full
else
  NODE="${1:?usage: $0 {core|apps} {full|db <name>|list}}"
  shift
  ACTION="${1:-full}"
  shift || true
fi

case "${NODE}" in
  core)
    ENV_FILE="${REPO_ROOT}/core-node/.env"
    PROJECT="meenerva-core"
    DB_ENGINE=postgres
    DB_CONTAINER=core-postgres
    # dest volume name (bare, gets prefixed with ${PROJECT}_) : archive dir name under backup/
    VOLUMES=(stalwart-data stalwart-etc n8n-data webmail-data traefik-acme)
    ;;
  apps)
    ENV_FILE="${REPO_ROOT}/apps-node/.env"
    PROJECT=""   # each app volume already carries its own full external name below
    DB_ENGINE=mariadb
    DB_CONTAINER=apps-mariadb
    # dest volume name : archive dir name under backup/ (both explicit since,
    # unlike core, these don't share one project prefix - see
    # apps-node/docker-compose.yml's external volume block for why)
    VOLUMES=(
      "meenerva-nextcloud_nextcloud-data:nextcloud-data"
      "meenerva-mattermost_mattermost-data:mattermost-data"
      "meenerva-mattermost_mattermost-config:mattermost-config"
      "frappe_frappe-sites:frappe-sites"
      "espocrm_espocrm-data:espocrm-data"
      "espocrm_espocrm-custom:espocrm-custom"
      "espocrm_espocrm-client-custom:espocrm-client-custom"
      "meenerva-docuseal_docuseal-data:docuseal-data"
      "openproject_openproject-data:openproject-data"
    )
    ;;
  *) die "node must be 'core' or 'apps' - usage: $0 {core|apps} {full|db <name>|list}" ;;
esac

load_env "${ENV_FILE}"

export AWS_ACCESS_KEY_ID="${B2_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${B2_SECRET_ACCESS_KEY}"
S3="aws --endpoint-url ${B2_S3_ENDPOINT} s3"
PREFIX="s3://${B2_BUCKET}/${NODE}-node"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

list_snapshots() {
  log "Available snapshots in ${PREFIX}:"
  ${S3} ls "${PREFIX}/" | awk '{print "   ", $4}' | sort
}

download_and_extract() {
  list_snapshots
  read -r -p "Snapshot filename to restore: " SNAP
  [ -n "${SNAP}" ] || die "no snapshot given"
  log "Downloading ${SNAP}"
  ${S3} cp "${PREFIX}/${SNAP}" "${WORK}/${SNAP}"
  log "Decrypting + extracting"
  gpg --batch --yes --passphrase "${RESTIC_PASSWORD}" -o "${WORK}/archive.tar.gz" -d "${WORK}/${SNAP}"
  mkdir -p "${WORK}/extract"
  tar -xzf "${WORK}/archive.tar.gz" -C "${WORK}/extract"
}

restore_volume() {
  local dest="$1" archive_dir="$2"
  local src="${WORK}/extract/backup/${archive_dir}"
  [ -d "${src}" ] || { warn "no ${archive_dir} in snapshot, skipping"; return; }
  log "Restoring volume ${dest}"
  docker volume create "${dest}" >/dev/null
  docker run --rm -v "${dest}:/dst" -v "${src}:/src:ro" alpine \
    sh -c 'rm -rf /dst/* && cp -a /src/. /dst/'
}

restore_postgres_dumps() {
  log "Starting only core-postgres to load dumps"
  docker compose --project-directory "${REPO_ROOT}/core-node" --env-file "${ENV_FILE}" up -d postgres
  sleep 10
  # postgres-backup-local nests every timestamped dump under last/ - the
  # daily/weekly/monthly dirs only hold hardlinks to a subset, not the full
  # set (confirmed against the image's own docs; a bare */*.sql.gz glob one
  # level up misses this and silently "restores" nothing).
  local dumpdir="${WORK}/extract/backup/pg-dumps/last"
  for dump in "${dumpdir}"/*.sql.gz; do
    [ -e "${dump}" ] || { warn "no SQL dumps found under pg-dumps/last in snapshot"; break; }
    local db
    db="$(basename "${dump}" | sed -E 's/-[0-9]{8}-[0-9]{6}\.sql\.gz$//')"
    log "Loading ${db}"
    gunzip -c "${dump}" | docker exec -i -e PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}" core-postgres \
      psql -U "${POSTGRES_SUPERUSER}" -d "${db}"
  done
}

restore_mariadb_dumps() {
  log "Starting only apps-mariadb to load dumps"
  docker compose --project-directory "${REPO_ROOT}/apps-node" --env-file "${ENV_FILE}" up -d mariadb
  sleep 10
  # fradelg/mysql-cron-backup writes latest.<db>.sql.gz (a copy, not a
  # symlink, inside the archived tarball) alongside timestamped ones - use
  # that instead of picking a timestamp to parse.
  local dumpdir="${WORK}/extract/backup/mariadb-dumps"
  for dump in "${dumpdir}"/latest.*.sql.gz; do
    [ -e "${dump}" ] || { warn "no SQL dumps found under mariadb-dumps in snapshot"; break; }
    local db
    db="$(basename "${dump}" | sed -E 's/^latest\.//; s/\.sql\.gz$//')"
    log "Loading ${db}"
    # mysqldump's per-db output has no CREATE DATABASE statement (fradelg
    # passes the db name as a bare positional arg, not --databases) - the
    # target database must exist before loading.
    docker exec -i apps-mariadb mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" \
      -e "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    gunzip -c "${dump}" | docker exec -i apps-mariadb mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" "${db}"
  done
}

restore_full() {
  download_and_extract
  warn "About to restore volumes and databases for ${NODE}-node. Its stack should be DOWN."
  confirm "Proceed?" || die "aborted"

  for entry in "${VOLUMES[@]}"; do
    if [ "${NODE}" = "core" ]; then
      restore_volume "${PROJECT}_${entry}" "${entry}"
    else
      restore_volume "${entry%%:*}" "${entry##*:}"
    fi
  done

  if [ "${DB_ENGINE}" = "postgres" ]; then
    restore_postgres_dumps
  else
    restore_mariadb_dumps
  fi

  ok "Full restore done for ${NODE}-node. Now: make ${NODE}-up"
  [ "${NODE}" = "apps" ] && warn "App DB users/roles (app_<name>) are NOT recreated by this script - run scripts/create-mysql-database.sh <app> first if a fresh apps-mariadb has no users yet."
}

restore_db() {
  local name="${1:?usage: $0 ${NODE} db <name>}"
  local db="app_${name}"
  download_and_extract
  warn "This DROPS and reloads ${db}."
  confirm "Proceed?" || die "aborted"

  if [ "${DB_ENGINE}" = "postgres" ]; then
    local dump
    dump="$(find "${WORK}/extract" -path "*/pg-dumps/last/*" -name "${db}-*.sql.gz" | sort | tail -1)"
    [ -n "${dump}" ] || die "no dump for ${db} in that snapshot"
    gunzip -c "${dump}" | docker exec -i -e PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}" core-postgres \
      psql -U "${POSTGRES_SUPERUSER}" -d "${db}"
  else
    local dump
    dump="$(find "${WORK}/extract" -path "*/mariadb-dumps/*" -name "latest.${db}.sql.gz" | head -1)"
    [ -n "${dump}" ] || die "no dump for ${db} in that snapshot"
    docker exec -i apps-mariadb mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" \
      -e "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    gunzip -c "${dump}" | docker exec -i apps-mariadb mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" "${db}"
  fi
  ok "${db} restored"
}

case "${ACTION}" in
  full)  restore_full ;;
  db)    restore_db "$@" ;;
  list)  list_snapshots ;;
  *) die "usage: $0 {core|apps} {full|db <name>|list}" ;;
esac
