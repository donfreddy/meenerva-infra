#!/usr/bin/env bash
# =============================================================================
# bootstrap-node.sh :: base preparation for ANY fresh Ubuntu 24.04 node.
# Idempotent. Run once as root before init-<role>-node.sh.
#
#   timezone, apt upgrade, Docker CE + compose plugin, UFW baseline,
#   fail2ban, unattended-upgrades, 4 GB swap, sysctl tuning, WireGuard tools.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
require_root
require_cmd curl

TZ_VALUE="${TZ_VALUE:-UTC}"
SWAP_SIZE="${SWAP_SIZE:-4G}"

log "Setting timezone to ${TZ_VALUE}"
timedatectl set-timezone "${TZ_VALUE}" || warn "could not set timezone"

log "Updating base system"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl gnupg git ufw fail2ban \
  unattended-upgrades apache2-utils wireguard wireguard-tools jq

log "Installing Docker CE"
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  ok "Docker installed: $(docker --version)"
else
  ok "Docker already present: $(docker --version)"
fi

log "Configuring swap (${SWAP_SIZE})"
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l "${SWAP_SIZE}" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10
  grep -q 'vm.swappiness' /etc/sysctl.d/99-meenerva.conf 2>/dev/null || \
    printf 'vm.swappiness=10\nvm.overcommit_memory=1\nnet.core.somaxconn=1024\n' > /etc/sysctl.d/99-meenerva.conf
  sysctl --system >/dev/null
  ok "swap active"
else
  ok "swap already configured"
fi

log "UFW baseline (deny incoming, allow SSH)"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw --force enable
ok "UFW enabled - role script will open service ports"

log "Enabling unattended security upgrades + fail2ban"
systemctl enable --now fail2ban
dpkg-reconfigure -f noninteractive unattended-upgrades || true

ok "Node bootstrap complete. Next: ./scripts/init-core-node.sh or ./scripts/init-apps-node.sh"
