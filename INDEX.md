# MiniDev — Repository Index

> **TeamDev X Terminal** — A full-featured, browser-based Ubuntu 24.04 terminal (no SSH, no client install). Real PTY shell over WebSocket, served from a single pure-stdlib Python file.

**Version:** 2.4.0 · **License:** MIT · **Language:** Python 3.x (stdlib only) + vanilla JS/HTML · **Base image:** `ubuntu:24.04`

---

## 📁 File Map

| File | Lines | Role |
|------|-------|------|
| `terminal_server.py` | 360 | Backend — HTTP + WebSocket server, PTY session manager (pure Python stdlib) |
| `teamdev_terminal_ui.html` | 725 | Frontend — single-file UI (xterm.js, CSS, JS, PWA hooks) |
| `Dockerfile` | ~90 | Ubuntu 24.04 image — system-optimised + Cloudflare Tunnel (cloudflared) |
| `entrypoint.sh` | ~70 | Runtime init: sysctl → cloudflared tunnel → app |
| `docker-compose.yml` | ~60 | Compose stack: volumes, health check, logging |
| `manifest.json` | 40 | PWA web app manifest (icons, shortcuts, standalone display) |
| `requirements.txt` | 0 | Intentionally empty — zero pip dependencies |
| `icon-192.png` / `icon-512.png` | — | PWA icons |
| `README.md` | ~300 | Full docs: features, quick start, config, deployment matrix, security |
| `License` | — | MIT license |
| `.vscode/settings.json` | — | Editor settings |
| `.env.example` | — | Environment variable template |
| `.dockerignore` | — | Docker build exclusions |

### Platform configs (auto-detected by each deployer)

| Platform | Config file | Notes |
|----------|-------------|-------|
| Railway | `railway.json` | Nixpacks, health check, restart rollback |
| Render | `render.yaml` | Port 10000, auto keepalive URL |
| Fly.io | `fly.toml` | Volume, health check, auto-stop machines |
| Koyeb | `koyeb.yml` | Dockerfile, health check, volume |
| Zeabur | `zeabur.json` | Dockerfile, health check |
| Northflank | `northflank.json` | Dockerfile, health check, volume |
| Adaptable | `adaptable.json` | Python, health check |
| Qovery | `.qovery.yml` | Dockerfile, health check, storage |
| Platform.sh | `.platform.app.yaml` | Python 3.11, disk |
| Clever Cloud | `clevercloud/python.json` | Python, start command |
| Scalingo | `scalingo.json` | Python, start command |
| Glitch | `glitch.json` | Install + start |
| Replit | `replit.toml` | Run command + env |
| CapRover | `captain-definition` | Dockerfile |
| Deta Space | `Detafile` | Docker micro |
| Porter | `porter.yaml` | Dockerfile, health check |
| Heroku | `Procfile` + `app.json` + `runtime.txt` | Python buildpack, deploy button |
| Gitpod | `.gitpod.yml` | Dev environment |
| CodeSandbox | `sandbox.config.json` | Dev environment |
| Vercel | `vercel.json` | Python serverless, 300 s max duration |

---

## 🏗️ Architecture

```
Browser
  │  HTTP GET /          → serves teamdev_terminal_ui.html (password injected into <head>)
  │  HTTP GET /health    → 200 OK (load-balancer probes)
  │  HTTP GET /manifest.json → PWA manifest
  │  HTTP POST /upload   → base64 file upload (REST)
  │  WS  ws://host/      → WebSocket terminal session (PTY I/O)
  ▼
terminal_server.py  (pure Python, stdlib only)
  ├── HTTP handler  → serve_html / handle_http
  ├── WebSocket     → handshake, frame encode/decode, ping/pong
  └── PtySession    → pty.fork() → /bin/bash --login → read/write loop
```

---

## 🐍 `terminal_server.py` — Key Symbols

