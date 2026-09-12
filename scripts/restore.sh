#!/usr/bin/env bash
# =============================================================================
# restore.sh :: guided restore from Backblaze B2.
# Run on a freshly bootstrapped node with core-node/.env already recreated.
#
# Two modes:
#   full            restore volumes + all databases from the latest snapshot
#   db <name>       restore a single database from the newest local/B2 dump
#
# This script is deliberately interactive and asks before destructive steps.
# =============================================================================
# shellcheck source=SCRIPTDIR/lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker aws

load_env "${REPO_ROOT}/core-node/.env"

export AWS_ACCESS_KEY_ID="${B2_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${B2_SECRET_ACCESS_KEY}"
S3="aws --endpoint-url ${B2_S3_ENDPOINT} s3"
PREFIX="s3://${B2_BUCKET}/core-node"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

list_snapshots() {
  log "Available snapshots in ${PREFIX}:"
  ${S3} ls "${PREFIX}/" | awk '{print "   ", $4}' | sort
}

restore_full() {
  list_snapshots
  read -r -p "Snapshot filename to restore: " SNAP
  [ -n "${SNAP}" ] || die "no snapshot given"
  log "Downloading ${SNAP}"
  ${S3} cp "${PREFIX}/${SNAP}" "${WORK}/${SNAP}"

  log "Decrypting + extracting"
  gpg --batch --yes --passphrase "${RESTIC_PASSWORD}" -o "${WORK}/archive.tar.gz" -d "${WORK}/${SNAP}"
  mkdir -p "${WORK}/extract"
  tar -xzf "${WORK}/archive.tar.gz" -C "${WORK}/extract"

  warn "About to restore volumes and databases. The core stack should be DOWN."
  confirm "Proceed?" || die "aborted"

  # Volumes
  for vol in stalwart-data n8n-data traefik-acme; do
    src="${WORK}/extract/backup/${vol}"
    [ -d "${src}" ] || { warn "no ${vol} in snapshot, skipping"; continue; }
    log "Restoring volume ${vol}"
    docker volume create "meenerva-core_${vol}" >/dev/null
    docker run --rm -v "meenerva-core_${vol}:/dst" -v "${src}:/src:ro" alpine \
      sh -c 'rm -rf /dst/* && cp -a /src/. /dst/'
  done

  # Databases
  log "Starting only core-postgres to load dumps"
  docker compose --project-directory "${REPO_ROOT}/core-node" --env-file "${REPO_ROOT}/core-node/.env" up -d postgres
  sleep 10
  for dump in "${WORK}/extract/backup/pg-dumps"/*.sql.gz; do
    [ -e "${dump}" ] || { warn "no SQL dumps in snapshot"; break; }
    db="$(basename "${dump}" | sed -E 's/-[0-9]{8}-[0-9]{6}\.sql\.gz$//; s/\.sql\.gz$//')"
    log "Loading ${db}"
    gunzip -c "${dump}" | docker exec -i -e PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}" core-postgres \
      psql -U "${POSTGRES_SUPERUSER}" -d "${db}"
  done
  ok "Full restore done. Now: make core-up"
}

restore_db() {
  local db="app_${1:?usage: restore.sh db <name>}"
  list_snapshots
  warn "This DROPS and reloads ${db}."
  confirm "Proceed?" || die "aborted"
  read -r -p "Snapshot filename containing the dump: " SNAP
  ${S3} cp "${PREFIX}/${SNAP}" "${WORK}/${SNAP}"
  gpg --batch --yes --passphrase "${RESTIC_PASSWORD}" -o "${WORK}/a.tar.gz" -d "${WORK}/${SNAP}"
  tar -xzf "${WORK}/a.tar.gz" -C "${WORK}"
  dump="$(find "${WORK}" -name "${db}*.sql.gz" | head -1)"
  [ -n "${dump}" ] || die "no dump for ${db} in that snapshot"
  gunzip -c "${dump}" | docker exec -i -e PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}" core-postgres \
    psql -U "${POSTGRES_SUPERUSER}" -d "${db}"
  ok "${db} restored"
}

case "${1:-full}" in
  full)  restore_full ;;
  db)    shift; restore_db "$@" ;;
  list)  list_snapshots ;;
  *) die "usage: $0 {full|db <name>|list}" ;;
esac
