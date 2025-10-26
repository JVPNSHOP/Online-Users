#!/usr/bin/env bash
# Online User Count Server
# Shows only number of connected users at /server/online
# Includes auto token generation, systemd service setup, firewall allow

set -euo pipefail
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8888}"
TOKEN="${ONLINE_TOKEN:-}"

# Auto-generate token if not set
if [ -z "$TOKEN" ]; then
  TOKEN=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  echo "[+] Generated token: $TOKEN"
fi

WORKDIR="/opt/online-count"
mkdir -p "$WORKDIR"

cat > "$WORKDIR/server.py" <<'PY'
#!/usr/bin/env python3
import os, subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(os.getenv("PORT", "8888"))
HOST = os.getenv("HOST", "0.0.0.0")
TOKEN = os.getenv("ONLINE_TOKEN", "")

def run(cmd):
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""

def count_users():
    for cmd in (["who", "-u"], ["who"], ["w", "-h"]):
        out = run(cmd)
        if out:
            return sum(1 for ln in out.splitlines() if ln.strip())
    return 0

class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str): body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = urlparse(self.path)
        if p.path == "/server/online":
            if TOKEN:
                qs = parse_qs(p.query)
                if self.headers.get("X-Auth-Token") != TOKEN and (qs.get("token") or [None])[0] != TOKEN:
                    return self._send(401, "Unauthorized")
            return self._send(200, str(count_users()))
        if p.path == "/healthz":
            return self._send(200, "ok")
        return self._send(404, "Not Found")

    def log_message(self, *a, **k): return

if __name__ == "__main__":
    HTTPServer((HOST, PORT), H).serve_forever()
PY

chmod +x "$WORKDIR/server.py"

# --- systemd setup ---
cat > /etc/systemd/system/online-count.service <<UNIT
[Unit]
Description=Online Users Count Endpoint
After=network.target
[Service]
Type=simple
Environment=HOST=$HOST
Environment=PORT=$PORT
Environment=ONLINE_TOKEN=$TOKEN
ExecStart=/usr/bin/python3 $WORKDIR/server.py
Restart=on-failure
User=root
[Install]
WantedBy=multi-user.target
UNIT

# Reload + enable
systemctl daemon-reload
systemctl enable --now online-count.service

# Firewall open
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp" || true
fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --add-port="${PORT}/tcp" --permanent || true
  firewall-cmd --reload || true
fi

# Output info
IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo 127.0.0.1)
echo
echo "✅ Online Count Server Running!"
echo "→ URL: http://${IP}:${PORT}/server/online"
echo "→ Health: http://${IP}:${PORT}/healthz"
echo "→ Token: $TOKEN"
echo
echo "Test with:"
echo "  curl -H 'X-Auth-Token: $TOKEN' http://${IP}:${PORT}/server/online"
