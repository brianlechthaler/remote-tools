#!/usr/bin/env bash
# Cloud Agent install phase for remote-tools.
#
# Installs the toolchain the repository's development and test flow needs:
#   - Docker Engine + compose/buildx plugins: build the image and run the
#     docker-compose based startup and exit-node test suites.
#   - shellcheck / yamllint: static analysis used by scripts/test-exit-node.sh.
#   - iptables + fuse-overlayfs: exit-node NAT tests and nested-container Docker.
#
# git, curl, jq, and python3 already ship in the base image. This script is
# idempotent so it can safely run again on an already-prepared machine. Per-boot
# daemon startup lives in start.sh, not here.
set -euo pipefail

log() { echo "[install] $*"; }

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  SUDO="sudo"
fi

export DEBIAN_FRONTEND=noninteractive

log "installing base tooling (shellcheck, yamllint, iptables, fuse-overlayfs)"
${SUDO} apt-get update -qq
${SUDO} apt-get install -y -qq \
  ca-certificates \
  curl \
  shellcheck \
  yamllint \
  iptables \
  uidmap \
  fuse-overlayfs

if ! command -v docker >/dev/null 2>&1; then
  log "adding Docker apt repository"
  ${SUDO} install -m 0755 -d /etc/apt/keyrings
  ${SUDO} curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  ${SUDO} chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091  # /etc/os-release is sourced only for VERSION_CODENAME
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
    | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null
  ${SUDO} apt-get update -qq

  log "installing Docker Engine, CLI, buildx and compose plugins"
  ${SUDO} apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
else
  log "docker already installed: $(docker --version)"
fi

# Nested Cloud Agent containers lack the kernel overlay driver but expose
# /dev/fuse, so use fuse-overlayfs for Docker's graph storage.
log "configuring Docker to use the fuse-overlayfs storage driver"
${SUDO} mkdir -p /etc/docker
echo '{"storage-driver":"fuse-overlayfs"}' \
  | ${SUDO} tee /etc/docker/daemon.json >/dev/null

# Let the repo's test scripts call `docker` without sudo.
log "granting ${USER:-ubuntu} access to the docker group"
${SUDO} groupadd -f docker
${SUDO} usermod -aG docker "${USER:-ubuntu}"

log "install complete"
docker --version
docker compose version
shellcheck --version | head -2
