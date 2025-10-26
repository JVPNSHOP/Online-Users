sudo bash -c '
set -euo pipefail
APP=online-user
WORK=/opt/online-count
SRV=/etc/systemd/system/${APP}.service
HOST="${HOST:-0.0.0.0}"
PORT=81
ONLINE_TOKEN="${ONLINE_TOKEN:-}"

# deps
if ! command -v python3 >/dev/null 2>&1; then
  apt-get update -y && apt-get install -y python3 procps || true
fi

mkdir -p "$WORK"

# server.py  (GET /server/online -> number only)
cat > "$WORK/server.py" <<PY
#!/usr/bin/env python3
import os, subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "81"))
TOKEN = os.getenv("ONLINE_TOKEN", "")
def run(cmd):
    try: return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception: return ""
def count_users():
    for c in (["who","-u"], ["who"], ["w","-h"]):
        out = run(c)
        if out: return sum(1 for ln in out.splitlines() if ln.strip())
    return 0
class H(BaseHTTPRequestHandler):
    def _s(self, code, body, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str): body = body.encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        p = urlparse(self.path); qs = parse_qs(p.query)
        tok = self.headers.get("X-Auth-Token") or (qs.get("token") or [None])[0]
        if TOKEN and tok != TOKEN: return self._s(401, "Unauthorized")
        if p.path == "/server/online": return self._s(200, str(count_users()))
        if p.path == "/healthz": return self._s(200, "ok")
        return self._s(404, "Not Found")
    def log_message(self,*a,**k): return
if __name__ == "__main__":
    HTTPServer((HOST, PORT), H).serve_forever()
PY
chmod +x "$WORK/server.py"

# systemd unit (note: real ExecStart; stays running)
cat > "$SRV" <<UNIT
[Unit]
Description=Online Users count (port 81)
After=network.target
[Service]
Type=simple
Environment=HOST=${HOST}
Environment=PORT=${PORT}
Environment=ONLINE_TOKEN=${ONLINE_TOKEN}
ExecStart=/usr/bin/python3 ${WORK}/server.py
Restart=on-failure
User=root
WorkingDirectory=${WORK}
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now ${APP}.service

# ReadyIDC အတွက် ပုံမှန်အားဖြင့် 81/tcp အပြင်ကနေ ပွင့်ထားပါလိမ့်မယ်,
# UFW/Firewalld အလုပ်ဖြစ်နေရင်လည်း allow တင်ပေး (best-effort)
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then ufw allow 81/tcp || true; fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then firewall-cmd --add-port=81/tcp --permanent || true; firewall-cmd --reload || true; fi

IP=$(hostname -I 2>/dev/null | awk "{print \$1}"); [ -z "$IP" ] && IP=127.0.0.1
echo
echo "✅ Ready. Test:"
echo "  curl http://$IP:81/healthz"
if [ -n "$ONLINE_TOKEN" ]; then
  echo "  curl -H \"X-Auth-Token: $ONLINE_TOKEN\" http://$IP:81/server/online"
  echo "  (or http://$IP:81/server/online?token=$ONLINE_TOKEN)"
else
  echo "  curl http://$IP:81/server/online"
fi
'
