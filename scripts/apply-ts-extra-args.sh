#!/usr/bin/env bash
# Apply the container's TS_EXTRA_ARGS via `tailscale set`, then `tailscale up`.
#
# Tailscale containerboot (through at least v1.98.x) only passes TS_EXTRA_ARGS to
# `tailscale up`. When TS_AUTH_ONCE=true and the node is already authenticated,
# containerboot runs `tailscale set` without ExtraArgs — so flags like
# --advertise-exit-node never take effect on existing installs after an upgrade.
#
# Official exit-node docs also require `tailscale up` after
# `tailscale set --advertise-exit-node` so the control plane and local NAT path
# pick up the advertised default routes.
#
# Note: `AdvertiseExitNode` is NOT a field in `tailscale debug prefs` JSON.
# Exit-node mode is represented by AdvertiseRoutes containing 0.0.0.0/0 and ::/0.
# Checking for a fictional AdvertiseExitNode field causes a false "failed to apply"
# warning even when set succeeded (the bug users hit on main after PR #4).
#
# Invoked by start.sh / update.sh / healthcheck.sh after the stack is up.
set -euo pipefail

CONTAINER="${CONTAINER:-remote-tools-tailscale}"
LOG_TAG="${LOG_TAG:-remote-tools}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"
RETRY_DELAY="${RETRY_DELAY:-2}"

log() {
  echo "[$(date -Is)] $*"
  logger -t "${LOG_TAG}" "$*" 2>/dev/null || true
}

container_running() {
  docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null | grep -qx true
}

container_ts_extra_args() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER}" 2>/dev/null \
    | sed -n 's/^TS_EXTRA_ARGS=//p' \
    | head -n1
}

prefs_json() {
  docker exec "${CONTAINER}" tailscale debug prefs 2>/dev/null || true
}

# Parse prefs with python3 when available (reliable JSON). Bash fallback otherwise.
prefs_python() {
  local prefs="$1"
  local expression="$2"
  command -v python3 >/dev/null || return 2
  PREFS_JSON="${prefs}" python3 -c "
import json, os, sys
p = json.loads(os.environ['PREFS_JSON'])
${expression}
" 2>/dev/null
}

prefs_advertise_exit_node() {
  local prefs="$1"
  [[ -n "${prefs}" ]] || return 1

  local rc=0
  if prefs_python "${prefs}" '
routes = [str(r) for r in (p.get("AdvertiseRoutes") or [])]
sys.exit(0 if ("0.0.0.0/0" in routes and "::/0" in routes) else 1)
'; then
    return 0
  else
    rc=$?
    # rc=2 means python unavailable; fall through. rc=1 means check failed.
    if [[ "${rc}" -eq 1 ]]; then
      return 1
    fi
  fi

  # Bash fallback for multiline JSON from `tailscale debug prefs`.
  if grep -qE '"0\.0\.0\.0/0"' <<<"${prefs}" \
    && grep -qE '"(::/0)"' <<<"${prefs}" \
    && grep -q '"AdvertiseRoutes"' <<<"${prefs}"; then
    return 0
  fi
  return 1
}

prefs_accept_routes() {
  local prefs="$1"
  [[ -n "${prefs}" ]] || return 1

  local rc=0
  if prefs_python "${prefs}" 'sys.exit(0 if p.get("RouteAll") is True else 1)'; then
    return 0
  else
    rc=$?
    if [[ "${rc}" -eq 1 ]]; then
      return 1
    fi
  fi

  if grep -qE '"RouteAll"[[:space:]]*:[[:space:]]*true' <<<"${prefs}"; then
    return 0
  fi
  return 1
}

prefs_nosnat() {
  local prefs="$1"
  [[ -n "${prefs}" ]] || return 1
  if prefs_python "${prefs}" 'sys.exit(0 if p.get("NoSNAT") is True else 1)'; then
    return 0
  else
    local rc=$?
    if [[ "${rc}" -eq 1 ]]; then
      return 1
    fi
  fi
  grep -qE '"NoSNAT"[[:space:]]*:[[:space:]]*true' <<<"${prefs}"
}

prefs_summary() {
  local prefs="$1"
  if [[ -z "${prefs}" ]]; then
    printf 'prefs=<empty>'
    return 0
  fi
  if command -v python3 >/dev/null; then
    PREFS_JSON="${prefs}" python3 -c '
import json, os
p = json.loads(os.environ["PREFS_JSON"])
routes = [str(r) for r in (p.get("AdvertiseRoutes") or [])]
print(
  "AdvertiseRoutes=%s RouteAll=%s NoSNAT=%s"
  % (routes, p.get("RouteAll"), p.get("NoSNAT"))
)
' 2>/dev/null && return 0
  fi
  printf 'AdvertiseRoutes/RouteAll parse unavailable'
}

