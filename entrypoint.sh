#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  TeamDev X Terminal — Entrypoint
#  Starts Cloudflare WARP connector (if token present) then the terminal.
# ════════════════════════════════════════════════════════════════════════
set -e

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] ⚠ $*" >&2; }

# ── 1. Apply sysctl tuning (needs --privileged or NET_ADMIN + SYS_ADMIN) ──
if [ -w /proc/sys ]; then
    log "applying sysctl tuning…"
    sysctl -q --system 2>/dev/null || true
    # WARP connector forwarding requirements
    sysctl -q net.ipv4.ip_forward=1            2>/dev/null || true
    sysctl -q net.ipv6.conf.all.forwarding=1   2>/dev/null || true
    sysctl -q net.ipv6.conf.all.accept_ra=2    2>/dev/null || true
else
    warn "/proc/sys not writable — run with --privileged or cap-add NET_ADMIN,SYS_ADMIN"
fi

# ── 2. Cloudflare WARP connector (runtime only) ───────────────────────────
#  The connector token is base64 JSON.  Pass it via:
#    docker run -e WARP_TOKEN="eyJ…" …
#  or set it in your platform's env vars.  Without a token WARP is skipped
#  and the terminal starts normally.
WARP_TOKEN="${WARP_TOKEN:-}"

if [ -n "$WARP_TOKEN" ] && command -v warp-cli >/dev/null 2>&1; then
    log "WARP token detected — initialising Cloudflare mesh connector…"

    # 2a. Start the WARP daemon (warp-svc) in the background
    if command -v warp-svc >/dev/null 2>&1; then
        log "starting warp-svc daemon…"
        warp-svc >/var/log/warp-svc.log 2>&1 &
        echo $! > /var/run/warp-svc.pid
        # Give the daemon a moment to open its control socket
        for i in $(seq 1 20); do
            if warp-cli status >/dev/null 2>&1; then break; fi
            sleep 0.5
        done
    fi

    # 2b. Register the connector with the provided token
    log "registering connector…"
    if warp-cli connector new "$WARP_TOKEN" 2>/dev/null; then
        log "connector registered ✓"
    else
        # Token may already be registered from a previous container start
        warn "connector new failed (may already be registered) — continuing"
    fi

    # 2c. Connect
    log "connecting to Cloudflare mesh…"
    warp-cli connect 2>/dev/null || warn "warp-cli connect returned non-zero"

    # 2d. Wait until status is Connected (max ~30 s)
    for i in $(seq 1 30); do
        STATUS="$(warp-cli status 2>/dev/null | head -1 || true)"
        case "$STATUS" in
            *Connected*) log "WARP connected ✓  ($STATUS)"; break ;;
        esac
        sleep 1
    done
    [ "$i" = 30 ] && warn "WARP did not reach Connected state in 30 s — continuing anyway"

elif [ -n "$WARP_TOKEN" ]; then
    warn "WARP_TOKEN set but warp-cli not found — skipping mesh"
else
    log "no WARP_TOKEN — starting terminal without Cloudflare mesh"
fi

# ── 3. Exec the terminal server (PID 1) ────────────────────────────────────
log "starting terminal_server.py on port ${PORT:-7681}…"
exec python3 terminal_server.py
