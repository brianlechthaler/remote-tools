FROM tailscale/tailscale:v1.98.10

LABEL org.opencontainers.image.source=https://github.com/brianlechthaler/remote-tools
LABEL org.opencontainers.image.description="Tailscale remote access for unattended hosts"

ENV TS_STATE_DIR=/var/lib/tailscale \
    TS_AUTH_ONCE=true \
    TS_USERSPACE=false \
    TS_ENABLE_HEALTH_CHECK=true \
    TS_LOCAL_ADDR_PORT=127.0.0.1:9002

# In-container helpers for Kubernetes postStart / kubectl exec watchdogs.
# Host-side Docker installs continue to use scripts/ from the git checkout.
COPY scripts/apply-ts-extra-args-local.sh /usr/local/bin/apply-ts-extra-args-local.sh
RUN chmod 755 /usr/local/bin/apply-ts-extra-args-local.sh
