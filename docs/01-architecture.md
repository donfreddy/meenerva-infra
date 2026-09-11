# 01 - Architecture

## 1. Goals and constraints

| Goal | How it is met |
|------|---------------|
| Rebuild any node from zero in under 30 minutes | Everything is in this repo + off-site backups; bootstrap scripts are idempotent |
| Add a new open-source app in ~5 minutes | `apps/_template/` + `new-app.sh` + Portainer Git stacks |
| No single point of failure at the proxy layer | Each node runs its own Traefik and terminates its own TLS |
| Databases never exposed to the internet | PostgreSQL / Redis bind only to the WireGuard interface |
| Predictable resource usage | Every container has an explicit `mem_limit` and `healthcheck` |
| Grow to a third node without re-architecting | Role-based repo layout, private mesh, shared conventions |

Non-goals for now: Kubernetes, multi-region, automatic horizontal scaling. These
become relevant around Phase 4 (see [`09-roadmap.md`](09-roadmap.md)) and the repo
layout is designed so that a later move to K3s is a migration, not a rewrite.

## 2. Nodes

### core-node (Contabo Cloud VPS 6 - 6 vCPU / 12 GB RAM / 200 GB)

The foundation. Low service count, low change rate, tight firewall. Hosts everything
that other services depend on.

| Service | Image | Purpose | mem_limit |
|---------|-------|---------|-----------|
| Traefik v3 | `traefik:v3.3` | Edge reverse proxy, ACME TLS, HTTP->HTTPS | 192 MB |
| Portainer CE | `portainer/portainer-ce` | Visual stack + container management | 512 MB |
| PostgreSQL 16 | `postgres:16-alpine` | Shared relational database, one DB+user per app | 3 GB |
| Redis 7 | `redis:7-alpine` | Shared cache / queue backend | 384 MB |
| Keycloak 26 | `quay.io/keycloak/keycloak` | Central identity provider (OIDC / SAML), MFA | 1.25 GB (heap capped) |
| Stalwart Mail | `stalwartlabs/stalwart` | SMTP / IMAP / JMAP / Sieve, DKIM signing | 1 GB |
| Bulwark Webmail | `ghcr.io/bulwarkmail/webmail` | Native JMAP web client for Stalwart (mail + calendar + contacts + files); standalone / fallback - primary client is Nextcloud Mail on apps-node, see D-11 | 512 MB |
| n8n | `n8nio/n8n` | Workflow automation (onboarding, offboarding, ...) | 640 MB |
| postgres-backup | `prodrigestivill/postgres-backup-local` | Nightly rotating SQL dumps | 128 MB |
| offsite-backup | `offen/docker-volume-backup` | Encrypted push of dumps + volumes to Backblaze B2 | 256 MB |

Approximate steady-state budget: OS + Docker ~1.2 GB, services ~9 GB, leaving
~1.8 GB headroom on 12 GB. A 4 GB swap file absorbs spikes. **If sustained pressure
appears, n8n is the first service to relocate to apps-node**, followed by Bulwark
Webmail (Nextcloud Mail still covers the primary client on apps-node).

### apps-node (Contabo Cloud VPS 8 - 8 vCPU / 24 GB RAM / 300 GB)

Business and collaboration applications. Higher change rate, heavier workloads.
Runs its own Traefik; uses core-node for identity (OIDC), database, cache and
outbound mail over the private mesh.

| Service | Purpose |
|---------|---------|
| Traefik v3 | Edge proxy + ACME TLS for apps-node subdomains |
| Nextcloud + Collabora | Files and documents (first reference app); the Nextcloud **Mail** app is the primary mail client, pointed at Stalwart on core-node (D-11) |
| Mattermost | Team chat |
| OpenProject | Project and work management |
| ERPNext / Frappe HR | ERP + HR (source of truth for the onboarding workflow) |
| DocuSeal | Document signing |

### data-node (future - target 32 GB RAM)

Security and analytics workloads are deliberately kept off the app node because of
their disk-I/O and memory profile: Wazuh (OpenSearch indexing), PostHog
(ClickHouse), Metabase. Provisioned when Phase 5 begins.

## 3. Networks

### 3.1 Public

Only these ports are open to `0.0.0.0`:

| Port | Node | Service |
|------|------|---------|
| 80, 443 | both | Traefik (HTTP + HTTPS) |
| 25, 465, 587 | core | Stalwart SMTP / SMTPS / submission |
| 143, 993 | core | Stalwart IMAP / IMAPS |
| 4190 | core | Stalwart ManageSieve |

