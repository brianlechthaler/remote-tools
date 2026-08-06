#!/usr/bin/env bash
# Pull latest repo config and container image, then apply changes.
# Default branch is main. Override to test a PR branch, e.g.:
#   sudo BRANCH=cursor/fix-exit-node-nat-74ee /opt/remote-tools/scripts/update.sh
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/remote-tools}"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
IMAGE="ghcr.io/brianlechthaler/remote-tools:latest"
BRANCH="${BRANCH:-main}"
LOG_TAG="remote-tools-update"

log() {
  echo "[$(date -Is)] $*"
  logger -t "${LOG_TAG}" "$*" 2>/dev/null || true
}

image_id() {
  docker image inspect -f '{{.Id}}' "${IMAGE}" 2>/dev/null || echo ""
}

# Exit nodes need forwarding, loose rp_filter, and host NAT/firewall path.
ensure_exit_node_networking() {
  if [[ -x "${INSTALL_DIR}/scripts/ensure-exit-node-networking.sh" ]]; then
    LOG_TAG="${LOG_TAG}" "${INSTALL_DIR}/scripts/ensure-exit-node-networking.sh"
  else
    log "ERROR: missing ${INSTALL_DIR}/scripts/ensure-exit-node-networking.sh"
    return 1
  fi
}

reload_systemd_units() {
  install -m 644 "${INSTALL_DIR}/systemd/"*.service /etc/systemd/system/
  install -m 644 "${INSTALL_DIR}/systemd/"*.timer /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable remote-tools.service remote-tools-health.timer remote-tools-update.timer
}

sync_repo() {
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    log "pulling latest remote-tools from ${BRANCH}"
    git -C "${INSTALL_DIR}" fetch origin "${BRANCH}"
    git -C "${INSTALL_DIR}" reset --hard "origin/${BRANCH}"
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

# Re-apply TS_EXTRA_ARGS after recreate; containerboot omits them under TS_AUTH_ONCE.
apply_extra_args() {
  if [[ -x "${INSTALL_DIR}/scripts/apply-ts-extra-args.sh" ]]; then
    CONTAINER=remote-tools-tailscale LOG_TAG="${LOG_TAG}" \
      "${INSTALL_DIR}/scripts/apply-ts-extra-args.sh" || true
  else
    log "WARNING: missing ${INSTALL_DIR}/scripts/apply-ts-extra-args.sh"
  fi
}

# Keep /etc/remote-tools/env in sync with exit-node defaults for existing installs.
migrate_env_exit_node() {
  local env_file="/etc/remote-tools/env"
  if [[ ! -f "${env_file}" ]]; then
    return 0
  fi
  if grep -qE '^TS_EXTRA_ARGS=.*--advertise-exit-node' "${env_file}"; then
    return 0
  fi
  if ! grep -qE '^TS_EXTRA_ARGS=' "${env_file}"; then
    return 0
  fi

  local tmp replaced=0 line current
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == TS_EXTRA_ARGS=* && "${replaced}" -eq 0 ]]; then
      current="${line#TS_EXTRA_ARGS=}"
      if [[ "${current}" == *"--advertise-exit-node"* ]]; then
        printf '%s\n' "${line}"
      else
        printf 'TS_EXTRA_ARGS=%s --advertise-exit-node\n' "${current}"
      fi
      replaced=1
    else
      printf '%s\n' "${line}"
    fi
  done < "${env_file}" > "${tmp}"
  mv "${tmp}" "${env_file}"
  chmod 600 "${env_file}"
  if [[ "${replaced}" -eq 1 ]]; then
    log "migrated ${env_file}: appended --advertise-exit-node to TS_EXTRA_ARGS"
  fi
}

main() {
  if ! docker info >/dev/null 2>&1; then
    log "docker unavailable; skipping update"
    exit 0
  fi

  sync_repo
  reload_systemd_units
  ensure_exit_node_networking
  migrate_env_exit_node
  apply_container_update
  apply_extra_args
  # Re-assert NAT/firewall after container/tailscale0 is up.
  ensure_exit_node_networking || true
  log "update complete"
}

main "$@"