# Return 0 if prefs already match the bits we care about from ExtraArgs.
prefs_already_applied() {
  local extra_args="$1"
  local prefs
  prefs="$(prefs_json)"
  [[ -n "${prefs}" ]] || return 1

  if [[ "${extra_args}" == *"--advertise-exit-node"* ]]; then
    if ! prefs_advertise_exit_node "${prefs}"; then
      return 1
    fi
  fi

  if [[ "${extra_args}" == *"--accept-routes"* ]]; then
    if ! prefs_accept_routes "${prefs}"; then
      return 1
    fi
  fi

  return 0
}

run_in_container() {
  # Bound docker exec so unauthenticated/dev containers cannot hang the watchdog.
  if command -v timeout >/dev/null; then
    timeout 20 docker exec "${CONTAINER}" "$@"
  else
    docker exec "${CONTAINER}" "$@"
  fi
}

apply_once() {
  local extra_args="$1"
  # Word-split intentional: ExtraArgs is a shell-style flag string from compose.
  # shellcheck disable=SC2086
  run_in_container tailscale set ${extra_args} || return 1
  if [[ "${extra_args}" == *"--advertise-exit-node"* ]]; then
    # Docs: after set --advertise-exit-node, run up so advertising/NAT take effect.
    # Bare `up` keeps prefs written by `set` (unlike `up` with a partial flag set).
    run_in_container tailscale up >/dev/null 2>&1 || return 1
  fi
  return 0
}

warn_if_exit_node_unapproved() {
  local extra_args="$1"
  [[ "${extra_args}" == *"--advertise-exit-node"* ]] || return 0

  local prefs
  prefs="$(prefs_json)"
  if prefs_nosnat "${prefs}"; then
    log "WARNING: NoSNAT=true with exit node advertising; internet via this exit node may blackhole. Prefer default --snat-subnet-routes"
  fi

  local status
  status="$(docker exec "${CONTAINER}" tailscale status --json 2>/dev/null || true)"
  [[ -n "${status}" ]] || return 0

  # Self.ExitNodeOption is true only when offered and approved in the admin console.
  if grep -qE '"ExitNodeOption"[[:space:]]*:[[:space:]]*true' <<<"${status}"; then
    log "exit node is advertised and approved (ExitNodeOption=true)"
    return 0
  fi

  if prefs_advertise_exit_node "${prefs}"; then
    log "WARNING: advertising exit node, but it is not approved yet — approve in admin console: Machines → … → Edit route settings → Use as exit node"
  fi
}

main() {
  if ! command -v docker >/dev/null; then
    log "docker not available; skipping TS_EXTRA_ARGS apply"
    exit 0
  fi

  if ! container_running; then
    log "container ${CONTAINER} not running; skipping TS_EXTRA_ARGS apply"
    exit 0
  fi

  local extra_args
  extra_args="$(container_ts_extra_args)"
  if [[ -z "${extra_args}" ]]; then
    log "container has no TS_EXTRA_ARGS; nothing to apply"
    exit 0
  fi

  if prefs_already_applied "${extra_args}"; then
    log "tailscale prefs already match TS_EXTRA_ARGS (${extra_args})"
    warn_if_exit_node_unapproved "${extra_args}"
    exit 0
  fi

  local attempt prefs
  for attempt in $(seq 1 "${MAX_ATTEMPTS}"); do
    if apply_once "${extra_args}" >/dev/null 2>&1; then
      if prefs_already_applied "${extra_args}"; then
        log "applied TS_EXTRA_ARGS via tailscale set + up: ${extra_args}"
        warn_if_exit_node_unapproved "${extra_args}"
        exit 0
      fi
      prefs="$(prefs_json)"
      log "tailscale set/up returned ok; waiting for prefs to reflect (${attempt}/${MAX_ATTEMPTS}): $(prefs_summary "${prefs}")"
    else
      log "tailscale set/up not ready yet (${attempt}/${MAX_ATTEMPTS})"
    fi
    sleep "${RETRY_DELAY}"
  done

  prefs="$(prefs_json)"
  log "WARNING: failed to apply TS_EXTRA_ARGS via tailscale set/up after ${MAX_ATTEMPTS} attempts: ${extra_args} ($(prefs_summary "${prefs}"))"
  exit 0
}

main "$@"
