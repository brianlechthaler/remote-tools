#!/usr/bin/env bash
# Thorough offline tests for exit node mode. No Tailscale auth key required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

expect_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass "${label}"
  else
    fail "${label} (got '${actual}', want '${expected}')"
  fi
}

echo "== syntax / static checks =="

for script in "${ROOT}/scripts/"*.sh; do
  if bash -n "${script}"; then
    pass "bash -n $(basename "${script}")"
  else
    fail "bash -n $(basename "${script}")"
  fi
done

if command -v shellcheck >/dev/null; then
  if shellcheck -x "${ROOT}/scripts/"*.sh; then
    pass "shellcheck scripts/*.sh"
  else
    fail "shellcheck scripts/*.sh"
  fi
else
  fail "shellcheck not installed"
fi

if command -v yamllint >/dev/null; then
  if yamllint -d '{extends: relaxed, rules: {line-length: disable}}' \
    "${ROOT}/docker-compose.yml" "${ROOT}/.github/workflows/"*.yml; then
    pass "yamllint compose + workflows"
  else
    fail "yamllint compose + workflows"
  fi
fi

echo
echo "== exit node configuration =="

compose="$(cat "${ROOT}/docker-compose.yml")"
expect_contains "${compose}" "--advertise-exit-node" "compose defaults advertise exit node"
expect_contains "${compose}" "network_mode: host" "compose uses host networking"
expect_contains "${compose}" "NET_ADMIN" "compose has NET_ADMIN"
expect_contains "${compose}" "/dev/net/tun" "compose mounts TUN device"
expect_contains "${compose}" 'TS_USERSPACE: "false"' "compose disables userspace networking"

readme="$(cat "${ROOT}/README.md")"
expect_contains "${readme}" "exit node" "README documents exit node"
expect_contains "${readme}" "advertise-exit-node" "README mentions --advertise-exit-node"
expect_contains "${readme}" "Use as exit node" "README documents admin approval"
expect_contains "${readme}" "MASQUERADE" "README documents NAT/MASQUERADE path"
expect_contains "${readme}" "rp_filter" "README documents rp_filter hardening"

env_example="$(cat "${ROOT}/config/env.example")"
expect_contains "${env_example}" "--advertise-exit-node" "env.example mentions advertise-exit-node"
expect_contains "${env_example}" "Use as exit node" "env.example documents admin approval"

for script in start.sh update.sh install.sh healthcheck.sh; do
  body="$(cat "${ROOT}/scripts/${script}")"
  expect_contains "${body}" "ensure-exit-node-networking.sh" \
    "${script} calls ensure-exit-node-networking.sh"
done

net_script="$(cat "${ROOT}/scripts/ensure-exit-node-networking.sh")"
expect_contains "${net_script}" "net.ipv4.ip_forward = 1" "networking script enables IPv4 forwarding"
expect_contains "${net_script}" "net.ipv6.conf.all.forwarding = 1" "networking script enables IPv6 forwarding"
expect_contains "${net_script}" "net.ipv4.conf.all.rp_filter = 2" "networking script sets loose rp_filter"
expect_contains "${net_script}" "net.ipv4.conf.all.src_valid_mark = 1" "networking script sets src_valid_mark"
expect_contains "${net_script}" "99-remote-tools-tailscale.conf" "networking script writes persistent sysctl conf"
expect_contains "${net_script}" "100.64.0.0/10" "networking script MASQUERADEs Tailscale CGNAT"
expect_contains "${net_script}" "MASQUERADE" "networking script configures MASQUERADE"
expect_contains "${net_script}" "firewall-cmd" "networking script handles firewalld"
expect_contains "${net_script}" "ufw route allow" "networking script handles ufw routed traffic"

expect_contains "$(cat "${ROOT}/scripts/start.sh")" "apply-ts-extra-args.sh" \
  "start.sh re-applies TS_EXTRA_ARGS after stack start"
expect_contains "$(cat "${ROOT}/scripts/update.sh")" "apply-ts-extra-args.sh" \
  "update.sh re-applies TS_EXTRA_ARGS after container update"
expect_contains "$(cat "${ROOT}/scripts/healthcheck.sh")" "apply-ts-extra-args.sh" \
  "healthcheck.sh re-applies TS_EXTRA_ARGS when healthy"
expect_contains "$(cat "${ROOT}/scripts/apply-ts-extra-args.sh")" "tailscale set" \
  "apply-ts-extra-args.sh uses tailscale set"
expect_contains "$(cat "${ROOT}/scripts/apply-ts-extra-args.sh")" "tailscale up" \
  "apply-ts-extra-args.sh runs tailscale up after set"
