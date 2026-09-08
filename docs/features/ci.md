# CI and tests

GitHub Actions plus local shell scripts. There is no language unit-test runner; coverage is scripted checks and container/kind integration.

## Local

| Command | What it covers |
|---------|----------------|
| `./scripts/test-exit-node.sh` | bash -n, shellcheck, yamllint when present, compose defaults, ExtraArgs apply, networking script, offline exit-node behavior |
| `./scripts/test-tailscale-startup.sh` | Docker build + compose up with a fake key; `tailscaled` must start |
| `./scripts/test-k8s.sh` | Manifest drift, kubeconform, overlays, image helper, kind/kwok/docker cluster |

Kubernetes test env:

| Variable | Default | Meaning |
|----------|---------|---------|
| `KEEP_CLUSTER` | `0` | `1` leaves the kind/kwok cluster up |
| `SKIP_CLUSTER` | `0` | `1` for manifest/image checks only |
| `CLUSTER_PROVIDER` | `auto` | `kind`, `kwok`, `docker`, or `auto` |
| `WAIT_SECONDS` | `180` | Pod / container readiness timeout |

`./scripts/test-k8s.sh` fails if `k8s/base/scripts/` drifts from `scripts/` for the four mounted files.

## Workflows

| Workflow | Trigger | Jobs |
|----------|---------|------|
| [test.yml](../../.github/workflows/test.yml) | PR to `main`, `workflow_dispatch` | `test-tailscale-startup.sh`; `test-k8s.sh` with `CLUSTER_PROVIDER=kind`; squash-merge if label `automerge` |
| [test-k8s.yml](../../.github/workflows/test-k8s.yml) | PR and push to `main` | Same k8s script on GitHub-hosted runners (`CLUSTER_PROVIDER=kind`) |
| [build-and-publish.yml](../../.github/workflows/build-and-publish.yml) | Push to `main` | Build/push GHCR |
| [tailscale-version-bump.yml](../../.github/workflows/tailscale-version-bump.yml) | Weekly Monday | Dockerfile bump PR |

`test.yml` k8s job installs kustomize, kubeconform, kind, and shellcheck. `test-k8s.yml` also installs kwokctl as a documented fallback, but CI sets `CLUSTER_PROVIDER=kind` and fails closed if kind cannot start.

Re-run **Test Kubernetes** from the Actions tab if a run dies on runner acquisition before tests start.

## Related

- [Container image](container-image.md)
- [Kubernetes](kubernetes.md)
- [Auto-update](auto-update.md)
