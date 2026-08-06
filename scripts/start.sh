#!/usr/bin/env bash
# Start Tailscale remote access. Invoked by systemd on boot and after failures.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/remote-tools}"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
ENV_FILE="/etc/remote-tools/env"
LOG_TAG="remote-tools"
MAX_RETRIES=5
RETRY_DELAY=10

log() {
  echo "[$(date -Is)] $*"
  logger -t "${LOG_TAG}" "$*" 2>/dev/null || true
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "ERROR: must run as root"
    exit 1
  fi
}

wait_for_docker() {
  local attempt
  for attempt in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    log "waiting for docker (${attempt}/30)..."
    sleep 2
  done
  log "ERROR: docker did not become ready"
  return 1
}

ensure_tun() {
  if [[ ! -c /dev/net/tun ]]; then
    log "creating /dev/net/tun"
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 666 /dev/net/tun 2>/dev/null || true
  fi

  if ! lsmod | grep -q '^tun '; then
    log "loading tun kernel module"
    modprobe tun 2>/dev/null || true
  fi
}

# Exit nodes (and subnet routers) need the host kernel to forward packets.
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

validate_config() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    log "ERROR: missing ${ENV_FILE} (copy config/env.example and set TS_AUTHKEY)"
    exit 1
  fi

  if ! grep -qE '^TS_AUTHKEY=(tskey-|file:)' "${ENV_FILE}"; then
    log "ERROR: ${ENV_FILE} must define TS_AUTHKEY"
    exit 1
  fi

  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    log "ERROR: missing ${COMPOSE_FILE}"
    exit 1
  fi
}

start_stack() {
  local attempt
  for attempt in $(seq 1 "${MAX_RETRIES}"); do
    if docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans; then
      log "tailscale stack started"
      return 0
    fi
    log "compose up failed (${attempt}/${MAX_RETRIES}), retrying in ${RETRY_DELAY}s..."
    sleep "${RETRY_DELAY}"
  done
  log "ERROR: failed to start stack after ${MAX_RETRIES} attempts"
  return 1
}

# containerboot drops TS_EXTRA_ARGS on the TS_AUTH_ONCE `tailscale set` path;
# re-apply so --advertise-exit-node takes effect on already-joined nodes.
apply_extra_args() {
  if [[ -x "${INSTALL_DIR}/scripts/apply-ts-extra-args.sh" ]]; then
    CONTAINER=remote-tools-tailscale LOG_TAG="${LOG_TAG}" \
      "${INSTALL_DIR}/scripts/apply-ts-extra-args.sh" || true
  else
    log "WARNING: missing ${INSTALL_DIR}/scripts/apply-ts-extra-args.sh"
  fi
}

main() {
  require_root
  validate_config
  wait_for_docker
  ensure_tun
  ensure_ip_forwarding
  start_stack
  apply_extra_args
}

main "$@"
