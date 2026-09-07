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
        policykit-1 \
        dbus \
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

# ── 2. Cloudflare WARP repository + client (mesh connector) ──────────────
RUN curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
      | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
    && . /etc/os-release \
    && echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${VERSION_CODENAME} main" \
       > /etc/apt/sources.list.d/cloudflare-client.list \
    && apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends cloudflare-warp \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── 3. Kernel / network tuning (persisted for runtime sysctl --system) ───
RUN printf 'net.ipv4.ip_forward = 1\n\
net.ipv6.conf.all.forwarding = 1\n\
net.ipv6.conf.all.accept_ra = 2\n\
net.core.rmem_max = 16777216\n\
net.core.wmem_max = 16777216\n\
net.ipv4.tcp_rfc1337 = 1\n\
net.ipv4.tcp_fastopen = 3\n\
net.ipv4.tcp_slow_start_after_idle = 0\n\
net.ipv4.tcp_mtu_probing = 1\n' > /etc/sysctl.d/99-zzz-cloudflare-warp-connector.conf

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
# WARP connector token — set at deploy time, NOT baked into the image.
# Pass via:  docker run -e WARP_TOKEN="eyJ…"  (or platform env var)
ENV WARP_TOKEN="eyJhIjoiMzk0M2Q0ZWMxOGM1MzkxZmJiZTkxNThhNWQ2MjliNTUiLCJ0IjoiYTU5OGQ4MWEtN2E2OS00M2FlLWJjNDItN2ZjNmI3MjU1ZDk4IiwicyI6InlhNUVIT3J1MEUzaEQ2RjBHMVA4b3ZBQlU2V0hMZHZQMlYvWmJFQWhjNUE9In0="

VOLUME ["/tmp/teamdev_uploads", "/root/.bash_history_dir"]

STOPSIGNAL SIGINT

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1

EXPOSE ${PORT}

# Entrypoint handles: sysctl → WARP daemon → connector register → connect → app
ENTRYPOINT ["./entrypoint.sh"]
