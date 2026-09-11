# 09 - Roadmap

Phased rollout. Each phase should be stable (deployed, backed up, documented) before
the next starts. `[ ]` todo, `[~]` in progress, `[x]` done.

## Phase 1 - Infrastructure + Identity + Mail  (core-node)

- [ ] bootstrap-node.sh + init-core-node.sh
- [ ] Traefik v3 + Portainer
- [ ] PostgreSQL 16 (shared) + Redis
- [ ] Keycloak realm `meenerva`, MFA policy, SMTP
- [ ] Stalwart Mail: domain, DKIM/SPF/DMARC, mailboxes, outbound relay
- [ ] Bulwark Webmail (native JMAP client) on core-node
- [ ] n8n + baseline SMTP
- [ ] Backups to Backblaze B2, one tested restore

## Phase 2 - Collaboration  (apps-node)

- [ ] apps-node bootstrap + WireGuard mesh
- [ ] apps-node Traefik
- [ ] Nextcloud + Collabora
- [ ] Nextcloud Mail app wired to Stalwart (primary mail client, D-11); Bulwark Webmail stays as the standalone/fallback client
- [ ] Stalwart Keycloak/OIDC directory + XOAUTH2 for IMAP/SMTP (enables mail SSO)
- [ ] Mattermost
- [ ] Jitsi (or Nextcloud Talk)
- [ ] Cal.com
- [ ] all wired to Keycloak OIDC + core-postgres + Stalwart SMTP

## Phase 3 - Operating management  (apps-node)

- [ ] OpenProject
- [ ] Gitea / Forgejo (self-hosted git; "GitHub" in the source plan)
- [ ] Penpot ("Figma" equivalent, open source)
- [ ] PostHog -> deferred to data-node (heavy); stub only here

## Phase 4 - Core business  (apps-node, re-evaluate K3s here)

- [ ] ERPNext + Frappe HR
- [ ] EspoCRM
- [ ] DocuSeal
- [ ] OpenCLM / contract lifecycle
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
