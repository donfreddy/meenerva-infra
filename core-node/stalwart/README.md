# Stalwart on core-node

There is no `config.toml` to maintain here. Since Stalwart v0.16, the server no
longer reads a TOML file at all: every setting (domains, DKIM, directory backend,
outbound relay, TLS/ACME, listeners) lives in Stalwart's own internal store
(`/etc/stalwart`, the `stalwart-etc` Docker volume) and is managed through the web
admin UI (`https://mail.meenerva.io/admin`) or the JMAP-based management API - not
through a file in this repo.

This directory exists only as a placeholder so the folder structure documented in
[`docs/01-architecture.md`](../../docs/01-architecture.md) matches the repo. If you
previously used an older version of this repo that shipped a `config.toml` here
and mounted it into the container, that mount has been removed - see decision D-07
in [`docs/02-architecture-decisions.md`](../../docs/02-architecture-decisions.md)
and the "First-run" walkthrough in [`docs/05-dns-and-mail.md`](../../docs/05-dns-and-mail.md).

## What is set via `docker-compose.yml` (core-node/docker-compose.yml)

- `STALWART_RECOVERY_ADMIN=admin:${STALWART_ADMIN_PASSWORD}` - seeds the initial
  administrator so you can log in even before finishing the setup wizard.
- `STALWART_PUBLIC_URL=https://${STALWART_ADMIN_HOST}` - the server's own external
  HTTPS URL, used for autoconfig/autodiscover and generated links.

## What is set via the setup wizard / admin UI (first boot)

1. Open `https://mail.meenerva.io/admin` and log in as `admin` /
   `STALWART_ADMIN_PASSWORD` (or read the temporary bootstrap password from
   `docker logs core-stalwart | grep -A8 'bootstrap mode'` if you did not set
   `STALWART_ADMIN_PASSWORD`).
2. The 5-step wizard asks for: hostname, primary domain, storage backend, account
   directory (internal to start), and logging.
3. After the wizard: add the domain (if not already), publish the generated DKIM
   record, create mailboxes, and configure the outbound relay. Full walkthrough in
   [`docs/05-dns-and-mail.md`](../../docs/05-dns-and-mail.md).
