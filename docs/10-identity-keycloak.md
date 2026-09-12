# 10 - Identity (Keycloak)

Keycloak is the single source of identity truth for MEENERVA: one account per
person, used to log into every app that supports OIDC, with MFA enforced in one
place. This doc is the reference for how it is actually configured in this
repo - not a generic Keycloak primer. See decision context in
[`02-architecture-decisions.md`](02-architecture-decisions.md) (D-07 mail/Keycloak
interplay, D-11 mail SSO) and the service entry in
[`01-architecture.md`](01-architecture.md) section 4 "Identity flow".

## 1. Why it is on core-node, and what that means operationally

Keycloak runs as `core-keycloak` in `core-node/docker-compose.yml`, backed by
`app_keycloak` in the shared `core-postgres` (see
[`02-architecture-decisions.md`](02-architecture-decisions.md) D-04). It is a
**single point of failure by design**: if it is down, nobody can log into any
app that uses it for SSO (Nextcloud, and every future OIDC-enabled app), though
existing sessions typically keep working until their token expires.
Consequences this repo already accounts for:

- Backed up nightly with the rest of `core-postgres` (per-database dump, see
  [`06-secrets-and-backups.md`](06-secrets-and-backups.md)).
- Kept on the tightly-scoped, low-churn core node rather than next to volatile
  business apps.
- `mem_limit: 1280m` with `KEYCLOAK_JVM_HEAP="-Xms512m -Xmx1024m"` in
  `core-node/.env` - if Keycloak needs more headroom as the realm grows, raise
  the heap and `mem_limit` together, in that order (a heap larger than the
  container's memory limit gets OOM-killed).
- To reset it to a clean state (realm and all), see "Resetting the realm" below
  - this happened once already during Phase 1 bring-up.

## 2. Realm structure

**One realm: `meenerva`.** Never put application clients or real users in the
`master` realm - `master` is reserved for the bootstrap admin
(`KEYCLOAK_ADMIN_PASSWORD` in `core-node/.env`) that manages Keycloak itself.

Realm settings already configured (see
[`07-deployment-guide.md`](07-deployment-guide.md) Step 5):

- **Email**: SMTP host `core-stalwart`, port `587`, StartTLS, from
  `no-reply@meenerva.io`, authenticated with that mailbox's password.
- **Authentication -> Required actions**: `Configure OTP` set as a **default
  action**, so every user without OTP configured is forced to set it up at
  next login (see [`07-deployment-guide.md`](07-deployment-guide.md) Step 5 for
  why this is preferred over editing the browser flow directly).

## 3. Groups and RBAC

Convention (create under **Groups** as the studio grows past a handful of
people - not all need to exist on day one):

| Group | Grants access to |
|-------|------------------|
| `employees` | Baseline: Nextcloud, webmail, whatever every hire needs |
| `devs` | Gitea/Forgejo, n8n, CI-facing tools |
| `hr` | Frappe HR, DocuSeal |
| `admins` | Keycloak realm management, Traefik dashboard, infra-facing tools |

Apps read group membership from the ID token's `groups` claim (add a **Group
Membership** mapper on the client, or a client scope shared across clients, if
it is not included by default) and map it to their own local roles/permissions
- Keycloak does not manage in-app permissions itself, only who the user is and
which groups they are in.

## 4. Clients registry

Every OIDC client that should exist in the `meenerva` realm. Keep this table
current when you add one - it is the fastest way to answer "does app X already
have a client, and what is its redirect URI" without opening the admin UI.

| Client ID | App | Type | Redirect URI | Secret stored in |
|-----------|-----|------|---------------|-------------------|
| `webmail` | Bulwark Webmail (core) | Confidential | `https://webmail.meenerva.io/*` | `core-node/.env` (`WEBMAIL_OAUTH_CLIENT_SECRET`) |
| `nextcloud` | Nextcloud (apps) | Confidential | `https://cloud.meenerva.io/apps/user_oidc/code` | Nextcloud admin UI / `occ user_oidc:provider`, not in a repo `.env` (see note below) |
| `security-admin-console` | Keycloak's own admin console | Public | (built-in, do not edit) | n/a |

