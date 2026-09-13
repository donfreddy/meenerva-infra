#!/usr/bin/env bash
# =============================================================================
# build.sh :: build the custom Frappe image (frappe + erpnext + hrms) for the
# meenerva-infra Frappe stack. Run on apps-node, once per version bump.
#
# The official frappe/erpnext image on Docker Hub only bundles frappe+erpnext,
# not hrms - a custom image via frappe_docker's own Containerfile is the
# supported way to add hrms (runtime `bench get-app` in a production
# container is known-broken upstream, see apps-node/apps/frappe/README.md).
#
# Requires Docker Engine v23+ with buildx (BuildKit) - the build uses a
# `--secret` mount for apps.json, which needs BuildKit specifically. Check
# with `docker version` if the build fails with a secret-mount error.
# =============================================================================
set -euo pipefail

FRAPPE_DOCKER_TAG="v3.2.2"          # pin, don't build against a moving `main`
FRAPPE_BRANCH="version-16"          # must match apps.json's branch for erpnext/hrms
IMAGE_TAG="${IMAGE_TAG:-meenerva/frappe-erpnext-hrms:16}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

echo "[*] Cloning frappe_docker ${FRAPPE_DOCKER_TAG} into ${BUILD_DIR}"
git clone --branch "${FRAPPE_DOCKER_TAG}" --depth 1 https://github.com/frappe/frappe_docker "${BUILD_DIR}"

cp "${SCRIPT_DIR}/apps.json" "${BUILD_DIR}/apps.json"

echo "[*] Building ${IMAGE_TAG} (this takes 10-20+ minutes, downloads erpnext+hrms source and builds assets)"
cd "${BUILD_DIR}"
docker build \
  --no-cache \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH="${FRAPPE_BRANCH}" \
  --secret=id=apps_json,src=apps.json \
  --tag="${IMAGE_TAG}" \
  --file=images/layered/Containerfile .

echo "[+] Built ${IMAGE_TAG}"
echo "    Next: make app-up NAME=frappe (docker-compose.yml already references this tag)"
