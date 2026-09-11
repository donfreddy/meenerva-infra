#!/bin/bash
# =============================================================================
# Runs ONCE, only when core-postgres initialises an empty data directory.
# Creates the isolated database + role for each core-node app that needs one.
#
# For apps added later (Nextcloud, Mattermost, ...), use:
#   ./scripts/create-app-database.sh <name>
# which performs the same steps against the running server.
#
# Password source: environment variables passed to the postgres container in
# docker-compose.yml (KEYCLOAK_DB_PASSWORD, N8N_DB_PASSWORD, STALWART_DB_PASSWORD).
# =============================================================================
set -euo pipefail

create_app_db() {
  local app="$1" pass="$2"
  if [ -z "${pass}" ] || [ "${pass}" = "CHANGE_ME" ]; then
    echo "SKIP app_${app}: password not set in .env"
    return 0
  fi
  echo "Creating database app_${app} and role app_${app}"
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname postgres <<-SQL
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_${app}') THEN
        CREATE ROLE app_${app} LOGIN PASSWORD '${pass}';
      ELSE
        ALTER ROLE app_${app} PASSWORD '${pass}';
      END IF;
    END
    \$\$;
SQL
  if ! psql -tAc "SELECT 1 FROM pg_database WHERE datname = 'app_${app}'" \
        --username "${POSTGRES_USER}" --dbname postgres | grep -q 1; then
    createdb --username "${POSTGRES_USER}" --owner "app_${app}" "app_${app}"
  fi
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "app_${app}" <<-SQL
    REVOKE ALL ON SCHEMA public FROM PUBLIC;
    GRANT ALL ON SCHEMA public TO app_${app};
SQL
}

create_app_db "keycloak" "${KEYCLOAK_DB_PASSWORD:-}"
create_app_db "n8n"      "${N8N_DB_PASSWORD:-}"
create_app_db "stalwart" "${STALWART_DB_PASSWORD:-}"

echo "Core database provisioning complete."
