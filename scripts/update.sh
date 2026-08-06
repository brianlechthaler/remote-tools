#!/usr/bin/env bash
# Pull latest repo config and container image from main, then apply changes.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/remote-tools}"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
IMAGE="ghcr.io/brianlechthaler/remote-tools:latest"
LOG_TAG="remote-tools-update"

log() {
  echo "[$(date -Is)] $*"
  logger -t "${LOG_TAG}" "$*" 2>/dev/null || true
}

image_id() {
  docker image inspect -f '{{.Id}}' "${IMAGE}" 2>/dev/null || echo ""
}

# Exit nodes need host IP forwarding; keep this in sync with start.sh.
ensure_ip_forwarding() {
  local conf="/etc/sysctl.d/99-remote-tools-tailscale.conf"
  cat > "${conf}" <<'EOF'
# Required for Tailscale exit node mode (managed by remote-tools)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
  if ! sysctl -p "${conf}" >/dev/null; then
    log "ERROR: failed to apply IP forwarding sysctl from ${conf}"
    return 1
  fi
  log "IP forwarding enabled for exit node mode"
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
  ensure_ip_forwarding
  migrate_env_exit_node
  apply_container_update
  apply_extra_args
  log "update complete"
}

main "$@"
