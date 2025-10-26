sudo bash -c '
set -euo pipefail
RAW_URL="https://raw.githubusercontent.com/JVPNSHOP/Online-Users/main/online-user.sh"
APP="online-user"
ENVFILE="/etc/default/${APP}"
SERVICE="/etc/systemd/system/${APP}.service"

# ENV သတ်မှတ် (မထည့်ရင် default)
: "${HOST:=0.0.0.0}"; : "${PORT:=8888}"; : "${ONLINE_TOKEN:=}"

echo "[+] Write env -> $ENVFILE"
cat >"$ENVFILE" <<EOF
HOST=$HOST
PORT=$PORT
ONLINE_TOKEN=$ONLINE_TOKEN
RAW_URL=$RAW_URL
EOF

echo "[+] Create systemd -> $SERVICE"
cat >"$SERVICE" <<UNIT
[Unit]
Description=Online Users endpoint (runs remote online-user.sh)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENVFILE
# မွန်ကန်တဲ့ raw URL ကိုသာ သုံး (404 ဘယ်တော့မဖြစ်အောင် -fL)
ExecStart=/bin/bash -lc "set -ae; . $ENVFILE; set +a; curl -fL \$RAW_URL | bash -s --"
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now "${APP}.service"

# firewall (ရှိရင်) ဖွင့်
if command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -q "Status: active"; then ufw allow "${PORT}/tcp" || true; fi
fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --add-port="${PORT}/tcp" --permanent || true; firewall-cmd --reload || true
fi

IP=$(hostname -I 2>/dev/null | awk "{print \$1}"); [ -z "$IP" ] && IP=127.0.0.1
echo
echo "✅ Installed & started."
echo "URL:   http://$IP:${PORT}/server/online"
[ -n "$ONLINE_TOKEN" ] && echo "Token: $ONLINE_TOKEN  (use header X-Auth-Token or ?token=)"
systemctl --no-pager --full status ${APP}.service || true
'