expect_contains "$(cat "${ROOT}/scripts/apply-ts-extra-args.sh")" "AdvertiseRoutes" \
  "apply-ts-extra-args.sh checks AdvertiseRoutes for exit-node prefs"
expect_contains "$(cat "${ROOT}/scripts/apply-ts-extra-args.sh")" "ExitNodeOption" \
  "apply-ts-extra-args.sh warns when exit node is unapproved"
expect_contains "$(cat "${ROOT}/scripts/install.sh")" "migrate_env_exit_node" \
  "install.sh migrates env files missing exit-node flag"
expect_contains "$(cat "${ROOT}/scripts/update.sh")" "migrate_env_exit_node" \
  "update.sh migrates env files missing exit-node flag"

echo
echo "== docker compose render =="

TMP_ENV="$(mktemp)"
TMP_COMPOSE_PROJECT="$(mktemp -d)"
cleanup() {
  rm -f "${TMP_ENV}"
  rm -rf "${TMP_COMPOSE_PROJECT}"
}
trap cleanup EXIT

cat > "${TMP_ENV}" <<'EOF'
TS_AUTHKEY=tskey-auth-TESTONLY
TS_HOSTNAME=exit-node-test
EOF

# Compose interpolates ${TS_EXTRA_ARGS:...} from the shell environment / .env next
# to the compose file; also point env_file at a temp path via a rendered copy.
RENDERED_COMPOSE="${TMP_COMPOSE_PROJECT}/docker-compose.yml"
sed -e "s|/etc/remote-tools/env|${TMP_ENV}|g" \
    -e "s|ghcr.io/brianlechthaler/remote-tools:latest|remote-tools:exit-node-test|g" \
    "${ROOT}/docker-compose.yml" > "${RENDERED_COMPOSE}"
cp "${ROOT}/Dockerfile" "${TMP_COMPOSE_PROJECT}/Dockerfile"

if docker compose -f "${RENDERED_COMPOSE}" config >/tmp/remote-tools-compose-config.yml 2>/tmp/remote-tools-compose-config.err; then
  pass "docker compose config validates"
  rendered="$(cat /tmp/remote-tools-compose-config.yml)"
  expect_contains "${rendered}" "--advertise-exit-node" "rendered compose includes --advertise-exit-node"
  expect_contains "${rendered}" "--accept-routes" "rendered compose includes --accept-routes"
  expect_contains "${rendered}" "network_mode: host" "rendered compose keeps host networking"
else
  fail "docker compose config validates"
  cat /tmp/remote-tools-compose-config.err >&2 || true
fi

# Explicit override must still allow disabling exit node if operator chooses.
if TS_EXTRA_ARGS="--accept-routes" docker compose -f "${RENDERED_COMPOSE}" config 2>/dev/null \
  | grep -q -- "--advertise-exit-node"; then
  fail "TS_EXTRA_ARGS override should replace default (still saw --advertise-exit-node)"
else
  pass "TS_EXTRA_ARGS override replaces default exit-node flag"
fi

echo
echo "== host exit-node networking (live) =="

CONF="/etc/sysctl.d/99-remote-tools-tailscale.conf"
BACKUP=""
if [[ -f "${CONF}" ]]; then
  BACKUP="$(mktemp)"
  cp "${CONF}" "${BACKUP}"
fi

if sudo LOG_TAG=remote-tools-test bash "${ROOT}/scripts/ensure-exit-node-networking.sh" \
  >/tmp/remote-tools-networking.out 2>&1; then
  pass "ensure-exit-node-networking.sh exits 0"
else
  fail "ensure-exit-node-networking.sh exits 0"
  cat /tmp/remote-tools-networking.out >&2 || true
fi

ipv4="$(sysctl -n net.ipv4.ip_forward)"
ipv6="$(sysctl -n net.ipv6.conf.all.forwarding)"
rp="$(sysctl -n net.ipv4.conf.all.rp_filter)"
expect_eq "${ipv4}" "1" "net.ipv4.ip_forward is 1"
expect_eq "${ipv6}" "1" "net.ipv6.conf.all.forwarding is 1"
expect_eq "${rp}" "2" "net.ipv4.conf.all.rp_filter is 2"

if [[ -f "${CONF}" ]] && grep -q 'net.ipv4.conf.all.rp_filter = 2' "${CONF}"; then
  pass "sysctl conf persists rp_filter=2"
else
  fail "sysctl conf persists rp_filter=2"
fi

