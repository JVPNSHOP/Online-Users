sudo bash -c '
set -euo pipefail
APP=online-user
WORK=/opt/online-count
SRV=/etc/systemd/system/${APP}.service
HOST="${HOST:-0.0.0.0}"
PORT=81
ONLINE_TOKEN="${ONLINE_TOKEN:-}"
# AGN-UDP/Hysteria port (default 36712). Comma-separated allowed (e.g. "36712,7300").
UDP_PORTS="${UDP_PORTS:-36712}"

# deps
if ! command -v python3 >/dev/null 2>&1; then
  apt-get update -y && apt-get install -y python3 procps || true
fi

mkdir -p "$WORK"

# server.py  (SSH + UDP users)
cat > "$WORK/server.py" <<PY
#!/usr/bin/env python3
import os, subprocess, json, re
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "81"))
TOKEN = os.getenv("ONLINE_TOKEN", "")
UDP_PORTS_ENV = os.getenv("UDP_PORTS", "36712")  # AGN-UDP/Hysteria default

def run(cmd):
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""

def ssh_users_list():
    out = run(["who","-u"]) or run(["who"]) or ""
    users = []
    for ln in out.splitlines():
        ln = ln.strip()
        if not ln: continue
        users.append(ln.split()[0])
    return users

def parse_ports():
    ports = []
    for p in (UDP_PORTS_ENV or "").split(","):
        p = p.strip()
        if not p: continue
        # allow ":36712" or "36712"
        ports.append(p[1:] if p.startswith(":") else p)
    # de-dup while keeping order
    seen=set(); out=[]
    for x in ports:
        if x not in seen:
            seen.add(x); out.append(x)
    return out

def udp_clients_by_ports(ports):
    # Use ss -Huan to get UDP sockets with peers
    out = run(["ss","-Huan"])
    if not out: return 0, {}
    by = {}
    for ln in out.splitlines():
        cols = ln.split()
        if len(cols) < 6:  # Netid State Recv-Q Send-Q Local:Port Peer:Port
            continue
        local = cols[4]
        peer  = cols[5]
        for p in ports:
            # match ...:PORT or ]:PORT (IPv6)
            if local.endswith(f":{p}") or f"]:{p}" in local or f":{p} " in local:
                ip = peer.rsplit(":",1)[0].strip("[]")
                if ip and ip != "*":
                    by.setdefault(str(p), set()).add(ip)
    total = sum(len(v) for v in by.values())
    # convert to lists for JSON
    by = {k: sorted(list(v)) for k,v in by.items()}
    return total, by

def snapshot(mode=None):
    ssh_users = ssh_users_list()
    ssh_count = len(ssh_users)

    udp_ports = parse_ports()
    udp_count, udp_by = udp_clients_by_ports(udp_ports)

    if mode == "ssh":
        total = ssh_count
    elif mode == "udp":
        total = udp_count
    else:
        total = ssh_count + udp_count

    return {
        "total": total,
        "ssh_count": ssh_count,
        "udp_count": udp_count,
        "udp_by_port": udp_by,
        "udp_ports_considered": udp_ports,
        "ssh_users": ssh_users,
    }

class H(BaseHTTPRequestHandler):
    def _s(self, code, body, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str): body = body.encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        p = urlparse(self.path); qs = parse_qs(p.query)
        tok = self.headers.get("X-Auth-Token") or (qs.get("token") or [None])[0]
        mode = (qs.get("mode") or [None])[0]  # None|ssh|udp
        if TOKEN and tok != TOKEN: return self._s(401, "Unauthorized")
        if p.path == "/server/online":
            data = snapshot(mode=mode)
            return self._s(200, str(data["total"]))
        if p.path == "/server/online.json":
            data = snapshot(mode=mode)
            return self._s(200, json.dumps(data, ensure_ascii=False), "application/json; charset=utf-8")
        if p.path == "/healthz":
            return self._s(200, "ok")
        return self._s(404, "Not Found")
    def log_message(self,*a,**k): return

if __name__ == "__main__":
    HTTPServer((HOST, PORT), H).serve_forever()
PY
chmod +x "$WORK/server.py"

# systemd unit (keeps running)
cat > "$SRV" <<UNIT
[Unit]
Description=Online Users count (SSH + UDP) on port 81
After=network.target
[Service]
Type=simple
Environment=HOST=${HOST}
Environment=PORT=${PORT}
Environment=ONLINE_TOKEN=${ONLINE_TOKEN}
Environment=UDP_PORTS=${UDP_PORTS}
ExecStart=/usr/bin/python3 ${WORK}/server.py
Restart=on-failure
User=root
WorkingDirectory=${WORK}
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now ${APP}.service

# UFW/Firewalld (best-effort)
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then ufw allow 81/tcp || true; fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then firewall-cmd --add-port=81/tcp --permanent || true; firewall-cmd --reload || true; fi

IP=$(hostname -I 2>/dev/null | awk "{print \$1}"); [ -z "\$IP" ] && IP=127.0.0.1
echo
echo "✅ Ready. Test:"
echo "  curl http://\$IP:81/healthz"
if [ -n "\$ONLINE_TOKEN" ]; then
  echo "  curl -H \"X-Auth-Token: \$ONLINE_TOKEN\" \"http://\$IP:81/server/online\""
  echo "  curl -H \"X-Auth-Token: \$ONLINE_TOKEN\" \"http://\$IP:81/server/online?mode=udp\""
  echo "  curl -H \"X-Auth-Token: \$ONLINE_TOKEN\" \"http://\$IP:81/server/online.json\""
else
  echo "  curl \"http://\$IP:81/server/online\""
  echo "  curl \"http://\$IP:81/server/online?mode=udp\""
  echo "  curl \"http://\$IP:81/server/online.json\""
fi
'
