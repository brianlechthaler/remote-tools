# Architecture

remote-tools runs Tailscale in a container with **host networking**, then layers systemd or Kubernetes around it so the node stays on the tailnet and usable as an exit node.

It is not the Tailscale Kubernetes Operator. It makes **the host or node** reachable (SSH to the machine, internet via the node WAN), not cluster Services.

## Components

```mermaid
flowchart TB
  subgraph host [Linux host or cluster node]
    tun["/dev/net/tun"]
    sysctl["sysctl + iptables/UFW"]
    state["Tailscale state"]
    ts["container remote-tools-tailscale"]
    ts --> tun
    ts --> state
    netprep["ensure-exit-node-networking.sh"] --> sysctl
  end
  tailnet[Tailnet / coordination] <--> ts
  clients[Other devices] --> tailnet
```

| Piece | Docker / systemd | Kubernetes |
|-------|------------------|------------|
| Image | `ghcr.io/brianlechthaler/remote-tools:latest` | same |
| Network | `network_mode: host` | `hostNetwork: true` |
| Identity | Docker volume `remote-tools-tailscale-state` | hostPath `/var/lib/remote-tools/tailscale` |
| Auth | `/etc/remote-tools/env` | Secret `remote-tools-auth` |
| Flags | compose `TS_EXTRA_ARGS` | ConfigMap `remote-tools-config` |
| ExtraArgs re-apply | `apply-ts-extra-args.sh` via docker exec | `apply-ts-extra-args-local.sh` in the image |
| Host NAT / firewall | `ensure-exit-node-networking.sh` as root | initContainer + watchdog sidecar (privileged) |

## Redundancy

```mermaid
flowchart LR
  subgraph docker [Docker host]
    d1["compose restart: unless-stopped"]
    d2["remote-tools.service"]
    d3["health timer 5 min"]
    d4["6 restarts / hour"]
  end
  subgraph k8s [Kubernetes]
    k1["kubelet + probes"]
    k2["DaemonSet or Deployment"]
    k3["CronJob health 5 min"]
    k4["same rate limit"]
  end
```

| Layer | Docker / systemd | Kubernetes |
|-------|------------------|------------|
| Runtime restart | `restart: unless-stopped` | kubelet restarts + probes |
| Supervisor | `remote-tools.service` (`Restart=on-failure`) | DaemonSet / Deployment |
| Watchdog | `remote-tools-health.timer` (5 min) | CronJob + networking sidecar |
| Rate limit | 6 restarts / hour | same (`k8s-healthcheck.sh`) |
| State | Docker volume | hostPath `/var/lib/remote-tools/tailscale` |
| Updates | git pull + `docker pull` every 6h | CronJob `rollout restart` + `imagePullPolicy: Always` |

## Why ExtraArgs are re-applied

The Tailscale image uses `TS_AUTH_ONCE=true`. After a node is already authenticated, containerboot runs `tailscale set` **without** `TS_EXTRA_ARGS`, so `--advertise-exit-node` would not stick across upgrades.

`start.sh` / `update.sh` / `healthcheck.sh` (and the Kubernetes health CronJob) call `tailscale set` then `tailscale up` with those flags. Exit-node mode is confirmed via `AdvertiseRoutes` containing `0.0.0.0/0` and `::/0`, not a fictional `AdvertiseExitNode` prefs field.

## Boot path (host)

```mermaid
sequenceDiagram
  participant systemd
  participant start as start.sh
  participant net as ensure-exit-node-networking.sh
  participant compose as docker compose
  participant apply as apply-ts-extra-args.sh
  systemd->>start: ExecStart
  start->>start: wait for Docker, TUN
  start->>net: sysctl, firewall, MASQUERADE
  start->>compose: up -d
  start->>apply: tailscale set + up
  start->>net: re-assert after tailscale0 exists
```

## Related

- [Exit node](features/exit-node.md)
- [Health watchdog](features/health-watchdog.md)
- [Auto-update](features/auto-update.md)
- [Kubernetes](features/kubernetes.md)
- [Container image](features/container-image.md)
