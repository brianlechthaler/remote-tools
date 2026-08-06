# Remote Tools

Unattended Tailscale remote access for a Linux host, running in Docker with layered redundancy and automatic updates from GitHub.

## What it does

- Runs [Tailscale](https://tailscale.com/) in a Docker container with **host networking** so you can SSH to this machine over your tailnet
- Advertises itself as a Tailscale **exit node** so other devices can route internet traffic through this host
- Starts automatically on boot via **systemd**
- **Health watchdog** checks every 5 minutes and restarts if the container or tailnet connection fails
- **Auto-updater** pulls the latest config from `main` and the latest container from GHCR every 6 hours
- Container image is built and published to **GHCR** on every push to `main`

## Redundancy layers

| Layer | Mechanism |
|-------|-----------|
| Docker | `restart: unless-stopped` |
| systemd | `remote-tools.service` retries on failure |
| Watchdog | `remote-tools-health.timer` every 5 min |
| Rate limit | Health restarts capped at 6/hour to avoid restart loops |
| State | Persistent Docker volume keeps the same Tailscale node identity |
| Updates | Periodic pull from GitHub + GHCR keeps the host current |

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

**Exit node:** The stack advertises this host as an exit node and enables IPv4/IPv6 forwarding on the host (`/etc/sysctl.d/99-remote-tools-tailscale.conf`). Because Tailscale's container entrypoint ignores `TS_EXTRA_ARGS` on already-authenticated nodes (`TS_AUTH_ONCE`), `start.sh` / `update.sh` / `healthcheck.sh` also run `tailscale set` with those flags so `--advertise-exit-node` actually sticks after upgrades. After the node appears online, approve it in the [Tailscale admin console](https://login.tailscale.com/admin/machines): **Machines → … → Edit route settings → Use as exit node**. Other devices can then select this machine as their exit node.

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

# Manual update (same as the timer)
sudo /opt/remote-tools/scripts/update.sh

# Manual health check
sudo /opt/remote-tools/scripts/healthcheck.sh
```

## Container image

Published to:

```
ghcr.io/brianlechthaler/remote-tools:latest
```

Built from `tailscale/tailscale:v1.98.10` with health-check defaults enabled. Pushes to `main` trigger the [build workflow](.github/workflows/build-and-publish.yml).

## Development

Edit files in this repo and push to `main`. Within ~6 hours (or immediately via `update.sh`), installed hosts will:

1. `git pull` the latest scripts, compose file, and systemd units
2. `docker pull` the latest GHCR image
3. Recreate the container if the image changed

## License

MIT
