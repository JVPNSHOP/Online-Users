#!/usr/bin/env bash
set -e
DOCROOT=/var/www/html
PORT=8181
WEB_USER=www-data

if ! command -v php >/dev/null 2>&1; then
  apt-get -o Acquire::ForceIPv4=true update -y
  apt-get install -y php-cli conntrack jq
fi

mkdir -p "$DOCROOT/server"

cat > "$DOCROOT/server/online" <<'PHP'
<?php
header("Content-Type: text/plain; charset=UTF-8"); header("Cache-Control: no-store");
$cfg="/etc/hysteria/config.json"; $p=36712;
if (is_readable($cfg)) { $j=json_decode(file_get_contents($cfg),true);
  if (isset($j["listen"]) && preg_match("/(\d{2,5})$/",(string)$j["listen"],$m)) $p=(int)$m[1]; }
$svr=trim(shell_exec('ip -4 addr show scope global | awk "/inet /{print \$2}" | cut -d/ -f1 | head -1'));
$ct =trim(shell_exec("command -v conntrack"))?:"/usr/sbin/conntrack";
$cmdA="sudo $ct -L -p udp 2>/dev/null | awk -v P=$p -v S=\"$svr\" '\''($0 ~ (\" dport=\" P)) || ($0 ~ (\"dst=\" S) && $0 ~ (\" dport=\" P)) { if (match($0,/src=([0-9.]+)/,m)) print m[1] }'\'' | sort -u | wc -l";
$cmdB="sudo $ct -L -p udp 2>/dev/null | awk -v S=\"$svr\" '\''($0 ~ /udp/ && $0 ~ (\"dst=\" S) && $0 ~ /dport=(10000|[1-5][0-9]{4}|6[0-4][0-9]{3}|65000)/) { if (match($0,/src=([0-9.]+)/,m)) print m[1] }'\'' | sort -u | wc -l";
$n=trim(shell_exec($cmdA)); if ($n==="" || intval($n)===0) $n=trim(shell_exec($cmdB)); echo ($n===""?"0":$n);
PHP

cat > "$DOCROOT/server/json" <<'PHP'
<?php
header("Content-Type: application/json; charset=UTF-8"); header("Cache-Control: no-store");
$cfg="/etc/hysteria/config.json"; $p=36712;
if (is_readable($cfg)) { $j=json_decode(file_get_contents($cfg),true);
  if (isset($j["listen"]) && preg_match("/(\d{2,5})$/",(string)$j["listen"],$m)) $p=(int)$m[1]; }
$svr=trim(shell_exec('ip -4 addr show scope global | awk "/inet /{print \$2}" | cut -d/ -f1 | head -1'));
$ct =trim(shell_exec("command -v conntrack"))?:"/usr/sbin/conntrack";
$ipsA="sudo $ct -L -p udp 2>/dev/null | awk -v P=$p -v S=\"$svr\" '\''($0 ~ (\" dport=\" P)) || ($0 ~ (\"dst=\" S) && $0 ~ (\" dport=\" P)) { if (match($0,/src=([0-9.]+)/,m)) print m[1] }'\'' | sort -u";
$ips=trim(shell_exec($ipsA));
if ($ips==="") {
  $ipsB="sudo $ct -L -p udp 2>/dev/null | awk -v S=\"$svr\" '\''($0 ~ /udp/ && $0 ~ (\"dst=\" S) && $0 ~ /dport=(10000|[1-5][0-9]{4}|6[0-4][0-9]{3}|65000)/) { if (match($0,/src=([0-9.]+)/,m)) print m[1] }'\'' | sort -u";
  $ips=trim(shell_exec($ipsB));
}
$arr=$ips===""?[]:explode("\n",$ips);
echo json_encode(["ts"=>gmdate("c"),"port"=>$p,"online"=>count($arr),"ips"=>array_values($arr)], JSON_UNESCAPED_SLASHES);
PHP

chmod 644 "$DOCROOT/server/online" "$DOCROOT/server/json"

CTBIN=$(command -v conntrack || echo /usr/sbin/conntrack)
id -u "$WEB_USER" >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin "$WEB_USER" || true
echo "$WEB_USER ALL=(root) NOPASSWD: $CTBIN" > /etc/sudoers.d/${WEB_USER}-conntrack
chmod 440 /etc/sudoers.d/${WEB_USER}-conntrack
visudo -c >/dev/null || true

pkill -f "php -S 0.0.0.0:$PORT" 2>/dev/null || true
nohup php -S 0.0.0.0:$PORT -t "$DOCROOT" >/tmp/php-endpoint.log 2>&1 &
if command -v ufw >/dev/null 2>&1; then ufw allow "$PORT"/tcp || true; fi
iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true

PUB_IP=$(ip route get 1.1.1.1 2>/dev/null | awk "{print \$7; exit}")
[ -z "$PUB_IP" ] && PUB_IP=$(hostname -I | awk "{print \$1}")
echo
echo "ONLINE endpoint:  http://$PUB_IP:$PORT/server/online"
echo "JSON   endpoint:  http://$PUB_IP:$PORT/server/json"
echo
curl -sS http://127.0.0.1:$PORT/server/online || true; echo
