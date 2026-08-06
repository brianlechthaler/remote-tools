#!/usr/bin/env bash
# Static + kind integration tests for the Kubernetes packaging.
# Uses a fake auth key; tailnet join is expected to fail, but tailscaled must start.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-remote-tools-k8s-test}"
IMAGE_LOCAL="${IMAGE_LOCAL:-remote-tools:k8s-test}"
NAMESPACE="remote-tools"
WAIT_SECONDS="${WAIT_SECONDS:-180}"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"
SKIP_KIND="${SKIP_KIND:-0}"
FAILS=0
PASSES=0

pass() {
  PASSES=$((PASSES + 1))
  echo "PASS: $*"
}

fail() {
  FAILS=$((FAILS + 1))
  echo "FAIL: $*" >&2
}

expect_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass "${label}"
  else
    fail "${label} (expected to contain: ${needle})"
  fi
}

cleanup() {
  if [[ "${KEEP_CLUSTER}" == "1" ]]; then
    echo "KEEP_CLUSTER=1 — leaving kind cluster ${CLUSTER_NAME}"
    return 0
  fi
  if [[ "${SKIP_KIND}" != "1" ]] && command -v kind >/dev/null; then
    kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "== syntax / static checks =="

for script in \
  "${ROOT}/scripts/apply-ts-extra-args-local.sh" \
  "${ROOT}/scripts/k8s-install.sh" \
  "${ROOT}/scripts/k8s-healthcheck.sh" \
  "${ROOT}/scripts/k8s-update.sh" \
  "${ROOT}/scripts/test-k8s.sh"
do
  if bash -n "${script}"; then
    pass "bash -n $(basename "${script}")"
  else
    fail "bash -n $(basename "${script}")"
  fi
done

# kustomize ConfigMap files must live under k8s/base/; keep them identical to scripts/.
for name in ensure-exit-node-networking.sh apply-ts-extra-args-local.sh k8s-healthcheck.sh k8s-update.sh; do
  if diff -q "${ROOT}/scripts/${name}" "${ROOT}/k8s/base/scripts/${name}" >/dev/null; then
    pass "k8s/base/scripts/${name} matches scripts/${name}"
  else
    fail "k8s/base/scripts/${name} matches scripts/${name} (run: cp scripts/${name} k8s/base/scripts/)"
  fi
done

if command -v shellcheck >/dev/null; then
  if shellcheck -x \
    "${ROOT}/scripts/apply-ts-extra-args-local.sh" \
    "${ROOT}/scripts/k8s-install.sh" \
    "${ROOT}/scripts/k8s-healthcheck.sh" \
    "${ROOT}/scripts/k8s-update.sh" \
    "${ROOT}/scripts/test-k8s.sh"
  then
    pass "shellcheck k8s scripts"
  else
    fail "shellcheck k8s scripts"
  fi
else
  echo "WARN: shellcheck not installed; skipping"
fi

echo
echo "== manifest feature parity =="

for overlay in daemonset single-node; do
  built="$(mktemp)"
  if kustomize build "${ROOT}/k8s/overlays/${overlay}" > "${built}" 2>/tmp/kustomize-${overlay}.err; then
    pass "kustomize build overlays/${overlay}"
  else
    fail "kustomize build overlays/${overlay}"
    cat /tmp/kustomize-${overlay}.err >&2 || true
    continue
  fi

  body="$(cat "${built}")"
  expect_contains "${body}" "hostNetwork: true" "overlays/${overlay} uses hostNetwork"
  expect_contains "${body}" "NET_ADMIN" "overlays/${overlay} has NET_ADMIN"
  expect_contains "${body}" "/dev/net/tun" "overlays/${overlay} mounts TUN"
  expect_contains "${body}" "--advertise-exit-node" "overlays/${overlay} advertises exit node"
  expect_contains "${body}" "ensure-exit-node-networking.sh" "overlays/${overlay} ships networking script"
  expect_contains "${body}" "apply-ts-extra-args-local.sh" "overlays/${overlay} ships local apply script"
  expect_contains "${body}" "remote-tools-health" "overlays/${overlay} includes health CronJob"
  expect_contains "${body}" "remote-tools-update" "overlays/${overlay} includes update CronJob"
  expect_contains "${body}" "TS_USERSPACE" "overlays/${overlay} configures TS_USERSPACE"
  expect_contains "${body}" "kind: Namespace" "overlays/${overlay} creates namespace"

  if command -v kubeconform >/dev/null; then
    if kubeconform -strict -ignore-missing-schemas "${built}"; then
      pass "kubeconform overlays/${overlay}"
    else
      fail "kubeconform overlays/${overlay}"
    fi
  fi

  if command -v kubectl >/dev/null; then
    if kubectl apply --dry-run=client -f "${built}" >/dev/null; then
      pass "kubectl dry-run overlays/${overlay}"
    else
      fail "kubectl dry-run overlays/${overlay}"
    fi
  fi

  rm -f "${built}"
done

ds_built="$(kustomize build "${ROOT}/k8s/overlays/daemonset")"
expect_contains "${ds_built}" "kind: DaemonSet" "daemonset overlay includes DaemonSet"
if grep -q 'kind: Deployment' <<<"${ds_built}"; then
  fail "daemonset overlay should not include Deployment"
else
  pass "daemonset overlay has no Deployment"
fi

sn_built="$(kustomize build "${ROOT}/k8s/overlays/single-node")"
expect_contains "${sn_built}" "kind: Deployment" "single-node overlay includes Deployment"
expect_contains "${sn_built}" "remote-tools/exit-node" "single-node overlay pins exit-node label"
if grep -q 'kind: DaemonSet' <<<"${sn_built}"; then
  fail "single-node overlay should delete DaemonSet"
else
  pass "single-node overlay has no DaemonSet"
fi

docs="$(cat "${ROOT}/docs/kubernetes.md" "${ROOT}/README.md")"
expect_contains "${docs}" "kubectl" "docs mention kubectl"
expect_contains "${docs}" "DaemonSet" "docs mention DaemonSet"
expect_contains "${docs}" "exit node" "docs mention exit node"
expect_contains "${docs}" "k8s-install.sh" "docs mention k8s-install.sh"
expect_contains "${docs}" "hostNetwork" "docs mention hostNetwork"
expect_contains "${docs}" "CronJob" "docs mention CronJobs"

dockerfile="$(cat "${ROOT}/Dockerfile")"
expect_contains "${dockerfile}" "apply-ts-extra-args-local.sh" \
  "Dockerfile installs in-container apply helper"

echo
echo "== image build =="

build_ok=0
if docker build -t "${IMAGE_LOCAL}" "${ROOT}" >/tmp/remote-tools-k8s-build.log 2>&1; then
  build_ok=1
else
  if grep -qiE 'buildx|BuildKit|overlay|invalid argument|mount' /tmp/remote-tools-k8s-build.log; then
    echo "default build failed; retrying with DOCKER_BUILDKIT=0..."
    if DOCKER_BUILDKIT=0 docker build -t "${IMAGE_LOCAL}" "${ROOT}" \
      >/tmp/remote-tools-k8s-build.log 2>&1; then
      build_ok=1
    fi
  fi
fi

if [[ "${build_ok}" -eq 1 ]]; then
  pass "docker build for k8s image"
  if docker run --rm --entrypoint /bin/sh "${IMAGE_LOCAL}" \
    -c 'command -v tailscale && command -v containerboot && test -x /usr/local/bin/apply-ts-extra-args-local.sh'
  then
    pass "image contains tailscale, containerboot, apply helper"
  else
    fail "image contains tailscale, containerboot, apply helper"
  fi
else
  fail "docker build for k8s image"
  tail -50 /tmp/remote-tools-k8s-build.log >&2 || true
fi

if [[ "${SKIP_KIND}" == "1" ]]; then
  echo
  echo "SKIP_KIND=1 — skipping kind integration"
  echo "Result: ${PASSES} passed, ${FAILS} failed"
  [[ "${FAILS}" -eq 0 ]]
  exit $?
fi

echo
echo "== kind cluster integration =="

if ! command -v kind >/dev/null || ! command -v kubectl >/dev/null; then
  fail "kind and kubectl are required for integration tests"
  echo "Result: ${PASSES} passed, ${FAILS} failed"
  exit 1
fi

kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
cat > /tmp/remote-tools-kind.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF

if kind create cluster --name "${CLUSTER_NAME}" --config /tmp/remote-tools-kind.yaml; then
  pass "kind cluster created"
else
  fail "kind cluster created"
  echo "Result: ${PASSES} passed, ${FAILS} failed"
  exit 1
fi

if [[ "${build_ok}" -eq 1 ]]; then
  if kind load docker-image "${IMAGE_LOCAL}" --name "${CLUSTER_NAME}"; then
    pass "loaded image into kind"
  else
    fail "loaded image into kind"
  fi
fi

# Point overlay image at the local tag and disable Always pull for offline kind.
TMP_OVERLAY="$(mktemp -d)"
cp -a "${ROOT}/k8s/overlays/daemonset/." "${TMP_OVERLAY}/"
# Patch base via a kind-specific overlay copy that also patches the DaemonSet.
cat > "${TMP_OVERLAY}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
images:
  - name: ghcr.io/brianlechthaler/remote-tools
    newName: ${IMAGE_LOCAL%%:*}
    newTag: ${IMAGE_LOCAL##*:}
patches:
  - target:
      group: apps
      version: v1
      kind: DaemonSet
      name: remote-tools
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/imagePullPolicy
        value: Never
EOF
# Fix relative path: TMP_OVERLAY is not under k8s/overlays, so point at absolute base.
cat > "${TMP_OVERLAY}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ${ROOT}/k8s/base
images:
  - name: ghcr.io/brianlechthaler/remote-tools
    newName: ${IMAGE_LOCAL%%:*}
    newTag: ${IMAGE_LOCAL##*:}
patches:
  - target:
      group: apps
      version: v1
      kind: DaemonSet
      name: remote-tools
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/imagePullPolicy
        value: Never
EOF

BUILT="${TMP_OVERLAY}/built.yaml"
if kustomize build "${TMP_OVERLAY}" > "${BUILT}"; then
  pass "built kind test manifests"
else
  fail "built kind test manifests"
fi

# Placeholder auth key — same approach as scripts/test-tailscale-startup.sh
if kubectl apply -f "${BUILT}"; then
  pass "kubectl apply succeeded"
else
  fail "kubectl apply succeeded"
  kubectl get events -A --sort-by=.lastTimestamp | tail -40 >&2 || true
fi

deadline=$((SECONDS + WAIT_SECONDS))
ready=0
while (( SECONDS < deadline )); do
  phase="$(kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/component=tailscale \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo Missing)"
  ts_ready="$(kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/component=tailscale \
    -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="tailscale")].ready}' 2>/dev/null || echo false)"
  if [[ "${phase}" == "Running" && "${ts_ready}" == "true" ]]; then
    ready=1
    break
  fi
  sleep 5
done

if [[ "${ready}" -eq 1 ]]; then
  pass "tailscale pod Running and ready"
else
  fail "tailscale pod Running and ready"
  kubectl -n "${NAMESPACE}" get pods -o wide >&2 || true
  kubectl -n "${NAMESPACE}" describe pods -l app.kubernetes.io/component=tailscale >&2 || true
  kubectl -n "${NAMESPACE}" logs -l app.kubernetes.io/component=tailscale -c exit-node-networking --tail=80 >&2 || true
  kubectl -n "${NAMESPACE}" logs -l app.kubernetes.io/component=tailscale -c tailscale --tail=80 >&2 || true
  kubectl -n "${NAMESPACE}" logs -l app.kubernetes.io/component=tailscale -c watchdog --tail=40 >&2 || true
fi

pod="$(kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/component=tailscale \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -n "${pod}" ]]; then
  if kubectl -n "${NAMESPACE}" exec "${pod}" -c tailscale -- \
    sh -c 'pgrep -x tailscaled >/dev/null 2>&1 || pgrep tailscaled >/dev/null 2>&1'
  then
    pass "tailscaled process running in pod"
  else
    fail "tailscaled process running in pod"
  fi

  envdump="$(kubectl -n "${NAMESPACE}" exec "${pod}" -c tailscale -- \
    sh -c 'printenv' 2>/dev/null || true)"
  expect_contains "${envdump}" "TS_EXTRA_ARGS=--accept-routes --advertise-exit-node" \
    "pod has expected TS_EXTRA_ARGS"
  expect_contains "${envdump}" "TS_USERSPACE=false" "pod disables userspace networking"

  if kubectl -n "${NAMESPACE}" exec "${pod}" -c tailscale -- \
    sh -c 'test -x /scripts/apply-ts-extra-args-local.sh && test -x /scripts/ensure-exit-node-networking.sh'
  then
    pass "scripts mounted into tailscale container"
  else
    fail "scripts mounted into tailscale container"
  fi

  if MAX_ATTEMPTS=2 RETRY_DELAY=1 kubectl -n "${NAMESPACE}" exec "${pod}" -c tailscale -- \
    /scripts/apply-ts-extra-args-local.sh >/tmp/remote-tools-k8s-apply.out 2>&1
  then
    pass "apply-ts-extra-args-local.sh exits 0 in pod"
  else
    fail "apply-ts-extra-args-local.sh exits 0 in pod"
    cat /tmp/remote-tools-k8s-apply.out >&2 || true
  fi

  # Init networking should have configured sysctl on the kind node.
  ipv4="$(docker exec "${CLUSTER_NAME}-control-plane" sysctl -n net.ipv4.ip_forward 2>/dev/null || echo missing)"
  if [[ "${ipv4}" == "1" ]]; then
    pass "init container enabled net.ipv4.ip_forward on node"
  else
    fail "init container enabled net.ipv4.ip_forward on node (got ${ipv4})"
  fi

  if docker exec "${CLUSTER_NAME}-control-plane" \
    iptables -t nat -C POSTROUTING -s 100.64.0.0/10 ! -o tailscale0 -j MASQUERADE 2>/dev/null
  then
    pass "CGNAT MASQUERADE fallback present on node"
  else
    fail "CGNAT MASQUERADE fallback present on node"
  fi
fi

# CronJobs exist and health job can be triggered manually.
if kubectl -n "${NAMESPACE}" get cronjob remote-tools-health remote-tools-update >/dev/null; then
  pass "health and update CronJobs present"
else
  fail "health and update CronJobs present"
fi

if kubectl -n "${NAMESPACE}" create job --from=cronjob/remote-tools-health "health-manual-$$"; then
  pass "manual health CronJob create"
  # Wait briefly for completion (may install kubectl inside the job).
  job_deadline=$((SECONDS + 120))
  while (( SECONDS < job_deadline )); do
    status="$(kubectl -n "${NAMESPACE}" get job "health-manual-$$" \
      -o jsonpath='{.status.succeeded}' 2>/dev/null || echo 0)"
    failed="$(kubectl -n "${NAMESPACE}" get job "health-manual-$$" \
      -o jsonpath='{.status.failed}' 2>/dev/null || echo 0)"
    if [[ "${status}" == "1" ]]; then
      pass "manual health job succeeded"
      break
    fi
    if [[ "${failed}" == "1" ]]; then
      fail "manual health job succeeded"
      kubectl -n "${NAMESPACE}" logs -l job-name="health-manual-$$" --tail=80 >&2 || true
      break
    fi
    sleep 5
  done
  if [[ "${status:-0}" != "1" && "${failed:-0}" != "1" ]]; then
    fail "manual health job succeeded (timeout)"
    kubectl -n "${NAMESPACE}" describe job "health-manual-$$" >&2 || true
    kubectl -n "${NAMESPACE}" logs -l job-name="health-manual-$$" --tail=80 >&2 || true
  fi
else
  fail "manual health CronJob create"
fi

rm -rf "${TMP_OVERLAY}"

echo
echo "Result: ${PASSES} passed, ${FAILS} failed"
if [[ "${FAILS}" -ne 0 ]]; then
  exit 1
fi
