# 02 - Architecture decision log

Lightweight ADRs. Each entry: context, decision, consequences. Newest decisions can
supersede older ones; mark the old one `Superseded by D-NN` rather than deleting it.

---

## D-01 - Docker Compose now, Kubernetes later

**Context.** Two nodes, one operator, 15-20 apps over 8 phases. K3s adds ~1.5-2.5 GB
overhead per node and a steep operational learning curve.

**Decision.** Use Docker Compose + Portainer (Git-backed stacks) for Phases 1-3.
Re-evaluate K3s at Phase 4 (ERPNext / high-availability need). Keep the repo
role-structured so manifests, not architecture, are what changes in a migration.

**Consequences.** No inter-node auto-healing or rolling updates. Acceptable at this
scale. Portainer's Git integration gives us GitOps without an orchestrator.

---

## D-02 - Split into core-node and apps-node from day one

**Context.** A single VPS running identity + mail + ERP + chat is one OOM-kill away
from a full outage, and mixes a stable low-churn layer with a volatile one.

**Decision.** Physically separate the **foundation** (routing, identity, mail,
automation, shared data) from the **applications**. core-node on the smaller VPS 6,
apps-node on the larger VPS 8 (apps are the heavy consumers).

**Consequences.** Need a private link between nodes (see D-06). An app outage cannot
take down identity or mail. core-node can be firewalled far more tightly.

---

## D-03 - Role-based repository layout

**Decision.** Directories are `core-node/`, `apps-node/`, `data-node/` (by role), not
`vps6/`, `vps8/` (by hardware). Hardware mapping is documented in the README only.

**Consequences.** Resizing or migrating a VPS does not touch the repo. Adding the
third node is `mkdir data-node/` + a compose file.

---

## D-04 - One shared PostgreSQL, one database + user per app

**Context.** 15-20 separate Postgres containers would cost 5-8 GB of RAM in idle
overhead.

**Decision.** A single hardened `core-postgres`. Each app gets `app_<name>` database
owned by `app_<name>` role with a unique password. Provisioned by
`create-app-database.sh`. Apps needing a different engine (ClickHouse for PostHog,
OpenSearch for Wazuh) get a dedicated container inside their own stack.

**Consequences.** `core-postgres` is a SPOF for stateful apps - mitigated by nightly
per-database dumps, healthcheck, resource limits, and app-side connection retry. A
leaked app password only exposes that app's own database (role privileges are
scoped, no cross-database grants).

---

## D-05 - One Traefik per node, not a central proxy

**Context.** A single Traefik on core-node routing to apps-node means every app
request crosses the WireGuard tunnel and the proxy is a SPOF.

**Decision.** Each node runs its own Traefik and obtains its own Let's Encrypt
certificates. DNS points each subdomain directly at the node that serves it.

**Consequences.** No cross-node hop for normal traffic. Losing core-node's Traefik
does not affect apps-node's web surface. Slight duplication of Traefik config
(mitigated by shared dynamic-config snippets). WireGuard carries only
service-to-service traffic (DB, cache, SMTP relay).

---

## D-06 - WireGuard for the inter-node mesh

**Context.** apps-node must reach `core-postgres`, `core-redis` and Stalwart
submission without exposing those ports publicly.

**Decision.** WireGuard mesh on `10.10.0.0/24`. core = `.1`, apps = `.2`,
data = `.3` (reserved). Private services bind to the node's mesh IP only. Managed by
`setup-wireguard.sh`; keys never committed. Tailscale is a valid drop-in
alternative if NAT traversal or device onboarding becomes a pain.

**Consequences.** One more service to keep alive on each node (systemd-managed,
very stable). Firewall rules allow the mesh subnet on the private ports.

---

## D-07 - Stalwart Mail Server lives on core-node

**Context.** Should mail sit on the "core" node or the "apps" node? core-node is the
RAM-constrained one (12 GB); apps-node has headroom (24 GB).

**Decision.** **Stalwart Mail Server and the standalone webmail client (Bulwark
Webmail, see D-11) run on core-node.**

Reasons:

1. **Mail is foundational infrastructure, not an application.** Keycloak, n8n,
   Nextcloud, Mattermost, OpenProject and ERPNext all send email (activation,
   notifications, digests). It belongs with the other cross-cutting services that
   everything depends on, in the same operational and backup lifecycle.
2. **Deliverability is tied to IP and DNS stability.** The sending IP needs a stable
   PTR/rDNS record and aligned SPF/DKIM/DMARC. core-node is the node we treat as
   immutable infrastructure; apps-node is expected to be resized, rebuilt and
   experimented on as the app catalogue grows. Mail must not ride on a moving IP.
3. **Attack surface.** Mail is a high-value target and a high-value asset. Keeping it
   on the tightly-scoped core node (few services, strict UFW, no arbitrary app
   containers) is safer than co-locating it with a dozen churny business apps that
   each pull third-party images.
