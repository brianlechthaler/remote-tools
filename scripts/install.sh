#!/usr/bin/env bash
# One-time installer: clone repo, configure systemd, and start Tailscale.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/remote-tools}"
ENV_DIR="/etc/remote-tools"
ENV_FILE="${ENV_DIR}/env"
REPO_URL="${REPO_URL:-https://github.com/brianlechthaler/remote-tools.git}"
BRANCH="${BRANCH:-main}"
LOG_TAG="remote-tools-install"

log() {
  echo "[$(date -Is)] $*"
  logger -t "${LOG_TAG}" "$*" 2>/dev/null || true
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
  fi
}

install_packages() {
  if ! command -v git >/dev/null; then
    apt-get update -qq
    apt-get install -y git
  fi
}

clone_or_update_repo() {
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    log "updating existing install at ${INSTALL_DIR}"
    git -C "${INSTALL_DIR}" fetch origin "${BRANCH}"
    git -C "${INSTALL_DIR}" reset --hard "origin/${BRANCH}"
  else
    log "cloning ${REPO_URL} to ${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}"
    git clone --branch "${BRANCH}" --depth 1 "${REPO_URL}" "${INSTALL_DIR}"
  fi
}

setup_env() {
  mkdir -p "${ENV_DIR}"
  chmod 700 "${ENV_DIR}"

  if [[ ! -f "${ENV_FILE}" ]]; then
    cp "${INSTALL_DIR}/config/env.example" "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
    log "created ${ENV_FILE} — edit TS_AUTHKEY before the service will start"
  else
    chmod 600 "${ENV_FILE}"
  fi

  if ! grep -qE '^TS_HOSTNAME=' "${ENV_FILE}"; then
    echo "TS_HOSTNAME=$(hostname -s)" >> "${ENV_FILE}"
    log "set TS_HOSTNAME=$(hostname -s)"
  fi
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

install_systemd_units() {
  install -m 644 "${INSTALL_DIR}/systemd/"*.service /etc/systemd/system/
  install -m 644 "${INSTALL_DIR}/systemd/"*.timer /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable remote-tools.service
  systemctl enable remote-tools-health.timer
  systemctl enable remote-tools-update.timer
}

make_scripts_executable() {
  chmod +x "${INSTALL_DIR}/scripts/"*.sh
}

# Existing installs may pin TS_EXTRA_ARGS without --advertise-exit-node. Compose
# defaults still win for the container env, but keep the host env file consistent
# so operators reading /etc/remote-tools/env see the exit-node flag.
migrate_env_exit_node() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    return 0
  fi

  if grep -qE '^TS_EXTRA_ARGS=.*--advertise-exit-node' "${ENV_FILE}"; then
    return 0
  fi

  if ! grep -qE '^TS_EXTRA_ARGS=' "${ENV_FILE}"; then
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
  done < "${ENV_FILE}" > "${tmp}"
  mv "${tmp}" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  if [[ "${replaced}" -eq 1 ]]; then
    log "migrated ${ENV_FILE}: appended --advertise-exit-node to TS_EXTRA_ARGS"
  fi
}

start_services() {
  systemctl start remote-tools-health.timer
  systemctl start remote-tools-update.timer

  if grep -qE '^TS_AUTHKEY=(tskey-|file:)' "${ENV_FILE}"; then
    systemctl restart remote-tools.service
    log "remote-tools started"
  else
    log "TS_AUTHKEY not configured; edit ${ENV_FILE} then run: systemctl restart remote-tools"
  fi
}

main() {
  require_root
  install_packages
  clone_or_update_repo
  setup_env
  migrate_env_exit_node
  make_scripts_executable
  ensure_exit_node_networking
  install_systemd_units
  start_services

  cat <<EOF

Install complete.

1. Set your Tailscale auth key:
     sudo nano ${ENV_FILE}

2. Start (or restart) the service:
     sudo systemctl restart remote-tools

3. Check status:
     systemctl status remote-tools
     docker logs remote-tools-tailscale

4. Approve exit node in the Tailscale admin console:
     Machines → … → Edit route settings → Use as exit node

EOF
}

main "$@"