### Configuration (env vars)
| Variable | Default | Purpose |
|----------|---------|---------|
| `PORT` | `7681` | Listen port |
| `TERMINAL_PASSWORD` | `R@b1u2004@` | Login password (injected into served HTML) |
| `KEEPALIVE_URL` | *(empty)* | If set, pings `<url>/health` every 25 s to prevent spin-down |
| `SHELL` | `/bin/bash` | Shell binary for PTY sessions |
| `TUNNEL_TOKEN` | *(empty)* | Cloudflare Tunnel token. When set, entrypoint starts `cloudflared tunnel run --token <TOKEN>` to expose the terminal via a Cloudflare Tunnel. No special capabilities needed. |
### WebSocket protocol helpers
- `ws_accept_key(key)` — SHA-1 + base64 Sec-WebSocket-Accept
- `ws_handshake(key)` — 101 Switching Protocols response
- `_recv_exact(sock, n)` — read exactly n bytes
- `ws_recv(sock)` — decode one WS frame (handles masking, 126/127 lengths)
- `ws_send(sock, data, opcode)` — encode + send WS frame
- `ws_json(sock, obj)` — send JSON text frame

### `class PtySession` — PTY lifecycle
- `start()` — `pty.fork()` → `os.execvpe(shell, [shell, "--login"])`; sets `TERM=xterm-256color`, `COLORTERM=truecolor`, `LANG/LC_ALL=en_US.UTF-8`, custom green `PS1`, `HOME=UPLOAD_DIR`
- `_set_winsize(cols, rows)` — `TIOCSWINSZ` ioctl
- `resize(cols, rows)` — dynamic terminal resize
- `write(data)` — write to PTY fd
- `_read_loop()` — `select()` on fd → sends `{"type":"output","data":<base64>}` frames; sends `{"type":"exit"}` on EOF
- `kill()` — SIGTERM + close fd

### HTTP layer
- `http_resp(sock, status, body, ctype)` — minimal HTTP response with CORS header
- `serve_html(sock)` — reads HTML, injects `<script>window.__TERMINAL_PASSWORD__=…</script>` before `</head>`
- `handle_http(sock, method, path, buf)` — routes:
  - `GET /` & `/index.html` → UI
  - `GET /manifest.json` → PWA manifest
  - `GET /health` → `200 OK`
  - `POST /upload` → JSON `{name, data(base64)}` → writes to `UPLOAD_DIR`

### Connection handling
- `ws_loop(sock, session)` — message loop: `input` (base64 → PTY), `resize`, `ping`→`pong`, `upload` (base64 → file + `upload_ok` + terminal banner)
- `handle_conn(sock, addr)` — TCP_NODELAY/SO_KEEPALIVE, 20 s handshake timeout, parses request line + headers, detects WebSocket upgrade, dispatches to WS or HTTP
- `keepalive_loop()` — background thread pinging `KEEPALIVE_URL/health` every 25 s

### Server
- `class TermServer` — socket bind/listen (SO_REUSEADDR + SO_REUSEPORT), thread-per-connection `serve_forever()`
- `__main__` — starts keepalive thread if configured, then `TermServer(HOST, PORT).serve_forever()`

---

## ☁️ Cloudflare Tunnel (`entrypoint.sh`)

The Docker image ships with the `cloudflared` binary pre-installed. When `TUNNEL_TOKEN` is set, the entrypoint:

1. Applies kernel forwarding sysctls (`ip_forward`, IPv6 forwarding, `accept_ra` + TCP tuning)
2. Starts `cloudflared tunnel run --token "$TUNNEL_TOKEN"` in the background
3. Verifies the process is alive, then `exec python3 terminal_server.py`

**No special capabilities needed** — cloudflared makes outbound HTTPS connections to Cloudflare's edge, so it works on any platform (Render, Railway, Fly.io, etc.) without `NET_ADMIN` or `/dev/net/tun`. Without `TUNNEL_TOKEN`, the container starts the terminal normally.

**Why runtime, not build time:** the tunnel token is secret and the tunnel must connect to Cloudflare's edge at container start. The entrypoint runs cloudflared at container start so it works on any deploy target.

---

## 🌐 `teamdev_terminal_ui.html` — Frontend

### External deps (CDN, jsdelivr)
- `xterm@5.3.0` + addons: `fit@0.8.0`, `web-links@0.9.0`, `search@0.13.0`

