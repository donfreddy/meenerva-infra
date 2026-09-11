# 05 - DNS and mail (Stalwart)

Placeholder domain: `meenerva.io`. Placeholder IPs: core `203.0.113.10`,
apps `203.0.113.20`.

## 1. DNS zone

### Web / A records

| Name | Type | Value | Notes |
|------|------|-------|-------|
| `meenerva.io` | A | `203.0.113.10` | apex -> core (landing / redirect) |
| `traefik` `portainer` `id` `mail` `webmail` `n8n` | A | `203.0.113.10` | core-node |
| `autoconfig` `autodiscover` | CNAME | `mail.meenerva.io.` | mail client discovery |
| `cloud` `office` `chat` `project` `sign` `erp` | A | `203.0.113.20` | apps-node |
| `*` (optional wildcard) | A | `203.0.113.20` | catch-all for new apps-node apps |

Add AAAA records if the VPS has IPv6 (recommended for mail).

### Mail records

| Name | Type | Value |
|------|------|-------|
| `meenerva.io` | MX | `10 mail.meenerva.io.` |
| `mail` | A / AAAA | core-node IPs |
| `meenerva.io` | TXT (SPF) | `v=spf1 mx a:mail.meenerva.io include:<relay-spf> -all` |
| `<selector>._domainkey` | TXT (DKIM) | public key emitted by Stalwart on first run |
| `_dmarc` | TXT | `v=DMARC1; p=quarantine; rua=mailto:dmarc@meenerva.io; ruf=mailto:dmarc@meenerva.io; fo=1; adkim=s; aspf=s` |
| `_mta-sts` | TXT | `v=STSv1; id=<timestamp>` |
| `mta-sts` | A/CNAME | core-node (serves `/.well-known/mta-sts.txt` via Traefik) |
| `_smtp._tls` | TXT | `v=TLSRPTv1; rua=mailto:tls-reports@meenerva.io` |

Replace `<relay-spf>` with the `include:` your transactional provider gives you
(e.g. `include:amazonses.com`). If you do **not** use a relay initially, drop the
`include:` and keep `v=spf1 mx a:mail.meenerva.io -all`.

### Reverse DNS (PTR) - do not skip

In the **Contabo control panel**, set the rDNS of the core-node IP(s) to
`mail.meenerva.io`. Missing or mismatched PTR is the number-one reason outbound
mail is rejected. This is why mail is pinned to core-node (decision D-07): the IP
must be stable.

## 2. Stalwart configuration

Since **v0.16**, Stalwart no longer reads a `config.toml` at all: every setting
(domains, DKIM, directory backend, relay, TLS) lives in its own internal store
(`/etc/stalwart`, the `stalwart-etc` Docker volume) and is managed through the web
admin UI / JMAP management API. Runtime mail data (mailboxes, indexes, generated
keys) is in the separate `stalwart-data` volume. There is nothing to hand-edit in
this repo for Stalwart itself - see
[`core-node/stalwart/README.md`](../core-node/stalwart/README.md).

