# OpenProject

- **Node:** apps-node
- **Subdomain:** `project.meenerva.io`
- **Database:** `app_openproject` on core-postgres (`./scripts/create-app-database.sh openproject`)
- **Keycloak client:** none - see "Identity" below
- **Upstream docs:** <https://www.openproject.org/docs/installation-and-operations/installation/docker/>,
  reference compose: <https://github.com/opf/openproject-docker-compose>

## Deploy

1. On core-node: `./scripts/create-app-database.sh openproject`
2. DNS: `project A <apps-node-ip>`
3. `cp apps-node/apps/openproject/.env.example apps-node/apps/openproject/.env`,
   fill in `OPENPROJECT_DB_PASSWORD` (step 1), `OPENPROJECT_SECRET_KEY_BASE`
   (`openssl rand -hex 64` - this exact value is baked into every container
   below, so generate it once and paste it, don't let each container invent
   its own), and a real `OPENPROJECT_ADMIN_PASSWORD`
4. `./scripts/check-images.sh apps-node/apps/openproject/docker-compose.yml`
5. `make app-up NAME=openproject`
6. Verify the healthcheck's tool actually exists before trusting it stays
   green: `docker exec apps-openproject which curl wget` - this is a `-slim`
   image tag, which trims packages compared to the full image; swap the
   healthcheck command if `curl` is missing (see the DocuSeal/EspoCRM
   precedent in [`02-architecture-decisions.md`](../../../docs/02-architecture-decisions.md))
7. Watch `docker logs apps-openproject-seeder` - it should run migrations,
   seed the admin account, and exit (`restart: on-failure`, not
   `unless-stopped` - a healthy seeder container is a STOPPED one, not a
   running one; don't mistake that for a crash)
8. Open `https://project.meenerva.io` and log in with
   `OPENPROJECT_SEED__ADMIN__USER__MAIL` (= `MAIL_FROM`) /
   `OPENPROJECT_ADMIN_PASSWORD`

## Outbound mail (Stalwart)

SMTP env vars are set directly in `docker-compose.yml` (`OPENPROJECT_SMTP__*`),
pointed at Stalwart. **Verify this actually works after deploy** - there is a
known upstream report
([opf/openproject-docker-compose#155](https://github.com/opf/openproject-docker-compose/issues/155))
that env-based SMTP settings have not always been picked up reliably in
Docker Compose deployments. If notification emails don't arrive, configure
the identical values under **Administration -> System settings -> Email
notifications** instead - don't assume the env vars are silently working
without checking a real notification.

**Known issue (2026-09-13, parked, not yet fixed):** sending mail fails with
`Connection refused - connect(2) for "10.10.0.1" port 587`. First hit
OpenProject's SSRF protection (fixed - `OPENPROJECT_SSRF_PROTECTION_IP_ALLOWLIST`
above), but the connection itself is still refused underneath that. This is
the exact same root cause already being tracked for Mattermost - Stalwart's
own container sends an immediate TCP RST to mesh-sourced connections,
confirmed via `tcpdump`, not a firewall/network issue on apps-node's or
core-node's side. See D-16's final update in
[`02-architecture-decisions.md`](../../../docs/02-architecture-decisions.md)
before touching this again.

## Identity (read this before looking for a Keycloak client)

**Custom OpenID Connect providers (which is how you'd point OpenProject at
Keycloak) are an Enterprise add-on in OpenProject**, not available in the
free Community Edition this repo deploys - confirmed against OpenProject's
own docs as of 2026-09. A 14-day Enterprise trial exists but is not a
permanent answer. Consequence for the "Keycloak is the only place accounts
are created" policy ([`10-identity-keycloak.md`](../../../docs/10-identity-keycloak.md)
section 4): same treatment as Mattermost - do nothing for now, use
OpenProject's own local accounts, and keep exactly one break-glass local
admin, same reasoning as every other app. Revisit only if the Enterprise
add-on cost is ever worth it for this specific feature.

## Notes

- Four containers (`openproject`, `openproject-worker`, `openproject-cron`,
  `openproject-seeder`) share the same image with a different `command`,
  and the same `/var/openproject/assets` volume via `volumes_from` -
  matches OpenProject's own reference deployment, not a simplification on
  our part. `openproject-worker` and `openproject-cron` **must both stay
  running** - background jobs (mail, imports) and scheduled tasks
  (reminders, cleanups) silently stop otherwise, with no obvious symptom in
  the web UI.
- `openproject-cache` (Memcached) is local, unauthenticated, and
  internal-only (`apps-internal`) - it is Rails' cache store, not a
  persistence layer; losing it on restart is fine and expected.
- Historically RAM-heavy - budgeted ~3.5 GB across all 5 containers here
  (see `docs/09-roadmap.md` Phase 3 note). Watch apps-node's steady-state
  RAM after this lands; this is the app most likely to justify moving
  something else off apps-node or resizing the VPS if pressure appears.
- Add `openproject-data` to `apps-node/docker-compose.yml`'s
  `offsite-backup.volumes` once real data exists - it holds all attachments.
  Work package/project data itself is in `app_openproject`, already covered
  by the nightly core-postgres dump.
- Real-time collaborative wiki/text editing (Hocuspocus, in OpenProject's
  own reference compose) is deliberately not included here - it is a
  separate service with its own secret and adds meaningful complexity for a
  feature that degrades gracefully without it (last-save-wins instead of
  live co-editing). Add it later if a concrete need shows up.
