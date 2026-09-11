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
4. Portainer (apps-node) -> Stacks -> Add stack -> Repository ->
   `apps-node/apps/APPNAME/docker-compose.yml`
5. Set the stack environment from `.env.example`

## Backup

Add `APPNAME-data` to the `offsite-backup` volume list in
`apps-node/docker-compose.yml`.

## Notes

<anything operationally important: migrations, first-run admin, quirks>
