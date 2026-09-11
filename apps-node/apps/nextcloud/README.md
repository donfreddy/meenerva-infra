# Nextcloud + Collabora

- **Node:** apps-node
- **Subdomains:** `cloud.meenerva.io` (Nextcloud), `office.meenerva.io` (Collabora)
- **Database:** `app_nextcloud` on core-postgres
- **Redis index:** 3
- **Keycloak client:** `nextcloud` (via the *Social Login* or *OIDC* app; redirect
  `https://cloud.meenerva.io/apps/user_oidc/code`)

## Deploy

1. On core-node: `./scripts/create-app-database.sh nextcloud`
2. DNS: `cloud A <apps-ip>`, `office A <apps-ip>`
3. Portainer (apps-node) -> Stacks -> Repository ->
   `apps-node/apps/nextcloud/docker-compose.yml`, env from `.env.example`
4. First load `https://cloud.meenerva.io`, complete the admin setup (DB fields are
   pre-filled from env).
5. Install the **OpenID Connect user backend** app, point it at
   `https://id.meenerva.io/realms/meenerva`.
6. Settings -> Administration -> Office: set the Collabora URL to
   `https://office.meenerva.io`.

## Backup

Add to `apps-node/docker-compose.yml` `offsite-backup.volumes`:

```
- nextcloud-data:/backup/nextcloud-data:ro
- nextcloud-html:/backup/nextcloud-html:ro
```

Also enable Nextcloud's own `occ` DB dump or rely on the nightly core-postgres
dump of `app_nextcloud`.

## Mail app (primary mail client - decision D-11)

Nextcloud Mail is the primary web mail client for the studio. It connects to
Stalwart on core-node over the **public** endpoint so the TLS certificate name
matches (never `10.10.0.1` for IMAP):

```
IMAP  mail.meenerva.io : 993  SSL/TLS
SMTP  mail.meenerva.io : 587  STARTTLS
```

### Install + baseline

```
occ app:install mail
occ app:enable mail
```

### Auth: app password (works now)

Each user creates an app-specific password in Stalwart
(`https://mail.meenerva.io` -> Account -> App passwords) and adds the account once
in Nextcloud Mail. Pre-fill new accounts by shipping a provisioning config:

```
occ config:app:set mail provisioning_settings --value='[
  {
    "provisioningDomain": "meenerva.io",
    "imapHost": "mail.meenerva.io", "imapPort": 993, "imapSslMode": "ssl",
    "imapUser": "%EMAIL%",
    "smtpHost": "mail.meenerva.io", "smtpPort": 587, "smtpSslMode": "tls",
    "smtpUser": "%EMAIL%",
    "sieveEnabled": true, "sieveHost": "mail.meenerva.io", "sievePort": 4190
  }
]'
```

### Auth: XOAUTH2 / SSO (target, Phase 2)

Once the Keycloak directory backend is live in Stalwart (`[directory.oidc]` in
`core-node/stalwart/config/config.toml`), enable `OAUTHBEARER` / `XOAUTH2` on
Stalwart's IMAP/SMTP and configure the Mail app's OAuth connection so the user's
Keycloak token is used and no mailbox password is stored.

Bulwark Webmail on core-node (`webmail.meenerva.io`) stays available as the
native JMAP standalone / fallback client.

## Notes

- Run `occ maintenance:repair` and the recommended cron (`nextcloud-cron`
  sidecar) once traffic grows; add a `nextcloud-cron` service using the same
  image with `entrypoint: /cron.sh`.
- Large-file uploads: `readTimeout` is already raised to 600s in Traefik.
