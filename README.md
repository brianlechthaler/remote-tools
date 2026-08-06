# Remote Tools

Unattended Tailscale remote access for a Linux host, running in Docker (systemd) or Kubernetes with layered redundancy and automatic updates from GitHub.

## What it does

- Runs [Tailscale](https://tailscale.com/) with **host networking** so you can SSH to this machine (or cluster node) over your tailnet
- Advertises itself as a Tailscale **exit node** so other devices can route internet traffic through this host
- Starts automatically on boot via **systemd** or a Kubernetes **DaemonSet** / **Deployment**
- **Health watchdog** checks every 5 minutes and restarts if the container/pod or tailnet connection fails
- **Auto-updater** pulls the latest config/image every 6 hours (git + GHCR on hosts; CronJob rollout restart on Kubernetes)
- Container image is built and published to **GHCR** on every push to `main`
- Full **Kubernetes** packaging (manifests, install/health/update scripts, kind CI) — see [docs/kubernetes.md](docs/kubernetes.md)

## Redundancy layers

| Layer | Docker / systemd | Kubernetes |
|-------|------------------|------------|
| Runtime restart | `restart: unless-stopped` | kubelet restarts + probes |
| Supervisor | `remote-tools.service` | DaemonSet / Deployment |
| Watchdog | `remote-tools-health.timer` (5 min) | CronJob + networking sidecar |
| Rate limit | 6 restarts / hour | same (`k8s-healthcheck.sh`) |
| State | Docker volume | hostPath `/var/lib/remote-tools/tailscale` |
| Updates | git pull + `docker pull` every 6h | CronJob `rollout restart` + `imagePullPolicy: Always` |

## Quick install

Generate a **reusable, non-ephemeral** auth key at [Tailscale admin → Keys](https://login.tailscale.com/admin/settings/keys).

```bash
curl -fsSL https://raw.githubusercontent.com/brianlechthaler/remote-tools/main/scripts/install.sh | sudo bash
sudo nano /etc/remote-tools/env   # set TS_AUTHKEY=tskey-auth-...
sudo systemctl restart remote-tools
```

Or clone and install manually:

```bash
git clone https://github.com/brianlechthaler/remote-tools.git /opt/remote-tools
sudo /opt/remote-tools/scripts/install.sh
sudo nano /etc/remote-tools/env
sudo systemctl restart remote-tools
```

## Configuration

Environment file: `/etc/remote-tools/env`

| Variable | Required | Description |
|----------|----------|-------------|
| `TS_AUTHKEY` | Yes | Tailscale auth key (`tskey-auth-...`) |
| `TS_HOSTNAME` | No | Name shown in the admin console |
| `TS_EXTRA_ARGS` | No | Extra flags for `tailscale up` (default: `--accept-routes --advertise-exit-node`) |

**SSH access:** Connect with regular OpenSSH over the tailnet (`ssh user@hostname`). Do not enable Tailscale SSH (`--ssh`) in Docker — it looks up users inside the container, not on the host, and will fail with `failed to look up local user`.

**Exit node:** The stack advertises this host as an exit node and prepares the host network path for forwarded internet traffic:

- IPv4/IPv6 forwarding, loose `rp_filter`, and `src_valid_mark` via `/etc/sysctl.d/99-remote-tools-tailscale.conf`
- UFW / firewalld allowances when those firewalls are active
- Idempotent iptables MASQUERADE/FORWARD fallback for Tailscale CGNAT (`100.64.0.0/10`) so clients do not blackhole when Docker/UFW defeat Tailscale's mark-based NAT

Because Tailscale's container entrypoint ignores `TS_EXTRA_ARGS` on already-authenticated nodes (`TS_AUTH_ONCE`), `start.sh` / `update.sh` / `healthcheck.sh` also run `tailscale set` + `tailscale up` with those flags so `--advertise-exit-node` actually sticks after upgrades. After the node appears online, approve it in the [Tailscale admin console](https://login.tailscale.com/admin/machines): **Machines → … → Edit route settings → Use as exit node**. Other devices can then select this machine as their exit node.

If a client can resolve DNS but `ping`/`curl` through this exit node times out, run `sudo /opt/remote-tools/scripts/update.sh` (or wait for the health timer) and confirm admin approval. Check host logs for `MASQUERADE` / `ExitNodeOption` messages.

## Operations

```bash
# Service status
systemctl status remote-tools
systemctl list-timers 'remote-tools-*'

# Logs
journalctl -u remote-tools -f
docker logs -f remote-tools-tailscale

# Tailscale status
docker exec remote-tools-tailscale tailscale status

# Manual update (same as the timer; tracks main)
sudo /opt/remote-tools/scripts/update.sh

# Optional: install/test a PR branch before it lands on main
sudo BRANCH=cursor/some-fix-branch /opt/remote-tools/scripts/update.sh

# Manual health check
sudo /opt/remote-tools/scripts/healthcheck.sh
```

## Kubernetes

```bash
cp k8s/secret.env.example k8s/secret.env
# set TS_AUTHKEY=tskey-auth-...
./scripts/k8s-install.sh --overlay daemonset
```

Overlays:

- `k8s/overlays/daemonset` — one Tailscale pod per node (default)
- `k8s/overlays/single-node` — Deployment pinned to `remote-tools/exit-node=true`

See **[docs/kubernetes.md](docs/kubernetes.md)** for feature parity, configuration, operations, RBAC, and testing.

```bash
./scripts/test-k8s.sh          # static checks + kind integration
```

## Container image

Published to:

```
ghcr.io/brianlechthaler/remote-tools:latest
```

Built from `tailscale/tailscale:v1.98.10` with health-check defaults enabled and an in-container `apply-ts-extra-args-local.sh` for Kubernetes. Pushes to `main` trigger the [build workflow](.github/workflows/build-and-publish.yml).

## Development

Edit files in this repo and push to `main`. Within ~6 hours (or immediately via `update.sh` / `k8s-update.sh`), installs will refresh:

**Docker hosts**

1. `git pull` the latest scripts, compose file, and systemd units
2. `docker pull` the latest GHCR image
3. Recreate the container if the image changed

**Kubernetes**

1. Re-apply manifests (`./scripts/k8s-install.sh` or `kubectl apply -k …`) when YAML/scripts change
2. The update CronJob rolls the workload every 6 hours so nodes pull `:latest`

CI:

- [`.github/workflows/test.yml`](.github/workflows/test.yml) — Docker compose startup
- [`.github/workflows/test-k8s.yml`](.github/workflows/test-k8s.yml) — Kubernetes manifests + kind

## License

MIT
