#!/usr/bin/env bash
# =============================================================================
# create-app-database.sh :: create an isolated database + role in core-postgres.
# Run on core-node. Safe to re-run: if the role already exists, its password is
# left untouched by default (see ROTATE below) - this script is meant to be
# safe to run again "just to check", not a way to silently break a running app.
#
#   ./scripts/create-app-database.sh <app>              # create if missing; never touches an existing password
#   APP_DB_PASSWORD=... ./scripts/create-app-database.sh <app>   # create (or set) with this exact password
#   ROTATE=1 ./scripts/create-app-database.sh <app>      # force a NEW random password on an existing role
#
# Result: database app_<app> owned by role app_<app> (LOGIN only, no CREATEDB,
# no SUPERUSER, schema public locked to the owner).
# =============================================================================
# shellcheck source=SCRIPTDIR/lib/common.sh
source "$(dirname "$0")/lib/common.sh"

APP="${1:-}"
[ -n "${APP}" ] || die "usage: $0 <app>"
[[ "${APP}" =~ ^[a-z][a-z0-9_]*$ ]] || die "app name must be lowercase alnum/underscore"

load_env "${REPO_ROOT}/core-node/.env"

CONTAINER="${POSTGRES_CONTAINER:-core-postgres}"
DB="app_${APP}"
ROLE="app_${APP}"

# Only rotate an EXISTING role's password if the caller explicitly asked for
# it (a real password, or ROTATE=1). A bare re-run must be a no-op on an
# already-provisioned role, or every app connected to it breaks silently the
# next time it opens a new connection.
EXPLICIT_PASSWORD=0
[ -n "${APP_DB_PASSWORD:-}" ] && EXPLICIT_PASSWORD=1
PASS="${APP_DB_PASSWORD:-$(gen_secret)}"

docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}" || die "container ${CONTAINER} is not running"

ROLE_EXISTS="$(docker exec -i -e PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}" "${CONTAINER}" \
  psql -tAqc "SELECT 1 FROM pg_roles WHERE rolname='${ROLE}'" -U "${POSTGRES_SUPERUSER}" -d postgres)"

if [ "${ROLE_EXISTS}" = "1" ] && [ "${EXPLICIT_PASSWORD}" -eq 0 ] && [ "${ROTATE:-0}" != "1" ]; then
  log "Role ${ROLE} already exists - leaving its password untouched (pass APP_DB_PASSWORD=... or ROTATE=1 to change it)"
  SET_PASSWORD=0
else
  SET_PASSWORD=1
fi

log "Provisioning ${DB} / ${ROLE} in ${CONTAINER}"
if [ "${SET_PASSWORD}" -eq 1 ]; then
  docker exec -i -e PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}" "${CONTAINER}" \
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_SUPERUSER}" -d postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${ROLE}') THEN
    CREATE ROLE ${ROLE} LOGIN PASSWORD '${PASS}';
  ELSE
    ALTER ROLE ${ROLE} PASSWORD '${PASS}';
  END IF;
END
\$\$;
SQL
else
  docker exec -i -e PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}" "${CONTAINER}" \
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_SUPERUSER}" -d postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${ROLE}') THEN
    CREATE ROLE ${ROLE} LOGIN PASSWORD '${PASS}';
  END IF;
END
\$\$;
SQL
fi

if ! docker exec -i -e PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}" "${CONTAINER}" \
      psql -tAqc "SELECT 1 FROM pg_database WHERE datname='${DB}'" -U "${POSTGRES_SUPERUSER}" -d postgres | grep -q 1; then
  docker exec -i -e PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}" "${CONTAINER}" \
    createdb -U "${POSTGRES_SUPERUSER}" -O "${ROLE}" "${DB}"
  ok "database ${DB} created"
else
  ok "database ${DB} already exists"
fi

docker exec -i -e PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}" "${CONTAINER}" \
  psql -v ON_ERROR_STOP=1 -U "${POSTGRES_SUPERUSER}" -d "${DB}" <<SQL
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO ${ROLE};
ALTER DATABASE ${DB} OWNER TO ${ROLE};
SQL

echo
if [ "${SET_PASSWORD}" -eq 1 ]; then
  ok "Done. Store this password now (shown once):"
  echo
  echo "    app:      ${APP}"
  echo "    database: ${DB}"
  echo "    user:     ${ROLE}"
  echo "    password: ${PASS}"
  echo
  echo "  From core-node containers:  host=core-postgres port=5432"
  echo "  From apps-node containers:   host=10.10.0.1     port=5432"
  [ "${ROLE_EXISTS}" = "1" ] && warn "This ROTATED an existing role's password - update the app's *_DB_PASSWORD in .env and redeploy it now, or it will start failing to connect."
else
  ok "Done. ${DB}/${ROLE} already provisioned, password left as-is (not shown - it wasn't changed)."
fi
