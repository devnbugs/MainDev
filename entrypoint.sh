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
