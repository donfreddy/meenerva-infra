#!/usr/bin/env bash
# =============================================================================
# init-apps-node.sh :: apps-node specific setup. Idempotent. Run as root after
# bootstrap-node.sh. Establish the WireGuard mesh separately (setup-wireguard.sh).
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
require_root
require_cmd docker ufw

ENV_FILE="${REPO_ROOT}/apps-node/.env"
MESH_SUBNET="${MESH_SUBNET:-10.10.0.0/24}"

log "Opening apps-node firewall ports"
ufw allow 80/tcp    comment 'traefik http'
ufw allow 443/tcp   comment 'traefik https'
ufw allow 51820/udp comment 'wireguard'
ufw allow from "${MESH_SUBNET}" to any port 22   proto tcp comment 'ssh (mesh)'
ufw allow from "${MESH_SUBNET}" to any port 9001 proto tcp comment 'portainer agent (mesh)'
ufw reload
ok "firewall configured"

log "Creating shared Docker networks"
docker network inspect edge >/dev/null 2>&1 || docker network create --driver bridge edge
docker network inspect apps-internal >/dev/null 2>&1 || \
  docker network create --driver bridge --internal apps-internal
ok "networks ready: edge, apps-internal"

if [ -f "${ENV_FILE}" ]; then
  grep -qE '=(CHANGE_ME|)$' "${ENV_FILE}" && warn "apps-node/.env has unset values" || ok "apps-node/.env populated"
else
  warn "apps-node/.env not found - copy apps-node/.env.example and fill it in"
fi

ok "apps-node init complete. Next: ./scripts/setup-wireguard.sh apps, then 'make apps-up'"
