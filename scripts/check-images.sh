#!/usr/bin/env bash
# =============================================================================
# check-images.sh :: verify every image tag pinned in the compose files
# actually resolves on its registry BEFORE you run `make core-up` / `apps-up`.
#
# This stack pins exact versions (see docs/03-naming-conventions.md); fast-moving
# projects occasionally remove or never publish a given patch tag, which makes
# `docker compose up` fail mid-pull with "not found". Run this first, on the
# server, to catch that in one shot instead of one image at a time.
#
#   ./scripts/check-images.sh                # checks core-node + apps-node + apps/*
#   ./scripts/check-images.sh core-node       # checks a single compose file/dir
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
require_cmd docker

TARGETS=()
if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=("${REPO_ROOT}/core-node/docker-compose.yml" "${REPO_ROOT}/apps-node/docker-compose.yml")
  for d in "${REPO_ROOT}"/apps-node/apps/*/; do
    [ "$(basename "$d")" = "_template" ] && continue
    [ -f "${d}docker-compose.yml" ] && TARGETS+=("${d}docker-compose.yml")
  done
fi

fail=0
seen=""

check_one() {
  local image="$1"
  case " ${seen} " in *" ${image} "*) return 0 ;; esac
  seen="${seen} ${image}"
  printf '  %-70s ' "${image}"
  if docker manifest inspect "${image}" >/dev/null 2>&1; then
    ok "found"
  else
    printf '%s[x] NOT FOUND%s\n' "${c_red}" "${c_reset}"
    fail=1
  fi
}

for f in "${TARGETS[@]}"; do
  [ -f "$f" ] || { warn "skip (not a file): $f"; continue; }
  log "Checking images in ${f#"${REPO_ROOT}"/}"
  while IFS= read -r image; do
    check_one "$image"
  done < <(grep -E '^\s*image:\s*' "$f" | sed -E 's/^\s*image:\s*//; s/\s*#.*$//; s/^"|"$//g')
done

echo
if [ "$fail" -eq 0 ]; then
  ok "All pinned image tags resolve."
else
  die "One or more image tags do not exist on their registry. Fix the tag in the compose file (check the project's Docker Hub / registry page for the current release), then re-run."
fi
