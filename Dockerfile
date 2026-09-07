FROM ubuntu:24.04

LABEL maintainer="@MR_ARMAN_08"
LABEL org.opencontainers.image.title="TeamDev X Terminal"
LABEL org.opencontainers.image.description="TeamDev Terminal – Root + ubuntu + Cloudflare Tunnel"
LABEL org.opencontainers.image.url="https://t.me/Team_X_Og"
LABEL org.opencontainers.image.version="2.5.0"

# ── System-optimised environment ──────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    TERM=xterm-256color \
    COLORTERM=truecolor \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=7681 \
    KEEPALIVE_URL="" \
    SHELL=/bin/bash \
    HOME=/root \
    TZ=UTC \
    # ── Performance / resource tuning ──
    MALLOC_ARENA_MAX=2 \
    PYTHONHASHSEED=0

# ── 1. Base packages + system tooling ────────────────────────────────────
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        # Core utils
        bash curl wget git vim nano htop procps \
        net-tools iputils-ping dnsutils \
        build-essential gcc g++ make \
        python3 python3-pip python3-venv python3-dev \
        zip unzip tar gzip bzip2 xz-utils \
        locales sudo openssh-client \
        ca-certificates gnupg lsb-release \
        tree jq tmux less file \
        # ── System-optimisation additions ──
        tzdata \
        iproute2 iptables ipset \
        conntrack \
        lsof strace \
        lvm2 \
        e2fsprogs \
        xfsprogs \
        util-linux \
    && locale-gen en_US.UTF-8 \
    && update-locale LANG=en_US.UTF-8 \
    && ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo "${TZ}" > /etc/timezone \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ── 2. Kernel / network tuning (persisted for runtime sysctl --system) ───
RUN printf 'net.ipv4.ip_forward = 1\n\
net.ipv6.conf.all.forwarding = 1\n\
net.ipv6.conf.all.accept_ra = 2\n\
net.core.rmem_max = 16777216\n\
net.core.wmem_max = 16777216\n\
net.ipv4.tcp_rfc1337 = 1\n\
net.ipv4.tcp_fastopen = 3\n\
net.ipv4.tcp_slow_start_after_idle = 0\n\
net.ipv4.tcp_mtu_probing = 1\n' > /etc/sysctl.d/99-zzz-network-tuning.conf

# ── 3. Cloudflare Tunnel (cloudflared) ───────────────────────────────────
#  Installs the cloudflared binary so the terminal can expose itself via
#  a Cloudflare Tunnel.  Set TUNNEL_TOKEN at deploy time and the entrypoint
#  starts `cloudflared tunnel run` automatically.
#  Docs: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
RUN curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
        -o /usr/local/bin/cloudflared && \
    chmod +x /usr/local/bin/cloudflared

# ── 4. Railway CLI (optional, best-effort) ───────────────────────────────
RUN curl -fsSL https://railway.app/install.sh | sh 2>/dev/null || true

# ── 5. App layer ─────────────────────────────────────────────────────────
WORKDIR /app

COPY entrypoint.sh              ./entrypoint.sh
COPY terminal_server.py         ./terminal_server.py
COPY teamdev_terminal_ui.html   ./teamdev_terminal_ui.html

RUN chmod +x entrypoint.sh \
    && mkdir -p /tmp/teamdev_uploads \
    && chmod 777 /tmp/teamdev_uploads

# ── 6. Sudoers (sandbox convenience) ─────────────────────────────────────
RUN echo "root ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    echo "teamdev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers 2>/dev/null || true

# ── 7. Runtime config ────────────────────────────────────────────────────
# Cloudflare Tunnel runs in-image via the cloudflared binary.
# Set TUNNEL_TOKEN at deploy time to start the tunnel.
# If TUNNEL_TOKEN is empty, cloudflared is skipped — terminal works normally.

VOLUME ["/tmp/teamdev_uploads", "/root/.bash_history_dir", "/root/.cloudflared"]

STOPSIGNAL SIGINT

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1

EXPOSE ${PORT}

# Entrypoint handles: sysctl → cloudflared tunnel → app
ENTRYPOINT ["./entrypoint.sh"]
