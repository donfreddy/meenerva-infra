# EspoCRM

- **Node:** apps-node
- **Subdomain:** `crm.meenerva.io`
- **Database:** `app_espocrm` on the shared `apps-mariadb` (MySQL/MariaDB
  only - EspoCRM does not support Postgres)
- **Keycloak client:** `espocrm` (confidential, OIDC - EspoCRM supports this
  natively, free, self-hosted - no workaround needed unlike Mattermost/no
  option at all unlike DocuSeal)
- **Upstream docs:** <https://docs.espocrm.com/administration/docker/installation/>,
  <https://docs.espocrm.com/administration/oidc/>

## Deploy

**First time only - bring up the shared MariaDB** (this is the first app on
apps-node needing MySQL, see `apps-node/docker-compose.yml`'s `mariadb`
service comment):

1. Set `MARIADB_ROOT_PASSWORD` in `apps-node/.env`
2. `make apps-up` (brings up/updates the apps-node edge stack, including the
   new `mariadb` service, alongside Traefik)
3. Confirm it is healthy: `docker ps --filter name=apps-mariadb`

**Then, for EspoCRM itself:**

1. `./scripts/create-mysql-database.sh espocrm` (on apps-node)
2. DNS: `crm A <apps-node-ip>`
3. `cp apps-node/apps/espocrm/.env.example apps-node/apps/espocrm/.env`,
   fill in `ESPOCRM_DB_PASSWORD` (step 1) and a real
   `ESPOCRM_ADMIN_PASSWORD`
4. `./scripts/check-images.sh apps-node/apps/espocrm/docker-compose.yml`
5. `make app-up NAME=espocrm`
6. Verify the healthcheck's tool actually exists before trusting it stays
   green: `docker exec apps-espocrm which curl wget nc` - swap the
   `docker-compose.yml` healthcheck command if `curl` is missing (see the
   comment there and the DocuSeal precedent in
   [`02-architecture-decisions.md`](../../../docs/02-architecture-decisions.md))
7. Open `https://crm.meenerva.io` and log in with `ESPOCRM_ADMIN_USERNAME`/
   `ESPOCRM_ADMIN_PASSWORD` - **no setup-wizard race window this time**: the
   admin account is created from the env vars during the container's first
   boot, not from whoever visits the URL first.

## Outbound mail (Stalwart)

No documented env var sets SMTP for this image, so configure it once, by
hand, in **Administration -> Outbound Emails**:

- Server: `mail.meenerva.io` (or `10.10.0.1` from apps-node)
- Port: `587`, Security: `STARTTLS`
- Username / password: the `no-reply@meenerva.io` mailbox credentials
  (`MAIL_FROM` / `MAIL_FROM_PASSWORD` in `apps-node/.env`)
- **From address:** `no-reply@meenerva.io`

## SSO (Keycloak OIDC - do this, it actually works here)

Unlike Mattermost (no free OIDC) or DocuSeal (no free SSO at all), EspoCRM
has real, native, free OIDC support. Set it up:

**In Keycloak** (realm `meenerva`):
1. Clients -> Create: ID `espocrm`, Client authentication: On, Standard
   flow: On. Leave the redirect URI blank for now - EspoCRM shows you the
   exact URI to paste, see step 2 below (do not guess it).
2. In EspoCRM: **Administration -> Authentication -> OIDC**, enable it, then
   copy the **Authorization Redirect URI** field it displays.
3. Back in Keycloak, paste that value into the `espocrm` client's Valid
   Redirect URIs. Copy the client secret from the Credentials tab.

**In EspoCRM** (Administration -> Authentication -> OIDC):
- Client ID / Client Secret: from the Keycloak client above
- Authorization Endpoint: `https://id.meenerva.io/realms/meenerva/protocol/openid-connect/auth`
- Token Endpoint: `https://id.meenerva.io/realms/meenerva/protocol/openid-connect/token`
- Userinfo Endpoint: `https://id.meenerva.io/realms/meenerva/protocol/openid-connect/userinfo`
- JWKS Endpoint: `https://id.meenerva.io/realms/meenerva/protocol/openid-connect/certs`
- Username Claim: `preferred_username` (Keycloak's default claim name - no
  custom protocol mapper needed here, unlike Mattermost's GitLab workaround)
- Allow user creation on first login: on, so a Keycloak login provisions the
  EspoCRM side automatically (see docs/10 section 4/6 - Keycloak stays the
  only place accounts are created)
- Group Claim / team mapping: optional, wire up later against the
  `groups` claim if EspoCRM team-based permissions need to follow Keycloak
  group membership

Keep exactly one local EspoCRM admin as the break-glass account (docs/10
section 4), same as every other app.

## Notes

- **`espocrm-daemon` restarting in a loop right after a fresh deploy is
  normal, not a bug**: its entrypoint prints `Waiting for the main container
  to be ready...` and exits/retries until `espocrm`'s install finishes
  (confirmed live 2026-09-13, resolved on its own once `espocrm` logged
  `Installation completed successfully`). Only investigate further if it is
  still restarting a few minutes after `espocrm` itself reports healthy.
- `espocrm-daemon` **must stay running** - it handles scheduled jobs,
  workflow automation, and the outbound email queue. If emails or workflows
  silently stop, check this container first, not just `espocrm`.
- `espocrm-daemon` shares `espocrm`'s three volumes via `volumes_from`, not
  its own copy of the mount list - this guarantees they can never drift out
  of sync (both containers must see identical `data`/`custom`/`client/custom`
  state, or scheduled jobs and customizations diverge from what the web UI
  sees).
- **Only three subdirectories are mounted** (`data`, `custom`,
  `client/custom`) - never mount the whole `/var/www/html`. Confirmed live
  2026-09-13: EspoCRM's own entrypoint detects a full-tree mount as the
  "legacy installation method" and permanently disables in-place upgrades
  for that install. If you ever see that warning in `docker logs
  apps-espocrm`, the volumes are wrong - fix the mounts before doing
  anything else, don't just ignore the warning.
- Add `espocrm-data`, `espocrm-custom`, `espocrm-client-custom` to
  `apps-node/docker-compose.yml`'s `offsite-backup.volumes` once real data
  exists - `espocrm-data` holds uploads AND the generated `data/config.php`
  (DB credentials, install state), not just attachments.
- Real-time websocket notifications are deliberately left commented out in
  `docker-compose.yml` - the UI works fine on polling; only enable it if a
  concrete need for live push shows up.
