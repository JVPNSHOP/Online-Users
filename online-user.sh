bash -c 'set -euo pipefail
HOST="${HOST:-0.0.0.0}"; PORT="${PORT:-8888}"; TOK="${ONLINE_TOKEN:-}";
[ -z "$TOK" ] && TOK=$(tr -dc "A-Za-z0-9" </dev/urandom | head -c 24)
WORK="/opt/online-count"; sudo mkdir -p "$WORK" && cd "$WORK"

sudo tee server.py >/dev/null <<PY
#!/usr/bin/env python3
import os, subprocess, json
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PORT=int(os.getenv("PORT","8888")); HOST=os.getenv("HOST","0.0.0.0"); TOKEN=os.getenv("ONLINE_TOKEN","")

def run(cmd):
  try: return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()
  except Exception: return ""

def users_list():
  # Try who -u → who → w -h (portable)
  for cmd in (["who","-u"], ["who"], ["w","-h"]):
    out = run(cmd)
    if out:
      rows=[ln for ln in out.splitlines() if ln.strip()]
      # best-effort parse for JSON view
      users=[]
      for ln in rows:
        p=ln.split()
        if len(p)>=2:
          user, tty = p[0], p[1]
          frm = (p[-1].strip("()") if "(" in ln and ")" in ln else (p[2] if len(p)>=3 else "-"))
          users.append({"user":user,"tty":tty,"from":frm})
      return users
  return []

def count_users(): return len(users_list())

class H(BaseHTTPRequestHandler):
  def _send(self, code, body, ctype="text/plain; charset=utf-8"):
    if isinstance(body,str): body=body.encode()
    self.send_response(code); self.send_header("Content-Type", ctype)
    self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
  def do_GET(self):
    p=urlparse(self.path); qs=parse_qs(p.query); t=self.headers.get("X-Auth-Token") or (qs.get("token") or [None])[0]
    if TOKEN and t!=TOKEN: return self._send(401,"Unauthorized")
    if p.path=="/server/online": return self._send(200, str(count_users()))
    if p.path=="/server/online.json": return self._send(200, json.dumps({"online_count":count_users(),"users":users_list()}), "application/json; charset=utf-8")
    if p.path=="/healthz": return self._send(200,"ok")
    return self._send(404,"Not Found")
  def log_message(self,*a,**k): return

if __name__=="__main__":
  HTTPServer((HOST,PORT),H).serve_forever()
PY

sudo chmod +x server.py

# systemd service (auto-start like SSHPlus option 19)
sudo tee /etc/systemd/system/online-count.service >/dev/null <<UNIT
[Unit]
Description=Online Users (number & JSON endpoints)
After=network.target
[Service]
Type=simple
Environment=HOST=$HOST
Environment=PORT=$PORT
Environment=ONLINE_TOKEN=$TOK
ExecStart=/usr/bin/python3 $WORK/server.py
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now online-count.service || true

# open firewall if present
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then sudo ufw allow "$PORT/tcp" || true; fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then sudo firewall-cmd --add-port="$PORT/tcp" --permanent || true; sudo firewall-cmd --reload || true; fi

IP=$(hostname -I 2>/dev/null | awk "{print \$1}"); [ -z "$IP" ] && IP=127.0.0.1
echo "======================================================="
echo " Online link (count only):  http://$IP:$PORT/server/online"
echo " JSON details:              http://$IP:$PORT/server/online.json"
echo " Health check:              http://$IP:$PORT/healthz"
echo " Token: $TOK"
echo " cURL test:"
echo "   curl -H \"X-Auth-Token: $TOK\" http://$IP:$PORT/server/online"
echo "======================================================="
'
