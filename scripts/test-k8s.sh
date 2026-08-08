#!/usr/bin/env bash
# Static + cluster integration tests for the Kubernetes packaging.
# Prefer kind when available; fall back to kwok (API) + Docker runtime
# simulation when nested Docker cannot boot kind/k3d (common in DinD).
#
# Uses a fake auth key; tailnet join is expected to fail, but tailscaled must start.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-remote-tools-k8s-test}"
IMAGE_LOCAL="${IMAGE_LOCAL:-remote-tools:k8s-test}"
NAMESPACE="remote-tools"
WAIT_SECONDS="${WAIT_SECONDS:-180}"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"
SKIP_CLUSTER="${SKIP_CLUSTER:-0}"
# auto | kind | kwok
CLUSTER_PROVIDER="${CLUSTER_PROVIDER:-auto}"
FAILS=0
PASSES=0
PROVIDER_USED=""

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
    echo "KEEP_CLUSTER=1 — leaving cluster (${PROVIDER_USED:-none})"
    return 0
  fi
  case "${PROVIDER_USED}" in
    kind)
      kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
      ;;
    kwok)
      kwokctl delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
      ;;
  esac
  docker rm -f remote-tools-k8s-rt-tailscale remote-tools-k8s-rt-init >/dev/null 2>&1 || true
  docker network rm remote-tools-k8s-rt-net >/dev/null 2>&1 || true
  rm -rf /tmp/remote-tools-k8s-rt-state /tmp/remote-tools-k8s-rt-sysctl 2>/dev/null || true
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
    # Client dry-run still needs discovery against an apiserver on some kubectl
    # builds; skip when none is reachable (kubeconform already validated schemas).
    if kubectl cluster-info >/dev/null 2>&1; then
      if kubectl apply --dry-run=client --validate=false -f "${built}" >/dev/null; then
        pass "kubectl dry-run overlays/${overlay}"
      else
        fail "kubectl dry-run overlays/${overlay}"
      fi
    else
      echo "WARN: no apiserver for kubectl dry-run overlays/${overlay}; relying on kubeconform"
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

if [[ "${SKIP_CLUSTER}" == "1" ]]; then
  echo
  echo "SKIP_CLUSTER=1 — skipping cluster + runtime integration"
  echo "Result: ${PASSES} passed, ${FAILS} failed"
  [[ "${FAILS}" -eq 0 ]]
  exit $?
fi

try_kind() {
  command -v kind >/dev/null || return 1
  kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  cat > /tmp/remote-tools-kind.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF
  if kind create cluster --name "${CLUSTER_NAME}" --config /tmp/remote-tools-kind.yaml; then
    PROVIDER_USED=kind
    return 0
  fi
  kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  return 1
}

try_kwok() {
  command -v kwokctl >/dev/null || return 1
  kwokctl delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  if kwokctl create cluster --name "${CLUSTER_NAME}"; then
    PROVIDER_USED=kwok
    kwokctl scale node --name "${CLUSTER_NAME}" --replicas 1 >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

echo
echo "== cluster bootstrap (provider=${CLUSTER_PROVIDER}) =="

case "${CLUSTER_PROVIDER}" in
  kind)
    if try_kind; then
      pass "kind cluster created"
    else
      fail "kind cluster created"
    fi
    ;;
  kwok)
    if try_kwok; then
      pass "kwok cluster created"
    else
      fail "kwok cluster created"
    fi
    ;;
  docker)
    PROVIDER_USED=docker
    pass "using Docker runtime simulation (CLUSTER_PROVIDER=docker)"
    ;;
  auto)
    if try_kind; then
      pass "kind cluster created"
    elif [[ "${GITHUB_ACTIONS:-}" == "true" || "${CI:-}" == "true" ]]; then
      # GitHub-hosted runners can run kind; fail closed there instead of
      # silently degrading coverage.
      fail "kind cluster created (required in CI)"
    else
      echo "kind unavailable here; using Docker runtime simulation of the DaemonSet pod"
      PROVIDER_USED=docker
      pass "Docker runtime simulation selected (kind fallback)"
    fi
    ;;
  *)
    fail "unknown CLUSTER_PROVIDER=${CLUSTER_PROVIDER}"
    ;;
esac