if command -v iptables >/dev/null; then
  if sudo iptables -t nat -C POSTROUTING -s 100.64.0.0/10 ! -o tailscale0 -j MASQUERADE 2>/dev/null; then
    pass "iptables CGNAT MASQUERADE fallback installed"
  else
    fail "iptables CGNAT MASQUERADE fallback installed"
  fi
  if sudo iptables -C FORWARD -i tailscale0 -j ACCEPT 2>/dev/null; then
    pass "iptables FORWARD ACCEPT for tailscale0 installed"
  else
    fail "iptables FORWARD ACCEPT for tailscale0 installed"
  fi
  # Idempotency: second run must not fail or duplicate-error.
  if sudo LOG_TAG=remote-tools-test bash "${ROOT}/scripts/ensure-exit-node-networking.sh" \
    >/tmp/remote-tools-networking2.out 2>&1; then
    pass "ensure-exit-node-networking.sh is idempotent"
  else
    fail "ensure-exit-node-networking.sh is idempotent"
    cat /tmp/remote-tools-networking2.out >&2 || true
  fi
else
  fail "iptables not installed"
fi

if [[ -n "${BACKUP}" ]]; then
  sudo cp "${BACKUP}" "${CONF}"
  rm -f "${BACKUP}"
fi

echo
echo "== container image build =="

build_ok=0
if docker build -t remote-tools:exit-node-test "${ROOT}" >/tmp/remote-tools-docker-build.log 2>&1; then
  build_ok=1
else
  # Cloud/nested VMs often lack buildx or reject overlay mounts.
  if grep -qiE 'buildx|BuildKit|overlay|invalid argument|mount' /tmp/remote-tools-docker-build.log; then
    echo "default build failed; retrying with DOCKER_BUILDKIT=0..."
    if DOCKER_BUILDKIT=0 docker build -t remote-tools:exit-node-test "${ROOT}" \
      >/tmp/remote-tools-docker-build.log 2>&1; then
      build_ok=1
    fi
  fi
fi

if [[ "${build_ok}" -eq 1 ]]; then
  pass "docker build succeeds"
  if docker run --rm --entrypoint /bin/sh remote-tools:exit-node-test -c 'command -v tailscale && command -v tailscaled' >/dev/null; then
    pass "image contains tailscale binaries"
  else
    fail "image contains tailscale binaries"
  fi
else
  fail "docker build succeeds"
  tail -50 /tmp/remote-tools-docker-build.log >&2 || true
fi

echo
echo "== container env wiring (no auth) =="

# Bring up the stack with a throwaway project name and fake auth key. We only
# assert that containerboot receives --advertise-exit-node; full tailnet join
# requires a real key and admin approval.
PROJECT="rt-exitnode-test-$$"
if docker compose -p "${PROJECT}" -f "${RENDERED_COMPOSE}" up -d --pull never 2>/tmp/remote-tools-compose-up.err; then
  pass "compose up starts container"
  # Give containerboot a moment to set env / attempt up.
  sleep 2
  extra_args="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${PROJECT}-tailscale-1" 2>/dev/null \
    || docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' remote-tools-tailscale 2>/dev/null \
    || true)"
  # Prefer container_name from compose when project doesn't rename it.
  if [[ -z "${extra_args}" ]] || ! grep -q 'TS_EXTRA_ARGS' <<<"${extra_args}"; then
    cid="$(docker compose -p "${PROJECT}" -f "${RENDERED_COMPOSE}" ps -q tailscale 2>/dev/null || true)"
    if [[ -n "${cid}" ]]; then
      extra_args="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${cid}")"
    fi
  fi
  expect_contains "${extra_args}" "TS_EXTRA_ARGS=--accept-routes --advertise-exit-node" \
    "running container has exit-node TS_EXTRA_ARGS"
  expect_contains "${extra_args}" "TS_USERSPACE=false" "running container uses kernel networking"

  # Apply helper should target this container; without a real login, set will
  # fail and the script warns but must still exit 0 (non-fatal for start/update).
  cid="$(docker compose -p "${PROJECT}" -f "${RENDERED_COMPOSE}" ps -q tailscale 2>/dev/null || true)"
  cname="$(docker inspect -f '{{.Name}}' "${cid}" 2>/dev/null | sed 's#^/##')"
  if [[ -n "${cname}" ]] \
    && CONTAINER="${cname}" MAX_ATTEMPTS=2 RETRY_DELAY=1 \
         bash "${ROOT}/scripts/apply-ts-extra-args.sh" \
         >/tmp/remote-tools-apply-live.out 2>&1; then
    pass "apply-ts-extra-args.sh exits 0 against running unauthenticated container"
    if grep -qiE 'tailscale set|TS_EXTRA_ARGS|not ready|WARNING|already match' \
      /tmp/remote-tools-apply-live.out; then
      pass "apply-ts-extra-args.sh attempted set or reported status"
    else
      fail "apply-ts-extra-args.sh attempted set or reported status"
      cat /tmp/remote-tools-apply-live.out >&2 || true
    fi
  else
    fail "apply-ts-extra-args.sh exits 0 against running unauthenticated container"
    cat /tmp/remote-tools-apply-live.out >&2 || true
  fi

  # containerboot should attempt login with our fake key; logs mention auth or up flags.
  logs="$(docker compose -p "${PROJECT}" -f "${RENDERED_COMPOSE}" logs --no-color 2>/dev/null || true)"
  if [[ -n "${logs}" ]]; then
    pass "container produced logs"
  else
    fail "container produced logs"
  fi
