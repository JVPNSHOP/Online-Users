sudo bash -c 'cat >/tmp/agnudp_online_autoserve.sh <<'"'"'BASH'"'"'
#!/usr/bin/env bash
set -euo pipefail

DOCROOT="/var/www/html"
CFG="/etc/hysteria/config.json"
WEB_USER="www-data"
SERVICE_NAME="php-endpoint"
SERVE_PORT="8181"

say(){ printf "\033[1;32m==>\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m!!\033[0m %s\n" "$*"; }

# 1) Packages
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::ForceIPv4=true update -y
  apt-get -o Acquire::ForceIPv4=true install -y php-cli conntrack jq
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y php-cli conntrack jq
elif command -v yum >/dev/null 2>&1; then
  yum install -y php php-cli conntrack jq
elif command -v zypper >/dev/null 2>&1; then
  zypper install -y php8 php8-cli conntrack-tools jq
elif command -v pacman >/dev/null 2>&1; then
  pacman -Sy --noconfirm php conntrack-tools jq
else
  echo "Unsupported distro (need apt/dnf/yum/zypper/pacman)"; exit 1
fi

# 2) Files
mkdir -p "$DOCROOT/server"
CTBIN="$(command -v conntrack || echo /usr/sbin/conntrack)"

# /server/online
cat > "$DOCROOT/server/online" <<'PHP'
<?php
header("Content-Type: text/plain; charset=UTF-8");
header("Cache-Control: no-store");
$cfg="/etc/hysteria/config.json"; $p=36712;
if (is_readable($cfg)) { $j=json_decode(file_get_contents($cfg),true);
  if (isset($j["listen"]) && preg_match("/(\d{2,5})$/",(string)$j["listen"],$m)) $p=(int)$m[1];
}
$ct=trim(shell_exec("command -v conntrack"))?:"/usr/sbin/conntrack";
$cmd="sudo $ct -L -p udp 2>/dev/null | awk '\''$0 ~ (\"dport=$p\") { if (match($0,/src=([0-9.]+)/,m)) print m[1] }'\'' | sort -u | wc -l";
$out=trim(shell_exec($cmd)); echo ($out===""?"0":$out);
PHP

# /server/json
cat > "$DOCROOT/server/json" <<'PHP'
<?php
header("Content-Type: application/json; charset=UTF-8");
header("Cache-Control: no-store");
$cfg="/etc/hysteria/config.json"; $p=36712;
if (is_readable($cfg)) { $j=json_decode(file_get_contents($cfg),true);
  if (isset($j["listen"]) && preg_match("/(\d{2,5})$/",(string)$j["listen"],$m)) $p=(int)$m[1];
}
$ct=trim(shell_exec("command -v conntrack"))?:"/usr/sbin/conntrack";
$ips_cmd="sudo $ct -L -p udp 2>/dev/null | awk '\''$0 ~ (\"dport=$p\") { if (match($0,/src=([0-9.]+)/,m)) print m[1] }'\'' | sort -u";
$ips_raw=trim(shell_exec($ips_cmd)); $ips=$ips_raw===""?[]:explode("\n",$ips_raw);
echo json_encode(["ts"=>gmdate("c"),"port"=>$p,"online"=>count($ips),"ips"=>array_values($ips)], JSON_UNESCAPED_SLASHES);
PHP
chmod 644 "$DOCROOT/server/online" "$DOCROOT/server/json"

# 3) sudoers (web user → conntrack)
id -u "$WEB_USER" >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin "$WEB_USER" || true
echo "$WEB_USER ALL=(root) NOPASSWD: $CTBIN" > "/etc/sudoers.d/${WEB_USER}-conntrack"
chmod 440 "/etc/sudoers.d/${WEB_USER}-conntrack"
visudo -c >/dev/null

# 4) systemd service for php -S 0.0.0.0:8181 -t /var/www/html
cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=PHP built-in server for AGN-UDP endpoints
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/php -S 0.0.0.0:${SERVE_PORT} -t ${DOCROOT}
Restart=always
RestartSec=2
User=root
WorkingDirectory=${DOCROOT}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"

# 5) Firewall open 8181/tcp
if command -v ufw >/dev/null 2>&1; then
  ufw allow ${SERVE_PORT}/tcp || true
fi
iptables -I INPUT -p tcp --dport ${SERVE_PORT} -j ACCEPT 2>/dev/null || true
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --add-port=${SERVE_PORT}/tcp --permanent && firewall-cmd --reload
fi

# 6) Show links + quick test
LAN_IP="$(hostname -I 2>/dev/null | awk "{print \$1}")"
PUB_IP="$(curl -4fsS http://ifconfig.me 2>/dev/null || true)"
[ -z "$LAN_IP" ] && LAN_IP="<LAN_IP>"
[ -z "$PUB_IP" ] && PUB_IP="<PUBLIC_IP>"

echo
say "Endpoints are live on port ${SERVE_PORT}:"
echo "  Local:  http://$LAN_IP:${SERVE_PORT}/server/online"
echo "  Local:  http://$LAN_IP:${SERVE_PORT}/server/json"
echo "  Public: http://$PUB_IP:${SERVE_PORT}/server/online"
echo "  Public: http://$PUB_IP:${SERVE_PORT}/server/json"
echo
say "Service status (should be active):"
systemctl --no-pager --full status ${SERVICE_NAME}.service || true

say "Local quick check:"
curl -sS http://127.0.0.1:${SERVE_PORT}/server/online || true
echo
BASH
chmod +x /tmp/agnudp_online_autoserve.sh
bash /tmp/agnudp_online_autoserve.sh'
