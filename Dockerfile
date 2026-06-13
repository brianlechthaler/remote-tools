FROM tailscale/tailscale:stable

LABEL org.opencontainers.image.source=https://github.com/brianlechthaler/remote-tools
LABEL org.opencontainers.image.description="Tailscale remote access for unattended hosts"

ENV TS_STATE_DIR=/var/lib/tailscale \
    TS_AUTH_ONCE=true \
    TS_USERSPACE=false \
    TS_ENABLE_HEALTH_CHECK=true \
    TS_LOCAL_ADDR_PORT=127.0.0.1:9002
