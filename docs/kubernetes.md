# Kubernetes deployment

Run **remote-tools** on Kubernetes with the same features as the Docker + systemd host install: Tailscale on the node network, exit-node advertisement, host NAT/firewall prep, health watchdog, and periodic image refresh.

## Feature parity

| Feature | Docker / systemd | Kubernetes |
|---------|------------------|------------|
| Node / host networking | `network_mode: host` | `hostNetwork: true` |
| TUN + caps | `/dev/net/tun`, `NET_ADMIN` | hostPath + capabilities |
| Exit node flags | `TS_EXTRA_ARGS` | ConfigMap `TS_EXTRA_ARGS` |
| Auth key | `/etc/remote-tools/env` | Secret `remote-tools-auth` |
| Persistent identity | Docker volume | hostPath `/var/lib/remote-tools/tailscale` (`TS_KUBE_SECRET=""`) |
| Boot / restart | systemd + Docker restart | DaemonSet / Deployment + kubelet |
| Host NAT / sysctl / firewall | `ensure-exit-node-networking.sh` | initContainer + watchdog sidecar |
| Re-apply `--advertise-exit-node` | `apply-ts-extra-args.sh` | `apply-ts-extra-args-local.sh` via CronJob |
| Health watchdog (5m) | `remote-tools-health.timer` | probes + CronJob `remote-tools-health` |
| Restart rate limit | 6 / hour | same, in `k8s-healthcheck.sh` |
| Auto-update (6h) | `remote-tools-update.timer` | CronJob `remote-tools-update` (rollout restart + `imagePullPolicy: Always`) |

## Prerequisites

- Kubernetes 1.27+ (tested with kind and upstream kubeconform schemas)
- `kubectl` and preferably `kustomize`
- Nodes that allow:
  - `hostNetwork: true`
  - privileged init/watchdog containers (sysctl + iptables)
  - hostPath mounts for `/dev/net/tun` and `/var/lib/remote-tools/tailscale`