### UI structure
| Element | Purpose |
|---------|---------|
| `#pw-screen` | Password login gate (eye toggle, error msg) |
| `#install-banner` | PWA install prompt |
| `#titlebar` | Window controls, WS status pill (`#ws-pill`), live clock |
| `#toolbar` | Upload / Clear / Tab / Find + command shortcuts (ls, pwd, top, df, mem, git, railway) |
| `#search-bar` | xterm search addon UI |
| `#sidebar` | Quick-command shortcuts (python3 main.py, pip install, apt upgrade…) |
| `#term-pane` | Tabs (`#tabs`), xterm container, bottom status bar (user, cwd, size) |
| `#ctrl-bar` | Mobile control bar: Ctrl+C/D, ESC, TAB, arrows, upload, clear |
| `#ctrl-picker` | Extended Ctrl+… key picker |
| `#upload-modal` | Drag-and-drop upload modal with progress bar + "run after upload" toggle |
| `#toast` | Toast notifications |

### Key JS functions
- `checkPw()` / `togglePwEye()` — login gate (compares against injected `TERMINAL_PASSWORD`)
- `bootTerminal()` → `initTerm()` + `connectWS()` — xterm setup (fit/search/web-links addons) + WebSocket connect with retry
- `connectWS()` — alternates `/` and `/ws` paths, 8 s connect timeout, sends `x-cols`/`x-rows` headers, handles `output`/`pong`/`upload_ok`/`exit` messages
- `sendRaw()` / `sendLine()` / `sendCtrlC()` / `sendCtrlD()` / `clearTerm()` — input helpers
- `openUpload()` / `handleFiles()` / `doUpload()` — base64 chunked upload over WS with progress
- `newTab()` / `activateTab()` / `closeTab()` — multi-tab terminal sessions
- `toggleSidebar()` / `toggleSearch()` / `doSearch()` — UI toggles
- `showToast()` / `setFontSize()` / `openCtrlPicker()` — misc UX
- PWA: `beforeinstallprompt` / `appinstalled` handlers, `doInstall()`

---

## 🐳 Deployment Targets

| Platform | Config | Notes |
|----------|--------|-------|
| Docker Compose | `docker-compose.yml` | Volumes: `uploads`, `bash_history`; healthcheck `curl /health`; json-file logging 10 MB × 3 |
| Docker | `Dockerfile` | `ubuntu:24.04` + dev toolchain; passwordless sudo; `PORT=7681` |
| Railway | `railway.json` | Nixpacks builder, `python3 terminal_server.py`, health check |
| Render | `render.yaml` | `PORT=10000`, `KEEPALIVE_URL` auto-wired to own hostname |
| Fly.io | `fly.toml` | Volume mount, `/health` check, auto-stop machines |
| Koyeb | `koyeb.yml` | Dockerfile build, port 7681, health check |
| Zeabur | `zeabur.json` | Dockerfile, health check |
| Northflank | `northflank.json` | Dockerfile, health check, volume |
| Adaptable | `adaptable.json` | Python type, health check |
| Qovery | `.qovery.yml` | Dockerfile, health check, storage |
| Platform.sh | `.platform.app.yaml` | Python 3.11, disk 1024 |
| Clever Cloud | `clevercloud/python.json` | Python, start command |
| Scalingo | `scalingo.json` | Python, start command |
| Glitch | `glitch.json` | Install + start |
| Replit | `replit.toml` | Run command + env |
| CapRover | `captain-definition` | Dockerfile |
| Deta Space | `Detafile` | Docker micro |
| Porter | `porter.yaml` | Dockerfile, health check |
| Heroku / Procfile | `Procfile` + `app.json` + `runtime.txt` | `web: python3 terminal_server.py` |
| Gitpod | `.gitpod.yml` | Dev environment |
| CodeSandbox | `sandbox.config.json` | Dev environment |
| Vercel | `vercel.json` | Python serverless, 300 s max duration |

---

## 🔑 Key Facts / Gotchas

- **Zero pip dependencies** — `requirements.txt` is intentionally empty; everything is Python stdlib.
- **Password injection** — the server injects the plaintext password into the served HTML (`window.__TERMINAL_PASSWORD__`); client-side check only. Always set a strong `TERMINAL_PASSWORD` before public deployment.
- **Uploads** land in `/tmp/teamdev_uploads` (also the PTY `HOME`/cwd).
- **Windows not supported** — requires the `pty` module (POSIX only).
- **No TLS by default** — terminate TLS at a reverse proxy or platform.
- **Root/sudo** — container grants passwordless sudo by design (sandbox only).
- **Keepalive** — `KEEPALIVE_URL` pings `/health` every 25 s to avoid free-tier spin-down.