#!/usr/bin/env bash
# Shared helpers for meenerva-infra scripts. Source this, do not execute it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_blu=$'\033[34m'

log()  { printf '%s[*]%s %s\n' "$c_blu" "$c_reset" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_reset" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"; }

require_cmd() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing command: $c"; done
}

confirm() {
  local prompt="${1:-Continue?}"
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Load a KEY=VALUE env file into the environment (ignores comments/blanks).
load_env() {
  local file="$1"
  [ -f "$file" ] || die "env file not found: $file (copy the .env.example)"
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
}

# Hex, not base64: several apps in this repo embed the generated password
# directly inside a single connection-string env var (e.g.
# "postgres://user:${PASSWORD}@host/db" - Mattermost, DocuSeal, OpenProject).
# base64's alphabet includes '/', '+', and '=', any of which can appear at
# any position, and an unescaped '/' or '+' inside a URI's userinfo silently
# breaks parsing (confirmed live 2026-09-13: OpenProject's DATABASE_URL
# failed with "URI::InvalidURIError ... does not accept registry part"
# because create-app-database.sh had generated a password ending in '/').
# Hex output is always URL-safe by construction, so this class of bug cannot
# recur - no encoding-awareness needed at every call site.
gen_secret() { openssl rand -hex 32; }