run_docker_runtime_simulation() {
  echo
  echo "== Docker runtime simulation of DaemonSet pod =="

  mkdir -p /tmp/remote-tools-k8s-rt-state /tmp/remote-tools-k8s-rt-sysctl /tmp/remote-tools-k8s-rt-scripts
  cp "${ROOT}/k8s/base/scripts/"*.sh /tmp/remote-tools-k8s-rt-scripts/
  chmod +x /tmp/remote-tools-k8s-rt-scripts/*.sh

  # initContainer equivalent: privileged networking prep against this host/netns.
  if docker run --rm --privileged --network host \
    -v /tmp/remote-tools-k8s-rt-scripts:/scripts:ro \
    -v /tmp/remote-tools-k8s-rt-sysctl:/etc/sysctl.d \
    alpine:3.21 \
    /bin/sh -c 'apk add --no-cache bash iptables ip6tables iproute2 procps >/dev/null \
      && LOG_TAG=remote-tools-k8s-test bash /scripts/ensure-exit-node-networking.sh'
  then
    pass "init networking container exits 0"
  else
    fail "init networking container exits 0"
  fi

  if [[ -f /tmp/remote-tools-k8s-rt-sysctl/99-remote-tools-tailscale.conf ]] \
    && grep -q 'net.ipv4.ip_forward = 1' /tmp/remote-tools-k8s-rt-sysctl/99-remote-tools-tailscale.conf
  then
    pass "networking script wrote persistent sysctl conf"
  else
    fail "networking script wrote persistent sysctl conf"
  fi

  if docker run -d --name remote-tools-k8s-rt-tailscale \
    --network host \
    --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_MODULE \
    --device /dev/net/tun:/dev/net/tun \
    -v /tmp/remote-tools-k8s-rt-state:/var/lib/tailscale \
    -v /tmp/remote-tools-k8s-rt-scripts:/scripts:ro \
    -e TS_AUTHKEY=tskey-auth-TESTONLY \
    -e TS_HOSTNAME=k8s-runtime-test \
    -e TS_EXTRA_ARGS='--accept-routes --advertise-exit-node' \
    -e TS_USERSPACE=false \
    -e TS_AUTH_ONCE=true \
    -e TS_STATE_DIR=/var/lib/tailscale \
    -e TS_ENABLE_HEALTH_CHECK=true \
    -e TS_LOCAL_ADDR_PORT=127.0.0.1:9002 \
    "${IMAGE_LOCAL}" >/tmp/remote-tools-k8s-rt-cid
  then
    pass "tailscale container started with DaemonSet-equivalent config"
  else
    fail "tailscale container started with DaemonSet-equivalent config"
    return 0
  fi

  deadline=$((SECONDS + WAIT_SECONDS))
  ready=0
  while (( SECONDS < deadline )); do
    if docker exec remote-tools-k8s-rt-tailscale \
      sh -c 'pgrep -x tailscaled >/dev/null 2>&1 || pgrep tailscaled >/dev/null 2>&1'
    then
      ready=1
      break
    fi
    # Bail early if the container exited.
    if [[ "$(docker inspect -f '{{.State.Status}}' remote-tools-k8s-rt-tailscale 2>/dev/null || echo missing)" == "exited" ]]; then
      break
    fi
    sleep 2
  done

  if [[ "${ready}" -eq 1 ]]; then
    pass "tailscaled running in simulated pod"
  else
    fail "tailscaled running in simulated pod"
    docker logs remote-tools-k8s-rt-tailscale >&2 || true
  fi

  envdump="$(docker exec remote-tools-k8s-rt-tailscale printenv 2>/dev/null || true)"
  expect_contains "${envdump}" "TS_EXTRA_ARGS=--accept-routes --advertise-exit-node" \
    "simulated pod has expected TS_EXTRA_ARGS"
  expect_contains "${envdump}" "TS_USERSPACE=false" "simulated pod disables userspace networking"

  if docker exec remote-tools-k8s-rt-tailscale \
    sh -c 'test -x /scripts/apply-ts-extra-args-local.sh && test -x /scripts/ensure-exit-node-networking.sh'
  then
    pass "scripts mounted into simulated pod"
  else
    fail "scripts mounted into simulated pod"
  fi

  if docker exec -e MAX_ATTEMPTS=2 -e RETRY_DELAY=1 remote-tools-k8s-rt-tailscale \
    /scripts/apply-ts-extra-args-local.sh >/tmp/remote-tools-k8s-apply.out 2>&1
  then
    pass "apply-ts-extra-args-local.sh exits 0 in simulated pod"
  else
    fail "apply-ts-extra-args-local.sh exits 0 in simulated pod"
    cat /tmp/remote-tools-k8s-apply.out >&2 || true
  fi

  if command -v iptables >/dev/null; then
    if iptables -t nat -C POSTROUTING -s 100.64.0.0/10 ! -o tailscale0 -j MASQUERADE 2>/dev/null \
      || sudo iptables -t nat -C POSTROUTING -s 100.64.0.0/10 ! -o tailscale0 -j MASQUERADE 2>/dev/null
    then
      pass "CGNAT MASQUERADE fallback present after init networking"
    else
      fail "CGNAT MASQUERADE fallback present after init networking"
    fi
  fi
}

# Build a temporary overlay under k8s/overlays/ so resources can use a
# relative ../../base path (kustomize rejects absolute resource roots).
make_ci_overlay() {
  local with_pull_never="${1:-0}"
  local overlay_dir
  overlay_dir="${ROOT}/k8s/overlays/.ci-test-$$"
  rm -rf "${overlay_dir}"
  mkdir -p "${overlay_dir}"

  cat > "${overlay_dir}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
images:
  - name: ghcr.io/brianlechthaler/remote-tools
    newName: ${IMAGE_LOCAL%%:*}
    newTag: ${IMAGE_LOCAL##*:}
EOF

  if [[ "${with_pull_never}" == "1" ]]; then
    cat >> "${overlay_dir}/kustomization.yaml" <<'EOF'
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
  fi

  printf '%s' "${overlay_dir}"
}

run_kwok_api_checks() {
  echo
  echo "== kwok API integration =="

  TMP_OVERLAY="$(make_ci_overlay 0)"
  BUILT="${TMP_OVERLAY}/built.yaml"
  if ! kustomize build "${TMP_OVERLAY}" > "${BUILT}"; then
    fail "built kwok test manifests"
    rm -rf "${TMP_OVERLAY}"
    return 0
  fi

  if kubectl apply -f "${BUILT}"; then
    pass "kubectl apply to kwok succeeded"
  else
    fail "kubectl apply to kwok succeeded"
    rm -rf "${TMP_OVERLAY}"
    return 0
  fi

  if kubectl -n "${NAMESPACE}" get daemonset remote-tools >/dev/null; then
    pass "DaemonSet remote-tools exists"
  else
    fail "DaemonSet remote-tools exists"
  fi

  if kubectl -n "${NAMESPACE}" get cronjob remote-tools-health remote-tools-update >/dev/null; then
    pass "health and update CronJobs present"
  else
    fail "health and update CronJobs present"
  fi

  if kubectl -n "${NAMESPACE}" get configmap remote-tools-config remote-tools-scripts >/dev/null; then
    pass "config and scripts ConfigMaps present"
  else
    fail "config and scripts ConfigMaps present"
  fi

  if kubectl -n "${NAMESPACE}" get secret remote-tools-auth >/dev/null; then
    pass "auth Secret present"
  else
    fail "auth Secret present"
  fi

  # kwok will create a fake pod for the DaemonSet once a node exists.
  deadline=$((SECONDS + 60))
  pod=""
  while (( SECONDS < deadline )); do
    pod="$(kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/component=tailscale \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "${pod}" ]] && break
    sleep 2
  done

  if [[ -n "${pod}" ]]; then
    pass "DaemonSet scheduled a pod on kwok node (${pod})"
    # Inspect pod spec parity even though containers are not really executed.
    spec="$(kubectl -n "${NAMESPACE}" get pod "${pod}" -o yaml)"
    expect_contains "${spec}" "hostNetwork: true" "kwok pod has hostNetwork"
    expect_contains "${spec}" "NET_ADMIN" "kwok pod has NET_ADMIN"
    expect_contains "${spec}" "exit-node-networking" "kwok pod has networking initContainer"
    expect_contains "${spec}" "name: watchdog" "kwok pod has watchdog sidecar"
    expect_contains "${spec}" "apply-ts-extra-args-local.sh" "kwok pod references local apply script"
  else
    fail "DaemonSet scheduled a pod on kwok node"
  fi

  # Health CronJob object can still be materialized as a Job.
  if kubectl -n "${NAMESPACE}" create job --from=cronjob/remote-tools-health "health-manual-$$"; then
    pass "manual health CronJob create on kwok"
  else
    fail "manual health CronJob create on kwok"
  fi

  rm -rf "${TMP_OVERLAY}"
}

run_kind_integration() {
  echo
  echo "== kind cluster integration =="

  if [[ "${build_ok}" -eq 1 ]]; then
    if kind load docker-image "${IMAGE_LOCAL}" --name "${CLUSTER_NAME}"; then
      pass "loaded image into kind"
    else
      fail "loaded image into kind"
    fi
  fi

  TMP_OVERLAY="$(make_ci_overlay 1)"
  BUILT="${TMP_OVERLAY}/built.yaml"
  if kustomize build "${TMP_OVERLAY}" > "${BUILT}"; then
    pass "built kind test manifests"
  else
    fail "built kind test manifests"
    rm -rf "${TMP_OVERLAY}"
    return 0
  fi

  if kubectl apply -f "${BUILT}"; then
    pass "kubectl apply succeeded"
  else
    fail "kubectl apply succeeded"
    kubectl get events -A --sort-by=.lastTimestamp | tail -40 >&2 || true
    rm -rf "${TMP_OVERLAY}"
    return 0
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

    envdump="$(kubectl -n "${NAMESPACE}" exec "${pod}" -c tailscale -- printenv 2>/dev/null || true)"
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

    if kubectl -n "${NAMESPACE}" exec "${pod}" -c tailscale -- \
      /scripts/apply-ts-extra-args-local.sh >/tmp/remote-tools-k8s-apply.out 2>&1
    then
      pass "apply-ts-extra-args-local.sh exits 0 in pod"
    else
      # MAX_ATTEMPTS may need env; still accept exit 0 from script defaults.
      if kubectl -n "${NAMESPACE}" exec -e MAX_ATTEMPTS=2 -e RETRY_DELAY=1 "${pod}" -c tailscale -- \
        /scripts/apply-ts-extra-args-local.sh >/tmp/remote-tools-k8s-apply.out 2>&1
      then
        pass "apply-ts-extra-args-local.sh exits 0 in pod"
      else
        fail "apply-ts-extra-args-local.sh exits 0 in pod"
        cat /tmp/remote-tools-k8s-apply.out >&2 || true
      fi
    fi

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

  if kubectl -n "${NAMESPACE}" get cronjob remote-tools-health remote-tools-update >/dev/null; then
    pass "health and update CronJobs present"
  else
    fail "health and update CronJobs present"
  fi

  if kubectl -n "${NAMESPACE}" create job --from=cronjob/remote-tools-health "health-manual-$$"; then
    pass "manual health CronJob create"
    job_deadline=$((SECONDS + 120))
    status=0
    failed=0
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
    if [[ "${status}" != "1" && "${failed}" != "1" ]]; then
      fail "manual health job succeeded (timeout)"
      kubectl -n "${NAMESPACE}" describe job "health-manual-$$" >&2 || true
      kubectl -n "${NAMESPACE}" logs -l job-name="health-manual-$$" --tail=80 >&2 || true
    fi
  else
    fail "manual health CronJob create"
  fi

  rm -rf "${TMP_OVERLAY}"
}

case "${PROVIDER_USED}" in
  kind)
    run_kind_integration
    ;;
  kwok)
    run_kwok_api_checks
    if [[ "${build_ok}" -eq 1 ]]; then
      run_docker_runtime_simulation
    fi
    ;;
  docker)
    if [[ "${build_ok}" -eq 1 ]]; then
      run_docker_runtime_simulation
    else
      fail "Docker runtime simulation requires a successful image build"
    fi
    ;;
  *)
    fail "no cluster provider available"
    ;;
esac

echo
echo "Result: ${PASSES} passed, ${FAILS} failed (provider=${PROVIDER_USED:-none})"
if [[ "${FAILS}" -ne 0 ]]; then
  exit 1
fi
