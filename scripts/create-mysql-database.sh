#!/usr/bin/env bash
# =============================================================================
# create-mysql-database.sh :: create an isolated database + user in the shared
# apps-mariadb. Run on apps-node. Safe to re-run: if the user already exists,
# its password is left untouched by default (see ROTATE below) - mirrors
# scripts/create-app-database.sh's behavior for core-postgres (same lesson:
# a bare re-run must be a no-op, not a silent password rotation).
#
#   ./scripts/create-mysql-database.sh <app>              # create if missing; never touches an existing password
#   APP_DB_PASSWORD=... ./scripts/create-mysql-database.sh <app>   # create (or set) with this exact password
#   ROTATE=1 ./scripts/create-mysql-database.sh <app>      # force a NEW random password on an existing user
#
# Result: database app_<app>, user app_<app>@'%' (scoped to apps-internal's
# subnet in practice - MariaDB itself is not reachable outside that Docker
# network, see apps-node/docker-compose.yml), all privileges on app_<app> only.
# =============================================================================
# shellcheck source=SCRIPTDIR/lib/common.sh
source "$(dirname "$0")/lib/common.sh"

APP="${1:-}"
[ -n "${APP}" ] || die "usage: $0 <app>"
[[ "${APP}" =~ ^[a-z][a-z0-9_]*$ ]] || die "app name must be lowercase alnum/underscore"

load_env "${REPO_ROOT}/apps-node/.env"

CONTAINER="${MARIADB_CONTAINER:-apps-mariadb}"
DB="app_${APP}"
USER="app_${APP}"

EXPLICIT_PASSWORD=0
[ -n "${APP_DB_PASSWORD:-}" ] && EXPLICIT_PASSWORD=1
PASS="${APP_DB_PASSWORD:-$(gen_secret)}"

docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}" || die "container ${CONTAINER} is not running"

USER_EXISTS="$(docker exec -i "${CONTAINER}" \
  mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" -N -B \
  -e "SELECT COUNT(*) FROM mysql.user WHERE User='${USER}'")"

if [ "${USER_EXISTS}" = "1" ] && [ "${EXPLICIT_PASSWORD}" -eq 0 ] && [ "${ROTATE:-0}" != "1" ]; then
  log "User ${USER} already exists - leaving its password untouched (pass APP_DB_PASSWORD=... or ROTATE=1 to change it)"
  SET_PASSWORD=0
else
  SET_PASSWORD=1
fi

log "Provisioning ${DB} / ${USER} in ${CONTAINER}"

docker exec -i "${CONTAINER}" mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL

if [ "${SET_PASSWORD}" -eq 1 ]; then
  docker exec -i "${CONTAINER}" mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" <<SQL
CREATE USER IF NOT EXISTS '${USER}'@'%' IDENTIFIED BY '${PASS}';
ALTER USER '${USER}'@'%' IDENTIFIED BY '${PASS}';
GRANT ALL PRIVILEGES ON \`${DB}\`.* TO '${USER}'@'%';
FLUSH PRIVILEGES;
SQL
else
  docker exec -i "${CONTAINER}" mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" <<SQL
CREATE USER IF NOT EXISTS '${USER}'@'%' IDENTIFIED BY '${PASS}';
GRANT ALL PRIVILEGES ON \`${DB}\`.* TO '${USER}'@'%';
FLUSH PRIVILEGES;
SQL
fi

echo
if [ "${SET_PASSWORD}" -eq 1 ]; then
  ok "Done. Store this password now (shown once):"
  echo
  echo "    app:      ${APP}"
  echo "    database: ${DB}"
  echo "    user:     ${USER}"
  echo "    password: ${PASS}"
  echo
  echo "  From apps-node containers on apps-internal:  host=apps-mariadb  port=3306"
  [ "${USER_EXISTS}" = "1" ] && warn "This ROTATED an existing user's password - update the app's *_DB_PASSWORD in .env and redeploy it now, or it will start failing to connect."
else
  ok "Done. ${DB}/${USER} already provisioned, password left as-is (not shown - it wasn't changed)."
fi
