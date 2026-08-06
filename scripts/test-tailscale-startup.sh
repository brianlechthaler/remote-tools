#!/usr/bin/env bash
# Verify the Tailscale container builds and starts with this repo's compose config.
# Uses a fake auth key; tailnet join is expected to fail, but tailscaled must start.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
PROJECT="rt-startup-test-$$"
WAIT_SECONDS="${WAIT_SECONDS:-30}"

cleanup() {
  docker compose -p "${PROJECT}" -f "${TMP_DIR}/docker-compose.yml" down -v >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

TMP_ENV="${TMP_DIR}/env"
cat > "${TMP_ENV}" <<'EOF'
TS_AUTHKEY=tskey-auth-TESTONLY
TS_HOSTNAME=startup-test
EOF

RENDERED_COMPOSE="${TMP_DIR}/docker-compose.yml"
sed -e "s|/etc/remote-tools/env|${TMP_ENV}|g" \
    -e "s|ghcr.io/brianlechthaler/remote-tools:latest|remote-tools:startup-test|g" \
    "${ROOT}/docker-compose.yml" > "${RENDERED_COMPOSE}"
cp "${ROOT}/Dockerfile" "${TMP_DIR}/Dockerfile"

echo "== build image =="
if ! docker build -t remote-tools:startup-test "${ROOT}" >/tmp/remote-tools-startup-build.log 2>&1; then
  if grep -qiE 'buildx|BuildKit|overlay|invalid argument|mount' /tmp/remote-tools-startup-build.log \
    && DOCKER_BUILDKIT=0 docker build -t remote-tools:startup-test "${ROOT}" \
      >/tmp/remote-tools-startup-build.log 2>&1; then
    :
  else
    tail -50 /tmp/remote-tools-startup-build.log >&2 || true
    fail "docker build failed"
  fi
fi
pass "docker build succeeded"

if ! docker run --rm --entrypoint /bin/sh remote-tools:startup-test \
  -c 'command -v tailscale && command -v tailscaled' >/dev/null; then
  fail "image is missing tailscale binaries"
fi
pass "image contains tailscale binaries"

echo
echo "== compose startup =="
if ! docker compose -p "${PROJECT}" -f "${RENDERED_COMPOSE}" up -d --pull never \
  >/tmp/remote-tools-startup-up.log 2>&1; then
  cat /tmp/remote-tools-startup-up.log >&2 || true
  fail "docker compose up failed"
fi
pass "docker compose up started container"

cid="$(docker compose -p "${PROJECT}" -f "${RENDERED_COMPOSE}" ps -q tailscale)"
[[ -n "${cid}" ]] || fail "tailscale container id not found"

deadline=$((SECONDS + WAIT_SECONDS))
state=""
while (( SECONDS < deadline )); do
  state="$(docker inspect -f '{{.State.Status}}' "${cid}" 2>/dev/null || echo missing)"
  if [[ "${state}" == "exited" ]]; then
    docker logs "${cid}" >&2 || true
    fail "container exited during startup (state=${state})"
  fi
  if [[ "${state}" == "running" ]]; then
    if docker exec "${cid}" sh -c 'pgrep -x tailscaled >/dev/null 2>&1 || pgrep tailscaled >/dev/null 2>&1'; then
      break
    fi
  fi
  sleep 2
done

if [[ "${state}" != "running" ]]; then
  docker logs "${cid}" >&2 || true
  fail "container did not reach running state (state=${state})"
fi

if ! docker exec "${cid}" sh -c 'pgrep -x tailscaled >/dev/null 2>&1 || pgrep tailscaled >/dev/null 2>&1'; then
  docker logs "${cid}" >&2 || true
  fail "tailscaled process is not running"
fi
pass "tailscaled is running"

logs="$(docker logs "${cid}" 2>&1 || true)"
[[ -n "${logs}" ]] || fail "container produced no logs"
pass "container produced logs"

if grep -qiE 'panic:|fatal error|exec format error' <<<"${logs}"; then
  echo "${logs}" >&2
  fail "container logs contain fatal startup errors"
fi
pass "container logs show no fatal startup errors"

extra_args="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${cid}")"
if [[ "${extra_args}" != *"TS_EXTRA_ARGS=--accept-routes --advertise-exit-node"* ]]; then
  fail "container is missing expected TS_EXTRA_ARGS"
fi
pass "container has expected TS_EXTRA_ARGS"

echo
echo "Tailscale startup test passed"
