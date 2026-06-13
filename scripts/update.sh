#!/usr/bin/env bash
# Pull latest repo config and container image from main, then apply changes.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/remote-tools}"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
IMAGE="ghcr.io/brianlechthaler/remote-tools:latest"
LOG_TAG="remote-tools-update"
REPO_URL="https://github.com/brianlechthaler/remote-tools.git"

log() {
  echo "[$(date -Is)] $*"
  logger -t "${LOG_TAG}" "$*" 2>/dev/null || true
}

image_id() {
  docker image inspect -f '{{.Id}}' "${IMAGE}" 2>/dev/null || echo ""
}

reload_systemd_units() {
  install -m 644 "${INSTALL_DIR}/systemd/"*.service /etc/systemd/system/
  install -m 644 "${INSTALL_DIR}/systemd/"*.timer /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable remote-tools.service remote-tools-health.timer remote-tools-update.timer
}

sync_repo() {
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    log "pulling latest remote-tools from main"
    git -C "${INSTALL_DIR}" fetch origin main
    git -C "${INSTALL_DIR}" reset --hard origin/main
  else
    log "ERROR: ${INSTALL_DIR} is not a git checkout"
    exit 1
  fi
}

apply_container_update() {
  local before after
  before="$(image_id)"
  log "pulling ${IMAGE}"
  docker compose -f "${COMPOSE_FILE}" pull
  after="$(image_id)"

  if [[ "${before}" != "${after}" || "${before}" == "" ]]; then
    log "image updated; recreating container"
    docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans
  else
    log "image unchanged"
    docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans
  fi
}

main() {
  if ! docker info >/dev/null 2>&1; then
    log "docker unavailable; skipping update"
    exit 0
  fi

  sync_repo
  reload_systemd_units
  apply_container_update
  log "update complete"
}

main "$@"
