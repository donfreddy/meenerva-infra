# 04 - Networking and the WireGuard mesh

## Public exposure

UFW default: `deny incoming`, `allow outgoing`, `allow routed`.

### core-node

| Port(s) | Proto | Source | Purpose |
|---------|-------|--------|---------|
| 22 | TCP | admin allow-list + `10.10.0.0/24` | SSH |
| 80, 443 | TCP | any | Traefik |
| 25 | TCP | any | SMTP (inbound MX) |
| 465, 587 | TCP | any | SMTPS + submission |
| 143, 993 | TCP | any | IMAP + IMAPS |
| 4190 | TCP | any | ManageSieve |
| 51820 | UDP | apps-node public IP (and data-node later) | WireGuard |
| 5432, 6379 | TCP | `10.10.0.0/24` **only** | Postgres, Redis (published on 0.0.0.0, restricted by this UFW rule - see D-14) |

### apps-node

| Port(s) | Proto | Source | Purpose |
|---------|-------|--------|---------|
| 22 | TCP | admin allow-list + `10.10.0.0/24` | SSH |
| 80, 443 | TCP | any | Traefik |
| 51820 | UDP | core-node public IP | WireGuard |

Application containers never publish host ports. They are reached only through
Traefik on `edge`.

## WireGuard mesh

```
  core-node                                 apps-node
  wg0: 10.10.0.1/24        <== UDP 51820 ==>  wg0: 10.10.0.2/24
  - Postgres :5432 (UFW-restricted)  -------  - relays outbound mail to 10.10.0.1:587
  - Redis    :6379 (UFW-restricted)  -------  - connects apps to 10.10.0.1:5432
  - Stalwart submission :587                  - connects apps to 10.10.0.1:6379
```

- Subnet: `10.10.0.0/24`. Addresses assigned in
  [`03-naming-conventions.md`](03-naming-conventions.md).
- Keys are generated on each node by `setup-wireguard.sh` and **never leave the
  node / never enter git**. Only public keys are exchanged (the script prints the
  block to paste into the peer).
- The interface is `systemd`-managed (`wg-quick@wg0`), `PersistentKeepalive = 25`.
- Config template: `core-node/wireguard/wg0.conf.example`,
  `apps-node/wireguard/wg0.conf.example`.

### Bringing the mesh up

1. On **core-node**: `./scripts/setup-wireguard.sh core`
   - generates keys, writes `/etc/wireguard/wg0.conf`, enables `wg-quick@wg0`
   - prints core's **public key** and endpoint
2. On **apps-node**: `./scripts/setup-wireguard.sh apps`
   - prompts for core's public key + endpoint
   - prints apps's public key
3. Back on **core-node**: `./scripts/setup-wireguard.sh add-peer apps <apps-pubkey> <apps-public-ip>`
4. Verify: `wg show` on both, then `ping 10.10.0.1` from apps-node.

### Adding data-node later

Repeat step 2-3 with `10.10.0.3`. No change to existing peers beyond adding the new
`[Peer]` block. `setup-wireguard.sh add-peer` is idempotent.

## Why not a shared Docker overlay network?

An overlay network needs a manager (Swarm) or an external key-value store and
encrypts at the container layer, not the host layer. WireGuard is simpler, is
independent of the container runtime, protects SSH too, and is the natural
on-ramp to adding a third node or an operator laptop as a peer.

## Service endpoints cheat-sheet

| From | To | Address |
|------|----|---------|
| core container | Postgres | `core-postgres:5432` |
| core container | Redis | `core-redis:6379` |
| core container (n8n, Keycloak) | Stalwart SMTP | `core-stalwart:587` |
| Bulwark Webmail (core) | Stalwart JMAP | `https://mail.meenerva.io` (public, for TLS + OAuth) |
| apps-node container | Postgres | `10.10.0.1:5432` |
| apps-node container | Redis | `10.10.0.1:6379` |
| apps-node container | outbound SMTP | `10.10.0.1:587` (Stalwart relay) |
| any app (browser redirect) | Keycloak | `https://id.meenerva.io` |
