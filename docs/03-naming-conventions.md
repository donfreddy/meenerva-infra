# 03 - Naming conventions

Consistency is what keeps a growing catalogue debuggable. Apply these from app #1.

## Placeholder domain

Docs and examples use `meenerva.io`. Replace with the real primary domain in
`*.env` and Traefik config. `<app>` is the lowercase application slug
(`n8n`, `nextcloud`, `mattermost`, `openproject`, `erpnext`, `docuseal`, ...).

## Nodes

| Role | Repo dir | Mesh IP | Hardware today |
|------|----------|---------|----------------|
| core | `core-node/` | `10.10.0.1` | Contabo Cloud VPS 6 |
| apps | `apps-node/` | `10.10.0.2` | Contabo Cloud VPS 8 |
| data | `data-node/` | `10.10.0.3` | not provisioned |

## Compose projects (`name:` in the compose file)

| Stack | Project name |
|-------|--------------|
| core-node stack | `meenerva-core` |
| apps-node edge stack | `meenerva-apps` |
| Individual application | `meenerva-<app>` |

## Containers

`<node>-<service>`:

```
core-traefik   core-postgres   core-redis
core-keycloak  core-stalwart   core-webmail   core-n8n
apps-traefik   apps-nextcloud   apps-collabora  apps-mattermost
```

## Docker networks

| Name | Where | Type |
|------|-------|------|
| `edge` | every node | bridge, attachable - Traefik + routed containers |
| `core-internal` | core-node | bridge, `internal: true` - data stores + core services |
| `apps-internal` | apps-node | bridge, `internal: true` - per-app private links |

Application stacks join `edge` as `external: true`. They never join
`core-internal`.

## DNS subdomains

One subdomain per user-facing service, `<service>.meenerva.io`.

| Subdomain | Points to | Service |
|-----------|-----------|---------|
| `traefik.` | core | Traefik dashboard (auth-protected) |
| `id.` | core | Keycloak |
| `mail.` | core | Stalwart admin UI + JMAP + autoconfig |
| `webmail.` | core | Bulwark Webmail (native JMAP client) |
| `autoconfig.` / `autodiscover.` | core | Mail client autoconfiguration (CNAME to `mail.`) |
| `n8n.` | core | n8n |
| `cloud.` | apps | Nextcloud |
| `office.` | apps | Collabora Online |
| `chat.` | apps | Mattermost |
| `project.` | apps | OpenProject |
| `sign.` | apps | DocuSeal |
| `crm.` | apps | EspoCRM |
| `erp.` | apps | ERPNext (Frappe bench site 1) |
| `hr.` | apps | Frappe HR (Frappe bench site 2, same bench as `erp.`) |
| `siem.` / `analytics.` / `bi.` | data | reserved |

Mail service records (`MX`, `_dmarc`, `_domainkey`, `mta-sts`): see
[`05-dns-and-mail.md`](05-dns-and-mail.md).

## PostgreSQL

| Item | Pattern | Example |
|------|---------|---------|
| Database | `app_<app>` | `app_keycloak`, `app_n8n` |
| Role / user | `app_<app>` | `app_keycloak` |
| Password env var | `<APP>_DB_PASSWORD` | `KEYCLOAK_DB_PASSWORD` |
| Host (from core containers) | `core-postgres` | |
| Host (from apps-node) | `10.10.0.1` | over WireGuard |

Each role owns only its own database. No `SUPERUSER`, no `CREATEDB`, no cross-grants.

## MariaDB (apps-node only)

For apps that require MySQL/MariaDB instead of Postgres (EspoCRM, later
ERPNext/Frappe HR - see D-17 in `02-architecture-decisions.md`). Same naming
pattern as PostgreSQL above, different engine and host:

| Item | Pattern | Example |
|------|---------|---------|
| Database | `app_<app>` | `app_espocrm` |
| User | `app_<app>` | `app_espocrm` |
| Password env var | `<APP>_DB_PASSWORD` | `ESPOCRM_DB_PASSWORD` |
| Host (from apps-node containers on `apps-internal`) | `apps-mariadb` | no mesh hop - same node |
| Provisioning script | `scripts/create-mysql-database.sh <app>` | mirrors `create-app-database.sh` |

## Redis

Logical separation by numbered DB index or key prefix, one per app:
`redis://:PASS@core-redis:6379/3` (core), `redis://:PASS@10.10.0.1:6379/3` (apps).
Maintain the index assignment table in `core-node/.env.example` comments.

## Volumes

`<service>-data` (`postgres-data`, `stalwart-data`, `n8n-data`). Extra volumes:
`<service>-<purpose>` (`stalwart-logs`, `nextcloud-config`).

## Traefik router / service labels

```
traefik.http.routers.<app>.rule=Host(`<service>.meenerva.io`)
traefik.http.routers.<app>.entrypoints=websecure
traefik.http.routers.<app>.tls.certresolver=letsencrypt
traefik.http.services.<app>.loadbalancer.server.port=<container-port>
```

Router and service names = the app slug. Shared middlewares are referenced from
`traefik/dynamic/middlewares.yml` (e.g. `security-headers@file`,
`rate-limit@file`).

## Secrets in `.env`

`SCREAMING_SNAKE_CASE`, grouped by service with a comment header. Generate with
`openssl rand -base64 36` (or `-hex 32` where the consumer rejects `+//=`).

## Git branches

`main` is deployed. Work on `feat/<slug>` or `fix/<slug>`, open a PR, merge to
`main`, then `git pull` + `make core-up`/`apps-up`/`app-up` on the affected
node (D-12/D-15: no Portainer GitOps).