4. **Resource reality.** Stalwart is written in Rust and is genuinely light at rest
   (~150-400 MB idle; ~1 GB working set with full-text search). It fits the core
   budget. It uses its **own embedded store (RocksDB)** by default, so it adds no
   load to `core-postgres`.
5. **Locality with the webmail client.** Bulwark Webmail sits on the same node as
   Stalwart (it uses the public JMAP URL for TLS/OAuth correctness, but stays on
   the same host and lifecycle), never across the mesh.

**Consequences.** core-node RAM budget is tighter - accepted, with n8n as the
first relocation candidate if needed. When mailbox volume grows large (heavy
attachments, archiving, many mailboxes), the mitigation is: (a) move the
`stalwart-data` volume onto a mounted Contabo block-storage volume, then (b) if
still needed, migrate Stalwart to a dedicated mail node. The compose is written so
the data path is a single named volume that can be relocated without config changes.

**Rejected alternative - mail on apps-node:** more RAM, but couples deliverability to
a volatile node, splits infrastructure across two lifecycles, and enlarges the
blast radius of an app-container compromise.

---

## D-08 - Outbound mail through an SMTP relay (smarthost)

**Context.** Contabo IP ranges are frequently present on consumer-mail block-lists.
Direct-to-MX delivery from a fresh Contabo IP often lands in spam or is rejected.

**Decision.** Receive mail directly (MX -> Stalwart on core-node:25), but send
**outbound through a transactional relay** (Amazon SES, Postmark, MailerSend or
Brevo) configured as Stalwart's smarthost. All apps on apps-node relay through
Stalwart (`10.10.0.1:587`), which then relays to the provider. Keep direct-to-MX
sending available as a fallback / for low-volume internal mail.

**Consequences.** A small monthly cost and a third-party dependency for outbound,
in exchange for reliable delivery decoupled from IP reputation. SPF must list the
relay; DKIM is signed by Stalwart (and optionally also by the provider). If the
studio later warms a dedicated IP, the relay can be dropped by config only.

---

## D-09 - Every service declares mem_limit and healthcheck

**Decision.** No service is deployed without an explicit memory limit and a
healthcheck. Enforced by review and by `make *-config`.

**Consequences.** A leaking container is killed and restarted instead of taking the
node down. Portainer and `docker ps` show real health, not just "running".

---

## D-10 - Secrets never enter the repository

**Decision.** Only `*.env.example` files are committed. Real values live in the
per-node `.env` (git-ignored) and/or Portainer stack environment, with a copy in a
team password manager. Rotation procedure in
[`06-secrets-and-backups.md`](06-secrets-and-backups.md).

---

## D-11 - Dual mail-client access: Nextcloud Mail (primary) + Bulwark Webmail (standalone)

**Context.** Stalwart is the single mail data store. Users work in different
contexts: some live inside Nextcloud all day (files, calendar, Talk, tasks); others
just want a fast inbox check, and admins/devs need an access path that does not
depend on Nextcloud being up.

**Decision.** Expose the **same mailboxes on the same Stalwart server** through two
web clients, chosen by use case, not by exclusivity:

| Client | Node | Protocol | Role |
|--------|------|----------|------|
| **Nextcloud Mail** | apps-node | IMAP/SMTP (XOAUTH2 via Keycloak) to `mail.meenerva.io` | **Primary** client for business users. Email becomes a first-class object next to files, calendar, Talk and OpenProject tasks. |
| **Bulwark Webmail** | core-node | **JMAP** to `https://mail.meenerva.io`, OAuth/OIDC via Keycloak | **Standalone / native / fallback**. Fast mail-first UI (also native Calendar / Contacts / Files over JMAP+WebDAV). Works when apps-node is down; lives with the mail server, same lifecycle. |

Bulwark Webmail (`github.com/bulwarkmail/webmail`) is the JMAP-native client built
for Stalwart - it replaces the earlier Roundcube choice: JMAP instead of IMAP
polling (lighter, faster, push), OIDC login out of the box, and one UI for mail +
calendar + contacts + files. Both clients are stateless views; a read/delete/move
in one is reflected everywhere within seconds because state lives in Stalwart. SSO:
the user authenticates once against Keycloak; Nextcloud Mail uses OAuth token
passthrough to Stalwart, Bulwark discovers Keycloak from `OAUTH_ISSUER_URL`.