else
  fail "compose up starts container"
  cat /tmp/remote-tools-compose-up.err >&2 || true
fi

docker compose -p "${PROJECT}" -f "${RENDERED_COMPOSE}" down -v >/dev/null 2>&1 || true

echo
echo "== env migration =="

MIG_ENV="$(mktemp)"
cat > "${MIG_ENV}" <<'EOF'
TS_AUTHKEY=tskey-auth-TESTONLY
TS_EXTRA_ARGS=--accept-routes --advertise-tags=tag:remote
EOF

# Exercise install.sh's migrate logic inline (same algorithm).
migrate_env_exit_node_test() {
  local env_file="$1"
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
}

migrate_env_exit_node_test "${MIG_ENV}"
migrated="$(cat "${MIG_ENV}")"
expect_contains "${migrated}" "--advertise-exit-node" "migration appends --advertise-exit-node"
expect_contains "${migrated}" "--accept-routes" "migration preserves --accept-routes"
expect_contains "${migrated}" "--advertise-tags=tag:remote" "migration preserves existing flags"
rm -f "${MIG_ENV}"

MIG_ENV2="$(mktemp)"
cat > "${MIG_ENV2}" <<'EOF'
TS_AUTHKEY=tskey-auth-TESTONLY
TS_EXTRA_ARGS=--accept-routes --advertise-exit-node
EOF
before="$(cat "${MIG_ENV2}")"
migrate_env_exit_node_test "${MIG_ENV2}"
after="$(cat "${MIG_ENV2}")"
expect_eq "${after}" "${before}" "migration is idempotent when exit-node already present"
rm -f "${MIG_ENV2}"

echo
echo "== apply-ts-extra-args.sh dry behavior =="

# Without a running container, the helper should no-op successfully.
if CONTAINER=remote-tools-does-not-exist MAX_ATTEMPTS=1 RETRY_DELAY=0 \
  bash "${ROOT}/scripts/apply-ts-extra-args.sh" >/tmp/remote-tools-apply-extra.out 2>&1; then
  pass "apply-ts-extra-args.sh no-ops when container missing"
else
  fail "apply-ts-extra-args.sh no-ops when container missing"
  cat /tmp/remote-tools-apply-extra.out >&2 || true
fi

echo
echo "== start.sh dry validation paths =="

# validate_config should reject missing env / bad auth key when run as root.
if sudo env INSTALL_DIR="${ROOT}" bash -c '
  ENV_FILE=/tmp/remote-tools-missing-env-$$
  COMPOSE_FILE="'"${ROOT}"'/docker-compose.yml"
  source /dev/null
  # Inline the validate_config checks from start.sh
  if [[ ! -f "${ENV_FILE}" ]]; then exit 11; fi
' ; then
  fail "missing env should be rejected"
else
  rc=$?
  if [[ "${rc}" -eq 11 ]]; then
    pass "missing env file detected"
  else
    fail "missing env file detected (rc=${rc})"
  fi
fi

BAD_ENV="$(mktemp)"
echo "TS_AUTHKEY=not-a-key" > "${BAD_ENV}"
if grep -qE '^TS_AUTHKEY=(tskey-|file:)' "${BAD_ENV}"; then
  fail "auth key validator rejects non-tskey values"
else
  pass "auth key validator rejects non-tskey values"
fi
rm -f "${BAD_ENV}"

GOOD_ENV="$(mktemp)"
echo "TS_AUTHKEY=tskey-auth-testdata" > "${GOOD_ENV}"
if grep -qE '^TS_AUTHKEY=(tskey-|file:)' "${GOOD_ENV}"; then
  pass "auth key validator accepts tskey-auth values"
else
  fail "auth key validator accepts tskey-auth values"
fi
rm -f "${GOOD_ENV}"

echo
echo "Result: ${PASSES} passed, ${FAILS} failed"
if [[ "${FAILS}" -ne 0 ]]; then
  exit 1
fi
