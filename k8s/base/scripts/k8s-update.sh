#!/usr/bin/env bash
# Kubernetes updater: roll the remote-tools workload so nodes pull the latest image.
# Parity with scripts/update.sh + remote-tools-update.timer (image pull half).
#
# Manifest/script updates still come from git (kubectl apply / kustomize). This
# CronJob forces a rolling restart so imagePullPolicy: Always fetches GHCR latest.
#
# Expected environment:
#   NAMESPACE (default: remote-tools)
set -euo pipefail

NAMESPACE="${NAMESPACE:-remote-tools}"
LOG_TAG="${LOG_TAG:-remote-tools-update}"

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

main() {
  ensure_kubectl

  if kubectl -n "${NAMESPACE}" get daemonset remote-tools >/dev/null 2>&1; then
    log "rolling restart DaemonSet/remote-tools"
    kubectl -n "${NAMESPACE}" rollout restart daemonset/remote-tools
    kubectl -n "${NAMESPACE}" rollout status daemonset/remote-tools --timeout=5m
    log "DaemonSet update complete"
    return 0
  fi

  if kubectl -n "${NAMESPACE}" get deployment remote-tools >/dev/null 2>&1; then
    log "rolling restart Deployment/remote-tools"
    kubectl -n "${NAMESPACE}" rollout restart deployment/remote-tools
    kubectl -n "${NAMESPACE}" rollout status deployment/remote-tools --timeout=5m
    log "Deployment update complete"
    return 0
  fi

  log "ERROR: neither DaemonSet nor Deployment remote-tools found in ${NAMESPACE}"
  exit 1
}

main "$@"
