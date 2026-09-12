#!/usr/bin/env bash
# =============================================================================
# new-app.sh :: scaffold apps-node/apps/<name>/ from the _template.
#
#   ./scripts/new-app.sh metabase
#
# Then edit the generated docker-compose.yml (replace APPNAME / SUBDOMAIN /
# ports / image) and follow docs/08-adding-an-app.md.
# =============================================================================
# shellcheck source=SCRIPTDIR/lib/common.sh
source "$(dirname "$0")/lib/common.sh"

NAME="${1:-}"
[ -n "${NAME}" ] || die "usage: $0 <app-name>"
[[ "${NAME}" =~ ^[a-z][a-z0-9-]*$ ]] || die "app name must be lowercase alnum/hyphen"

SRC="${REPO_ROOT}/apps-node/apps/_template"
DST="${REPO_ROOT}/apps-node/apps/${NAME}"

[ -d "${DST}" ] && die "${DST} already exists"

cp -r "${SRC}" "${DST}"
# Underscore form for DB/role/env-var names (hyphens are invalid there).
SLUG_UNDERSCORE="${NAME//-/_}"

for f in "${DST}/docker-compose.yml" "${DST}/.env.example" "${DST}/README.md"; do
  sed -i.bak \
    -e "s/APPNAME_/${SLUG_UNDERSCORE^^}_/g" \
    -e "s/app_APPNAME/app_${SLUG_UNDERSCORE}/g" \
    -e "s/APPNAME/${NAME}/g" \
    -e "s/SUBDOMAIN/${NAME}/g" \
    "$f"
  rm -f "${f}.bak"
done

ok "scaffolded ${DST}"
echo "  next:"
echo "   1. edit ${DST}/docker-compose.yml (image, port, subdomain, env)"
echo "   2. ./scripts/create-app-database.sh ${SLUG_UNDERSCORE}   # on core-node, if it needs Postgres"
echo "   3. create the Keycloak client '${NAME}'"
echo "   4. add DNS: ${NAME} A <apps-node-ip>"
echo "   5. deploy with: make app-up NAME=${NAME}"
echo "   6. update docs/03-naming-conventions.md and docs/09-roadmap.md"
