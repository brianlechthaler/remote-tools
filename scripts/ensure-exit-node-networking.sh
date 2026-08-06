#!/usr/bin/env bash
# Prepare the host so Tailscale can forward and SNAT exit-node traffic.
#
# IP forwarding alone is not enough on many Ubuntu/Debian hosts: UFW/firewalld
# default-deny FORWARD, and strict rp_filter can drop forwarded packets. Tailscale
# normally installs mark-based MASQUERADE rules, but host firewalls and Docker's
# iptables ownership often leave exit-node clients with blackholed internet
# (DNS may still resolve locally while ping/HTTPS time out).
#
# Invoked by start.sh / install.sh / update.sh / healthcheck.sh as root.
set -euo pipefail

LOG_TAG="${LOG_TAG:-remote-tools}"
SYSCTL_CONF="${SYSCTL_CONF:-/etc/sysctl.d/99-remote-tools-tailscale.conf}"

log() {
  echo "[$(date -Is)] $*"
  logger -t "${LOG_TAG}" "$*" 2>/dev/null || true
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "ERROR: ensure-exit-node-networking.sh must run as root"
    return 1
  fi
}

# Persist and apply the sysctls Tailscale documents for exit nodes, plus loose
# rp_filter (strict mode breaks forwarding on GCE and similar images).
ensure_sysctl() {
  cat > "${SYSCTL_CONF}" <<'EOF'
# Required for Tailscale exit node mode (managed by remote-tools)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
# Loose reverse-path filter: strict (1) drops forwarded exit-node traffic.
# See https://github.com/tailscale/tailscale/issues/3310
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.src_valid_mark = 1
EOF
  if ! sysctl -p "${SYSCTL_CONF}" >/dev/null; then
    log "ERROR: failed to apply exit-node sysctl from ${SYSCTL_CONF}"
    return 1
  fi
  log "exit-node sysctl applied (ip_forward, ipv6 forwarding, rp_filter=2)"
}

wan_iface() {
  # Prefer the interface used for public IPv4; fall back to default route.
  local iface
  iface="$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true)"
  if [[ -z "${iface}" ]]; then
    iface="$(ip -4 -o route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true)"
  fi
  printf '%s' "${iface}"
}

# firewalld: Tailscale docs recommend enabling masquerade as a workaround.
ensure_firewalld() {
  if ! command -v firewall-cmd >/dev/null; then
    return 0
  fi
  if ! systemctl is-active --quiet firewalld 2>/dev/null; then
    return 0
  fi

  if firewall-cmd --query-masquerade >/dev/null 2>&1; then
    log "firewalld masquerade already enabled"
  else
    if firewall-cmd --permanent --add-masquerade >/dev/null 2>&1 \
      && firewall-cmd --reload >/dev/null 2>&1; then
      log "enabled firewalld masquerade for exit-node NAT"
    else
      log "WARNING: failed to enable firewalld masquerade"
    fi
  fi
}

# UFW often denies forwarded CGNAT traffic even when Tailscale is up.
ensure_ufw() {
  if ! command -v ufw >/dev/null; then
    return 0
  fi
  if ! ufw status 2>/dev/null | grep -qiE '^Status:\s*active'; then
    return 0
  fi

  local wan
  wan="$(wan_iface)"

  # Allow traffic on the Tailscale interface itself.
  ufw allow in on tailscale0 >/dev/null 2>&1 || true
  ufw allow out on tailscale0 >/dev/null 2>&1 || true

  # Permit routed exit-node traffic tailscale0 → WAN without opening FORWARD globally.
  if [[ -n "${wan}" ]]; then
    ufw route allow in on tailscale0 out on "${wan}" >/dev/null 2>&1 || true
    ufw route allow in on "${wan}" out on tailscale0 >/dev/null 2>&1 || true
    log "ufw route allow configured for tailscale0 <-> ${wan}"
  else
    log "WARNING: could not detect WAN iface; skipped ufw route allow"
  fi
}

iptables_have() {
  local table="$1"
  shift
  if [[ "${table}" == "filter" ]]; then
    iptables -C "$@" >/dev/null 2>&1
  else
    iptables -t "${table}" -C "$@" >/dev/null 2>&1
  fi
}

ip6tables_have() {
  local table="$1"
  shift
  command -v ip6tables >/dev/null || return 1
  if [[ "${table}" == "filter" ]]; then
    ip6tables -C "$@" >/dev/null 2>&1
  else
    ip6tables -t "${table}" -C "$@" >/dev/null 2>&1
  fi
}

# Tailscale installs mark-based MASQUERADE in ts-postrouting. When that chain is
# missing or defeated (UFW/Docker/firewalld), exit-node clients blackhole. Add an
# idempotent CGNAT-sourced fallback that does not depend on packet marks.
ensure_nat_fallback() {
  if ! command -v iptables >/dev/null; then
    log "WARNING: iptables not found; cannot ensure NAT fallback"
    return 0
  fi

  if iptables_have nat POSTROUTING -s 100.64.0.0/10 ! -o tailscale0 -j MASQUERADE; then
    log "IPv4 CGNAT MASQUERADE fallback already present"
  else
    iptables -t nat -A POSTROUTING -s 100.64.0.0/10 ! -o tailscale0 -j MASQUERADE
    log "added IPv4 CGNAT MASQUERADE fallback for exit-node traffic"
  fi

  if iptables_have filter FORWARD -i tailscale0 -j ACCEPT; then
    :
  else
    iptables -I FORWARD 1 -i tailscale0 -j ACCEPT
    log "added FORWARD ACCEPT for -i tailscale0"
  fi

  if iptables_have filter FORWARD -o tailscale0 -j ACCEPT; then
    :
  else
    iptables -I FORWARD 1 -o tailscale0 -j ACCEPT
    log "added FORWARD ACCEPT for -o tailscale0"
  fi

  if command -v ip6tables >/dev/null; then
    # Tailscale IPv6 unique local prefix used for CGNAT6.
    if ip6tables_have nat POSTROUTING -s fd7a:115c:a1e0::/48 ! -o tailscale0 -j MASQUERADE; then
      :
    else
      if ip6tables -t nat -A POSTROUTING -s fd7a:115c:a1e0::/48 ! -o tailscale0 -j MASQUERADE 2>/dev/null; then
        log "added IPv6 CGNAT MASQUERADE fallback for exit-node traffic"
      else
        log "WARNING: could not add IPv6 MASQUERADE fallback (ip6tables nat unavailable?)"
      fi
    fi
  fi
}

main() {
  require_root
  ensure_sysctl
  ensure_firewalld
  ensure_ufw
  ensure_nat_fallback
}

main "$@"
