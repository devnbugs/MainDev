FROM ubuntu:24.04

LABEL maintainer="@MR_ARMAN_08"
LABEL org.opencontainers.image.title="TeamDev X Terminal"
LABEL org.opencontainers.image.description="TeamDev Terminal – Root + ubuntu + Cloudflare WARP mesh"
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
        # ── Cloudflare Mesh (in-image connector) ──
        dbus dbus-x11 \
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

# ── 3. Cloudflare Mesh connector (in-image) ───────────────────────────────
#  Installs the cloudflare-warp package so the Mesh connector can run
#  directly inside this container — no sidecar needed.  Works on
#  single-container platforms like Render, Railway, Fly.io, etc.
#  The connector is registered at runtime via MESH_NODE_TOKEN in
#  entrypoint.sh.
RUN curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
        gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ noble main" | \
        tee /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends cloudflare-warp && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

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
# Cloudflare Mesh connector runs in-image via cloudflare-warp package.
# Set MESH_NODE_TOKEN at deploy time to register the connector.
# The entrypoint starts warp-svc, registers with the token, and connects.
# If MESH_NODE_TOKEN is empty or warp-svc fails (e.g. no NET_ADMIN),
# the terminal still works — mesh is best-effort.

VOLUME ["/tmp/teamdev_uploads", "/root/.bash_history_dir", "/var/lib/cloudflare-warp"]

STOPSIGNAL SIGINT

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1

EXPOSE ${PORT}

# Entrypoint handles: sysctl → warp-svc → connector register → connect → app
ENTRYPOINT ["./entrypoint.sh"]
