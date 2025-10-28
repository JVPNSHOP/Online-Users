sudo bash -c '
set -e
DOCROOT=/var/www/html; CFG=/etc/hysteria/config.json; PORT=8181

# 1) deps
if ! command -v php >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then apt-get -o Acquire::ForceIPv4=true update -y && apt-get install -y php-cli conntrack jq
  elif command -v dnf >/dev/null 2>&1; then dnf install -y php-cli conntrack jq
  elif command -v yum >/dev/null 2>&1; then yum install -y php php-cli conntrack jq
  else echo "need php-cli"; exit 1; fi
fi

# 2) endpoints
mkdir -p "$DOCROOT/server"
cat > "$DOCROOT/server/online" <<'"PHP"'
<?php
header("Content-Type: text/plain; charset=UTF-8"); header("Cache-Control: no-store");
$cfg="/etc/hysteria/config.json"; $p=36712;
if (is_readable($cfg)) { $j=json_decode(file_get_contents($cfg),true);
  if (isset($j["listen"]) && preg_match("/(\d{2,5})$/",(string)$j["listen"],$m)) $p=(int)$m[1]; }
$ct=trim(shell_exec("command -v conntrack"))?:"/usr/sbin/conntrack";
$cmd="sudo $ct -L -p udp 2>/dev/null | awk '\''$0 ~ (\"dport=$p\") { if (match($0,/src=([0-9.]+)/,m)) print m[1] }'\'' | sort -u | wc -l";
$out=trim(shell_exec($cmd)); echo ($out===""?"0":$out);
PHP
cat > "$DOCROOT/server/json" <<'"PHP"'
<?php
header("Content-Type: application/json; charset=UTF-8"); header("Cache-Control: no-store");
$cfg="/etc/hysteria/config.json"; $p=36712;
if (is_readable($cfg)) { $j=json_decode(file_get_contents($cfg),true);
  if (isset($j["listen"]) && preg_match("/(\d{2,5})$/",(string)$j["listen"],$m)) $p=(int)$m[1]; }
$ct=trim(shell_exec("command -v conntrack"))?:"/usr/sbin/conntrack";
$ips_cmd="sudo $ct -L -p udp 2>/dev/null | awk '\''$0 ~ (\"dport=$p\") { if (match($0,/src=([0-9.]+)/,m)) print m[1] }'\'' | sort -u";
$ips_raw=trim(shell_exec($ips_cmd)); $ips=$ips_raw===""?[]:explode("\n",$ips_raw);
echo json_encode(["ts"=>gmdate("c"),"port"=>$p,"online"=>count($ips),"ips"=>array_values($ips)], JSON_UNESCAPED_SLASHES);
PHP
chmod 644 "$DOCROOT/server/online" "$DOCROOT/server/json"

# 3) allow www-data to call conntrack (not critical since we run as root)
WEB_USER=www-data; CTBIN=$(command -v conntrack || echo /usr/sbin/conntrack)
id -u "$WEB_USER" >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin "$WEB_USER" || true
echo "$WEB_USER ALL=(root) NOPASSWD: $CTBIN" > /etc/sudoers.d/${WEB_USER}-conntrack
chmod 440 /etc/sudoers.d/${WEB_USER}-conntrack
visudo -c >/dev/null || true

# 4) kill old server & start new one (background)
pkill -f "php -S 0.0.0.0:$PORT" 2>/dev/null || true
nohup php -S 0.0.0.0:$PORT -t "$DOCROOT" >/tmp/php-endpoint.log 2>&1 &

# 5) open firewall (best-effort)
if command -v ufw >/dev/null 2>&1; then ufw allow '"$PORT"'/tcp || true; fi
iptables -I INPUT -p tcp --dport '"$PORT"' -j ACCEPT 2>/dev/null || true

PUB_IP=$(curl -4fsS http://ifconfig.me 2>/dev/null || hostname -I | awk "{print \$1}")
echo
echo "ONLINE endpoint:  http://$PUB_IP:'"$PORT"'/server/online"
echo "JSON   endpoint:  http://$PUB_IP:'"$PORT"'/server/json"
echo "Local quick test:"
curl -sS http://127.0.0.1:'"$PORT"'/server/online || true; echo
'
