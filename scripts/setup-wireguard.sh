#!/usr/bin/env bash
# =============================================================================
# setup-wireguard.sh :: bring up / update the inter-node mesh (10.10.0.0/24).
# Idempotent. Keys are generated locally and never leave the node.
#
#   ./scripts/setup-wireguard.sh core
#   ./scripts/setup-wireguard.sh apps
#   ./scripts/setup-wireguard.sh data
#   ./scripts/setup-wireguard.sh add-peer <name> <peer-pubkey> <peer-endpoint-ip>
#   ./scripts/setup-wireguard.sh show
# =============================================================================
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_root
require_cmd wg wg-quick

WG_DIR=/etc/wireguard
WG_CONF="${WG_DIR}/wg0.conf"
WG_PORT=51820

declare -A MESH_IP=( [core]=10.10.0.1 [apps]=10.10.0.2 [data]=10.10.0.3 )

ensure_keys() {
  umask 077
  mkdir -p "${WG_DIR}"
  [ -f "${WG_DIR}/privatekey" ] || wg genkey | tee "${WG_DIR}/privatekey" | wg pubkey > "${WG_DIR}/publickey"
}

init_interface() {
  local role="$1" ip="${MESH_IP[$1]:-}"
  [ -n "$ip" ] || die "unknown role: $role (core|apps|data)"
  ensure_keys
  if [ ! -f "${WG_CONF}" ]; then
    cat > "${WG_CONF}" <<EOF
# meenerva mesh - ${role} (${ip})
[Interface]
Address = ${ip}/24
ListenPort = ${WG_PORT}
PrivateKey = $(cat "${WG_DIR}/privatekey")
EOF
    ok "created ${WG_CONF}"
  else
    ok "${WG_CONF} already exists, leaving [Interface] untouched"
  fi
  systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
  systemctl restart wg-quick@wg0
  echo
  ok "This node's PUBLIC KEY (give it to peers):"
  echo "    $(cat "${WG_DIR}/publickey")"
  ok "Endpoint: <this-node-public-ip>:${WG_PORT}"
}

add_peer() {
  local name="$1" pubkey="$2" endpoint_ip="$3"
  [ -n "$name" ] && [ -n "$pubkey" ] && [ -n "$endpoint_ip" ] || die "usage: add-peer <name> <pubkey> <endpoint-ip>"
  local peer_ip="${MESH_IP[$name]:-}"
  [ -n "$peer_ip" ] || die "unknown peer name: $name"
  if grep -q "${pubkey}" "${WG_CONF}" 2>/dev/null; then
    ok "peer ${name} already present"
    return 0
  fi
  cat >> "${WG_CONF}" <<EOF

# --- ${name} ---
[Peer]
PublicKey = ${pubkey}
AllowedIPs = ${peer_ip}/32
Endpoint = ${endpoint_ip}:${WG_PORT}
PersistentKeepalive = 25
EOF
  systemctl restart wg-quick@wg0
  ok "peer ${name} (${peer_ip}) added and interface reloaded"
}

case "${1:-}" in
  core|apps|data) init_interface "$1" ;;
  add-peer)       shift; add_peer "$@" ;;
  show)           wg show ;;
  *) die "usage: $0 {core|apps|data|add-peer <name> <pubkey> <ip>|show}" ;;
esac
