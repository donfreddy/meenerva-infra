# meenerva-infra

Infrastructure-as-Code for the **MEENERVA** startup studio. Self-hosted, open-source
SaaS tooling deployed with Docker Compose, managed visually through Portainer, and
version-controlled here.

This repository is the single source of truth. If a server is lost, it can be rebuilt
from a blank Ubuntu image using only the scripts and compose files in this repo plus
the off-site backups.

---

## Topology (current)

Two Contabo VPS instances today, a third planned.

| Logical node | Hardware (today)            | Role                                             | Public subdomains |
|--------------|-----------------------------|-------------------------------------------------|-------------------|
| `core-node`  | Contabo Cloud VPS 6 (6 vCPU / 12 GB RAM / 200 GB) | Edge routing, identity, mail, automation, shared data stores | `traefik.` `portainer.` `id.` `mail.` `webmail.` `autoconfig.` `n8n.` |
| `apps-node`  | Contabo Cloud VPS 8 (8 vCPU / 24 GB RAM / 300 GB) | Business and collaboration applications          | `cloud.` `office.` `chat.` `project.` `sign.` `erp.` |
| `data-node`  | _not provisioned yet_        | SIEM, analytics, business intelligence (Wazuh, PostHog, Metabase, ClickHouse) | `siem.` `analytics.` `bi.` |

The hardware names ("VPS 6" / "VPS 8") are an implementation detail. The repository is
organised by **role** (`core-node`, `apps-node`, `data-node`) so a node can be resized
or migrated without touching the structure.

Nodes communicate over a private **WireGuard** mesh (`10.10.0.0/24`). Only HTTP(S) and
mail ports are exposed to the public internet; databases and caches are never publicly
reachable.

```
                       Internet
                          |
        +-----------------+------------------+
        |                                    |
  core-node (10.10.0.1)  <== WireGuard ==>  apps-node (10.10.0.2)
  - Traefik (edge)                          - Traefik (edge)
  - Keycloak (id.)                          - Nextcloud (cloud.)
  - Stalwart Mail (mail.)                   - Mattermost (chat.)
  - Bulwark Webmail (webmail.)              - Nextcloud Mail app (primary client)
  - n8n (n8n.)                              - OpenProject (project.)
  - PostgreSQL 16 (private, :5432 on wg)    - ERPNext, DocuSeal, ...
  - Redis (private, :6379 on wg)
  - Portainer + backups
```

---

## Repository layout

```
meenerva-infra/
├── core-node/                 # Everything that runs on core-node
│   ├── docker-compose.yml     # The "core" stack (bootstrapped once over SSH)
│   ├── .env.example           # Copy to .env and fill in; never commit .env
│   ├── traefik/               # Traefik v3 static + dynamic configuration
│   ├── stalwart/              # Stalwart Mail Server configuration
│   ├── postgres/initdb/       # One-time DB/user provisioning for every app
│   └── backup/                # Backup job configuration
│
├── apps-node/                 # Everything that runs on apps-node
│   ├── docker-compose.yml     # apps-node edge stack (Traefik only)
│   ├── .env.example
│   └── apps/                  # One directory per application
│       ├── _template/         # Copy this to scaffold a new app
│       └── nextcloud/         # First reference application
│
├── scripts/                   # Idempotent automation, safe to re-run
│   ├── lib/common.sh
│   ├── bootstrap-node.sh      # Base hardening + Docker for any fresh node
│   ├── init-core-node.sh      # core-node specific setup
│   ├── init-apps-node.sh      # apps-node specific setup
│   ├── setup-wireguard.sh     # Bring up / update the inter-node mesh
│   ├── create-app-database.sh # Create an isolated DB + user in core PostgreSQL
│   ├── new-app.sh             # Scaffold apps-node/apps/<name>/ from _template
│   ├── backup-now.sh          # Trigger an on-demand backup
│   └── restore.sh             # Guided restore from Backblaze B2
│
├── docs/                      # Architecture, conventions, runbooks
└── Makefile                   # Thin wrappers around the common operations
```

---

## Quick start (Phase 1: core-node + mail)

Full detail in [`docs/07-deployment-guide.md`](docs/07-deployment-guide.md). Summary:

1. **DNS** – point the records in [`docs/05-dns-and-mail.md`](docs/05-dns-and-mail.md)
   at the two server IPs (A/AAAA, MX, SPF, DKIM, DMARC, PTR/rDNS).
2. **Bootstrap core-node**
   ```sh
   ssh root@<core-ip>
   git clone https://github.com/<org>/meenerva-infra.git /opt/meenerva-infra
   cd /opt/meenerva-infra
   ./scripts/bootstrap-node.sh
   ./scripts/init-core-node.sh
   ```
3. **Configure** `core-node/.env` from `core-node/.env.example`
   (`openssl rand -base64 36` for every secret).
4. **Launch the core stack**
   ```sh
   make core-up
   ```
5. **Provision app databases**
   ```sh
   ./scripts/create-app-database.sh keycloak
   ./scripts/create-app-database.sh n8n
   ./scripts/create-app-database.sh stalwart   # only if using the SQL backend
   ```
6. **Verify**: `https://traefik.meenerva.io`, `https://portainer.meenerva.io`,
   `https://id.meenerva.io`, `https://mail.meenerva.io`, `https://webmail.meenerva.io`.
7. **Bring up apps-node** later with `./scripts/init-apps-node.sh` +
   `./scripts/setup-wireguard.sh`, then deploy apps from `apps-node/apps/`.

After the first manual launch, every subsequent change is deployed through
**Portainer → Stacks → Git repository**, pointing at this repo.

---

## Conventions

See [`docs/03-naming-conventions.md`](docs/03-naming-conventions.md). In short:

- Container name: `<node>-<service>` (`core-postgres`, `apps-nextcloud`)
- Compose project: `meenerva-core`, `meenerva-apps`, `meenerva-<app>`
- Database + user: `app_<name>` (`app_keycloak`, `app_n8n`)
- Subdomain: `<service>.meenerva.io`
- Every service sets an explicit `mem_limit` and `healthcheck`.

---

## Documentation index

| Doc | Contents |
|-----|----------|
| [`docs/01-architecture.md`](docs/01-architecture.md) | The full picture: nodes, networks, data flows, capacity budget |
| [`docs/02-architecture-decisions.md`](docs/02-architecture-decisions.md) | Decision log (why Compose, why the core/apps split, where mail lives, ...) |
| [`docs/03-naming-conventions.md`](docs/03-naming-conventions.md) | Naming rules for everything |
| [`docs/04-networking-wireguard.md`](docs/04-networking-wireguard.md) | The private mesh and firewall model |
| [`docs/05-dns-and-mail.md`](docs/05-dns-and-mail.md) | DNS zone, Stalwart Mail, deliverability, relay |
| [`docs/06-secrets-and-backups.md`](docs/06-secrets-and-backups.md) | Secret handling and the Backblaze B2 backup/restore strategy |
| [`docs/07-deployment-guide.md`](docs/07-deployment-guide.md) | Step-by-step first deployment |
| [`docs/08-adding-an-app.md`](docs/08-adding-an-app.md) | The 5-minute new-application workflow |
| [`docs/09-roadmap.md`](docs/09-roadmap.md) | Phased rollout of the application catalogue |
