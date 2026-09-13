#!/usr/bin/env bash
# =============================================================================
# init-core-node.sh :: core-node specific setup. Idempotent. Run as root after
# bootstrap-node.sh.
#   - opens the public + mesh firewall ports for core-node
#   - creates the shared Docker networks
#   - prepares Traefik ACME storage
#   - sanity-checks core-node/.env
# =============================================================================
# shellcheck source=SCRIPTDIR/lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_root
require_cmd docker ufw

ENV_FILE="${REPO_ROOT}/core-node/.env"
MESH_SUBNET="${MESH_SUBNET:-10.10.0.0/24}"

log "Opening core-node firewall ports"
ufw allow 80/tcp        comment 'traefik http'
ufw allow 443/tcp       comment 'traefik https'
ufw allow 25/tcp        comment 'smtp inbound'
ufw allow 465/tcp       comment 'smtps'
ufw allow 587/tcp       comment 'submission'
ufw allow 143/tcp       comment 'imap'
ufw allow 993/tcp       comment 'imaps'
ufw allow 4190/tcp      comment 'managesieve'
ufw allow 51820/udp     comment 'wireguard'
# Private services: mesh only
ufw allow from "${MESH_SUBNET}" to any port 5432 proto tcp comment 'postgres (mesh)'
ufw allow from "${MESH_SUBNET}" to any port 6379 proto tcp comment 'redis (mesh)'
ufw allow from "${MESH_SUBNET}" to any port 22   proto tcp comment 'ssh (mesh)'
# Docker containers on this node reaching a peer over the mesh go through the
# FORWARD chain, not INPUT/OUTPUT - UFW's default `deny (routed)` blocks that
# regardless of the `allow` rules above, which only cover traffic to/from
# this host itself. Confirmed live on apps-node reaching core-node's
# postgres/redis/stalwart; add the same rule here for symmetry (e.g. a
# future n8n workflow calling an apps-node or data-node service directly).
ufw route allow out on wg0 to "${MESH_SUBNET}" comment 'containers to mesh peers'
ufw reload
ok "firewall configured"

log "Creating shared Docker networks"
docker network inspect edge >/dev/null 2>&1 || docker network create --driver bridge edge
docker network inspect core-internal >/dev/null 2>&1 || \
  docker network create --driver bridge --internal core-internal
ok "networks ready: edge, core-internal"

log "Preparing Traefik ACME storage"
docker volume inspect meenerva-core_traefik-acme >/dev/null 2>&1 || true
# The compose file uses a named volume; nothing to chmod on the host.

if [ -f "${ENV_FILE}" ]; then
  log "Checking core-node/.env for unset secrets"
  if grep -qE '=(CHANGE_ME|)$' "${ENV_FILE}"; then
    warn "core-node/.env still contains CHANGE_ME / empty values:"
    grep -nE '=(CHANGE_ME|)$' "${ENV_FILE}" | sed 's/^/    /' || true
  else
    ok "core-node/.env looks populated"
  fi
else
  warn "core-node/.env not found - copy core-node/.env.example and fill it in"
fi

ok "core-node init complete. Next: fill core-node/.env, then 'make core-up'"
