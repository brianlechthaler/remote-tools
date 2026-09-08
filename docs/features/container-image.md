# Container image

Image used by Docker Compose and Kubernetes: `ghcr.io/brianlechthaler/remote-tools:latest`.

Built from `tailscale/tailscale:v1.98.10` with health-check defaults and an in-container ExtraArgs helper for Kubernetes.

## Overview

`Dockerfile` starts from the pinned Tailscale image, sets `TS_AUTH_ONCE`, kernel TUN, and the local health bind, installs bash/coreutils, and copies `scripts/apply-ts-extra-args-local.sh` to `/usr/local/bin/`.

Host installs still run ExtraArgs from the git checkout (`apply-ts-extra-args.sh` + `docker exec`). Kubernetes uses the in-image script because CronJobs exec into the Tailscale container.

## Tags

| Tag | When |
|-----|------|
| `latest` | Push to `main` (default branch) |
| git SHA (no prefix) | Same build |

Workflow: [`.github/workflows/build-and-publish.yml`](../../.github/workflows/build-and-publish.yml). Login uses `GITHUB_TOKEN`; `packages: write`. A follow-up step tries to mark the GHCR package public.

## Weekly Tailscale bump

[`.github/workflows/tailscale-version-bump.yml`](../../.github/workflows/tailscale-version-bump.yml) runs Mondays 09:00 UTC (and `workflow_dispatch`).

`scripts/tailscale-version.sh current` reads the Dockerfile pin. `latest` walks Docker Hub tags for `vMAJOR.MINOR.PATCH` and takes the highest.

If they differ, the workflow updates `Dockerfile` and this file (`tailscale/tailscale:v…`), then opens a PR labeled `automerge`. [Test](ci.md) squash-merges that PR after startup and Kubernetes jobs pass.

## Related

- [Auto-update](auto-update.md)
- [CI and tests](ci.md)
- [Kubernetes](kubernetes.md)