- A **reusable, non-ephemeral** Tailscale auth key from [Tailscale admin → Keys](https://login.tailscale.com/admin/settings/keys)

> **Note:** This stack is for making **cluster nodes** reachable on your tailnet (SSH to the node, exit-node traffic via the node WAN). It is not the Tailscale Kubernetes Operator (which proxies cluster Services).

## Quick install (DaemonSet — every node)

```bash
cp k8s/secret.env.example k8s/secret.env
nano k8s/secret.env   # set TS_AUTHKEY=tskey-auth-...

./scripts/k8s-install.sh --overlay daemonset
```

Or apply with kustomize directly after creating the secret:

```bash
kubectl create namespace remote-tools
kubectl -n remote-tools create secret generic remote-tools-auth \
  --from-literal=TS_AUTHKEY=tskey-auth-...

kubectl apply -k k8s/overlays/daemonset
```

## Single-node exit node

Use this when only one labeled node should join the tailnet / advertise an exit node:

```bash
kubectl label node <node-name> remote-tools/exit-node=true
./scripts/k8s-install.sh --overlay single-node
```

The single-node overlay **deletes** the DaemonSet and installs a `replicas: 1` Deployment with `nodeSelector: remote-tools/exit-node=true`.

## Configuration

### Secret

| Key | Required | Description |
|-----|----------|-------------|
| `TS_AUTHKEY` | Yes | Tailscale auth key (`tskey-auth-...`) |

### ConfigMap `remote-tools-config`

| Key | Default | Description |
|-----|---------|-------------|
| `TS_HOSTNAME` | empty (uses node name) | Name in the Tailscale admin console |
| `TS_EXTRA_ARGS` | `--accept-routes --advertise-exit-node` | Flags re-applied via `tailscale set` + `up` |
| `TS_USERSPACE` | `false` | Kernel TUN mode (required for exit node) |
| `WATCHDOG_INTERVAL_SECONDS` | `300` | Sidecar networking reassert interval |
| `MAX_RESTARTS_PER_HOUR` | `6` | Health CronJob rate limit |

Edit live values:

```bash
kubectl -n remote-tools edit configmap remote-tools-config
kubectl -n remote-tools rollout restart daemonset/remote-tools
```

**SSH access:** Connect with OpenSSH to the **node** over the tailnet (`ssh user@node-tailscale-name`). Do not add `--ssh` to `TS_EXTRA_ARGS` — Tailscale SSH inside the container cannot see host users.

**Exit node approval:** After the node appears online, approve it in the admin console: **Machines → … → Edit route settings → Use as exit node**.

## Operations

```bash
# Status
kubectl -n remote-tools get pods,ds,cronjobs -o wide
kubectl -n remote-tools logs -l app.kubernetes.io/component=tailscale -c tailscale -f

# Tailscale status inside a pod
POD=$(kubectl -n remote-tools get pod -l app.kubernetes.io/component=tailscale -o jsonpath='{.items[0].metadata.name}')
kubectl -n remote-tools exec "$POD" -c tailscale -- tailscale status

# Manual health / update (same scripts the CronJobs run)
kubectl -n remote-tools create job --from=cronjob/remote-tools-health health-manual
kubectl -n remote-tools create job --from=cronjob/remote-tools-update update-manual

# Host-side helpers (from a machine with kubeconfig)
./scripts/k8s-healthcheck.sh
./scripts/k8s-update.sh
```

## Layout

```
k8s/
  base/                  # Namespace, RBAC, ConfigMap, Secret placeholder,
                         # DaemonSet, CronJobs, scripts ConfigMap generator
    scripts/             # Copies mounted into pods (must match scripts/*)
  overlays/
    daemonset/           # Default: one pod per node
    single-node/         # Deployment pinned to remote-tools/exit-node=true
  secret.env.example
scripts/
  k8s-install.sh
  k8s-healthcheck.sh
  k8s-update.sh
  apply-ts-extra-args-local.sh
  test-k8s.sh
```

When you edit `scripts/ensure-exit-node-networking.sh`, `apply-ts-extra-args-local.sh`,
`k8s-healthcheck.sh`, or `k8s-update.sh`, copy them into `k8s/base/scripts/` as well
(kustomize cannot load files outside `k8s/base/`). `./scripts/test-k8s.sh` fails if they drift.

## How the pieces fit

1. **initContainer `exit-node-networking`** — privileged Alpine pod that runs `ensure-exit-node-networking.sh` against the node (sysctl, UFW/firewalld when present, CGNAT MASQUERADE fallback).
2. **container `tailscale`** — `ghcr.io/brianlechthaler/remote-tools` with `hostNetwork`, TUN, and Capabilities.
3. **container `watchdog`** — every 5 minutes re-asserts host networking (UFW reloads / Docker iptables drift).
4. **CronJob `remote-tools-health`** — every 5 minutes execs into pods, re-applies ExtraArgs (so `--advertise-exit-node` sticks under `TS_AUTH_ONCE`), and rate-limits pod deletes when unhealthy.
5. **CronJob `remote-tools-update`** — every 6 hours `rollout restart` so `imagePullPolicy: Always` picks up GHCR `:latest`.

## Testing

Static + kind integration (no real Tailscale key required):

```bash
./scripts/test-k8s.sh
```

Useful env vars:

| Variable | Default | Meaning |
|----------|---------|---------|
| `KEEP_CLUSTER` | `0` | Set `1` to leave the kind/kwok cluster up |
| `SKIP_CLUSTER` | `0` | Set `1` for manifest/image checks only |
| `CLUSTER_PROVIDER` | `auto` | `kind`, `kwok`, `docker`, or `auto` (prefer kind; outside CI fall back to Docker runtime simulation) |
| `WAIT_SECONDS` | `180` | Pod / container readiness timeout |

CI runs the same script via [`.github/workflows/test-k8s.yml`](../.github/workflows/test-k8s.yml) and requires **kind** on GitHub-hosted runners.

## RBAC

The `remote-tools` ServiceAccount can list/get/delete pods, create pods/exec, and patch DaemonSets/Deployments in the `remote-tools` namespace — enough for the health and update CronJobs. It cannot mutate other namespaces.

Tailscale workload pods set `automountServiceAccountToken: false` and `TS_KUBE_SECRET=""` so containerboot does **not** try to store node state in a Kubernetes Secret (identity stays on the node hostPath, matching Docker).

## Security notes

- Pods use **host networking** and a **privileged** networking sidecar/init container. Treat the namespace as sensitive; restrict who can edit its ConfigMaps/Secrets.
- Prefer short-lived or tag-scoped auth keys when your tailnet ACLs allow it.
- Do not commit `k8s/secret.env`.

## Uninstall

```bash
kubectl delete -k k8s/overlays/daemonset
# or: kubectl delete namespace remote-tools
```

Node hostPath state (Tailscale identity) remains under `/var/lib/remote-tools/tailscale` until removed manually.


## CI notes

The [Test Kubernetes](../.github/workflows/test-k8s.yml) workflow requires GitHub-hosted runners and sets `CLUSTER_PROVIDER=kind`. Re-run the workflow from the Actions tab if a run fails with a runner-acquisition error before tests start.
