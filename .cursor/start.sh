#!/usr/bin/env bash
# Cloud Agent start phase for remote-tools.
#
# The base image has no init system, so the Docker daemon must be launched on
# every boot before the repo's build/compose tests can run. Cursor runs this
# script as an already-detached pod process, so dockerd stays in the foreground
# (via exec) and remains attached for the lifetime of the environment.
#
# dockerd creates /var/run/docker.sock owned by root:docker, so members of the
# docker group (install.sh adds the agent user) can run `docker` without sudo.
set -euo pipefail

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  SUDO="sudo"
fi

echo "[start] launching dockerd (fuse-overlayfs, group=docker)"

# Make sure the group the socket is owned by exists before dockerd starts.
${SUDO} groupadd -f docker

# Clear any stale pid file left by a previous boot/snapshot.
${SUDO} rm -f /var/run/docker.pid

exec ${SUDO} dockerd \
  --group docker \
  --host unix:///var/run/docker.sock
