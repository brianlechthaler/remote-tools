#!/usr/bin/env bash
# Apply the container's TS_EXTRA_ARGS via `tailscale set`.
#
# Tailscale containerboot (through at least v1.98.x) only passes TS_EXTRA_ARGS to
# `tailscale up`. When TS_AUTH_ONCE=true and the node is already authenticated,
# containerboot runs `tailscale set` without ExtraArgs — so flags like
# --advertise-exit-node never take effect on existing installs after an upgrade.
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

# Return 0 if prefs already match the bits we care about from ExtraArgs.
prefs_already_applied() {
  local extra_args="$1"
  local prefs
  prefs="$(docker exec "${CONTAINER}" tailscale debug prefs 2>/dev/null || true)"
  [[ -n "${prefs}" ]] || return 1

  if [[ "${extra_args}" == *"--advertise-exit-node"* ]]; then
    # Prefer exact JSON field; fall back to substring for older CLI output.
    if ! grep -qE '"AdvertiseExitNode"[[:space:]]*:[[:space:]]*true' <<<"${prefs}" \
      && ! grep -q 'AdvertiseExitNode.*true' <<<"${prefs}"; then
      return 1
    fi
  fi

  if [[ "${extra_args}" == *"--accept-routes"* ]]; then
    if ! grep -qE '"RouteAll"[[:space:]]*:[[:space:]]*true' <<<"${prefs}" \
      && ! grep -q 'RouteAll.*true' <<<"${prefs}"; then
      return 1
    fi
  fi

  return 0
}

apply_once() {
  local extra_args="$1"
  # Word-split intentional: ExtraArgs is a shell-style flag string from compose.
  # shellcheck disable=SC2086
  docker exec "${CONTAINER}" tailscale set ${extra_args}
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
    exit 0
  fi

  local attempt
  for attempt in $(seq 1 "${MAX_ATTEMPTS}"); do
    if apply_once "${extra_args}" >/dev/null 2>&1; then
      if prefs_already_applied "${extra_args}"; then
        log "applied TS_EXTRA_ARGS via tailscale set: ${extra_args}"
        exit 0
      fi
      # set succeeded but prefs not yet reflecting (rare); keep trying briefly
      log "tailscale set returned ok; waiting for prefs to reflect (${attempt}/${MAX_ATTEMPTS})"
    else
      log "tailscale set not ready yet (${attempt}/${MAX_ATTEMPTS})"
    fi
    sleep "${RETRY_DELAY}"
  done

  log "WARNING: failed to apply TS_EXTRA_ARGS via tailscale set after ${MAX_ATTEMPTS} attempts: ${extra_args}"
  exit 0
}

main "$@"
