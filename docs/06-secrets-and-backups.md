# 06 - Secrets and backups

## Secrets

### Rules

- Only `*.env.example` is committed. `*.env`, `*.conf`, `acme.json`, `wg-keys/` are
  git-ignored.
- Real values live in **two places only**: the per-node `.env` on the server, and a
  team password manager (Bitwarden / Vaultwarden / 1Password).
- Generate: `openssl rand -base64 36`. For consumers that reject `+ / =`
  (some connection strings), use `openssl rand -hex 32`.
- One secret = one purpose. Never reuse the Postgres superuser password for an app.

### Inventory (keep updated)

| Secret | Consumer | Rotation impact |
|--------|----------|-----------------|
| `POSTGRES_SUPERUSER_PASSWORD` | core-postgres | restart Postgres + update `.env` |
| `<APP>_DB_PASSWORD` | one app | `ALTER ROLE app_<x> PASSWORD` + redeploy that app |
| `REDIS_PASSWORD` | all cache users | rolling redeploy of consumers |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak bootstrap | change in Keycloak UI after first boot, then blank the env |
| `N8N_ENCRYPTION_KEY` | n8n credential store | **do not rotate** without re-entering all credentials; back it up |
| `STALWART_ADMIN_PASSWORD` | Stalwart bootstrap admin (`STALWART_RECOVERY_ADMIN`) | rotate the password in the admin UI after first login; the env var only seeds it |
| `WEBMAIL_SESSION_SECRET` / `WEBMAIL_OAUTH_CLIENT_SECRET` | Bulwark Webmail | rotate + redeploy `core-webmail` |
| `RESTIC_PASSWORD` | backup encryption | **losing this makes every backup unrecoverable** - store it in 3 places |
| `B2_*` | offsite backup | create new B2 app key, update `.env` |
| WireGuard private keys | mesh | regenerate + re-exchange public keys |

### Future: move to a secret manager

When Phase 1 identity is stable, introduce **Infisical** or **Vault** on core-node
and have `docker compose` pull secrets at deploy time instead of a plain `.env`.
Not required now; the `.env` + password-manager model is fine for two nodes and
one operator.

### Database access (no GUI, see decision D-13)

`core-postgres` is not internet-facing and has no web admin UI. Use `psql`:

```sh
# on core-node, as the superuser
docker exec -it core-postgres psql -U "$POSTGRES_USER" -d postgres

# a specific app's own database, as its own role (interactive login shell)
docker exec -it core-postgres psql -U app_n8n -d app_n8n
```

> **This does NOT verify an app's actual password.** Without `-h`, `psql`
> connects over the local Unix socket, which the official Postgres image
> authenticates with `trust` (no password check at all) regardless of what you
> type. This produced a false "it works" during a real n8n outage where the
> role's real (network) password had drifted from what was in `.env` - the
> socket login above happily succeeded throughout. To actually test the
> credential an app will use, connect the same way the app does: over the
> Docker network, by hostname, from a **different** container:
> ```sh
> docker run --rm --network core-internal postgres:16-alpine \
>   sh -c "PGPASSWORD='<password>' psql -h core-postgres -U app_n8n -d app_n8n -c 'select current_user;'"
> ```
> This is the only form that exercises the same `host ... scram-sha-256` rule
> real apps hit. If this fails, the credential is genuinely wrong - fix it with
> `ROTATE=1 ./scripts/create-app-database.sh <app>` and update that app's
> `.env`, however confidently a socket-based `psql` login "worked".

From apps-node (or any machine on the WireGuard mesh), point a regular Postgres
client at `10.10.0.1:5432` with the app's own role/database credentials - that
path goes over the network too, so it is a valid test.

Need to browse tables visually just once? Run **Adminer** on demand rather than
adding a permanent service:

```sh
docker run --rm --network core-internal -p 127.0.0.1:8081:8080 adminer
# ssh -L 8081:localhost:8081 root@<core-ip>, then open http://localhost:8081
# System: PostgreSQL, Server: core-postgres, then your usual user/db/password
```

Stop it (`Ctrl+C`) when done - it is not meant to stay running.

## Backups

### What, where, when

