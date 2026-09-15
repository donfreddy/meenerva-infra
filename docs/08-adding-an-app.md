# 08 - Adding an application

Target: a new open-source app live in ~5 minutes. Example: `metabase`.

## 1. Pick the node

| The app is... | Goes on |
|---------------|---------|
| identity, mail, automation, a shared data store | core-node |
| business / collaboration / user-facing | apps-node |
| SIEM / analytics / BI (heavy indexing) | data-node (when it exists) |

## 2. Scaffold

```sh
make app-new NAME=metabase
# creates apps-node/apps/metabase/{docker-compose.yml,.env.example,README.md} from _template
```

## 3. Create its database (if it uses PostgreSQL)

```sh
./scripts/create-app-database.sh metabase        # run on core-node
# prints the generated password once; put it in the app's .env
```

Apps needing a non-Postgres engine (ClickHouse, OpenSearch, MongoDB) declare that
container inside their own `docker-compose.yml` with its own volume and mem_limit.

## 4. Fill the compose file

Edit `apps-node/apps/metabase/docker-compose.yml` (the template is fully annotated):

- image pinned to a specific version (never `latest` in `main`)
- `container_name: apps-metabase`, compose `name: meenerva-metabase`
- joins `edge` (`external: true`); joins `apps-internal` only if it has private
  sidecars
- DB env: host `10.10.0.1`, db `app_metabase`, user `app_metabase`
- Redis env (if needed): `redis://:PASS@10.10.0.1:6379/<index>`
- SMTP env: host `10.10.0.1`, port `587`, from `no-reply@meenerva.io`
- OIDC env: issuer `https://id.meenerva.io/realms/meenerva`, client `metabase`
- Traefik labels: `Host(\`bi.meenerva.io\`)`, `websecure`, `certresolver=letsencrypt`,
  `loadbalancer.server.port=<port>`, `security-headers@file`
- explicit `mem_limit` and `healthcheck`

## 5. DNS

Add `bi  A  <apps-node-ip>` (or rely on the wildcard if configured).

## 6. Keycloak client

Keycloak -> realm `meenerva` -> Clients -> Create: `metabase`, confidential, redirect
`https://bi.meenerva.io/*`. Copy the secret into the app env.

## 7. Deploy

First, verify the pinned image tag actually exists (a bad tag otherwise fails
mid-pull with no early warning):

```sh
./scripts/check-images.sh apps-node/apps/metabase/docker-compose.yml
```

Then, on apps-node (deployment is `git pull` + `docker compose`, not Portainer -
see decision D-12):

```sh
cd /opt/meenerva-infra
git pull
cp apps-node/apps/metabase/.env.example apps-node/apps/metabase/.env   # fill in
make app-up NAME=metabase
```

Traefik picks up the labels within seconds and issues the certificate.

## 8. Wire its volume(s) into offsite-backup

Each app is its own compose project, so its volumes are NOT visible to the
`offsite-backup` service in `apps-node/docker-compose.yml` by bare name - it
runs in the `meenerva-apps` project. For each stateful volume the app declares
(skip anything purely reconstructible, like an `-html`/app-code volume):

- In `apps-node/docker-compose.yml`'s top-level `volumes:`, add it as
  `external: true` with `name: <app's compose project name>_<volume-name>`
  (the project name is the app's `name:` field, or its directory name if that
  field is absent - always set `name:` per step 4 so this stays predictable).
- Mount it read-only under `/backup/<volume-name>` in the `offsite-backup`
  service.
- If the app's data lives in `apps-mariadb` (MySQL/MariaDB) rather than its
  own volume, there is currently no dump mechanism for that database (unlike
  core-postgres's `postgres-backup-local`) - flag this rather than skipping
  it silently.

Verify the external volume actually exists after first deploy:
`docker volume ls | grep <app>` on apps-node.

## 9. Register it

- Add the row to the subdomain table in [`03-naming-conventions.md`](03-naming-conventions.md).
- Add the Redis index (if used) to the table in `core-node/.env.example`.
- Note it in [`09-roadmap.md`](09-roadmap.md) as done.
- Commit: `feat/app-metabase`.

## Checklist (copy into the PR)

```
- [ ] node chosen and correct
- [ ] database created via create-app-database.sh (or dedicated engine justified)
- [ ] image version pinned and verified with scripts/check-images.sh
- [ ] container_name / compose name follow conventions
- [ ] mem_limit + healthcheck set
- [ ] joins edge only (+ apps-internal if sidecars)
- [ ] Traefik labels + security-headers middleware
- [ ] DB / Redis / SMTP / OIDC wired to core-node endpoints
- [ ] Keycloak client created
- [ ] DNS record added
- [ ] stateful volume(s) wired into offsite-backup (external volume + mount)
- [ ] docs updated (naming, roadmap)
- [ ] deployed with `make app-up NAME=<app>`, cert issued
```
