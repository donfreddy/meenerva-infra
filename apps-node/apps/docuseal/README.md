# DocuSeal

- **Node:** apps-node
- **Subdomain:** `sign.meenerva.io`
- **Database:** `app_docuseal` on core-postgres (`./scripts/create-app-database.sh docuseal`)
- **Redis index:** `6` (see `core-node/.env.example` index table)
- **Keycloak client:** none - see "Identity" below
- **Upstream docs:** <https://www.docuseal.com/docs>, image
  <https://hub.docker.com/r/docuseal/docuseal>

## Deploy

1. On core-node: `./scripts/create-app-database.sh docuseal`
2. DNS: `sign A <apps-node-ip>`
3. `cp apps-node/apps/docuseal/.env.example apps-node/apps/docuseal/.env`,
   fill in `DOCUSEAL_DB_PASSWORD` (from step 1), `DOCUSEAL_SECRET_KEY_BASE`
   (`openssl rand -hex 64`), and the shared mail/redis values
4. `./scripts/check-images.sh apps-node/apps/docuseal/docker-compose.yml`
5. `make app-up NAME=docuseal`
6. Open `https://sign.meenerva.io` and create the first (admin) account
   immediately - same "don't leave the setup window open" caution as every
   other app in this repo

## Identity (read this before looking for a Keycloak client)

**DocuSeal's OIDC/SAML SSO is a paid add-on, gated even for self-hosted
instances** (confirmed against DocuSeal's own pricing/docs as of 2026-09) -
unlike Nextcloud or ERPNext, there is no free way to point this app at
Keycloak. Consequence for the "Keycloak is the only place accounts are
created" policy ([`10-identity-keycloak.md`](../../../docs/10-identity-keycloak.md)
section 4): DocuSeal is a **full exception**, not just a break-glass admin -
every user of this app is a local DocuSeal account, invited from inside
DocuSeal itself (Settings -> Users). Track DocuSeal accounts manually in the
offboarding checklist (docs/10 section 6) since disabling a Keycloak user has
no effect here.

If Keycloak-backed login for DocuSeal becomes a hard requirement later, the
options are: pay for DocuSeal's SSO tier, or put DocuSeal behind a
Keycloak-aware auth proxy (e.g. oauth2-proxy in front of the `edge` router)
that gates access to `sign.meenerva.io` without touching DocuSeal's own
per-document signer links (external signers who are not MEENERVA staff still
need to reach signing links without a Keycloak account - do not gate those
paths if this is attempted).

## Notes

- Single container handles web + background jobs (Sidekiq) - there is no
  separate worker service to run, unlike some other Rails-based apps.
- **Redis is required, not optional**: without `REDIS_URL` reachable, email
  delivery (signature requests, completion notices) and PDF/document
  processing silently queue and never run. If SMTP notifications from
  DocuSeal stop working, check Redis connectivity first, not just SMTP
  settings.
- `docuseal-data` holds uploaded templates and generated/signed documents -
  add it to `apps-node/docker-compose.yml`'s `offsite-backup.volumes` once
  real documents exist. Submission/template metadata itself lives in
  `app_docuseal`, already covered by the nightly core-postgres dump.
- External signers (people outside MEENERVA who receive a signing link) never
  need an account of any kind - DocuSeal's signing links are unauthenticated
  by design (token in the URL). This is expected behavior, not a
  misconfiguration.
