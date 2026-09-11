#!/usr/bin/env bash
# =============================================================================
# pull-images.sh :: pull every image pinned in a compose file ONE AT A TIME,
# with retries and a pause between each, instead of letting
# `docker compose up` fire off 10+ pulls in parallel.
#
# Use this when `make core-up` / `apps-up` dies mid-pull with a 429 (Docker
# Hub anonymous rate limit) or a TLS/connection reset on auth.docker.io -
# both are made worse by bursting many concurrent pulls at once, and a single
# failed image aborts the whole `docker compose up` batch even though most of
# the others would have succeeded.
#
# Once every image is pulled and cached locally, `make core-up` / `apps-up`
# just creates containers from what is already on disk - no more registry
# calls, so it can no longer fail on a pull.
#
#   ./scripts/pull-images.sh core-node/docker-compose.yml
#   ./scripts/pull-images.sh                                # core + apps + all apps/*
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
require_cmd docker

RETRIES="${PULL_RETRIES:-4}"
DELAY_BETWEEN="${PULL_DELAY:-5}"   # seconds between images, be gentle on the registry

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

images=()
seen=""
for f in "${TARGETS[@]}"; do
  [ -f "$f" ] || { warn "skip (not a file): $f"; continue; }
  while IFS= read -r image; do
    case " ${seen} " in *" ${image} "*) continue ;; esac
    seen="${seen} ${image}"
    images+=("${image}")
  done < <(grep -E '^\s*image:\s*' "$f" | sed -E 's/^\s*image:\s*//; s/\s*#.*$//; s/^"|"$//g')
done

log "${#images[@]} image(s) to pull, one at a time (retry=${RETRIES}, pause=${DELAY_BETWEEN}s)"
echo

failed=()
for image in "${images[@]}"; do
  printf '%s ' "${image}"
  attempt=1
  success=0
  while [ "${attempt}" -le "${RETRIES}" ]; do
    # `if ... ; then` form on purpose - a bare assignment/command under this
    # script's `set -e` (from lib/common.sh) would abort on the first failure.
    if docker pull "${image}" >/tmp/pull-images.$$.log 2>&1; then
      success=1
      break
    fi
    backoff=$(( attempt * 10 ))
    warn "attempt ${attempt}/${RETRIES} failed for ${image}, retrying in ${backoff}s"
    tail -3 /tmp/pull-images.$$.log | sed 's/^/    /'
    sleep "${backoff}"
    attempt=$((attempt + 1))
  done
  rm -f "/tmp/pull-images.$$.log"

  if [ "${success}" -eq 1 ]; then
    ok "pulled"
  else
    printf '%s[x] gave up after %s attempts%s\n' "${c_red}" "${RETRIES}" "${c_reset}"
    failed+=("${image}")
  fi
  sleep "${DELAY_BETWEEN}"
done

echo
if [ "${#failed[@]}" -eq 0 ]; then
  ok "All ${#images[@]} images pulled and cached locally. Run 'make core-up' / 'make apps-up' now - it will not need the network anymore."
else
  warn "Still failing after retries:"
  printf '  - %s\n' "${failed[@]}"
  die "Wait a few minutes (registry-side throttling needs the window to clear) and re-run ./scripts/pull-images.sh - it skips nothing, so already-cached images are instant."
fi
