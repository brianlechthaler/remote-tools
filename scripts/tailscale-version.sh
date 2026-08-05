#!/usr/bin/env bash
# Print the Tailscale Docker image version pinned in the Dockerfile, or the
# latest stable semver tag published on Docker Hub.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="${ROOT}/Dockerfile"

current_version() {
  grep -oE 'tailscale/tailscale:v[0-9]+\.[0-9]+\.[0-9]+' "${DOCKERFILE}" \
    | head -1 \
    | sed 's/.*://'
}

latest_version() {
  local page=1
  local tags=()

  while true; do
    local response
    response="$(curl -sf "https://hub.docker.com/v2/repositories/tailscale/tailscale/tags?page_size=100&page=${page}")"
    while IFS= read -r tag; do
      [[ -n "${tag}" ]] && tags+=("${tag}")
    done < <(echo "${response}" | jq -r '.results[].name' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)

    local next
    next="$(echo "${response}" | jq -r '.next // empty')"
    [[ -z "${next}" ]] && break
    page=$((page + 1))
  done

  if [[ ${#tags[@]} -eq 0 ]]; then
    echo "error: no version tags found on Docker Hub" >&2
    exit 1
  fi

  printf '%s\n' "${tags[@]}" | sort -V | tail -1
}

case "${1:-}" in
  current) current_version ;;
  latest) latest_version ;;
  *)
    echo "usage: $0 {current|latest}" >&2
    exit 1
    ;;
esac
