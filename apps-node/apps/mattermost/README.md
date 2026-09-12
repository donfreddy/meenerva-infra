# Mattermost

- **Node:** apps-node
- **Subdomain:** `chat.meenerva.io`
- **Database:** `app_mattermost` on core-postgres
- **Edition:** Team Edition (free) - see the SSO note below before assuming
  Keycloak SSO will just work

## Deploy

1. On core-node: `./scripts/create-app-database.sh mattermost`
2. DNS: `chat A <apps-node-ip>`
3. `cp apps-node/apps/mattermost/.env.example apps-node/apps/mattermost/.env`,
   fill in `MATTERMOST_DB_PASSWORD` (from step 1) and the mail settings
4. `./scripts/check-images.sh apps-node/apps/mattermost/docker-compose.yml`
5. `make app-up NAME=mattermost`
6. Open `https://chat.meenerva.io` - the **first account created is the
   System Admin**, do this immediately (same "don't leave the setup window
   open" caution as Portainer/Nextcloud elsewhere in this repo)

## SSO (read this before configuring)

**Generic OpenID Connect is an Enterprise/Professional-only feature in
Mattermost** - it is not available in Team Edition, which is what this repo
deploys (free, no license needed). Do not expect a Keycloak client + env vars
to give you SSO here the way it did for Nextcloud.

Practical options, in order of effort:

1. **Do nothing for now.** Use Mattermost's own username/password accounts
   (create a break-glass admin manually, per
   [`10-identity-keycloak.md`](../../../docs/10-identity-keycloak.md) section
   4's "keeping Keycloak the only place accounts are created" note - this is
   the one deliberate exception, same as every other app's local admin).
2. **GitLab OAuth as a workaround.** Team Edition *does* include a built-in
   "Sign in with GitLab" OAuth2 integration. Keycloak can be configured to
   answer GitLab-shaped OAuth2 endpoints (a well-known self-hosting trick),
   giving SSO without Enterprise. Not set up here - verify the current
   Keycloak/Mattermost versions still support this pairing before investing
   time in it, and treat it as a distinct task, not a quick follow-up.
3. **Mattermost Enterprise.** Has a free tier for small teams in some
   licensing generations - check current Mattermost licensing before
   assuming this is free at your team size.

No OIDC environment variables are pre-set in `docker-compose.yml` for this
reason - avoid guessing at `MM_OPENIDSETTINGS_*` values for a feature that may
not even be unlocked in this edition.

## Notes

- First admin account creation happens through the web UI on first visit,
  not an env var - there is no bootstrap-admin equivalent to Keycloak's
  `KC_BOOTSTRAP_ADMIN_*` here.
- Add `mattermost-data` to `apps-node/docker-compose.yml`'s
  `offsite-backup.volumes` once real data exists (uploaded files live there;
  messages themselves are in `app_mattermost`, already covered by the
  nightly core-postgres dump).
