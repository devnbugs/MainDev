#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  TeamDev X Terminal — Entrypoint
#  Applies sysctl tuning then starts the terminal server.
#
#  Cloudflare Mesh runs as a separate sidecar container (see
#  docker-compose.yml).  This container shares the mesh's network namespace
#  so all traffic flows through the Cloudflare tunnel automatically — no
#  WARP install or daemon needed here.
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

# ── 2. Exec the terminal server (PID 1) ────────────────────────────────────
log "starting terminal_server.py on port ${PORT:-7681}…"
exec python3 terminal_server.py
