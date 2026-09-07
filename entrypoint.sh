#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  TeamDev X Terminal — Entrypoint
#  Applies sysctl tuning, starts Cloudflare Mesh connector (if token
#  provided), then starts the terminal server.
#
#  Cloudflare Mesh runs in-image via the cloudflare-warp package.
#  Set MESH_NODE_TOKEN to register the connector at startup.
#  If no token or warp-svc fails, the terminal still works normally.
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

# ── 2. Cloudflare Mesh connector (in-image, best-effort) ───────────────────
MESH_TOKEN="${MESH_NODE_TOKEN:-}"

if [ -n "$MESH_TOKEN" ] && [ -x /usr/bin/warp-svc ]; then
  log "starting Cloudflare Mesh connector…"

  # D-Bus is required by warp-svc
  if command -v dbus-daemon >/dev/null 2>&1; then
    log "starting D-Bus…"
    mkdir -p /run/dbus
    dbus-daemon --system --fork 2>/dev/null || warn "dbus-daemon failed to start"
  fi

  # Start warp-svc in the background
  warp-svc >/var/log/warp-svc.log 2>&1 &
  WARP_PID=$!
  log "warp-svc started (PID $WARP_PID)"

  # Wait for warp-svc to be ready
  for i in $(seq 1 15); do
    if warp-cli --accept-tos status >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  # Register the connector with the mesh token
  log "registering mesh connector…"
  if warp-cli --accept-tos connector new "$MESH_TOKEN" 2>/dev/null; then
    log "mesh connector registered"
  else
    # If already registered, just connect
    warn "connector new failed — may already be registered, trying connect…"
  fi

  warp-cli --accept-tos connect 2>/dev/null || warn "warp-cli connect failed"

  # Verify status
  sleep 2
  if warp-cli --accept-tos status 2>/dev/null | grep -qi "connected\|connecting"; then
    log "✓ Cloudflare Mesh is active"
  else
    warn "mesh connector not connected — check MESH_NODE_TOKEN and logs"
    warn "warp-svc log: $(tail -3 /var/log/warp-svc.log 2>/dev/null || echo 'no logs')"
  fi
else
  if [ -z "$MESH_TOKEN" ]; then
    log "MESH_NODE_TOKEN not set — skipping Cloudflare Mesh"
  else
    warn "warp-svc not found — Cloudflare Mesh not available"
  fi
fi

# ── 3. Exec the terminal server (PID 1) ────────────────────────────────────
log "starting terminal_server.py on port ${PORT:-7681}…"
exec python3 terminal_server.py
