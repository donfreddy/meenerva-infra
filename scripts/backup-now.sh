#!/usr/bin/env bash
# =============================================================================
# backup-now.sh :: trigger an on-demand backup (does not wait for the cron).
# Run on the node whose stack you want to back up.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
require_cmd docker

NODE="${1:-core}"
case "${NODE}" in
  core)
    PG_BACKUP=core-postgres-backup
    OFFSITE=core-offsite-backup
    ;;
  apps)
    PG_BACKUP=""
    OFFSITE=apps-offsite-backup
    ;;
  *) die "usage: $0 {core|apps}" ;;
esac

if [ -n "${PG_BACKUP}" ] && docker ps --format '{{.Names}}' | grep -qx "${PG_BACKUP}"; then
  log "Running PostgreSQL dump (${PG_BACKUP})"
  docker exec "${PG_BACKUP}" /backup.sh
  ok "SQL dumps written to the backup-dumps volume"
fi

docker ps --format '{{.Names}}' | grep -qx "${OFFSITE}" || die "${OFFSITE} not running"
log "Running off-site backup to Backblaze B2 (${OFFSITE})"
docker exec "${OFFSITE}" backup
ok "off-site backup complete - check the B2 bucket"
