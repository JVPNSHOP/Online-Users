#!/usr/bin/env bash
# Online Users HTTP Endpoint – one-shot installer
# Exposes: http://<IP>:8888/server/online  and /healthz
# Works on: Ubuntu/Debian, RHEL/CentOS/Alma/Rocky, Amazon Linux
# Usage:
#   bash install.sh               # default install (0.0.0.0:8888, no token)
#   PORT=8080 ONLINE_TOKEN=changeme bash install.sh
#   bash install.sh --uninstall
#   bash install.sh --no-firewall
#   HOST=127.0.0.1 bash install.sh  # bind locally (reverse proxy later)

set -euo pipefail

APP_DIR="/opt/online-users"
APP_PY="$APP_DIR/online_server.py"
SERVICE_NAME="online-users.service"

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8888}"
ONLINE_TOKEN="${ONLINE_TOKEN:-}"
NO_FIREWALL="false"
UNINSTALL="false"

for arg in "${@:-}"; do
  case "$arg" in
    --no-firewall) NO_FIREWALL="true" ;;
    --uninstall)   UNINSTALL="true" ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

log(){ printf "\033[1;32m[+] %s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
err(){ printf "\033[1;31m[-] %s\033[0m\n" "$*"; exit 1; }

detect_pm(){
  if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
  if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
  if command -v yum >/dev/null 2>&1; then echo yum; return; fi
  echo none
}

ensure_root(){
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Run as root (use sudo)."
  fi
}

stop_service(){
  if systemctl list-unit-files | grep -q "^$SERVICE_NAME"; then
    systemctl stop "$SERVICE_NAME" || true
    systemctl disable "$SERVICE_NAME" || true
  fi
}

uninstall_all(){
  log "Uninstalling service and files..."
  stop_service
  rm -f "/etc/systemd/system/$SERVICE_NAME"
  rm -f "/etc/default/online-users" "/etc/sysconfig/online-users"
  systemctl daemon-reload || true
  rm -rf "$APP_DIR"
  # firewall is left as-is (you may close the port manually)
  log "Done."
}

install_pkgs(){
  PM="$(detect_pm)"
  case "$PM" in
    apt)
      log "Installing dependencies via apt..."
      apt-get update -y
      apt-get install -y python3 procps
      ;;
    dnf)
      log "Installing dependencies via dnf..."
      dnf install -y python3 procps-ng || dnf install -y python3 procps
      ;;
    yum)
      log "Installing dependencies via yum..."
      yum install -y python3 procps-ng || yum install -y python3 procps
      ;;
    *)
      warn "Could not detect package manager; assuming python3 & procps already exist."
      ;;
  esac
  command -v python3 >/dev/null 2>&1 || err "python3 not found"
  command -v uptime  >/dev/null 2>&1 || warn "procps not found; uptime may be missing"
}

