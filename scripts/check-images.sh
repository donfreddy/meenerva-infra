#!/usr/bin/env bash
# =============================================================================
# check-images.sh :: DIAGNOSTIC, not a gate. `make core-up` / `apps-up` do NOT
# run this automatically (it hits the same registry, so under a Docker Hub
# rate limit it would just fail before the real pull ever gets a chance, which
# is worse than letting `docker compose up` try and report its own error).
#
# Run this by hand when `core-up`/`apps-up` fails on a pull, to see WHY in one
# shot instead of guessing image by image: a genuinely missing/renamed tag vs
# a rate limit / timeout you just need to wait out or fix with `docker login`.
#
#   make check-images-core     # or check-images-apps / check-images
#   ./scripts/check-images.sh core-node/docker-compose.yml
# =============================================================================
# shellcheck source=SCRIPTDIR/lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker

# Needed on older Docker CLI versions where `docker manifest` is gated behind
# the experimental flag; harmless no-op on newer ones.
export DOCKER_CLI_EXPERIMENTAL=enabled

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
  local image="$1" out rc attempt
  case " ${seen} " in *" ${image} "*) return 0 ;; esac
  seen="${seen} ${image}"
  printf '  %-70s ' "${image}"

  # One retry: registries occasionally hiccup on the first request, and this
  # tells transient network errors apart from a genuinely missing tag.
  # NB: the `if out=$(...)` form is required under `set -e` (inherited from
  # lib/common.sh) - a bare `out=$(...)` assignment aborts the whole script
  # the instant the command fails, before rc is even read.
  rc=1
  for attempt in 1 2; do
    if out="$(timeout 15 docker manifest inspect "${image}" 2>&1)"; then
      rc=0
      break
    else
      rc=$?
    fi
    [ "$attempt" -eq 1 ] && sleep 2
  done

  if [ "$rc" -eq 0 ]; then
    ok "found"
    return 0
  fi

  printf '%s[x] FAILED%s\n' "${c_red}" "${c_reset}"
  if [ "$rc" -eq 124 ]; then
    echo "      -> Timed out after 15s (network issue or registry throttling the"
    echo "         connection). Re-run in a bit; if it keeps timing out, check the"
    echo "         server's outbound network / DNS to the registry."
  elif echo "${out}" | grep -qiE 'toomanyrequests|429|rate limit'; then
    echo "      -> Docker Hub anonymous pull-rate limit hit (100 req/6h per IP)."
    echo "         Fix: 'docker login' with a free Docker Hub account (raises the"
    echo "         limit to 200/6h), or wait and re-run ./scripts/check-images.sh."
  elif echo "${out}" | grep -qiE 'no such manifest|manifest unknown|not found'; then
    echo "      -> Tag does not exist on the registry. Check the project's Docker"
    echo "         Hub / registry page for the current release and fix the pin."
  else
    echo "      -> unexpected error:"
    echo "${out}" | head -3 | sed 's/^/         /'
  fi
  fail=1
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
  die "One or more images failed - see the reason under each one above (rate limit / timeout / missing tag)."
fi