**Note on Nextcloud's client secret**: unlike core-node services, apps-node app
secrets configured through an app's own admin UI (not an env var) are not
tracked in this repo's `.env` files - note that gap in your password manager
entry for the app instead so it is not lost if the app's own storage is wiped.

When adding a new app's client, follow the pattern in
[`08-adding-an-app.md`](08-adding-an-app.md) step 6: `Client authentication: On`,
`Standard flow: On`, redirect URI scoped to that app's real callback path (not
a wildcard on the whole domain), Web origins set to the app's origin only.

## 5. Service accounts (for automation, e.g. n8n)

For n8n (or any automation) to call the Keycloak Admin API (create/disable
users as part of onboarding/offboarding - see section 7) without a human
logging in:

1. Create a client (e.g. `n8n-automation`), **Client authentication: On**,
   **Service accounts roles: On**, **Standard flow: Off** (this client never
   does a browser login).
2. Under that client's **Service account roles** tab, assign the realm-management
   roles it actually needs - typically `manage-users` at minimum, scoped as
   tightly as the workflow allows. Avoid `realm-admin` unless genuinely
   required.
3. n8n authenticates with `client_credentials` grant against
   `https://id.meenerva.io/realms/meenerva/protocol/openid-connect/token`
   using this client's ID + secret, then calls the Admin REST API
   (`/admin/realms/meenerva/users`, etc.).

## 6. Onboarding / offboarding (Phase 8 target)

This is the payoff for centralizing identity - see
[`09-roadmap.md`](09-roadmap.md) Phase 8. Not built yet; this is the intended
shape once n8n workflows are written:

**Onboarding**: HR system marks a hire -> n8n creates the Keycloak user via the
Admin API (section 5), assigns the right group(s) from section 3 -> the user's
first login is forced through `Configure OTP` (already realm-wide, section 2)
-> group membership alone grants Nextcloud/webmail/etc. access, no per-app
account creation needed for anything OIDC-enabled.

**Offboarding**: HR system marks a termination -> n8n disables (not necessarily
deletes, for audit trail) the Keycloak user and revokes active sessions via the
Admin API -> every OIDC-enabled app rejects that user's next request
immediately; apps with their own local session state should be revisited to
confirm they also honor a Keycloak-side session revocation promptly.

**What Keycloak does NOT remove access to on its own**: anything not wired to
OIDC (a mailbox's IMAP app-password in Stalwart, an SSH key, a Gitea repo
collaborator entry) has to be revoked separately - group-based SSO removes the
*login*, not every credential a person may hold. Track this explicitly in the
offboarding workflow rather than assuming Keycloak alone covers it.

## 7. Troubleshooting

### Admin console: "Timeout when waiting for 3rd party check iframe message"

Keycloak's admin console loads a same-origin iframe to poll session state. If
this fails in every browser, it is almost certainly `X-Frame-Options: DENY`
being applied to Keycloak's responses - check whether an **entrypoint-level**
Traefik middleware is overriding the router-level one (this happened during
Phase 1 bring-up: `entryPoints.websecure.http.middlewares` in `traefik.yml`
applied to every router unconditionally, on top of Keycloak's own
`security-headers-frameable@file`). Diagnose via Traefik's own API
(`GET /api/http/routers/keycloak@docker`) to see the actual middleware chain,
not just what the compose labels say. Keycloak's router must use
`security-headers-frameable@file` (`X-Frame-Options: SAMEORIGIN`), not the
default `security-headers@file` (`DENY`).

### Resetting the realm

If the realm/admin access is broken beyond repair (happened once during Phase
1), Keycloak's state is entirely in `app_keycloak` - wiping and recreating that
database gives a clean `master` realm with the bootstrap admin from
`KEYCLOAK_ADMIN_PASSWORD`, without touching any other app's data:

```sh
docker compose --project-directory core-node --env-file core-node/.env stop keycloak
docker exec -i core-postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE app_keycloak;"'
docker exec -i core-postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE app_keycloak OWNER app_keycloak;"'
docker compose --project-directory core-node --env-file core-node/.env up -d keycloak
```

This means **every realm, client, group, and user is lost** - only do this
when starting over is genuinely acceptable, and re-run the setup in sections
2-4 above afterward. There is no partial/soft reset; Keycloak has no separate
"factory reset this realm only" operation short of recreating the database.
