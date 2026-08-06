#!/usr/bin/env bash
# Apply TS_EXTRA_ARGS via `tailscale set` + `tailscale up` inside the container.
#
# Same rationale as apply-ts-extra-args.sh: containerboot drops ExtraArgs on the
# TS_AUTH_ONCE `tailscale set` path, so --advertise-exit-node must be re-applied.
# This variant talks to the local tailscaled (no docker/kubectl).
set -euo pipefail

LOG_TAG="${LOG_TAG:-remote-tools}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"
RETRY_DELAY="${RETRY_DELAY:-2}"
EXTRA_ARGS="${TS_EXTRA_ARGS:-}"

log() {
  echo "[$(date -Is)] $*"
  logger -t "${LOG_TAG}" "$*" 2>/dev/null || true
}

prefs_json() {
  tailscale debug prefs 2>/dev/null || true
}

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
    if [[ "${rc}" -eq 1 ]]; then
      return 1
    fi
  fi

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

run_ts() {
  if command -v timeout >/dev/null; then
    timeout 20 tailscale "$@"
  else
    tailscale "$@"
  fi
}

apply_once() {
  local extra_args="$1"
  # Word-split intentional: ExtraArgs is a shell-style flag string.
  # shellcheck disable=SC2086
  run_ts set ${extra_args} || return 1
  if [[ "${extra_args}" == *"--advertise-exit-node"* ]]; then
    run_ts up >/dev/null 2>&1 || return 1
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
  status="$(tailscale status --json 2>/dev/null || true)"
  [[ -n "${status}" ]] || return 0

  if grep -qE '"ExitNodeOption"[[:space:]]*:[[:space:]]*true' <<<"${status}"; then
    log "exit node is advertised and approved (ExitNodeOption=true)"
    return 0
  fi

  if prefs_advertise_exit_node "${prefs}"; then
    log "WARNING: advertising exit node, but it is not approved yet — approve in admin console: Machines → … → Edit route settings → Use as exit node"
  fi
}

main() {
  if ! command -v tailscale >/dev/null; then
    log "tailscale binary not available; skipping TS_EXTRA_ARGS apply"
    exit 0
  fi

  if [[ -z "${EXTRA_ARGS}" ]]; then
    log "TS_EXTRA_ARGS empty; nothing to apply"
    exit 0
  fi

  # Wait briefly for tailscaled to accept CLI commands.
  local ready=0 attempt
  for attempt in $(seq 1 15); do
    if tailscale status --peers=false >/dev/null 2>&1 \
      || tailscale debug prefs >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "${ready}" -ne 1 ]]; then
    log "tailscaled not ready yet; will retry on next watchdog cycle"
    exit 0
  fi

  if prefs_already_applied "${EXTRA_ARGS}"; then
    log "tailscale prefs already match TS_EXTRA_ARGS (${EXTRA_ARGS})"
    warn_if_exit_node_unapproved "${EXTRA_ARGS}"
    exit 0
  fi

  local prefs
  for attempt in $(seq 1 "${MAX_ATTEMPTS}"); do
    if apply_once "${EXTRA_ARGS}" >/dev/null 2>&1; then
      if prefs_already_applied "${EXTRA_ARGS}"; then
        log "applied TS_EXTRA_ARGS via tailscale set + up: ${EXTRA_ARGS}"
        warn_if_exit_node_unapproved "${EXTRA_ARGS}"
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
  log "WARNING: failed to apply TS_EXTRA_ARGS via tailscale set/up after ${MAX_ATTEMPTS} attempts: ${EXTRA_ARGS} ($(prefs_summary "${prefs}"))"
  exit 0
}

main "$@"