Everything else is filtered by UFW. SSH is restricted to the admin IP allow-list
and/or the WireGuard interface.

### 3.2 Private mesh (WireGuard, `10.10.0.0/24`)

| Node | Mesh IP |
|------|---------|
| core-node | `10.10.0.1` |
| apps-node | `10.10.0.2` |
| data-node | `10.10.0.3` (reserved) |

core-node binds its private services to the mesh IP only:

- `10.10.0.1:5432` - PostgreSQL
- `10.10.0.1:6379` - Redis
- `10.10.0.1:587`  - Stalwart submission (apps-node relays outbound mail here)

apps-node reaches identity through the public URL `https://id.meenerva.io` (browser
redirects require a public URL anyway); all back-channel traffic (token
introspection, DB, cache, SMTP) goes over the mesh.

### 3.3 Docker networks (per node)

| Network | Scope | Members |
|---------|-------|---------|
| `edge` | bridge, attachable | Traefik + any container that needs an HTTP route |
| `core-internal` | bridge, `internal: true` | PostgreSQL, Redis, Keycloak, n8n, Stalwart, backups (Bulwark Webmail is on `edge` only - it reaches Stalwart via the public JMAP URL) |

`core-internal` has no gateway to the internet, so a compromised app container
cannot exfiltrate directly. Cross-node database access is via the host mesh IP, not
a shared Docker network.

## 4. Identity flow

```
User browser ──► apps-node app ──(302)──► id.meenerva.io (Keycloak)
                                              │  authenticate + MFA
User browser ◄── app session ◄──(code)────────┘
apps-node app ──(client_credentials / introspection, over mesh or public)──► Keycloak
```

Keycloak realm `meenerva`, one confidential client per application. Groups drive
RBAC. n8n orchestrates account lifecycle (create on hire, disable on termination).

## 5. Mail flow

```
Inbound:   Internet ──MX──► core-node:25 ──► Stalwart ──► mailbox store (stalwart-data volume)

Clients (same mailboxes, D-11):
  Primary:  Browser ──► cloud.meenerva.io ──► Nextcloud Mail (apps-node)
                     ──IMAP/SMTP over TLS──► mail.meenerva.io:993/587 ──► Stalwart
  Fallback: Browser ──► webmail.meenerva.io ──► Bulwark Webmail (core-node)
                     ──JMAP over TLS──► mail.meenerva.io ──► Stalwart
  Native:   Thunderbird / K-9 / Apple Mail ──autoconfig.meenerva.io──► Stalwart

Outbound (apps):   app ──► 10.10.0.1:587 (mesh) ──► Stalwart ──relay──► SES/Postmark/... ──► recipient MX
Outbound (direct): Stalwart ──:25──► recipient MX   (fallback / internal only)
```

Both web clients are stateless views on one Stalwart server; mailbox state (read,
flags, folders) lives in Stalwart, so actions sync across clients and devices
whether the client speaks JMAP (Bulwark) or IMAP (Nextcloud Mail, native apps).

Rationale for placement, the two-client model and the relay recommendation: see
[`02-architecture-decisions.md`](02-architecture-decisions.md) decisions D-07, D-08
and D-11, and [`05-dns-and-mail.md`](05-dns-and-mail.md).

## 6. Data and state

| State | Location | Backup |
|-------|----------|--------|
| Relational data (Keycloak, n8n, Nextcloud, ...) | `core-postgres` volume | Nightly `pg_dump` per DB, then B2 |
| Mailboxes + mail metadata | `stalwart-data` volume | Nightly volume snapshot to B2 |
| Traefik ACME certs | `traefik-acme` volume (each node) | B2 (small, low priority - regenerable) |
| Portainer config | `portainer-data` volume | B2 |
| n8n encryption key, credentials | `.env` + `n8n-data` volume | `.env` in a password manager; volume to B2 |
| Nextcloud user files | `apps-node` volume / object storage | Nextcloud-side backup + B2 |

Restore procedure: [`06-secrets-and-backups.md`](06-secrets-and-backups.md).

## 7. Deployment model

1. **Bootstrap (once per node, over SSH):** `bootstrap-node.sh` then
   `init-<role>-node.sh`, then `make core-up` / `make apps-up` for the edge stack.
2. **Everything after that:** Portainer → Stacks → *Add stack* → *Repository*,
   pointing at this repo and the relevant `docker-compose.yml`. Pushing to `main`
   updates the stack (enable Portainer's automatic Git polling or the webhook).
3. **Secrets** live in each stack's environment in Portainer (or a per-node `.env`
   that is never committed), not in the repo.