```
                         core-node
  core-postgres --(nightly, pg_dump per DB)--> backup-dumps volume (*.sql.gz)
       |                                                        |
  named volumes (stalwart-data, n8n-data,        +--------------+
  webmail-data, traefik-acme)                    |
       |                                         v
       +--------> offen/docker-volume-backup --> Backblaze B2 (encrypted, GPG)
                                                  bucket: meenerva-backups
                                                  path: core-node/

                         apps-node
  apps-mariadb --(nightly, mysqldump per DB)--> mariadb-dumps volume (*.sql.gz)
       |                                                        |
  named volumes (nextcloud-data, mattermost-data,+---------------+
  mattermost-config, frappe-sites, espocrm-data,  |
  espocrm-custom, espocrm-client-custom,          v
  docuseal-data, openproject-data)  ---> offen/docker-volume-backup --> Backblaze B2
                                                  bucket: meenerva-backups
                                                  path: apps-node/
```

Retention (both nodes): controlled by `BACKUP_RETENTION_DAYS` in each node's
`.env`, enforced by `offen/docker-volume-backup`'s own pruning - not by B2
bucket lifecycle rules, which are left at "keep all versions" so they don't
race the container's pruning.

- **Layer 1 - local dumps.** `prodrigestivill/postgres-backup-local`
  (`core-postgres`) and `fradelg/mysql-cron-backup` (`apps-mariadb`) each write
  rotating per-database SQL dumps to a host-local volume. Fast restore,
  survives a container loss, and - critically - dumps the database through its
  own client instead of copying its live datadir, so the backup is
  transactionally consistent instead of a torn snapshot of a database still
  being written to.
- **Layer 2 - off-site.** `offen/docker-volume-backup` archives the dump
  directory **and** the stateful (file-based) volumes, encrypts them, and
  pushes to **Backblaze B2** (`~0.006 USD/GB/month`, S3-compatible). Retention
  + pruning handled by the container. Each app's compose project is separate
  from `offsite-backup`'s, so its volumes are wired in as `external: true` -
  see `apps-node/docker-compose.yml` and the checklist in
  [`08-adding-an-app.md`](08-adding-an-app.md) for the pattern to follow when
  a new app is added.
- Nextcloud user files additionally use Nextcloud's own backup or an
  object-storage primary once volume grows past what B2-of-a-Docker-volume is
  comfortable with.

### Configuration

`core-node/.env`:

```
B2_S3_ENDPOINT=s3.eu-central-003.backblazeb2.com   # bare FQDN, NO https://
B2_BUCKET=meenerva-backups
B2_ACCESS_KEY_ID=...
B2_SECRET_ACCESS_KEY=...
BACKUP_CRON=0 2 * * *
BACKUP_RETENTION_DAYS=30
RESTIC_PASSWORD=...
```

`offen/docker-volume-backup`'s S3 client rejects a scheme in `AWS_ENDPOINT`
with `Endpoint url cannot have fully qualified paths` and the offsite push
fails outright - B2's console shows this value *with* `https://`, which is
the trap. `restore.sh` reconstructs the full URL itself for `aws-cli`, which
needs one; nothing else should read this var expecting a scheme.

Same block in `apps-node/.env` (same B2 bucket, same `RESTIC_PASSWORD` - a
different one per node just means one node's snapshots become unreadable with
the other node's copy of the passphrase, for no benefit).

### On-demand backup

```
make backup                  # core-node (default)
make backup NODE=apps        # apps-node
# or directly: ./scripts/backup-now.sh {core|apps}
```

### Restore (full node loss)

```
1. Provision a fresh Ubuntu VPS, set the same rDNS / IP if possible.
2. git clone the repo, ./scripts/bootstrap-node.sh,
   ./scripts/init-core-node.sh (core) or ./scripts/init-apps-node.sh (apps)
3. Restore secrets: recreate that node's .env from the password manager.
4. make restore NODE=core            # or NODE=apps
     - lists snapshots in B2 for that node
     - pulls the chosen snapshot
     - restores its volumes, then loads each *.sql.gz into
       core-postgres (core) or apps-mariadb (apps)
5. On apps-node specifically: run scripts/create-mysql-database.sh <app> for
   each MySQL app BEFORE step 4's DB load if apps-mariadb has no users yet
   (a fresh MariaDB has no app_<name> roles - restore.sh loads data, it does
   not recreate users/grants).
6. make core-up   # or: make apps-up, then make app-up NAME=<app> per app
7. Re-check DNS + mail (mail-tester), re-issue Traefik certs (automatic).
```

Single-database restore (e.g. after a bad migration, not a full node loss):
`./scripts/restore.sh core db n8n` or `./scripts/restore.sh apps db espocrm`.

Test the restore path on a throwaway VPS at least once per quarter. A backup you
have never restored is a hypothesis, not a backup.

### What is intentionally NOT backed up

- Traefik ACME certs beyond a courtesy copy (Let's Encrypt re-issues in seconds).
- Container images (pinned by tag/digest in compose; re-pulled).
- Anything reconstructible from this repo.
