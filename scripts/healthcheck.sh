#!/usr/bin/env bash
# Watchdog: verify Tailscale is connected and restart if unhealthy.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/remote-tools}"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
CONTAINER="remote-tools-tailscale"
LOG_TAG="remote-tools-health"
MAX_RESTARTS_PER_HOUR=6
STAMP_DIR="/var/lib/remote-tools"
RESTART_LOG="${STAMP_DIR}/health-restarts.log"

log() {
  echo "[$(date -Is)] $*"
  logger -t "${LOG_TAG}" "$*" 2>/dev/null || true
}

rate_limit_ok() {
  mkdir -p "${STAMP_DIR}"
  touch "${RESTART_LOG}"
  local hour_count
  hour_count="$(awk -v cutoff="$(date -d '1 hour ago' -Is 2>/dev/null || date -v-1H -Is)" '$1 >= cutoff { c++ } END { print c+0 }' "${RESTART_LOG}" 2>/dev/null || echo 0)"
  if [[ "${hour_count}" -ge "${MAX_RESTARTS_PER_HOUR}" ]]; then
    log "restart rate limit reached (${MAX_RESTARTS_PER_HOUR}/hour); skipping"
    return 1
  fi
  return 0
}

record_restart() {
  echo "$(date -Is) health restart" >> "${RESTART_LOG}"
}

container_running() {
  docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null | grep -qx true
}

container_healthy() {
  local status
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${CONTAINER}" 2>/dev/null || echo missing)"
  [[ "${status}" == "healthy" || "${status}" == "none" ]]
}

tailscale_connected() {
  docker exec "${CONTAINER}" tailscale status --json 2>/dev/null \
    | grep -q '"BackendState": "Running"' 2>/dev/null
}

restart_stack() {
  if ! rate_limit_ok; then
    return 1
  fi
  log "restarting tailscale stack"
  record_restart
  docker compose -f "${COMPOSE_FILE}" up -d --force-recreate --remove-orphans
}

main() {
  if ! docker info >/dev/null 2>&1; then
    log "docker unavailable"
    exit 0
  fi

  if ! container_running; then
    log "container not running"
    restart_stack || exit 1
    exit 0
  fi

  if ! container_healthy; then
    log "container health check failing"
    restart_stack || exit 1
    exit 0
  fi

  if ! tailscale_connected; then
    log "tailscale backend not running"
    restart_stack || exit 1
    exit 0
  fi

  log "healthy"
}

main "$@"
