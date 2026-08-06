#!/usr/bin/env bash
# Cloud Agent start phase for remote-tools.
#
# The base image has no init system, so the Docker daemon must be launched on
# every boot before the repo's build/compose tests can run. This script starts
# dockerd (idempotently), waits for the socket to become ready, and makes the
# socket group-accessible so `docker` works without sudo. It then returns.
set -euo pipefail

log() { echo "[start] $*"; }

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  SUDO="sudo"
fi

# Log to a root-owned path. /tmp is world-writable and sticky, where Ubuntu's
# fs.protected_regular blocks writes (even for root) to files owned by others.
DOCKERD_LOG="/var/log/remote-tools-dockerd.log"

if ${SUDO} docker info >/dev/null 2>&1; then
  log "docker daemon already running"
else
  log "starting dockerd (logging to ${DOCKERD_LOG})"
  ${SUDO} rm -f /var/run/docker.pid
  ${SUDO} sh -c "setsid dockerd >>'${DOCKERD_LOG}' 2>&1 &"

  ready=0
  for i in $(seq 1 30); do
    if ${SUDO} docker info >/dev/null 2>&1; then
      ready=1
      log "docker daemon ready after ${i}s"
      break
    fi
    sleep 1
  done

  if [[ "${ready}" -ne 1 ]]; then
    log "ERROR: docker daemon did not become ready"
    tail -n 30 "${DOCKERD_LOG}" >&2 || true
    exit 1
  fi
fi

# Ensure the socket is usable by the docker group (non-sudo docker calls).
if [[ -S /var/run/docker.sock ]]; then
  ${SUDO} groupadd -f docker
  ${SUDO} chown root:docker /var/run/docker.sock
  ${SUDO} chmod 660 /var/run/docker.sock
fi

log "docker is ready:"
${SUDO} docker version --format 'Server {{.Server.Version}} (storage: {{.Server.Os}})' 2>/dev/null || true