> **Do this within minutes of DNS going live, not hours.** Stalwart auto-bans IPs
> it judges abusive (scanning, rapid requests). Because every request reaches it
> through Traefik, Stalwart only ever sees **Traefik's container IP**, never the
> real visitor - so once a bot scans `mail.meenerva.io` (they find new MX records
> within minutes), Stalwart can ban "the visitor" and lock out everyone, including
> you, with the whole HTTP surface returning 502 until the ban is cleared. The ban
> is written to the `stalwart-data` volume, so a container restart does not clear
> it. See the [community report](https://support.stalw.art/t/cant-finish-initial-install-my-ip-is-blacklisted/1644)
> of this exact failure mode.
>
> **If you get a 502 on `mail.meenerva.io` before finishing the wizard**, nothing
> of value is configured yet - clear it and start over:
> ```sh
> docker compose --project-directory core-node --env-file core-node/.env stop stalwart
> docker volume rm meenerva-core_stalwart-data
> docker compose --project-directory core-node --env-file core-node/.env up -d stalwart
> ```

First-run steps:

1. `make core-up` starts `core-stalwart`. `STALWART_RECOVERY_ADMIN` (built from
   `STALWART_ADMIN_PASSWORD` in `.env`) seeds the `admin` account so you can log in
   immediately. (If you skipped that env var, Stalwart prints a temporary
   16-character password on first boot: `docker logs core-stalwart | grep -A8
   'bootstrap mode'`.)
2. Open `https://mail.meenerva.io/admin` and log in as `admin`, **immediately**.
3. **Before anything else, Settings -> Security -> allow-list the Docker internal
   network** (e.g. `172.16.0.0/12`) so Stalwart stops treating Traefik's IP as a
   single hammering client. Do this before completing the rest of the wizard.
4. **Complete the 5-step setup wizard**: hostname (`mail.meenerva.io`), primary
   domain (`meenerva.io`), storage backend (RocksDB, the default), account
   directory (**Internal** for Phase 1 - see section 4), logging destination.
5. **Domains -> `meenerva.io` -> DKIM**: Stalwart generates a key pair and shows
   the exact DNS TXT record. Publish it, then *Check DNS* in the UI.
6. **Accounts -> create mailboxes** (`firstname.lastname@meenerva.io`).
7. Configure the outbound relay (section 3).
8. Send a test to <https://www.mail-tester.com> and aim for 10/10.

### TLS for mail protocols

Configured in the admin UI under **Settings -> TLS / ACME** (no file to edit):

- **A - ACME HTTP-01 via Traefik (default assumption in this repo).** Traefik
  forwards `Host(mail.meenerva.io) && PathPrefix(/.well-known/acme-challenge/)` to
  Stalwart (see the `stalwart-acme` router in `core-node/docker-compose.yml`),
  which runs its own ACME client and manages certs for 25/465/587/143/993. No DNS
  API needed.
- **B - ACME DNS-01 (recommended once you have a DNS provider API token).** Stalwart
  solves the challenge over DNS; works even if port 80 is busy and supports
  wildcards. Add the provider credentials in the admin UI's TLS settings.

The webmail (`webmail.meenerva.io`) and the Stalwart admin/JMAP HTTP surface
(`mail.meenerva.io`) are terminated by Traefik with Traefik's own certificate.

## 3. Outbound relay (decision D-08)

Recommended providers (S3-of-email, generous free tiers, good deliverability):

| Provider | Free tier | Notes |
|----------|-----------|-------|
| Amazon SES | 3k/mo (in-VPC) | cheapest at volume, needs production-access request |
| Postmark | 100/mo, then paid | best deliverability, transactional-only |
| MailerSend | 3k/mo | simple setup |
| Brevo (ex-Sendinblue) | 300/day | EU-hosted option |

Set in `core-node/.env`:

```
SMTP_RELAY_HOST=email-smtp.eu-central-1.amazonaws.com
SMTP_RELAY_PORT=587
SMTP_RELAY_USER=...
SMTP_RELAY_PASSWORD=...
```

Enter these in the admin UI under **Settings -> SMTP -> Outbound -> Remote host**
(a "relay" route). Keep the default direct-to-MX route as fallback for
internal-only mail. Add the provider's `include:` to SPF and, if the provider
signs, add their DKIM selector too (multi-signature is fine).

## 4. Directory backend (choose per phase)

| Phase | Backend | How |
|-------|---------|-----|
| Phase 1 (now) | Stalwart internal directory | Chosen in the setup wizard; manage mailboxes in the admin UI. Simple, zero dependencies. |
| Phase 1+ | PostgreSQL (`app_stalwart`) | `create-app-database.sh stalwart`, then Settings -> Directories -> add a SQL directory pointing at `10.10.0.1` / `core-postgres`. Lets n8n manage mailboxes via SQL. |
| Phase 2+ | Keycloak (LDAP/OIDC) | Settings -> Directories -> add an OIDC/LDAP directory against `https://id.meenerva.io/realms/meenerva`, so one identity = mail + SSO. Recommended end state; wire it once the Keycloak realm design is stable. |

Start with **Internal** (the wizard default) and switch backend later from the
admin UI - no rebuild or redeploy needed, it is a live setting change.

## 5. Mail clients (dual access - decision D-11)

Stalwart is the single source of truth. Two web clients present the **same
mailboxes**, picked by use case:

| Client | Where | Use it for |
|--------|-------|-----------|
| **Nextcloud Mail** | apps-node, `cloud.meenerva.io` -> *Mail* | primary client for business users - email next to files, calendar, Talk, tasks |
| **Bulwark Webmail** | core-node, `webmail.meenerva.io` | fast native JMAP client (mail + calendar + contacts + files); standalone/fallback, works when apps-node is down |

Both are stateless: a change in one shows in the other (and on phones) within
seconds, because mailbox state lives in Stalwart.

### 5.1 Bulwark Webmail (in the core stack)

`github.com/bulwarkmail/webmail` - the JMAP-native web client for Stalwart. It
connects to Stalwart over the **public** endpoint (`https://mail.meenerva.io`, set
via `JMAP_SERVER_URL`) so the TLS certificate name matches and OAuth discovery
works. Do not point it at the internal Docker hostname or the WireGuard IP.

- **SSO (default in the compose):** `OAUTH_ENABLED=true` with
  `OAUTH_ISSUER_URL=https://id.meenerva.io/realms/meenerva`. Create a Keycloak
  client `webmail` (confidential, redirect `https://webmail.meenerva.io/*`), put
  the id/secret in `core-node/.env` (`WEBMAIL_OAUTH_CLIENT_ID`,
  `WEBMAIL_OAUTH_CLIENT_SECRET`). Endpoints are auto-discovered from
  `.well-known/openid-configuration`.
- **Fallback:** comment out the `OAUTH_*` block to use username/password login
  straight against Stalwart.
- `WEBMAIL_SESSION_SECRET` (`openssl rand -base64 36`) encrypts the session /
  credential store in the `webmail-data` volume.
- First launch shows a setup wizard; because `JMAP_SERVER_URL` is set by env, the
  server field is locked and hidden.
- The image has no stable semver tag yet - pin `ghcr.io/bulwarkmail/webmail` to a
  digest before production.

### 5.2 Nextcloud Mail

Nextcloud Mail connects to Stalwart over the **public** endpoint so the TLS name
matches the certificate (do **not** use `10.10.0.1` here):

```
IMAP  host: mail.meenerva.io   port: 993  security: SSL/TLS
SMTP  host: mail.meenerva.io   port: 587  security: STARTTLS
```

Two auth models:

1. **XOAUTH2 / SSO (target).** In Stalwart's admin UI, enable OAuth for IMAP/SMTP
   (`OAUTHBEARER` / `XOAUTH2`) backed by the Keycloak OIDC directory (Settings ->
   Directories, see section 4). In Nextcloud, the Mail app picks up the user's
   Keycloak access token - no mailbox password stored. Requires the Keycloak
   directory backend to be live (Phase 2).
2. **Per-user app password (fallback, works today).** Each user creates an
   app-specific password in Stalwart and enters it once in Nextcloud Mail. Enable
   `mail.autoconfig` and set the provisioning defaults so new users get the account
   pre-filled:

   ```
   occ config:app:set mail installed_version
   occ mail:account:create --auto ...        # or a provisioning config JSON
   ```

   See `apps-node/apps/nextcloud/README.md` for the provisioning config block.

### 5.3 Autoconfiguration for desktop/mobile clients

`autoconfig.meenerva.io` / `autodiscover.meenerva.io` are CNAMEs to
`mail.meenerva.io`; Stalwart serves the Thunderbird autoconfig and Outlook
autodiscover XML, so native clients (K-9, Thunderbird, Apple Mail) self-configure
from the email address alone.

## 6. n8n and mail

n8n (core-node) sends via `core-stalwart:587` using a dedicated
`no-reply@meenerva.io` mailbox. This powers activation, onboarding and reporting
workflows. Keycloak's SMTP settings point at the same mailbox.

## 7. Troubleshooting: 502 Bad Gateway on `mail.meenerva.io`

**Symptom:** Traefik logs show `OriginStatus: 502` for the `stalwart` service
(connection to Stalwart succeeds, Stalwart itself answers 502), and
`docker logs core-stalwart` shows repeated `Blocked IP address
(security.ip-blocked) listenerId = "http-recovery"` lines.

**Cause:** Stalwart's built-in abuse protection banned the IP it sees making
requests - which, behind Traefik, is **Traefik's own container IP**, not the real
visitor. A bot scanning the new MX/A records (this happens within minutes of DNS
going live) is enough to trip it, and it then blocks everyone, including you. The
ban lives in the `stalwart-data` volume, so restarting the container does not
clear it.

**Fix:**

1. If the domain/DKIM/mailboxes are not configured yet (first-run), wipe the
   volume and start clean:
   ```sh
   docker compose --project-directory core-node --env-file core-node/.env stop stalwart
   docker volume rm meenerva-core_stalwart-data
   docker compose --project-directory core-node --env-file core-node/.env up -d stalwart
   ```
   If real configuration already exists and you cannot afford to lose it, use
   Stalwart's CLI/JMAP management API to remove the specific ban entry instead of
   wiping the volume (check `docker exec core-stalwart stalwart-cli --help` for
   the current subcommand, or the admin UI's Security section if it happens to be
   reachable from a different, non-banned source in the meantime).
2. **Immediately** after logging back into `https://mail.meenerva.io/admin`, go to
   **Settings -> Security** and allow-list the Docker network (e.g.
   `172.16.0.0/12`) *before* doing anything else in the wizard. This is step 3 in
   section 2 above - do not skip it, or the next bot scan reproduces the same
   lockout.
