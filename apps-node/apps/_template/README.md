# APPNAME

> Replace this file when scaffolding a real app.

- **Node:** apps-node
- **Subdomain:** `SUBDOMAIN.meenerva.io`
- **Database:** `app_APPNAME` on core-postgres (`./scripts/create-app-database.sh APPNAME`)
- **Redis index:** `<n>` (record it in `core-node/.env.example`)
- **Keycloak client:** `APPNAME` (confidential, redirect `https://SUBDOMAIN.meenerva.io/*`)
- **Upstream docs:** <link>

## Deploy

1. `./scripts/create-app-database.sh APPNAME` (on core-node)
2. Create the Keycloak client, copy the secret
3. Add `SUBDOMAIN A <apps-node-ip>` to DNS
4. `cp apps-node/apps/APPNAME/.env.example apps-node/apps/APPNAME/.env` and fill it in
5. `./scripts/check-images.sh apps-node/apps/APPNAME/docker-compose.yml`
6. `make app-up NAME=APPNAME`

## Backup

Add `APPNAME-data` to the `offsite-backup` volume list in
`apps-node/docker-compose.yml`.

## Notes

<anything operationally important: migrations, first-run admin, quirks>
