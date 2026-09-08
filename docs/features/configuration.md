# Configuration

Host installs use `/etc/remote-tools/env`. Kubernetes uses Secret `remote-tools-auth` plus ConfigMap `remote-tools-config`.

## Auth key

Required on both platforms. Generate a reusable, non-ephemeral key at [Tailscale admin → Keys](https://login.tailscale.com/admin/settings/keys).

| Location | Key |
|----------|-----|
| Host | `TS_AUTHKEY` in `/etc/remote-tools/env` |
| Kubernetes | `TS_AUTHKEY` in Secret `remote-tools-auth` (from `k8s/secret.env`, gitignored) |

Accepted prefixes: `tskey-` or `file:`. `install.sh` / `start.sh` refuse to start without one.

Do not commit `/etc/remote-tools/env` or `k8s/secret.env`.

## Host env (`/etc/remote-tools/env`)

Copied from `config/env.example` on first install. Directory mode `700`, file mode `600`.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `TS_AUTHKEY` | Yes | none | Tailscale auth key |
| `TS_HOSTNAME` | No | `hostname -s` on install | Name in the admin console (compose falls back to `remote-tools`) |
| `TS_EXTRA_ARGS` | No | `--accept-routes --advertise-exit-node` | Flags for `tailscale up` / `tailscale set` |

Compose also hard-sets:

| Variable | Value | Why |
|----------|-------|-----|
| `TS_STATE_DIR` | `/var/lib/tailscale` | Persistent identity in the Docker volume |
| `TS_AUTH_ONCE` | `true` | Do not re-consume the key every start |
| `TS_USERSPACE` | `false` | Kernel TUN (needed for exit node) |
| `TS_ENABLE_HEALTH_CHECK` | `true` | Container health endpoint |
| `TS_LOCAL_ADDR_PORT` | `127.0.0.1:9002` | Health check bind |

Existing host env files that already set `TS_EXTRA_ARGS` without `--advertise-exit-node` are migrated by `install.sh` and `update.sh`.

## Kubernetes ConfigMap `remote-tools-config`

| Key | Default | Description |
|-----|---------|-------------|
| `TS_HOSTNAME` | empty (node/pod name) | Admin console hostname |
| `TS_EXTRA_ARGS` | `--accept-routes --advertise-exit-node` | Re-applied via `tailscale set` + `up` |
| `TS_USERSPACE` | `false` | Kernel TUN |
| `TS_AUTH_ONCE` | `true` | Same as Docker |
| `TS_KUBE_SECRET` | empty | Disables containerboot Secret state; identity stays on hostPath |
| `WATCHDOG_INTERVAL_SECONDS` | `300` | Sidecar networking reassert interval |
| `MAX_RESTARTS_PER_HOUR` | `6` | Health CronJob rate limit |

```bash
kubectl -n remote-tools edit configmap remote-tools-config
kubectl -n remote-tools rollout restart daemonset/remote-tools
```

## SSH

Connect with host OpenSSH over the tailnet. Do **not** add `--ssh` to `TS_EXTRA_ARGS`. Tailscale SSH looks up users inside the container and fails with `failed to look up local user`.

## Installer overrides

| Variable | Default | Used by |
|----------|---------|---------|
| `INSTALL_DIR` | `/opt/remote-tools` | host scripts |
| `REPO_URL` | this GitHub repo | `install.sh` |
| `BRANCH` | `main` | `install.sh`, `update.sh` |
| `OVERLAY` | `daemonset` | `k8s-install.sh` |
| `SECRET_ENV` | `k8s/secret.env` | `k8s-install.sh` |
| `IMAGE` | `ghcr.io/brianlechthaler/remote-tools:latest` | `k8s-install.sh` |

## Related

- [Getting started](../getting-started.md)
- [Exit node](exit-node.md)
- [Kubernetes](kubernetes.md)
