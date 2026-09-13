# Frappe (ERPNext + Frappe HR)

- **Node:** apps-node
- **Subdomains:** `erp.meenerva.io` (ERPNext site), `hr.meenerva.io` (Frappe HR site)
- **Database:** shared `apps-mariadb` (D-17) - Frappe self-provisions its own
  per-site database/user at site-creation time (see "Deploy" below), unlike
  every other app in this repo
- **Keycloak client:** none pre-configured - real, free, native OIDC support
  exists (Social Login Key), see "SSO" below
- **Upstream docs:** <https://github.com/frappe/frappe_docker>,
  <https://docs.frappe.io/framework>, <https://docs.erpnext.com>,
  <https://docs.frappe.io/hr>

## Why this app is different from every other one in this repo

Every other app here is a `docker pull` of a pre-built image. Frappe is not:
**the official `frappe/erpnext` image does not include the `hrms` app**, and
installing it at runtime inside a production container (`bench get-app`) is a
known-broken path upstream (`ModuleNotFoundError`, multiple open
frappe/frappe_docker and frappe/hrms issues) - the supported way to get
erpnext+hrms in one image is a **custom build** using frappe_docker's own
`Containerfile` and an `apps.json`. This repo does that build locally on
apps-node rather than trusting an unofficial pre-built third-party image
(supply-chain reasons - we control and can reproduce exactly what went into
this image).

## Building the image (once per version bump)

```sh
cd apps-node/apps/frappe/build
./build.sh
```

Takes 10-20+ minutes (downloads erpnext+hrms source, builds frontend assets).
Requires Docker Engine v23+ with BuildKit (the build uses a `--secret` mount
for `apps.json` - fails on older Docker with a cryptic secret-mount error).
Produces `meenerva/frappe-erpnext-hrms:16` locally - `docker-compose.yml`
already has this tag hardcoded, no further config needed. To bump versions
later, edit `build/apps.json` and `build/build.sh`'s
`FRAPPE_BRANCH`/`IMAGE_TAG` together, re-run `build.sh`, then update the
`image:` line in `docker-compose.yml` to match.

## Deploy

1. **Shared MariaDB must already be up** (D-17, brought up for EspoCRM - see
   `apps-node/apps/espocrm/README.md` if not done yet).
2. Build the image (above).
3. DNS: `erp A <apps-node-ip>` and `hr A <apps-node-ip>`.
4. `cp apps-node/apps/frappe/.env.example apps-node/apps/frappe/.env`.
5. Skip `check-images.sh` for this app: `meenerva/frappe-erpnext-hrms:16` is
   local-only (just built, not on any registry), so the script will always
   report it FAILED (`docker manifest inspect` only queries registries) -
   that specific line is expected noise here, not a real problem. It is
   still fine (and does something useful) to run it manually if you want to
   double check the `redis:8.6-alpine` sidecar specifically.
6. `make app-up NAME=frappe`. Wait for `frappe-configurator` to exit 0 and
   the rest to be `Up` before continuing - the same "a stopped one-shot
   container is success, not a crash" caution as OpenProject's seeder.
