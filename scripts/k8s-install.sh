#!/usr/bin/env bash
# Install / upgrade remote-tools on a Kubernetes cluster via kustomize.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="${OVERLAY:-daemonset}"
K8S_DIR="${ROOT}/k8s"
SECRET_ENV="${SECRET_ENV:-${K8S_DIR}/secret.env}"
NAMESPACE="${NAMESPACE:-remote-tools}"
IMAGE="${IMAGE:-ghcr.io/brianlechthaler/remote-tools:latest}"

log() {
  echo "[$(date -Is)] $*"
}

usage() {
  cat <<EOF
Usage: $0 [--overlay daemonset|single-node] [--secret-env PATH] [--image REF]

Installs remote-tools into the current kubectl context.

Options:
  --overlay       Kustomize overlay (default: daemonset)
  --secret-env    Path to env file with TS_AUTHKEY (default: k8s/secret.env)
  --image         Container image (default: ${IMAGE})
  -h, --help      Show this help

Prereqs:
  - kubectl configured for the target cluster
  - A reusable Tailscale auth key in --secret-env (created from example if missing)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --overlay) OVERLAY="$2"; shift 2 ;;
    --secret-env) SECRET_ENV="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

OVERLAY_DIR="${K8S_DIR}/overlays/${OVERLAY}"
if [[ ! -d "${OVERLAY_DIR}" ]]; then
  echo "ERROR: overlay not found: ${OVERLAY_DIR}" >&2
  exit 1
fi

if [[ ! -f "${SECRET_ENV}" ]]; then
  cp "${K8S_DIR}/secret.env.example" "${SECRET_ENV}"
  chmod 600 "${SECRET_ENV}"
  log "created ${SECRET_ENV} from example — set TS_AUTHKEY before pods can join the tailnet"
fi

TS_AUTHKEY=""
while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue
  if [[ "${line}" == TS_AUTHKEY=* ]]; then
    TS_AUTHKEY="${line#TS_AUTHKEY=}"
  fi
done < "${SECRET_ENV}"

if [[ ! "${TS_AUTHKEY}" =~ ^(tskey-|file:) ]]; then
  log "WARNING: ${SECRET_ENV} does not look like a valid TS_AUTHKEY yet"
fi

TMP="$(mktemp -d)"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

cp -a "${OVERLAY_DIR}" "${TMP}/overlay"
log "building manifests from overlay=${OVERLAY} image=${IMAGE}"
if command -v kustomize >/dev/null; then
  (cd "${TMP}/overlay" && kustomize edit set image "ghcr.io/brianlechthaler/remote-tools=${IMAGE}")
  kustomize build "${TMP}/overlay" > "${TMP}/built.yaml"
else
  kubectl kustomize "${OVERLAY_DIR}" > "${TMP}/built.yaml"
fi

log "applying to context=$(kubectl config current-context 2>/dev/null || echo unknown)"
kubectl apply -f "${TMP}/built.yaml"

kubectl -n "${NAMESPACE}" create secret generic remote-tools-auth \
  --from-literal="TS_AUTHKEY=${TS_AUTHKEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

log "waiting for workload"
if kubectl -n "${NAMESPACE}" get daemonset remote-tools >/dev/null 2>&1; then
  kubectl -n "${NAMESPACE}" rollout status daemonset/remote-tools --timeout=5m || true
elif kubectl -n "${NAMESPACE}" get deployment remote-tools >/dev/null 2>&1; then
  kubectl -n "${NAMESPACE}" rollout status deployment/remote-tools --timeout=5m || true
fi

cat <<EOF

Kubernetes install applied (overlay=${OVERLAY}).

  kubectl -n ${NAMESPACE} get pods -o wide
  kubectl -n ${NAMESPACE} logs -l app.kubernetes.io/component=tailscale -c tailscale -f

Approve exit node: Machines → … → Edit route settings → Use as exit node
Docs: ${ROOT}/docs/kubernetes.md
EOF
