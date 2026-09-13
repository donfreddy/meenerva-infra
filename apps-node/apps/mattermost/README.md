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
2. **GitLab OAuth as a workaround (confirmed viable, do this).** Team Edition
   *does* include a built-in "Sign in with GitLab" OAuth2 integration, and its
   endpoint fields accept any OAuth2-compatible server, not only gitlab.com -
   a well-known, legitimate self-hosting trick, not a hack that might break at
   any moment. Steps:

   **In Keycloak** (realm `meenerva`):
   1. Clients -> Create: ID `mattermost`, Client authentication: On, Standard
      flow: On, Valid redirect URI
      `https://chat.meenerva.io/signup/gitlab/complete` (also add
      `https://chat.meenerva.io/login/gitlab/complete`).
   2. **Add a protocol mapper so Mattermost's GitLab-shaped parser finds what
      it expects.** Mattermost's GitLab integration reads a `username` field
      from the user-info response, because that is what GitLab's own API
      calls it; Keycloak's default claim is `preferred_username`, not
      `username`, and login will fail on a missing-field error without this.
      On the `mattermost` client -> Client scopes -> its dedicated scope ->
      **Add mapper -> By configuration -> User Property**: Name `username`,
      Property `username`, Token Claim Name `username`, add to ID token +
      access token + userinfo.
   3. Copy the client secret.

   **In Mattermost** (System Console -> Authentication -> GitLab):
   - Enable
   - Application ID: the Keycloak client ID (`mattermost`)
   - Application Secret: the Keycloak client secret
   - User API Endpoint: `https://id.meenerva.io/realms/meenerva/protocol/openid-connect/userinfo`
   - Auth Endpoint: `https://id.meenerva.io/realms/meenerva/protocol/openid-connect/auth`
   - Token Endpoint: `https://id.meenerva.io/realms/meenerva/protocol/openid-connect/token`

   Optionally rename the login button's label from "GitLab" in Mattermost's
   custom branding settings so it reads "Keycloak" / "MEENERVA SSO" instead -
   cosmetic only, does not change the underlying mechanism.
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

> To-Do: Mattermost cannot reach Stalwart via the tunnel for SMTP (Not
> blocking access to the site, but will prevent email notifications).
> Root-caused (not yet fixed) via `tcpdump`: Stalwart's own container sends
> an immediate TCP RST to mesh-sourced connections - it is not a
> network/firewall issue (D-14/D-16's fixes are all correctly in place).
> Adding `10.10.0.0/24` to Stalwart's Allowed IPs and restarting it did not
> help. See D-16's final update in
> [`02-architecture-decisions.md`](../../../docs/02-architecture-decisions.md)
> before retrying - do not re-probe with bare `nc`, it may be
> self-perpetuating the block.
