# 07 - Deployment guide

End-to-end for Phase 1: core-node + Stalwart mail, then attach apps-node.

## Prerequisites

- Two Contabo VPS (core = VPS 6, apps = VPS 8), Ubuntu 24.04 LTS, root SSH.
- A registered domain with DNS you control.
- A Backblaze B2 bucket + application key.
- (Recommended) A transactional email provider account for the outbound relay.

## Step 0 - DNS

Publish the records from [`05-dns-and-mail.md`](05-dns-and-mail.md). Set the
**core-node rDNS/PTR** to `mail.meenerva.io` in the Contabo panel now (propagation
takes time).

## Step 1 - Bootstrap core-node

```sh
ssh root@<core-ip>
git clone https://github.com/<org>/meenerva-infra.git /opt/meenerva-infra
cd /opt/meenerva-infra

./scripts/bootstrap-node.sh          # timezone, updates, Docker, UFW base, fail2ban, 4G swap, unattended-upgrades
./scripts/init-core-node.sh          # core UFW rules (mail ports), dirs, acme.json perms, docker networks
```

## Step 2 - Configure secrets

```sh
cp core-node/.env.example core-node/.env
# fill EVERY value; for each secret:  openssl rand -base64 36
nano core-node/.env
```

Minimum to start: `PRIMARY_DOMAIN`, `ACME_EMAIL`, all `*_PASSWORD`, all `*_KEY`,
`B2_*`, `RESTIC_PASSWORD`. The relay vars can be filled after first boot.

## Step 3 - Launch the core stack

```sh
make core-config      # validate
make core-up          # start Traefik, Postgres, Redis, Keycloak, Stalwart, Bulwark Webmail, n8n, backups
make core-ps
```

Watch certificates issue:

```sh
make core-logs        # look for "Certificate obtained" from Traefik
```

## Step 4 - Provision application databases

```sh
./scripts/create-app-database.sh keycloak
./scripts/create-app-database.sh n8n
# ./scripts/create-app-database.sh stalwart   # only if using the SQL directory backend
```

Restart the consumers so they pick up the new DB:

```sh
make core-up          # re-applies; Keycloak / n8n reconnect
```

## Step 5 - First-run configuration

| Service | URL | Action |
|---------|-----|--------|
| Traefik | `https://traefik.meenerva.io` | log in with `TRAEFIK_DASHBOARD_AUTH`; confirm routers are green |
| Keycloak | `https://id.meenerva.io` | log in as admin, create realm `meenerva`, set SMTP (`core-stalwart:587`), enable MFA policy, create the `webmail` client (confidential, redirect `https://webmail.meenerva.io/*`) and put its secret in `core-node/.env` |
| Stalwart | `https://mail.meenerva.io` | add domain, publish DKIM, create `no-reply@` and user mailboxes, set relay |
| Bulwark Webmail | `https://webmail.meenerva.io` | log in (Keycloak SSO or mailbox password), send a test to mail-tester.com |
| n8n | `https://n8n.meenerva.io` | create owner account, set SMTP, import baseline workflows |

## Step 6 - Ongoing deploys (no Portainer - see D-12/D-15)

Every change after the initial bring-up follows the same two commands, on the
node that owns the change:

```sh
cd /opt/meenerva-infra
git pull
make core-up          # or: make apps-up / make app-up NAME=<app>
```

No Portainer anywhere in this stack: it was originally meant to provide both a
GitOps deploy flow and a visual status dashboard, but D-12 dropped the GitOps
role after Phase 1 bring-up showed every real fix went through direct SSH
regardless, and D-15 then removed it entirely once the "just a dashboard"
fallback also went unused, plus it drew a public Safe Browsing flag. Status
and logs come from `docker compose ps` / `docker logs`, as used throughout
this guide.

## Step 7 - Bring up apps-node

```sh
ssh root@<apps-ip>
git clone https://github.com/<org>/meenerva-infra.git /opt/meenerva-infra
cd /opt/meenerva-infra
./scripts/bootstrap-node.sh
./scripts/init-apps-node.sh
```

Establish the mesh (full detail in [`04-networking-wireguard.md`](04-networking-wireguard.md)):

```sh
# on core-node
./scripts/setup-wireguard.sh core
# on apps-node
./scripts/setup-wireguard.sh apps          # paste core pubkey + endpoint when prompted
# on core-node
./scripts/setup-wireguard.sh add-peer apps <apps-pubkey> <apps-public-ip>
# verify
ping -c3 10.10.0.1                          # from apps-node
```

Then the apps-node edge stack:

```sh
cp apps-node/.env.example apps-node/.env && nano apps-node/.env
make apps-config && make apps-up
```

## Step 8 - Deploy the first application

```sh
./scripts/create-app-database.sh nextcloud          # on core-node
make app-new NAME=nextcloud                          # already scaffolded; use for the next one
```

On apps-node:
```sh
cp apps-node/apps/nextcloud/.env.example apps-node/apps/nextcloud/.env   # fill in
make app-up NAME=nextcloud
```
See [`08-adding-an-app.md`](08-adding-an-app.md) for the full walkthrough.

## Rollback

- Bad deploy: `git revert` the offending commit on `main`, `git pull` on the
  node, then `make core-up` / `make apps-up` / `make app-up NAME=<app>` again.
- Bad data migration: restore that one database from the nightly dump
  (`./scripts/restore.sh`, choose *single database*).
