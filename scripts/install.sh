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
  make_scripts_executable
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

EOF
}

main "$@"
