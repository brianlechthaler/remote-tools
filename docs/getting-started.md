# Getting started

Install remote-tools on a Linux host with Docker and systemd, or on Kubernetes.

## Auth key

Create a **reusable, non-ephemeral** key at [Tailscale admin → Keys](https://login.tailscale.com/admin/settings/keys).

Recommended key settings:

- Reusable: yes
- Ephemeral: no
- Pre-approved: yes (if you use ACL tags)

## Host (Docker + systemd)

Requires root, Docker, and systemd. The installer clones this repo to `/opt/remote-tools`.

```bash
curl -fsSL https://raw.githubusercontent.com/brianlechthaler/remote-tools/main/scripts/install.sh | sudo bash
```

Or:

```bash
git clone https://github.com/brianlechthaler/remote-tools.git /opt/remote-tools
sudo /opt/remote-tools/scripts/install.sh
```

`install.sh` does the following:

1. Clones or hard-resets `/opt/remote-tools` to `origin/main` (`BRANCH` / `REPO_URL` / `INSTALL_DIR` are overridable)
2. Creates `/etc/remote-tools/env` from `config/env.example` if missing (`chmod 600`)
3. Sets `TS_HOSTNAME` to `hostname -s` when that key is absent
4. Appends `--advertise-exit-node` to existing `TS_EXTRA_ARGS` if it was missing
5. Runs [exit-node host networking](features/exit-node.md)
6. Installs and enables systemd units and timers
7. Starts `remote-tools` only if `TS_AUTHKEY` looks like `tskey-` or `file:`

Edit the key, then start:

```bash
sudo nano /etc/remote-tools/env
sudo systemctl restart remote-tools
```

### Check it

```bash
systemctl status remote-tools
docker logs -f remote-tools-tailscale
docker exec remote-tools-tailscale tailscale status
```

SSH with OpenSSH over the tailnet (`ssh user@hostname`). Do not add `--ssh` to `TS_EXTRA_ARGS`. Tailscale SSH runs inside the container and cannot see host users.

After the node is online, approve it as an exit node: **Machines → … → Edit route settings → Use as exit node**. See [Exit node](features/exit-node.md).

### Operations

```bash
systemctl list-timers 'remote-tools-*'
journalctl -u remote-tools -f
sudo /opt/remote-tools/scripts/healthcheck.sh
sudo /opt/remote-tools/scripts/update.sh
sudo BRANCH=some-pr-branch /opt/remote-tools/scripts/update.sh
```

Paths:

| Path | Role |
|------|------|
| `/opt/remote-tools` | Git checkout (scripts, compose, units) |
| `/etc/remote-tools/env` | Auth key and Tailscale flags |
| Docker volume `remote-tools-tailscale-state` | Tailscale identity |

## Kubernetes

```bash
cp k8s/secret.env.example k8s/secret.env
# set TS_AUTHKEY=tskey-auth-...
./scripts/k8s-install.sh --overlay daemonset
```

Full install, overlays, RBAC, and uninstall: [Kubernetes](features/kubernetes.md).

## Next

- [Configuration](features/configuration.md)
- [Architecture](architecture.md)
- [Health watchdog](features/health-watchdog.md)
- [Auto-update](features/auto-update.md)
