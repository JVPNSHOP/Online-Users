sudo bash -c '
set -euo pipefail

# --- Config you can override: DOCROOT / WEB_USER ---
DOCROOT="${DOCROOT:-/var/www/html}"
WEB_USER="${WEB_USER:-www-data}"
CFG="/etc/hysteria/config.json"

say(){ echo -e "\033[1;32m==>\033[0m $*"; }
warn(){ echo -e "\033[1;33m!!\033[0m $*"; }

# 1) deps
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y conntrack jq php-cli >/dev/null
elif command -v dnf >/dev/null; then dnf install -y conntrack jq php-cli
elif command -v yum >/dev/null; then yum install -y conntrack jq php-cli
elif command -v zypper >/dev/null; then zypper install -y conntrack jq php-cli
elif command -v pacman >/dev/null; then pacman -Sy --noconfirm conntrack jq php
fi

# 2) prepare docroot safely
mkdir -p "$DOCROOT/server"

# 3) allow web user (or create one if missing)
if ! id -u "$WEB_USER" >/dev/null 2>&1; then
  useradd -r -s /usr/sbin/nologin "$WEB_USER" || true
fi
CTBIN="$(command -v conntrack || echo /usr/sbin/conntrack)"
echo "$WEB_USER ALL=(root) NOPASSWD: $CTBIN" > "/etc/sudoers.d/${WEB_USER}-conntrack"
chmod 440 "/etc/sudoers.d/${WEB_USER}-conntrack"
visudo -c >/dev/null

# 4) write /server/online (plain integer)
cat > "$DOCROOT/server/online" <<'"PHP"'
<?php
header("Content-Type: text/plain; charset=UTF-8");
header("Cache-Control: no-store");
function listen_port($p="/etc/hysteria/config.json"){
  $fb=36712;
  if(!is_readable($p)) return $fb;
  $j=json_decode(file_get_contents($p),true);
  if(isset($j["listen"]) && preg_match("/(\d{2,5})$/",(string)$j["listen"],$m)) return (int)$m[1];
  return $fb;
}
$port = listen_port();
$ct = trim(shell_exec("command -v conntrack")) ?: "/usr/sbin/conntrack";
$cmd = "sudo $ct -L -p udp 2>/dev/null | awk '\''$0 ~ (\"dport=$port\") { if (match($0,/src=([0-9.]+)/,m)) print m[1] }'\'' | sort -u | wc -l";
$out = trim(shell_exec($cmd));
echo ($out === "" ? "0" : $out);
PHP

# 5) write /server/json (useful for JS dashboards)
cat > "$DOCROOT/server/json" <<'"PHP"'
<?php
header("Content-Type: application/json; charset=UTF-8");
header("Cache-Control: no-store");
function listen_port($p="/etc/hysteria/config.json"){
  $fb=36712;
  if(!is_readable($p)) return $fb;
  $j=json_decode(file_get_contents($p),true);
  if(isset($j["listen"]) && preg_match("/(\d{2,5})$/",(string)$j["listen"],$m)) return (int)$m[1];
  return $fb;
}
$port = listen_port();
$ct = trim(shell_exec("command -v conntrack")) ?: "/usr/sbin/conntrack";
$ips_cmd = "sudo $ct -L -p udp 2>/dev/null | awk '\''$0 ~ (\"dport=$port\") { if (match($0,/src=([0-9.]+)/,m)) print m[1] }'\'' | sort -u";
$ips_raw = trim(shell_exec($ips_cmd));
$ips = $ips_raw === "" ? [] : explode("\n",$ips_raw);
echo json_encode(["ts"=>gmdate("c"),"port"=>$port,"online"=>count($ips),"ips"=>array_values($ips)], JSON_UNESCAPED_SLASHES);
PHP

chmod 644 "$DOCROOT/server/online" "$DOCROOT/server/json"

# 6) try to use existing webserver, else start PHP built-in on 8181
PORT=80
if systemctl is-active --quiet nginx 2>/dev/null; then systemctl reload nginx || true
elif systemctl is-active --quiet apache2 2>/dev/null || systemctl is-active --quiet httpd 2>/dev/null; then
  systemctl reload apache2 2>/dev/null || systemctl reload httpd 2>/dev/null || true
else
  PORT=8181
  if ! pgrep -f "php -S 0.0.0.0:$PORT" >/dev/null; then
    nohup php -S 0.0.0.0:$PORT -t "$DOCROOT" >/tmp/php-server.log 2>&1 &
  fi
fi

LAN_IP="$(hostname -I 2>/dev/null | awk "{print \$1}")"
PUB_IP="$(curl -4fsS http://ifconfig.me 2>/dev/null || true)"
[[ -z "$LAN_IP" ]] && LAN_IP="<LAN_IP>"
[[ -z "$PUB_IP" ]] && PUB_IP="<PUBLIC_IP>"

say "Endpoints ready:"
echo "  http://$LAN_IP:$PORT/server/online"
echo "  http://$LAN_IP:$PORT/server/json"
echo "  http://$PUB_IP:$PORT/server/online"
echo "  http://$PUB_IP:$PORT/server/json"

# quick test
COUNT_NOW=$(php -r '"'"'
$cfg="'"$CFG"'"; $p=36712;
if(is_readable($cfg)){$j=json_decode(file_get_contents($cfg),true);if(isset($j["listen"])&&preg_match("/(\d{2,5})$/",(string)$j["listen"],$m))$p=(int)$m[1];}
$ct=trim(shell_exec("command -v conntrack"))?:"/usr/sbin/conntrack";
$cmd="sudo $ct -L -p udp 2>/dev/null | awk '\''$0 ~ (\"dport=$p\") { if (match($0,/src=([0-9.]+)/,m)) print m[1] }'\'' | sort -u | wc -l";
echo trim(shell_exec($cmd)) ?: "0";
'"'"')
say "Current online: $COUNT_NOW"
'