write_app(){
  log "Writing server to $APP_PY ..."
  mkdir -p "$APP_DIR"
  cat >"$APP_PY" <<'PY'
#!/usr/bin/env python3
import json, socket, subprocess, os
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
from datetime import datetime

PORT = int(os.getenv("PORT", "8888"))
HOST = os.getenv("HOST", "0.0.0.0")
TOKEN = os.getenv("ONLINE_TOKEN")  # optional

def run_cmd(cmd):
  try:
    out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
    return out.strip()
  except Exception:
    return ""

def get_users():
  data = {"users": []}
  who = run_cmd(["who", "-u"])
  if who:
    for line in who.splitlines():
      parts = line.split()
      if len(parts) < 2: continue
      user, tty = parts[0], parts[1]
      if len(parts) >= 6:
        idle, pid, host = parts[-3], parts[-2], parts[-1].strip("()")
        login_at = " ".join(parts[2:-3]) or "-"
      else:
        idle = pid = host = login_at = "-"
      if not host: host = "local"
      data["users"].append({
        "user": user, "tty": tty, "from": host,
        "login_at": login_at, "idle": idle, "pid": pid
      })
  else:
    w = run_cmd(["w", "-h"])
    for line in w.splitlines():
      parts = line.split()
      if len(parts) < 2: continue
      user, tty = parts[0], parts[1]
      frm = parts[2] if len(parts) >= 3 else "-"
      login_at = parts[3] if len(parts) >= 4 else "-"
      idle = parts[4] if len(parts) >= 5 else "-"
      data["users"].append({
        "user": user, "tty": tty, "from": frm,
        "login_at": login_at, "idle": idle, "pid": "-"
      })
  return data

def snapshot():
  host = socket.gethostname()
  now = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
  uptime = run_cmd(["uptime", "-p"]) or ""
  users = get_users()
  return {
    "host": host,
    "now_utc": now,
    "uptime": uptime,
    "online_count": len(users["users"]),
    **users
  }

class Handler(BaseHTTPRequestHandler):
  def _respond(self, code, body, ctype="text/plain; charset=utf-8"):
    if isinstance(body, str): body=body.encode()
    self.send_response(code)
    self.send_header("Content-Type", ctype)
    self.send_header("Content-Length", str(len(body)))
    self.end_headers()
    self.wfile.write(body)

  def do_GET(self):
    parsed = urlparse(self.path)
    path = parsed.path
    if path == "/healthz":
      return self._respond(200, b"ok")
    if path == "/":
      html = b"<html><body><a href='/server/online'>/server/online</a></body></html>"
      return self._respond(200, html, "text/html; charset=utf-8")
    if path == "/server/online":
      if TOKEN:
        qs = parse_qs(parsed.query)
        header_token = self.headers.get("X-Auth-Token")
        query_token = (qs.get("token") or [None])[0]
        if header_token != TOKEN and query_token != TOKEN:
          return self._respond(401, "Missing/invalid token")
      body = json.dumps(snapshot(), ensure_ascii=False).encode()
      return self._respond(200, body, "application/json; charset=utf-8")
    return self._respond(404, "Not Found")

  def log_message(self, fmt, *args):
    return  # silent

if __name__ == "__main__":
  httpd = HTTPServer((HOST, PORT), Handler)
  print(f"Serving on http://{HOST}:{PORT}")
  httpd.serve_forever()
PY
  chmod +x "$APP_PY"
}

write_env_and_service(){
  # Prefer /etc/default on Debian/Ubuntu, /etc/sysconfig on RHEL
  if [ -d /etc/default ]; then ENVFILE="/etc/default/online-users"; fi
  if [ -d /etc/sysconfig ]; then ENVFILE="/etc/sysconfig/online-users"; fi
  : "${ENVFILE:=/etc/default/online-users}"

  log "Writing environment to $ENVFILE ..."
  cat >"$ENVFILE" <<EOF
HOST="${HOST}"
PORT="${PORT}"
ONLINE_TOKEN="${ONLINE_TOKEN}"
EOF

  log "Writing systemd unit /etc/systemd/system/$SERVICE_NAME ..."
  cat >/etc/systemd/system/"$SERVICE_NAME" <<UNIT
[Unit]
Description=Online Users HTTP Endpoint
After=network.target

[Service]
Type=simple
EnvironmentFile=$ENVFILE
ExecStart=/usr/bin/python3 $APP_PY
WorkingDirectory=$APP_DIR
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
}

open_firewall(){
  [ "$NO_FIREWALL" = "true" ] && { warn "Skipping firewall config (--no-firewall)"; return; }
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
      log "Opening port $PORT via ufw ..."
      ufw allow "${PORT}/tcp" || warn "ufw allow failed"
    else
      warn "ufw inactive; skipping ufw rules"
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    if systemctl is-active --quiet firewalld; then
      log "Opening port $PORT via firewalld ..."
      firewall-cmd --add-port="${PORT}/tcp" --permanent || true
      firewall-cmd --reload || true
    fi
  fi
}

start_service(){
  log "Enabling & starting service ..."
  systemctl enable --now "$SERVICE_NAME"
  systemctl --no-pager status "$SERVICE_NAME" || true
  log "Health check: curl http://<your-ip>:${PORT}/healthz"
  if [ -n "$ONLINE_TOKEN" ]; then
    log "Auth enabled: use header 'X-Auth-Token: ${ONLINE_TOKEN}' or '?token=${ONLINE_TOKEN}'"
  fi
}

main(){
  ensure_root
  if [ "$UNINSTALL" = "true" ]; then
    uninstall_all
    exit 0
  fi
  install_pkgs
  write_app
  write_env_and_service
  open_firewall
  start_service
  log "Online endpoint ready: http://<your-ip>:${PORT}/server/online"
}

main "$@"
