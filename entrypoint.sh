#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  TeamDev X Terminal — Entrypoint
#  Starts Cloudflare WARP connector (if token present) then the terminal.
# ════════════════════════════════════════════════════════════════════════
set -e

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] ⚠ $*" >&2; }

# ── 1. Apply sysctl tuning ────────────────────────────────────────────────
#  Try direct first, then sudo (for non-root or capability-restricted envs).
apply_sysctl() {
    local key="$1" val="$2"
    if [ -w "/proc/sys" ] || [ "$(id -u)" = "0" ]; then
        sysctl -q "$key=$val" 2>/dev/null && return 0
    fi
    sudo sysctl -q "$key=$val" 2>/dev/null && return 0
    return 1
}

log "applying sysctl tuning…"
sysctl -q --system 2>/dev/null || true
apply_sysctl net.ipv4.ip_forward          1 || warn "cannot set net.ipv4.ip_forward"
apply_sysctl net.ipv6.conf.all.forwarding 1 || warn "cannot set net.ipv6.conf.all.forwarding"
apply_sysctl net.ipv6.conf.all.accept_ra  2 || warn "cannot set net.ipv6.conf.all.accept_ra"

# ── 2. Cloudflare WARP connector (runtime only) ───────────────────────────
#  The connector token is base64 JSON.  Pass it via:
#    docker run -e WARP_TOKEN="eyJ…" …
#  or set it in your platform's env vars.  Without a token WARP is skipped
#  and the terminal starts normally.
WARP_TOKEN="${WARP_TOKEN:-}"

if [ -n "$WARP_TOKEN" ] && command -v warp-cli >/dev/null 2>&1; then
    log "WARP token detected — initialising Cloudflare mesh connector…"

    # 2a. Start D-Bus (warp-svc depends on it)
    if command -v dbus-daemon >/dev/null 2>&1; then
        log "starting D-Bus system bus…"
        mkdir -p /run/dbus /var/run/dbus
        if [ ! -S /run/dbus/system_bus_socket ]; then
            dbus-daemon --system --fork 2>/dev/null || \
            dbus-daemon --system --nofork --print-address >/var/log/dbus.log 2>&1 &
            sleep 1
        fi
        log "D-Bus ready ✓"
    else
        warn "dbus-daemon not found — warp-svc may fail to start"
    fi

    # 2b. Start the WARP daemon (warp-svc) in the background
    if command -v warp-svc >/dev/null 2>&1; then
        log "starting warp-svc daemon…"
        # Kill any stale instance first
        pkill -f warp-svc 2>/dev/null || true
        sleep 0.5
        warp-svc >/var/log/warp-svc.log 2>&1 &
        echo $! > /var/run/warp-svc.pid
        log "warp-svc launched (PID $!), waiting for control socket…"

        # Accept the WARP Terms of Service (non-interactive, required before
        # any warp-cli command will work in a headless container).
        log "accepting WARP Terms of Service…"
        warp-cli --accept-tos tos accept 2>/dev/null || true

        # Give the daemon up to 15 s to open its control socket
        SVC_READY=false
        for i in $(seq 1 30); do
            if warp-cli --accept-tos status >/dev/null 2>&1; then
                SVC_READY=true
                log "warp-svc is ready ✓ (after ${i}×0.5s)"
                break
            fi
            # Check if the process died
            if ! kill -0 "$(cat /var/run/warp-svc.pid 2>/dev/null)" 2>/dev/null; then
                warn "warp-svc process died — check /var/log/warp-svc.log:"
                tail -5 /var/log/warp-svc.log 2>/dev/null | while read -r line; do warn "  $line"; done
                break
            fi
            sleep 0.5
        done
        if [ "$SVC_READY" = false ]; then
            warn "warp-svc did not become ready in 15 s — WARP mesh will not work"
        fi
    else
        warn "warp-svc not found — cannot start WARP daemon"
    fi

    # 2c. Register the connector with the provided token
    #  If a connector is already registered, tear it down first so the new
    #  token takes effect cleanly.
    log "registering connector…"
    EXISTING=$(warp-cli --accept-tos connector show 2>/dev/null || true)
    if [ -n "$EXISTING" ]; then
        log "existing connector found — tearing down…"
        warp-cli --accept-tos connector teardown 2>/dev/null || true
        sleep 1
    fi

    if warp-cli --accept-tos connector new "$WARP_TOKEN" 2>&1; then
        log "connector registered ✓"
    else
        warn "connector new failed — trying to continue with existing registration"
    fi

    # 2d. Connect (with retries)
    log "connecting to Cloudflare mesh…"
    CONNECTED=false
    for attempt in 1 2 3; do
        if warp-cli --accept-tos connect 2>&1; then
            log "connect command succeeded (attempt $attempt)"
            break
        else
            warn "connect attempt $attempt failed — retrying in 2s…"
            sleep 2
        fi
    done

    # 2e. Wait until status is Connected (max ~30 s)
    for i in $(seq 1 30); do
        STATUS="$(warp-cli --accept-tos status 2>/dev/null | head -1 || true)"
        case "$STATUS" in
            *Connected*) log "WARP connected ✓  ($STATUS)"; CONNECTED=true; break ;;
        esac
        sleep 1
    done
    if [ "$CONNECTED" = false ]; then
        warn "WARP did not reach Connected state in 30 s — continuing anyway"
        warn "last status: $(warp-cli --accept-tos status 2>/dev/null || echo 'unavailable')"
        warn "warp-svc log tail:"
        tail -5 /var/log/warp-svc.log 2>/dev/null | while read -r line; do warn "  $line"; done
    fi

elif [ -n "$WARP_TOKEN" ]; then
    warn "WARP_TOKEN set but warp-cli not found — skipping mesh"
else
    log "no WARP_TOKEN — starting terminal without Cloudflare mesh"
fi

# ── 3. Exec the terminal server (PID 1) ────────────────────────────────────
log "starting terminal_server.py on port ${PORT:-7681}…"
exec python3 terminal_server.py