**Consequences.** Bulwark runs in the core stack (~512 MB, a Node/Next.js app -
more than Roundcube's ~320 MB but still within the core budget) and connects to
Stalwart over the **public** endpoint so the TLS name matches and OAuth discovery
works - it does not use the internal Docker hostname or the WireGuard IP. The image
has no stable semver tags yet (young project): pin it to a digest before
production. XOAUTH2 / provisioning details and the password fallback are in
[`05-dns-and-mail.md`](05-dns-and-mail.md).

**Rejected alternatives:**
- *One client only* - Nextcloud-Mail-only leaves no mail access when apps-node is
  down (the node meant to be the most disposable); Bulwark-only loses the
  collaboration value (drag a Nextcloud file into a mail, turn a mail into an
  OpenProject task).
- *Roundcube as the standalone client* - proven and lighter, but IMAP-only, dated
  UX, no native OIDC, and no calendar/contacts; superseded by Bulwark for the
  JMAP-native path.

---

## D-12 - Deployment stays `git pull` + `docker compose up -d` over SSH; Portainer is a dashboard, not the GitOps engine

**Context.** D-01 through the Phase 1 deployment guide originally assumed
Portainer's "Stacks -> Repository" feature would take over as the deployment
mechanism after the first manual bring-up: push to `main`, Portainer polls Git
and redeploys. In practice, once core-node was live, Portainer showed the
CLI-launched `meenerva-core` stack in **Limited** control mode (it detects
externally-created Compose projects but does not own their lifecycle), and
every single fix made during initial operation - restarts, volume surgery,
`docker exec` diagnostics, log inspection - went through direct SSH and the
`docker`/`docker compose` CLI. Portainer's UI was never actually used.

**Decision.** Keep the manual workflow as the deployment mechanism on both
nodes: `git pull` then `docker compose --project-directory <node> --env-file
<node>/.env up -d` (wrapped by `make core-up` / `make apps-up` / `make app-up
NAME=<app>`). Portainer stays installed, but purely as a **visual status
dashboard** (container list, logs, resource usage) - not as the thing that
deploys anything. Do not attempt to migrate the CLI-launched stacks into
Portainer-owned "Repository" stacks; it would require adopting or replacing
already-running, named containers for a mechanism that duplicates two lines of
SSH with more moving parts and less visibility into *when* a deploy actually ran.

**Consequences.** No webhook/polling layer to reason about when something
doesn't redeploy as expected; a `git push` requires a manual `git pull` + `up -d`
on the target node (documented per-change in this repo's guidance, not
automatic). Portainer's ~512 MB stays a monitoring convenience, re-evaluate
dropping it entirely (D-12 vs removing it) if it turns out not to earn even that
- it is also a public-internet attack surface (see the Safe-Browsing note below)
worth minimizing if unused. `apps-node/apps/<name>/README.md` and
[`08-adding-an-app.md`](08-adding-an-app.md) deploy instructions were updated
to use `make app-up NAME=<app>` instead of "add a Portainer Repository stack".

**Aside - Portainer and public exposure.** `portainer.<domain>` triggered a
Chrome "Dangerous site" (Google Safe Browsing) warning shortly after going
live, most likely inherited IP reputation from a previous tenant of the
recycled Contabo IP rather than anything on this deployment - checked via
`transparencyreport.google.com/safe-browsing/search`. Independent of that,
exposing a tool with full Docker control (root-equivalent on the host) to the
entire internet is worth reconsidering: an IP allow-list Traefik middleware or
moving it behind the WireGuard mesh only are both cheap follow-ups if Portainer
is kept.

**Rejected alternative - migrate to Portainer GitOps as originally planned:**
would have required either standing up a second, differently-named stack
(duplicate containers, port/network conflicts) or manually adopting the
existing one into Portainer's model, for a benefit (saving `git pull && up -d`)
that does not offset the migration risk or the loss of directness when
debugging - shown repeatedly during Phase 1 bring-up to require SSH regardless.

---

## D-13 - No web-based database admin tool (pgAdmin/Adminer) for now

**Context.** The original plan (see `gemini.md`) included pgAdmin next to
`core-postgres`. Every actual database task during Phase 1 bring-up (creating
per-app roles/databases, wiping `app_keycloak`, ad-hoc lookups) was done with
`docker exec -it core-postgres psql -U <user> -d <db>` or
`scripts/create-app-database.sh`, and that covered everything needed.

**Decision.** Do not add a permanent database UI to the core stack.
`core-postgres` stays reachable only via `psql` over `docker exec` (or, from
apps-node, a Postgres client pointed at `10.10.0.1:5432`). Same reasoning as
D-12: a web UI here would need its own Traefik route and authentication to
expose safely (the database itself is deliberately not internet-facing, see
`core-node/docker-compose.yml`), for a workflow that plain `psql` already
covers.

**Consequences.** No extra always-on service (RAM, attack surface, one more
thing to patch). Exploring data visually (e.g. browsing table contents rather
than writing `SELECT`s) is less convenient than a GUI would be. If that becomes
a real need later, the lightweight fallback is **Adminer** run on-demand (a
single-file ~50 MB image, `docker run --rm --network core-internal -p
8081:8080 adminer`, connect to `core-postgres`, stop it when done) rather than
a permanent pgAdmin service - covers the same "I want to look at this table"
need without a standing footprint.

**Rejected alternative - permanent pgAdmin in the core stack:** ~300-500 MB RAM
on a 12 GB node for a capability plain `psql` already provides for everything
done so far, plus a public route to secure and maintain.
