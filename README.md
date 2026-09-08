# Remote Tools

Unattended [Tailscale](https://tailscale.com/) remote access for a Linux host or Kubernetes node. The stack joins your tailnet with host networking, advertises an exit node, and restarts or updates itself when the connection or image goes stale.

## Quick start

Generate a **reusable, non-ephemeral** auth key at [Tailscale admin → Keys](https://login.tailscale.com/admin/settings/keys).

```bash
curl -fsSL https://raw.githubusercontent.com/brianlechthaler/remote-tools/main/scripts/install.sh | sudo bash
sudo nano /etc/remote-tools/env   # set TS_AUTHKEY=tskey-auth-...
sudo systemctl restart remote-tools
```

Or clone and install:

```bash
git clone https://github.com/brianlechthaler/remote-tools.git /opt/remote-tools
sudo /opt/remote-tools/scripts/install.sh
```

Kubernetes:

```bash
cp k8s/secret.env.example k8s/secret.env   # set TS_AUTHKEY
./scripts/k8s-install.sh --overlay daemonset
```

Approve the machine as an exit node after it appears online: **Machines → … → Edit route settings → Use as exit node**.

## Documentation

- [Getting started](docs/getting-started.md)
- [Architecture](docs/architecture.md)
- [Feature index](docs/index.md)
- [Kubernetes](docs/features/kubernetes.md)
- [Exit node](docs/features/exit-node.md)
- [Configuration](docs/features/configuration.md)

## Requirements

- Linux host with Docker and systemd, or Kubernetes 1.27+
- Root (host) or node privileges for `hostNetwork`, `/dev/net/tun`, and sysctl
- Reusable Tailscale auth key (`tskey-auth-...`)

Image: `ghcr.io/brianlechthaler/remote-tools:latest`

## License

MIT
