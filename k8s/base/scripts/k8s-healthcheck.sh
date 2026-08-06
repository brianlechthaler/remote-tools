#!/usr/bin/env bash
# Kubernetes health watchdog: verify Tailscale pods and restart if unhealthy.
# Parity with scripts/healthcheck.sh + remote-tools-health.timer.
#
# Expected environment:
#   NAMESPACE              (default: remote-tools)
#   MAX_RESTARTS_PER_HOUR  (default: 6)
#   STAMP_DIR              (default: /var/lib/remote-tools)
set -euo pipefail

NAMESPACE="${NAMESPACE:-remote-tools}"
LOG_TAG="${LOG_TAG:-remote-tools-health}"
MAX_RESTARTS_PER_HOUR="${MAX_RESTARTS_PER_HOUR:-6}"
STAMP_DIR="${STAMP_DIR:-/var/lib/remote-tools}"
RESTART_LOG="${STAMP_DIR}/health-restarts.log"
LABEL_SELECTOR="${LABEL_SELECTOR:-app.kubernetes.io/name=remote-tools,app.kubernetes.io/component=tailscale}"

log() {
  echo "[$(date -Is)] $*"
}

ensure_kubectl() {
  if command -v kubectl >/dev/null; then
    return 0
  fi
  local ver arch
  ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  arch="$(uname -m)"
  case "${arch}" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
  esac
  curl -fsSL "https://dl.k8s.io/release/${ver}/bin/linux/${arch}/kubectl" -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
}

rate_limit_ok() {
  mkdir -p "${STAMP_DIR}"
  touch "${RESTART_LOG}"
  local hour_count
  hour_count="$(awk -v cutoff="$(date -d '1 hour ago' -Is 2>/dev/null || date -v-1H -Is)" \
    '$1 >= cutoff { c++ } END { print c+0 }' "${RESTART_LOG}" 2>/dev/null || echo 0)"
  if [[ "${hour_count}" -ge "${MAX_RESTARTS_PER_HOUR}" ]]; then
    log "restart rate limit reached (${MAX_RESTARTS_PER_HOUR}/hour); skipping"
    return 1
  fi
  return 0
}

record_restart() {
  echo "$(date -Is) health restart" >> "${RESTART_LOG}"
}

restart_pod() {
  local pod="$1"
  if ! rate_limit_ok; then
    return 1
  fi
  log "deleting unhealthy pod ${pod}"
  record_restart
  kubectl -n "${NAMESPACE}" delete pod "${pod}" --wait=false
}

apply_extra_args() {
  local pod="$1"
  kubectl -n "${NAMESPACE}" exec "${pod}" -c tailscale -- \
    /bin/sh -c 'MAX_ATTEMPTS=3 RETRY_DELAY=1 LOG_TAG=remote-tools-health \
      /scripts/apply-ts-extra-args-local.sh' || true
}

tailscale_connected() {
  local pod="$1"
  kubectl -n "${NAMESPACE}" exec "${pod}" -c tailscale -- \
    tailscale status --json 2>/dev/null \
    | grep -q '"BackendState": "Running"' 2>/dev/null
}

container_ready() {
  local pod="$1"
  local ready
  ready="$(kubectl -n "${NAMESPACE}" get pod "${pod}" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="tailscale")].ready}' 2>/dev/null || echo false)"
  [[ "${ready}" == "true" ]]
}

main() {
  ensure_kubectl

  local pods
  pods="$(kubectl -n "${NAMESPACE}" get pods -l "${LABEL_SELECTOR}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"

  if [[ -z "${pods}" ]]; then
    log "no remote-tools pods found in ${NAMESPACE}"
    exit 0
  fi

  local pod phase
  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    phase="$(kubectl -n "${NAMESPACE}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)"
    if [[ "${phase}" != "Running" ]]; then
      log "pod ${pod} phase=${phase}"
      restart_pod "${pod}" || true
      continue
    fi

    if ! container_ready "${pod}"; then
      log "pod ${pod} tailscale container not ready"
      restart_pod "${pod}" || true
      continue
    fi

    # Backend Running requires a real auth key. Without it, still re-apply ExtraArgs
    # and treat missing Running as a soft warning (do not restart loops in CI).
    if tailscale_connected "${pod}"; then
      apply_extra_args "${pod}"
      log "pod ${pod} healthy (BackendState=Running)"
    else
      apply_extra_args "${pod}"
      log "pod ${pod} tailscaled up but BackendState not Running yet (auth/approval pending?)"
    fi
  done <<<"${pods}"
}

main "$@"
