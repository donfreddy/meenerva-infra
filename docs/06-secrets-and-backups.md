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

### Failure notifications

Both `offsite-backup` containers email `BACKUP_ALERT_EMAIL` (`.env`, default
`alerts@meenerva.io`) if the push to B2 fails - nothing is sent on success
(`NOTIFICATION_LEVEL=error`, the default). Sent through Stalwart itself using
the existing no-reply@ mailbox credentials, no new secret required.

**One-time setup:** create `alerts@meenerva.io` as a real mailbox in the
Stalwart admin UI first (Accounts -> create mailboxes, same flow as
[`05-dns-and-mail.md`](05-dns-and-mail.md)) - sending to a mailbox that
doesn't exist fails silently as far as this container can tell.

**Both `NOTIFICATION_URLS` connect using `STALWART_ADMIN_HOST`
(`mail.meenerva.io`), never `core-stalwart` or the mesh IP directly** - the
TLS certificate's CN/SAN is the public hostname, and STARTTLS verification
fails on a name mismatch no matter how valid the certificate is otherwise.
core-node reaches it via a `core-internal` network alias on the `stalwart`
service (stays inside Docker, no public routing); apps-node reaches it via an
`extra_hosts` entry pointing that same hostname at the mesh IP
(`CORE_SMTP_HOST`) - the URL must reference the *hostname*, not the IP
directly, or DNS lookup (and therefore the `extra_hosts` override) never
happens at all. Neither path touches the public internet or port 587's
external reachability, which is a separate, unresolved problem (see below).

**If this ever needs debugging again**, the actual root cause the one time it
broke (2026-09) was three compounding issues, diagnosed in this order:
1. Stalwart's stored TLS certificate for `mail.meenerva.io` had only the leaf
   in its `Certificate` field, no intermediate - `openssl s_client -starttls
   smtp -connect mail.meenerva.io:25` showed a 1-certificate chain and
   `verify error:num=20`. Concatenating the correct intermediate (fetched
   from the leaf's own AIA URL, e.g. `curl http://<aia-host-from-cert>/`)
   fixed it once pasted into the same field and the container restarted.
2. Separately, Let's Encrypt's certs issued after 2026-05-13 chain by default
   through a brand-new root (`ISRG Root YR`/`YE`) not yet in most trust
   stores - a *complete, correctly-chained* cert can still fail verification
   everywhere for months for this reason alone. Stalwart's own ACME
   automation could not be gotten to request the older, universally-trusted
   chain (a `Domain.certificateManagement = Automatic` switch never actually
   scheduled a renewal task - unresolved, see below); the working fix was a
   one-off `certbot certonly --manual --preferred-challenges dns
   --preferred-chain "ISRG Root X1"` (DNS-01, since Spaceship isn't
   ACME-automatable - see docs/05) run in a throwaway container, with the
   resulting `fullchain.pem`/`privkey.pem` pasted into the same manual
   `TLS certificates` entry. That cert expires **2026-12-14** and will NOT
   auto-renew - it needs the same manual certbot run repeated before then,
   or D-21/the ACME automation below resolved first.
3. Testing this (many repeated `openssl s_client` connections to port 587)
   triggered Stalwart's self-lockout abuse protection again (see the
   `deployment-lessons` memory / `docs/02`) - it blocked BOTH the
   troubleshooting IPs, which looked identical to "port 587 is unreachable"
   from outside. Checked and cleared under Settings -> Security -> Blocked
   IPs. Test this port sparingly, one connection at a time, same lesson as
   before.

**Still unresolved, tracked as follow-ups, not blocking the notifications
above:**
- Stalwart's automatic ACME renewal (`Domain.certificateManagement =
  Automatic`, an `AcmeProvider` with `Preferred chain: ISRG Root X1`) does
  not appear to schedule an `AcmeRenewal` task at all - none showed up in the
  startup task list even at trace-level logging. Until this works, the
  manual certbot renewal above is the only path, and it's expiry-driven, not
  automatic - **calendar-remind for ~2026-12-01**.
- Port 587 refuses every external connection (confirmed from two unrelated
  networks) while port 25 on the same host works fine - ruled out ufw,
  Docker's port mapping, and Stalwart's own IP block list. Likely a
  Contabo-side network restriction tied to this IP's known prior abuse
  history (see `deployment-lessons` memory), which needs their support
  panel/a ticket to confirm - nobody on this project currently has panel
  access. This blocks real external mail *submission* to the domain (a
  sender authenticating on 587 from off-network) but not anything in this
  repo: nothing here depends on port 587 being reachable from the public
  internet.

A failure in the *local* dump step (`postgres-backup-local`, `mariadb-backup`)
would not otherwise stop `offsite-backup` from happily re-uploading a stale
volume without complaint - neither image has its own notification hook. This
is covered too: `postgres-backup` and `mariadb-backup` each carry a
`docker-volume-backup.archive-pre` label (matched via `EXEC_LABEL:
dump-freshness` on their node's `offsite-backup`) that runs a `find -mmin
+1560` check for a dump file older than 26h right before that node's archive
step starts. A non-zero exit there is a fatal error to
`offen/docker-volume-backup`, which fires the exact same B2-failure email -
one notification path for both failure modes, no separate watchdog.

To test either path without waiting for a real failure:
- **Offsite push:** temporarily break `B2_ACCESS_KEY_ID` in `.env`, run
  `make backup`, confirm the email arrives, then revert.
- **Dump freshness:** `docker exec core-postgres-backup touch -d '2 days ago'
  /backups/last/postgres-latest.sql.gz` (or the equivalent
  `latest.<db>.sql.gz` file in `apps-mariadb-backup`'s `/backup`), then
  `make backup` - confirm the email arrives, then let the next real dump
  overwrite the fake timestamp (or delete that one file - `postgres-backup`
  regenerates it, `mariadb-backup` will need a manual /backup.sh run).

Test the restore path on a throwaway VPS at least once per quarter. A backup you
have never restored is a hypothesis, not a backup.

### What is intentionally NOT backed up

- Traefik ACME certs beyond a courtesy copy (Let's Encrypt re-issues in seconds).
- Container images (pinned by tag/digest in compose; re-pulled).
- Anything reconstructible from this repo.
