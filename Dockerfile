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
        # ── Auto-install build tool prerequisites ──
        autoconf automake autotools-dev \
        pkg-config cmake ninja-build \
        libssl-dev libffi-dev \
        libsqlite3-dev libpq-dev libmysqlclient-dev \
        libreadline-dev libncursesw5-dev \
        libbz2-dev liblzma-dev \
        libxml2-dev libxslt1-dev \
        zlib1g-dev libgdbm-dev \
        libexpat1-dev \
        # ── Version managers & runtime installers ──
        unzip \
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

# ── 4b. Auto-install build tools (version managers & runtimes) ────────────
#  These are installed on-demand via /usr/local/bin/install-tools.sh so the
#  image stays small.  Users run `install-tools.sh` (or individual commands)
#  from the terminal to get Node.js, Rust, Go, Deno, Bun, Java, etc.
ENV NVM_DIR="/root/.nvm" \
    NVM_VERSION="v0.40.1" \
    GO_VERSION="1.23.0" \
    RUSTUP_HOME="/root/.rustup" \
    CARGO_HOME="/root/.cargo" \
    DENO_VERSION="2.0.0" \
    BUN_VERSION="1.1.30" \
    PYENV_ROOT="/root/.pyenv"

RUN curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash && \
    curl -fsSL https://raw.githubusercontent.com/pyenv/pyenv-installer/HEAD/bin/pyenv-installer | bash 2>/dev/null || true

# Create the auto-install helper script
RUN printf '#!/usr/bin/env bash\n\
set -e\n\
log() { echo "[install-tools] $*"; }\n\
\n\
# ── Node.js (via nvm) ──\n\
install_node() {\n\
  log "installing Node.js LTS via nvm…";\n\
  . "$NVM_DIR/nvm.sh";\n\
  nvm install --lts;\n\
  nvm use --lts;\n\
  log "✓ Node $(node -v) / npm $(npm -v)";\n\
}\n\
\n\
# ── Rust (via rustup) ──\n\
install_rust() {\n\
  log "installing Rust via rustup…";\n\
  curl -fsSL https://sh.rustup.rs | sh -s -- -y;\n\
  source "$CARGO_HOME/env";\n\
  log "✓ Rust $(rustc --version)";\n\
}\n\
\n\
# ── Go ──\n\
install_go() {\n\
  log "installing Go ${GO_VERSION}…";\n\
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xz;\n\
  export PATH="$PATH:/usr/local/go/bin";\n\
  echo "export PATH=\$PATH:/usr/local/go/bin" >> /root/.bashrc;\n\
  log "✓ Go $(go version)";\n\
}\n\
\n\
# ── Deno ──\n\
install_deno() {\n\
  log "installing Deno…";\n\
  curl -fsSL https://deno.land/install.sh | sh;\n\
  echo "export PATH=\$PATH:/root/.deno/bin" >> /root/.bashrc;\n\
  log "✓ Deno $(deno --version | head -1)";\n\
}\n\
\n\
# ── Bun ──\n\
install_bun() {\n\
  log "installing Bun…";\n\
  curl -fsSL https://bun.sh/install | bash;\n\
  echo "export PATH=\$PATH:/root/.bun/bin" >> /root/.bashrc;\n\
  log "✓ Bun $(bun --version)";\n\
}\n\
\n\
# ── Java (via SDKMAN) ──\n\
install_java() {\n\
  log "installing Java via SDKMAN…";\n\
  curl -fsSL "https://get.sdkman.io" | bash;\n\
  source "/root/.sdkman/bin/sdkman-init.sh";\n\
  sdk install java 17.0.13-tem;\n\
  log "✓ Java $(java -version 2>&1 | head -1)";\n\
}\n\
\n\
# ── Python versions (via pyenv) ──\n\
install_python() {\n\
  local ver="${1:-3.12.7}";\n\
  log "installing Python $ver via pyenv…";\n\
  export PATH="$PYENV_ROOT/bin:$PATH";\n\
  eval "$(pyenv init -)";\n\
  pyenv install "$ver";\n\
  pyenv global "$ver";\n\
  log "✓ Python $(python --version)";\n\
}\n\
\n\
# ── All ──\n\
install_all() {\n\
  install_node; install_rust; install_go; install_deno; install_bun; install_java;\n\
}\n\
\n\
# ── CLI ──\n\
case "${1:-all}" in\n\
  node)   install_node ;;\n\
  rust)   install_rust ;;\n\
  go)     install_go ;;\n\
  deno)   install_deno ;;\n\
  bun)    install_bun ;;\n\
  java)   install_java ;;\n\
  python) install_python "${2:-}" ;;\n\
  all)    install_all ;;\n\
  *) echo "Usage: install-tools.sh [node|rust|go|deno|bun|java|python [ver]|all]"; exit 1 ;;\n\
esac\n' > /usr/local/bin/install-tools.sh && \
    chmod +x /usr/local/bin/install-tools.sh

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

# ── 6b. Shell profile (auto-install tool paths) ───────────────────────────
RUN printf '\n\
# ── Auto-install build tools ──\n\
export NVM_DIR="/root/.nvm"\n\
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"\n\
export PYENV_ROOT="/root/.pyenv"\n\
[ -d "$PYENV_ROOT/bin" ] && export PATH="$PYENV_ROOT/bin:$PATH"\n\
[ -d "$PYENV_ROOT" ] && eval "$(pyenv init -)" 2>/dev/null\n\
export RUSTUP_HOME="/root/.rustup"\n\
export CARGO_HOME="/root/.cargo"\n\
[ -d "$CARGO_HOME/bin" ] && export PATH="$CARGO_HOME/bin:$PATH"\n\
[ -d "/usr/local/go/bin" ] && export PATH="$PATH:/usr/local/go/bin"\n\
[ -d "/root/.deno/bin" ] && export PATH="$PATH:/root/.deno/bin"\n\
[ -d "/root/.bun/bin" ] && export PATH="$PATH:/root/.bun/bin"\n\
[ -s "/root/.sdkman/bin/sdkman-init.sh" ] && source "/root/.sdkman/bin/sdkman-init.sh"\n\
# Run install-tools.sh to get Node, Rust, Go, Deno, Bun, Java, Python\n\
' >> /root/.bashrc

# ── 7. Runtime config ────────────────────────────────────────────────────
# Cloudflare Tunnel runs in-image via the cloudflared binary.
# Set TUNNEL_TOKEN at deploy time to start the tunnel.
# If TUNNEL_TOKEN is empty, cloudflared is skipped — terminal works normally.
#
# NOTE: No VOLUME instruction — some platforms (Railway) reject it.
#       Use platform-specific volume mounts instead:
#       - Railway:  Railway Volumes (dashboard)
#       - Fly.io:   fly.toml volumes
#       - Docker:   docker-compose.yml volumes

STOPSIGNAL SIGINT

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1

EXPOSE ${PORT}

# Entrypoint handles: sysctl → cloudflared tunnel → app
ENTRYPOINT ["./entrypoint.sh"]
