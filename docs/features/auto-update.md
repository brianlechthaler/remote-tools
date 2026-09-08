# Auto-update

Every 6 hours the host pulls this repo and the GHCR image; Kubernetes does a rollout restart so nodes pull `:latest`.

## Overview

| | Docker / systemd | Kubernetes |
|--|------------------|------------|
| Schedule | `remote-tools-update.timer`: `OnBootSec=15min`, `OnUnitActiveSec=6h`, `RandomizedDelaySec=300` | CronJob `remote-tools-update`: `0 */6 * * *` |
| Script | `scripts/update.sh` | `scripts/k8s-update.sh` |
| What changes | `git fetch` + `reset --hard origin/$BRANCH`, reinstall units, `docker compose pull`, `compose up` | `kubectl rollout restart` of the DaemonSet or Deployment (`imagePullPolicy: Always`) |

Image publishes happen on push to `main` via [Build and publish](../../.github/workflows/build-and-publish.yml). Hosts only pick up a new image after that workflow has run.

Kubernetes YAML/script changes are **not** applied by the CronJob. Re-run `./scripts/k8s-install.sh` or `kubectl apply -k …` when manifests change. Keep `k8s/base/scripts/` copies in sync with `scripts/` (see [Kubernetes](kubernetes.md)).

## Host `update.sh`

1. Skip if Docker is down (exit 0)
2. `git fetch origin $BRANCH` and `reset --hard origin/$BRANCH` (default `BRANCH=main`)
3. Reinstall systemd units and re-enable timers
4. Run [exit-node networking](exit-node.md)
5. Migrate `/etc/remote-tools/env` if `TS_EXTRA_ARGS` lacks `--advertise-exit-node`
6. `docker compose pull` and `up -d --remove-orphans`
7. Re-apply ExtraArgs, then re-assert NAT

`/opt/remote-tools` must be a git checkout. Testing a PR:

```bash
sudo BRANCH=cursor/some-fix-branch /opt/remote-tools/scripts/update.sh
```

That hard-resets the install to the named branch. Switch back to `main` the same way when done.

## Kubernetes

The update CronJob restarts the workload so kubelet pulls `ghcr.io/brianlechthaler/remote-tools:latest` again. It does not git-pull onto nodes.

```bash
kubectl -n remote-tools create job --from=cronjob/remote-tools-update update-manual
./scripts/k8s-update.sh
```

## Related

- [Container image](container-image.md)
- [Getting started](../getting-started.md)
- [CI and tests](ci.md)
