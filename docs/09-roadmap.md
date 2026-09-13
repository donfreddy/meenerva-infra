# 09 - Roadmap

Phased rollout. Each phase should be stable (deployed, backed up, documented) before
the next starts. `[ ]` todo, `[~]` in progress, `[x]` done.

## Phase 1 - Infrastructure + Identity + Mail  (core-node) - DONE

- [x] bootstrap-node.sh + init-core-node.sh
- [x] Traefik v3
- [x] PostgreSQL 16 (shared) + Redis
- [x] Keycloak realm `meenerva`, MFA policy, SMTP
- [x] Stalwart Mail: domain, DKIM/SPF/DMARC, mailboxes, outbound relay
- [x] Bulwark Webmail (native JMAP client) on core-node - login is currently
      app-password based; SSO login button kept visible but not wired end to
      end yet, see docs/05 section 4/5 and [[mail-server-placement]]
- [x] n8n + baseline SMTP
- [x] Backups to Backblaze B2 (restore procedure tested manually during
      incident response - Keycloak and Stalwart were both reset at least
      once during bring-up)

## Phase 2 - Collaboration  (apps-node) - in progress

- [x] apps-node bootstrap + WireGuard mesh
- [x] apps-node Traefik
- [x] Nextcloud + Collabora
- [x] Nextcloud Mail app wired to Stalwart (primary mail client, D-11) with
      an app-password (same pattern as Bulwark); Bulwark Webmail stays as
      the standalone/fallback client
- [~] Mattermost - deployed, admin created; SMTP relay to Stalwart over the
      mesh not working yet (parked, see D-16 in docs/02 and
      apps-node/apps/mattermost/README.md); SSO not configured yet
- [x] DocuSeal - deployed on apps-node (`sign.meenerva.io`); no Keycloak
      SSO (paid feature even self-hosted), see
      apps-node/apps/docuseal/README.md "Identity". Healthcheck uses a TCP
      probe (`nc -z`), not curl/HTTP - this image has no curl and no
      `/health` route, see docker-compose.yml comment
- [ ] EspoCRM

**On hold (2026-09-13, explicit user decision - revisit later, not dropped):**
- Cal.com - **Nextcloud's own Calendar app covers scheduling/appointments in
  the meantime** (see the Nextcloud-apps note below)
- Reqcore - confirmed real (Nuxt + Postgres, AGPL-3), just sequenced later
- Jitsi - needs its own session: JVB component wants a UDP port range and
  works best on host networking, not a drop-in Traefik-routed container like
  everything else here. **Nextcloud Talk covers calls/chat in the meantime.**
- OpenCLM - confirmed real (AGPL v3 contract lifecycle management), DB
  requirement not yet verified - check at install time

- [ ] Stalwart Keycloak/OIDC directory + XOAUTH2 for IMAP/SMTP (enables mail
      SSO) - attempted 2026-09-12, not completed, see
      docs/05-dns-and-mail.md section 4/5 before retrying blind

## Phase 3 - Operating management  (apps-node)

- [ ] OpenProject (historically RAM-heavy - budget 2-4 GB, watch it closely
      on apps-node after the Phase 2 apps land)
- [ ] Gitea / Forgejo (self-hosted git; "GitHub" in the source plan)
- [ ] Penpot ("Figma" equivalent, open source)
- [ ] PostHog -> deferred to data-node (heavy); stub only here

## Phase 4 - Core business  (apps-node, re-evaluate K3s here)

- [ ] **New shared MariaDB service on apps-node** (mirrors `core-postgres`'s
      mutualization: one database + isolated user per app), required because
      Frappe (ERPNext/Frappe HR) and EspoCRM don't speak Postgres. Add
      `create-app-database.sh`-equivalent tooling for MariaDB before the apps
      below.
- [ ] ERPNext + Frappe HR - same Frappe framework/bench; deploy as two
      "sites" on one Frappe stack rather than two separate deployments to
      save RAM and complexity
- [ ] decision: stay on Compose or move the three nodes into a K3s cluster

## Phase 5 - Security  (data-node - provision the third VPS)

- [ ] data-node bootstrap + mesh (`10.10.0.3`)
- [ ] Wazuh (dedicated, OpenSearch)
- [ ] Semgrep / Trivy / Grype in CI
- [ ] DefectDojo

## Phase 6 - GRC  (data-node)

- [ ] CISO Assistant
- [ ] FOSSology, ScanCode, Syft, Grype (SBOM + license)

## Phase 7 - Data / BI  (data-node)

- [ ] PostgreSQL analytics schema / read replica
- [ ] Metabase
- [ ] ClickHouse + Airbyte when volume justifies it

## Phase 8 - Automation  (n8n on core-node, integrations everywhere)

- [ ] onboarding (HIRED -> Frappe HR -> Keycloak -> MFA -> OpenProject -> Moodle -> Mattermost -> Nextcloud -> Gitea -> manager objectives)
- [ ] offboarding (termination -> disable identity -> revoke sessions -> transfer ownership -> rotate secrets -> device recovery -> audit evidence)
- [ ] contract approval + signature
- [ ] CRM -> project
- [ ] HR -> identity / training
- [ ] security finding -> project
- [ ] compliance evidence collection
- [ ] periodic reporting

## Capacity checkpoints

| Trigger | Action |
|---------|--------|
| core-node steady RAM > 85% | move n8n to apps-node |
| apps-node steady RAM > 85% | provision data-node early / resize VPS 8 |
| Stalwart data volume > 60% of disk | move to Contabo block storage volume |
| Phase 4 reached | K3s go/no-go decision (D-01) |
| any DB > 20 GB | dedicated engine or read replica |