7. **Create the ERPNext site** (root MariaDB access, used only for this one
   command - never stored in a running container's env):
   ```sh
   docker exec -it apps-frappe-backend bench new-site \
     --mariadb-user-host-login-scope='%' \
     --db-root-username root \
     --db-root-password '<MARIADB_ROOT_PASSWORD from apps-node/.env>' \
     --install-app erpnext \
     --admin-password '<choose a strong password>' \
     erp.meenerva.io
   ```
   `--mariadb-user-host-login-scope=%` is required - without it, MariaDB
   scopes the new user to a specific host that won't match how containers
   actually connect, and every login fails with an opaque access-denied
   error (confirmed in frappe_docker's own docs, not a guess).
8. **Create the Frappe HR site** the same way, with `--install-app hrms`
   instead of `--install-app erpnext`, site name `hr.meenerva.io`:
   ```sh
   docker exec -it apps-frappe-backend bench new-site \
     --mariadb-user-host-login-scope='%' \
     --db-root-username root \
     --db-root-password '<MARIADB_ROOT_PASSWORD>' \
     --install-app hrms \
     --admin-password '<choose a strong password>' \
     hr.meenerva.io
   ```
9. Open `https://erp.meenerva.io` and `https://hr.meenerva.io`, log in as
   `Administrator` with the password chosen per site above.

## Outbound mail (Stalwart)

No env-based SMTP config for Frappe (same pattern as EspoCRM) - configure it
per site, in-app: **Settings -> Email Account** (or Email Domain), pointing
at `mail.meenerva.io` / `10.10.0.1`, port `587`, STARTTLS, using the
`no-reply@meenerva.io` mailbox credentials. Do this on **both** sites
separately - Email Account settings are per-site, not shared across the
bench.

## SSO (Keycloak - real, free, native support)

Frappe has a built-in, free, open-source generic OAuth2/OIDC login mechanism
(**Social Login Key** doctype) - unlike Mattermost (no free OIDC) or
DocuSeal (no free SSO at all). This has been used with Keycloak by other
self-hosters (community writeups exist), but the exact field layout was not
verified live for this repo as of 2026-09 - **read the live form in
Settings -> Integrations -> Social Login Key before filling anything in**,
don't guess field names from memory. General shape (Keycloak side, realm
`meenerva`): create a client, confidential, standard flow on, get the client
ID/secret, and the discovery endpoint is
`https://id.meenerva.io/realms/meenerva/.well-known/openid-configuration`.
Configure per-site (Social Login Key is a per-site setting like everything
else here) once the exact form fields are confirmed live.

## Notes

- **Both sites look nearly identical - this is expected, not a routing
  bug.** `bench --site hr.meenerva.io install-app hrms` auto-installs
  `erpnext` too (hrms depends on it), so `hr.meenerva.io` ends up with
  frappe+erpnext+hrms while `erp.meenerva.io` has only frappe+erpnext -
  confirmed via `bench --site <site> list-apps`. The only functional
  difference is the HR module/workspaces on `hr.meenerva.io`; the rest of
  the desk UI looks the same because it mostly is the same app (ERPNext).
  If the Host-header routing itself were broken, both sites would show
  `list-apps` output for the SAME database - check that first if this comes
  up again, not the visual similarity alone.
- **All background containers
  (`frappe-backend`/`frappe-queue-short`/`frappe-queue-long`/`frappe-scheduler`)
  join `edge`, not just `apps-internal`** - they can all trigger outbound
  mail via `frappe.sendmail()`, which needs the WireGuard mesh route to
  Stalwart on core-node (D-19). Only `frappe-websocket`,
  `frappe-redis-cache`/`queue`, and `frappe-configurator` are
  `apps-internal`-only.
- `frappe-redis-cache`/`frappe-redis-queue` are **dedicated to this app**,
  unauthenticated, internal-only - do not point them at core-redis or try to
  reuse them for another app; this matches frappe_docker's own reference
  architecture exactly, not a simplification.
- `frappe-queue-long`/`frappe-queue-short`/`frappe-scheduler` **must all stay
  running** - background jobs (report generation, scheduled HR workflows,
  mail) silently stop otherwise, same caution as OpenProject's worker/cron.
- Add `frappe-sites` to `apps-node/docker-compose.yml`'s
  `offsite-backup.volumes` once real data exists - it holds both sites' full
  state (code, config, uploaded files). Site data itself lives in MariaDB
  databases Frappe created directly (not through
  `scripts/create-mysql-database.sh`) - confirm these are covered by whatever
  backup strategy governs `apps-mariadb` as a whole, since they were not
  provisioned through this repo's usual per-app database tooling.
- RAM budget: ~3.7 GB across all 8 containers here (backend 1.5 GB +
  2x workers 512 MB + frontend/scheduler/websocket/configurator ~1.2 GB
  combined + 2x redis ~320 MB) - similar weight class to OpenProject, watch
  apps-node's steady-state RAM after this lands (see the capacity
  checkpoints table in `docs/09-roadmap.md`).
- Health check assumes `curl` exists in the custom-built image - **not
  verified live yet**. Check with `docker exec apps-frappe-frontend which
  curl wget` before trusting it; this has now bitten Mattermost, DocuSeal,
  and partially EspoCRM/OpenProject - always verify a new image's tooling
  rather than assume.
