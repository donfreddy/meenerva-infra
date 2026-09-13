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
data = `.3` (reserved). Private services are reached at the node's mesh IP and
restricted to the mesh subnet by UFW (not by binding to that IP specifically -
see D-14). Managed by `setup-wireguard.sh`; keys never committed. Tailscale is
a valid drop-in alternative if NAT traversal or device onboarding becomes a
pain.

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

---

## D-14 - PostgreSQL/Redis publish on 0.0.0.0, restricted by UFW, not by IP-bind

**Context.** D-06 originally called for binding `core-postgres`/`core-redis`'s
published ports directly to the WireGuard mesh IP (`10.10.0.1:5432` /
`10.10.0.1:6379` in `docker-compose.yml`'s `ports:`), so the port would not
exist at all outside the mesh interface. When apps-node was brought up and the
mesh connected (handshake confirmed via `wg show` and successful `ping`),
`nc -zv 10.10.0.1 5432`/`6379` from apps-node got a clean **connection
refused** - not a timeout, meaning packets reached core-node's kernel but
nothing was listening there from the network's point of view. Diagnosis:
- `docker inspect core-postgres` showed `HostConfig.PortBindings` correctly
  requesting `{"HostIp":"10.10.0.1","HostPort":"5432"}`, but
  `NetworkSettings.Ports` was `null` - Docker accepted the config but never
  actually realized the binding.
- A plain `nc -l 10.10.0.1 5432` bound and listened fine - the OS/interface
  (a `POINTOPOINT` WireGuard interface with a `/24` address) was not the
  problem.
- `iptables -t nat -L DOCKER -n` had **no rule at all** for port 5432 or 6379
  - Docker never created the DNAT rule, across both a container
  `--force-recreate` and a full `systemctl restart docker`, in both orders.
- UFW's own rules were already correct (`5432/tcp ALLOW IN 10.10.0.0/24`) and
  not the cause - `DOCKER-USER`/`ufw-*` forward chains had no relevant DROP
  hit.

Switching the bind from `10.10.0.1:5432` to plain `0.0.0.0:5432` (first fix
attempted) made **no difference** - `iptables -t nat -L DOCKER` was still
completely empty for both ports after a fresh recreate. The real variable
turned out to be network membership, not bind address: `postgres` and `redis`
were the only services whose **sole** network is `core-internal`, which is
declared `internal: true` (no route to the outside world, by design - see
D-04's Docker-networks table). Every other service with a working published
port (Traefik, Portainer, Keycloak, Stalwart, Bulwark, n8n) is also on `edge`,
a normal bridge network. This matches a confirmed, long-standing Docker
limitation: **a container cannot have a working published port if its only
network is `internal: true`** - Docker does not create the DNAT rule for it at
all, silently (tracked as
[moby/moby#36174](https://github.com/moby/moby/issues/36174)). No amount of
bind-address tweaking, container recreation, or daemon restart works around
this; it does not depend on the bind IP.

**Decision.** Join `postgres` and `redis` to `edge` as well (`networks: [edge,
core-internal]`, matching every other service), publish `5432`/`6379` on
`0.0.0.0`, and rely on the **UFW** rule restricting source IPs to
`10.10.0.0/24` for the actual access control - not network membership, not
bind address. `edge` membership only makes Docker willing to create the DNAT
rule; it grants no HTTP route (no Traefik labels are set on these services)
and no additional exposure beyond what the published port + UFW already
governs.

**Consequences.** The port technically exists on the public interface at the
OS level, but UFW drops/rejects anything not sourced from `10.10.0.0/24`
before it reaches Postgres/Redis - verified equivalent to the original intent.
Removed `POSTGRES_WG_BIND_IP`/`REDIS_WG_BIND_IP` from `core-node/.env.example`
(no longer used - the bind address was never the actual variable). Always
still connect to these services via the mesh IP (`10.10.0.1`) from apps-node,
not the public IP - only which Docker network reaches them changed, not the
intended access path or naming convention. Any future service that needs a
published port and is currently `core-internal`-only will hit the same wall;
add it to `edge` too.

**Rejected alternatives:**
- *Keep debugging the IP-bind specifically* - abandoned once switching to
  `0.0.0.0` alone (no network change) also produced zero NAT rules, proving
  bind address was never the actual cause.
- *Drop `internal: true` from `core-internal` instead* - would restore port
  publishing for any container on it, but removes the "no internet egress"
  containment property that network exists for (see D-04), for every service
  on it, not just the two that needed publishing. Adding just postgres/redis
  to `edge` is the narrower fix.

---

## D-15 - Remove Portainer entirely (supersedes the "keep as dashboard" part of D-12)

**Context.** D-12 kept Portainer installed on core-node after dropping its
GitOps role, reasoning it might still earn its ~512 MB as a visual status
dashboard. Once core-node was actually live and reachable, that fallback value
never materialized either: across the full Phase 1 bring-up and every
incident handled afterward (Stalwart lockouts, the n8n DB password mismatch,
the WireGuard/Docker port-publish saga in D-14, ...), status and logs were
checked with `docker compose ps` / `docker logs` / `docker inspect` every
single time, never once through the Portainer UI - including after it was
live and working. Separately, `portainer.meenerva.io` triggered a Chrome
"Dangerous site" (Google Safe Browsing) warning (see D-12's aside), and the
attempt to also connect apps-node to it (D-12 anticipated this) hit the same
class of Docker port-publish issue as D-14, or would have required switching
to Portainer's Edge mode and opening a new port (8000) on core-node for a
feature that, again, had not been used once.

**Decision.** Remove Portainer from core-node entirely (the service, its
Traefik router, and the `portainer-data` volume) and drop the never-deployed
`portainer-agent` from apps-node (removed slightly earlier, same reasoning).
No replacement dashboard - `docker compose ps`, `docker logs`, `docker
inspect` over SSH are the monitoring workflow, matching how every incident in
this repo's history was actually diagnosed.

**Consequences.** Frees ~512 MB on core-node (meaningful on a 12 GB node) and
removes a public route that had already drawn one unrelated-but-real
blocklist flag. No visual container browser for anyone less comfortable with
the CLI - acceptable for a one-operator studio at this stage; revisit if a
team member without SSH access needs read-only visibility later (a lighter,
read-only tool - e.g. a simple `docker events`/`ps` status page - would be a
smaller footprint than Portainer for that narrow need).

**Rejected alternative - keep it "just in case":** the same reasoning was
already applied once in D-12 and the anticipated value did not show up even
with the tool live, accessible, and unremoved for the entire rest of Phase 1 -
carrying it further on hope alone was not worth the RAM and the public
attack surface.

---

## D-16 - `ufw route allow` needed for container-to-mesh traffic, not just `ufw allow`

**Context.** Mattermost (apps-node) failed to reach `core-stalwart:587` for
outbound mail with `connection refused`, even though `core-stalwart` was
confirmed healthy and publishing `0.0.0.0:587`, and an identical `nc` check
run **directly on the apps-node host** to `10.10.0.1:5432`/`6379` had
succeeded earlier (during the D-14 investigation). Retesting from a container
on `edge` (`docker run --rm --network edge busybox nc -zv 10.10.0.1 587`)
reproduced the failure - the working host-level test and the failing
container-level test were never actually the same code path, and nobody had
tested the container path until Mattermost needed it for real.

Root cause: a container's packet to a mesh peer is routed by the host through
a *different* interface (its Docker bridge in, `wg0` out), which the kernel
treats as **forwarded** traffic - the `FORWARD` chain, not `INPUT`/`OUTPUT`.
`ufw status verbose` showed `Default: deny (incoming), allow (outgoing), deny
(routed)` - every `ufw allow` rule added so far (D-04/init-*-node.sh) only
covers `INPUT` (traffic addressed to the host itself), so `deny (routed)`
silently blocked every container's mesh-bound packet regardless of those
rules. This is orthogonal to D-14 (that was Docker never creating a NAT rule
at all; this is UFW blocking traffic Docker *did* forward correctly).

**Decision.** Add `ufw route allow out on wg0 to 10.10.0.0/24` (the `ufw
route` subcommand targets the `FORWARD` chain specifically) to both
`init-core-node.sh` and `init-apps-node.sh`, alongside the existing `ufw
allow from <mesh> to any port <p>` rules. Both are required together: `ufw
allow ... port <p>` permits the *destination* node to accept the connection
at all; `ufw route allow out on wg0` permits the *source* node's kernel to
forward a container's packet out through the tunnel in the first place.

**Consequences.** Any node bootstrapped before this fix needs the rule added
by hand (`ufw route allow out on wg0 to 10.10.0.0/24 && ufw reload`) since
`init-*-node.sh` is not re-run automatically. Verified against Mattermost's
real SMTP-relay traffic, not just a synthetic `nc` check, so this is the
actual fix, not a theory. Anything added later that needs a container on one
node to reach a service on another over the mesh depends on this rule already
being in place - it is not specific to Mattermost or to port 587.

**Update 2026-09-13 - not the full story.** This rule was necessary but not
sufficient for Mattermost's actual SMTP traffic: `iptables -L FORWARD -n -v`
showed all forwarded packets being decided inside Docker's own
`DOCKER-USER`/`DOCKER-FORWARD` chains *before* UFW's chains are ever
consulted, regardless of the `ufw route allow` rule above. Explicit
`iptables -I DOCKER-USER -s/-d 10.10.0.0/24 -j ACCEPT` rules on both nodes
were required in addition, confirmed via packet counters actually
incrementing on those rules. Even with both fixes, the connection still
failed (fast, active "Connection refused" rather than a silent drop), and
the same DOCKER-USER gap was found present on **core-node** too, applying
only to apps-node originally - both nodes need it since a packet from an
apps-node container reaching a core-node container's *published port* is
forwarded twice (once on each host).

**Update 2026-09-13 (later same day) - true root cause found via tcpdump.**
With both fixes above confirmed correctly in place on both nodes (packet
counters incrementing, UFW route rules present), the connection to
`10.10.0.1:587` still failed - and OpenProject hit the identical symptom
independently, ruling out anything Mattermost-specific. `tcpdump -i any
'host 10.10.0.1 and port 587'` on core-node during a direct host-level
`nc` test gave the definitive answer: the SYN correctly reaches
`core-stalwart`'s container IP (`172.18.0.5:587`) via the DNAT rule, and
**Stalwart's own container replies with an immediate RST** - proven by the
packet capture showing the `[R.]` flag originating from `172.18.0.5`, not
from any host/Docker firewall layer. So D-14's and D-16's fixes were both
real and necessary (the packet does need to travel that whole path
correctly), but insufficient because Stalwart itself refuses the
connection once it arrives, based on the *unmasqueraded* source IP: a
connection via the loopback hairpin path (`127.0.0.1`) gets Docker's
automatic hairpin SNAT to a bridge-range address (inside the already
allow-listed `172.16.0.0/12`), while a real mesh-sourced connection
(`10.10.0.1` or `10.10.0.2`) shows its true source IP to Stalwart, which
is outside that range.

Adding `10.10.0.0/24` to Stalwart's **Settings -> Security -> Allowed IP
addresses** (confirmed saved, no expiry) did not fix it, and a full
`stalwart` container restart afterward did not either - the RST persisted
identically. Checked **Blocked IP addresses** too: no entry for `10.10.0.1`
or `10.10.0.2` (only an unrelated external IP banned for port scanning).
Working theory, not yet confirmed: repeated bare-TCP `nc -z` probes against
this port during the investigation itself (dozens, over roughly an hour)
may look exactly like the "excessive port scanning" pattern Stalwart's own
abuse protection is designed to catch, possibly triggering a short-lived,
in-memory rate-limit/throttle that does not appear in the persisted
Blocked IPs list - and each further `nc` test may have been re-extending
that same window, making `nc` an actively self-defeating diagnostic tool
here. **Status: parked, not fully resolved** - see
`apps-node/apps/mattermost/README.md` and
`apps-node/apps/openproject/README.md` to-do notes. Next time this is
picked up: do NOT probe port 587 with bare `nc`; wait several minutes with
zero connection attempts of any kind, then test with a real SMTP-speaking
client (an app's own "send test email" action) as the very first attempt,
and if it still fails, raise Stalwart's log verbosity (debug/trace, see the
Bulwark OIDC lesson in `05-dns-and-mail.md` section 4 for why default
verbosity has already been shown to hide the actual rejection reason once
before) rather than repeating more TCP-level probing.

---

## D-17 - Shared MariaDB on apps-node, moved up from Phase 4

**Context.** EspoCRM (next in the app queue after Mattermost/DocuSeal) only
supports MySQL/MariaDB, never Postgres - confirmed against EspoCRM's own
Docker documentation. `09-roadmap.md` Phase 4 already anticipated this need
("New shared MariaDB service on apps-node... required because Frappe
(ERPNext/Frappe HR) and EspoCRM don't speak Postgres") but scheduled it
alongside Frappe, later than EspoCRM's actual position in the user's
prioritized queue (Mattermost, DocuSeal, EspoCRM, OpenProject, then Frappe).

**Decision.** Bring up the shared MariaDB now, as an `apps-node/docker-compose.yml`
service (`apps-mariadb`), ahead of the originally planned Phase 4 timing -
mirrors core-postgres's mutualization model (D-04): one database + user per
app, provisioned by a new `scripts/create-mysql-database.sh` (parallel script
to `create-app-database.sh`, same safe-by-default re-run behavior). ERPNext
and Frappe HR will reuse this same instance when Phase 4 starts rather than
getting a second MariaDB.

**Why this one does NOT need D-14's edge/mesh treatment.** core-postgres and
core-redis had to join `edge` and publish a port because apps-node needs to
reach them *across* the WireGuard mesh (D-14). `apps-mariadb` has no such
requirement: every current and planned consumer (EspoCRM, ERPNext, Frappe HR)
runs on apps-node itself, so plain `apps-internal` container-to-container
networking is sufficient - no published port, no mesh hop, none of
moby/moby#36174's failure mode (that bug is specific to published ports, not
same-network container traffic). If a future node ever needs to reach this
MariaDB remotely, that requirement has to be solved then, not assumed to
already work.

**Consequences.** apps-node gains one more always-on service (~768 MB
`mem_limit`); revisit the apps-node RAM budget in `01-architecture.md` as
more MariaDB-backed apps land. `MARIADB_ROOT_PASSWORD` is a new required
secret in `apps-node/.env`.

---

## D-18 - `gen_secret()` must produce URL-safe passwords, not base64

**Context.** OpenProject failed to boot on first deploy with `URI::InvalidURIError:
the scheme postgres does not accept registry part: app_openproject:<password>
(or bad hostname?)`. Root cause: `scripts/create-app-database.sh` generates
passwords via `gen_secret()` (`openssl rand -base64 36`), and the generated
password happened to end in `/`. Several apps embed the DB password directly
inside a single connection-string env var - `postgres://user:${PASSWORD}@host/db`
(Mattermost's `MM_SQLSETTINGS_DATASOURCE`, DocuSeal's `DATABASE_URL`,
OpenProject's `DATABASE_URL`) - and an unescaped `/` (or `+`) inside a URI's
userinfo component breaks parsing: the parser hits the `/` before it ever
finds the `@` separating userinfo from host, and reports a mangled, host-less
"registry part" error that looks unrelated to the real cause. base64's
alphabet (`A-Za-z0-9+/=`) can produce any of `/`, `+`, `=` at any position in
any generated secret - this was latent, not new, and could equally have hit
Mattermost's or DocuSeal's DB password without anyone noticing until a
restart regenerated a differently-unlucky string.

**Decision.** Change `gen_secret()` in `scripts/lib/common.sh` from
`openssl rand -base64 36` to `openssl rand -hex 32`. Hex output
(`0-9a-f` only) is unconditionally URL-safe, shell-safe, and YAML-safe - no
call site needs to know or care that the value might need encoding.

**Consequences.** Only affects *newly generated* secrets - existing passwords
already stored in a `.env` are untouched (matches `create-app-database.sh`'s
and `create-mysql-database.sh`'s existing safe-by-default re-run behavior,
D-13-adjacent). Any app whose DB password happens to already contain `/`,
`+`, or `=` needs a one-time rotation: `ROTATE=1 ./scripts/create-app-database.sh
<app>` (or the mysql equivalent), then update that app's `.env` and redeploy
it - check `grep -E '[/+=]' <app>/.env` on every `*_DB_PASSWORD` /
`*_SECRET*` line as a quick audit. Apps that pass DB credentials as discrete
fields instead of one URL string (EspoCRM's `ESPOCRM_DATABASE_PASSWORD`,
Nextcloud's `POSTGRES_PASSWORD`) were never at risk from this specific bug,
but gain nothing from the old base64 either - no reason to keep two secret
formats around.

---

## D-19 - a multi-container app's non-web containers still need `edge` if they reach the mesh

**Context.** OpenProject's `openproject-worker`, `openproject-cron`, and
`openproject-seeder` were put on `apps-internal` only (same reasoning as
EspoCRM's `espocrm-daemon`: no HTTP endpoint of their own, no Traefik route
needed). The seeder failed with `PG::ConnectionBad: connection to server at
"10.10.0.1", port 5432 failed: Network is unreachable` - confirmed via
`bash -x` tracing the seeder script directly, not a guess. Root cause:
`apps-internal` is `internal: true`, and Docker gives such a network **no
gateway at all** - not just "no published ports" (D-14's finding), but no
route out for ANY traffic the container itself initiates, mesh-bound or
otherwise. `espocrm-daemon` never hit this because its only dependency
(`apps-mariadb`) lives on the same node's `apps-internal` network already;
`openproject-worker`/`cron`/`seeder` need `core-postgres`, which is a
different *node*, reachable only through the host's `wg0` interface - and
only `edge` (a plain, non-internal bridge) has a path to that.

**Decision.** Any container that needs to reach a service on another node
over the WireGuard mesh must join `edge`, regardless of whether it needs an
HTTP route through Traefik. `apps-internal`/`core-internal` are for
same-node, container-to-container traffic only (a private sidecar like
Collabora-to-Nextcloud or espocrm-daemon-to-apps-mariadb) - never assume a
background/worker container is exempt just because it has no Traefik labels.
`openproject-worker`, `openproject-cron`, and `openproject-seeder` now join
`[edge, apps-internal]`, same as the main `openproject` web container.

**Consequences.** When scaffolding a future multi-container app (Frappe's
bench likely has a similar web/worker/scheduler split), check each
container's actual dependencies individually rather than copying one
network list for all of them: same-node-only dependency -> `apps-internal`
suffices; any dependency on another node (core-postgres, core-redis,
Stalwart) -> that container needs `edge` too. This is now the second class
of "internal-only network breaks connectivity" bug found in this repo (D-14
was inbound/published-port; D-19 is outbound/initiated-by-the-container) -
worth checking both directions whenever an `internal: true` network is
involved.
