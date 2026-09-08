#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  TeamDev X Terminal — Entrypoint
#  Applies sysctl tuning, starts Cloudflare Tunnel (if token provided),
#  then starts the terminal server.
#
#  Cloudflare Tunnel runs in-image via the cloudflared binary.
#  Set TUNNEL_TOKEN to start the tunnel at startup.
#  If no token, the terminal still works normally.
# ════════════════════════════════════════════════════════════════════════
set -e

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] ⚠ $*" >&2; }

# ── 1. Apply sysctl tuning (best-effort, may not work without privileges) ─
log "applying sysctl tuning…"
sysctl -q --system 2>/dev/null || true
sysctl -q net.ipv4.ip_forward=1          2>/dev/null || warn "cannot set net.ipv4.ip_forward (needs NET_ADMIN)"
sysctl -q net.ipv6.conf.all.forwarding=1  2>/dev/null || true
sysctl -q net.ipv6.conf.all.accept_ra=2   2>/dev/null || true

# ── 1b. Start D-Bus (required by systemd / systemctl) ─────────────────────
if command -v dbus-daemon >/dev/null 2>&1; then
  log "starting D-Bus system bus…"
  mkdir -p /run/dbus
  if [ ! -f /run/dbus/pid ]; then
    dbus-daemon --system --fork 2>/dev/null || warn "dbus-daemon failed to start"
  fi
fi

# ── 1c. Start systemd (best-effort, for systemctl support) ─────────────────
#  In a container, systemd can't be PID 1 (python3 is).  We start it as a
#  user process so `systemctl` commands work from the terminal.  This needs
#  --privileged or --cap-add SYS_ADMIN at runtime for full functionality.
if [ -x /lib/systemd/systemd ] || [ -x /usr/lib/systemd/systemd ]; then
  SYSTEMD_BIN=$(command -v systemd 2>/dev/null || echo /lib/systemd/systemd)
  log "starting systemd (best-effort, for systemctl support)…"
  # Mount cgroup v2 if not already mounted (needs SYS_ADMIN)
  if [ ! -f /sys/fs/cgroup/cgroup.controllers ] 2>/dev/null; then
    mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || warn "cannot mount cgroup2 (needs SYS_ADMIN)"
  fi
  # Start systemd in user mode as a background process
  nohup "$SYSTEMD_BIN" --user >/var/log/systemd.log 2>&1 &
  SYSTEMD_PID=$!
  sleep 2
  if kill -0 "$SYSTEMD_PID" 2>/dev/null; then
    log "✓ systemd started (PID $SYSTEMD_PID) — systemctl available"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/0/bus"
    export XDG_RUNTIME_DIR="/run/user/0"
    mkdir -p /run/user/0 2>/dev/null || true
  else
    warn "systemd exited early — systemctl may not work (needs --privileged or --cap-add SYS_ADMIN)"
    warn "systemd log: $(tail -3 /var/log/systemd.log 2>/dev/null || echo 'no logs')"
  fi
else
  warn "systemd binary not found — systemctl not available"
fi

# ── 2. Cloudflare Tunnel (cloudflared, best-effort) ────────────────────────
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"

if [ -n "$TUNNEL_TOKEN" ] && [ -x /usr/local/bin/cloudflared ]; then
  log "starting Cloudflare Tunnel…"

  # Run cloudflared in the background — it connects to Cloudflare's edge
  # and routes traffic to localhost:PORT via the tunnel config in your
  # Cloudflare dashboard (Quick Tunnel or named tunnel with ingress rules).
  nohup cloudflared tunnel --no-autoupdate \
    --metrics 127.0.0.1:38000 \
    run --token "$TUNNEL_TOKEN" \
    >/var/log/cloudflared.log 2>&1 &
  CF_PID=$!
  log "cloudflared started (PID $CF_PID)"

  # Wait briefly and check it's still alive
  sleep 3
  if kill -0 "$CF_PID" 2>/dev/null; then
    log "✓ Cloudflare Tunnel is running"
  else
    warn "cloudflared exited early — check TUNNEL_TOKEN and logs"
    warn "cloudflared log: $(tail -5 /var/log/cloudflared.log 2>/dev/null || echo 'no logs')"
  fi
else
  if [ -z "$TUNNEL_TOKEN" ]; then
    log "TUNNEL_TOKEN not set — skipping Cloudflare Tunnel"
  else
    warn "cloudflared binary not found — Cloudflare Tunnel not available"
  fi
fi

# ── 3. Exec the terminal server (PID 1) ────────────────────────────────────
log "starting terminal_server.py on port ${PORT:-8080}…"
exec python3 terminal_server.py
