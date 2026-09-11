#!/usr/bin/env bash
# =============================================================================
# create-app-database.sh :: create an isolated database + role in core-postgres.
# Run on core-node. Idempotent (re-running only resets the password).
#
#   ./scripts/create-app-database.sh <app>            # generates a password
#   APP_DB_PASSWORD=... ./scripts/create-app-database.sh <app>   # use a given one
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
PASS="${APP_DB_PASSWORD:-$(gen_secret)}"
DB="app_${APP}"
ROLE="app_${APP}"

docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}" || die "container ${CONTAINER} is not running"

log "Provisioning ${DB} / ${ROLE} in ${CONTAINER}"
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
ok "Done. Store this password now (shown once):"
echo
echo "    app:      ${APP}"
echo "    database: ${DB}"
echo "    user:     ${ROLE}"
echo "    password: ${PASS}"
echo
echo "  From core-node containers:  host=core-postgres port=5432"
echo "  From apps-node containers:   host=10.10.0.1     port=5432"
