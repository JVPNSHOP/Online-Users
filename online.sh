sudo bash -c 'cat >/tmp/agnudp_one_shot.sh <<'"'"'BASH'"'"'
#!/usr/bin/env bash
set -e

DOCROOT="/var/www/html"
CFG="/etc/hysteria/config.json"
WEB_USER="www-data"

say(){ printf "\033[1;32m==>\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m!!\033[0m %s\n" "$*"; }

say "Installing packages (force IPv4 mirrors)…"
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::ForceIPv4=true update -y
  apt-get -o Acquire::ForceIPv4=true install -y nginx php-fpm php-cli conntrack jq
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y nginx php-fpm php-cli conntrack jq
  systemctl enable --now php-fpm || true
elif command -v yum >/dev/null 2>&1; then
  yum install -y nginx php php-cli conntrack jq
  systemctl enable --now php-fpm || true
else
  echo "Unsupported OS (need apt/dnf/yum)"; exit 1
fi

say "Ensuring docroot & endpoints directory…"
mkdir -p "$DOCROOT/server"

say "Granting sudoers for web user -> conntrack…"
CTBIN="$(command -v conntrack || echo /usr/sbin/conntrack)"
id -u "$WEB_USER" >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin "$WEB_USER" || true
echo "$WEB_USER ALL=(root) NOPASSWD: $CTBIN" > "/etc/sudoers.d/${WEB_USER}-conntrack"
chmod 440 "/etc/sudoers.d/${WEB_USER}-conntrack"
visudo -c >/dev/null || { echo "sudoers syntax error"; exit 1; }

say "Writing /server/online (integer)…"
/bin/cat > "$DOCROOT/server/online" <<'PHP'
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

say "Writing /server/json (JSON)…"
/bin/cat > "$DOCROOT/server/json" <<'PHP'
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

say "Configuring nginx for PHP…"
# choose a php-fpm socket
PHP_SOCK="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1)"
[ -z "$PHP_SOCK" ] && PHP_BACKEND="127.0.0.1:9000" || PHP_BACKEND="unix:${PHP_SOCK}"

cat >/etc/nginx/sites-available/agnudp.conf <<NG
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  root $DOCROOT;
  index index.php index.html;

  location / {
    try_files \$uri \$uri/ =404;
  }

  location ~ \.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass $PHP_BACKEND;
  }
}
NG
ln -sf /etc/nginx/sites-available/agnudp.conf /etc/nginx/sites-enabled/agnudp.conf
[ -f /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default || true

say "Restarting services…"
systemctl enable --now php*-fpm >/dev/null 2>&1 || true
nginx -t
systemctl restart nginx

say "Opening firewall (ufw if present)…"
if command -v ufw >/dev/null 2>&1; then ufw allow 80/tcp || true; fi

LAN_IP="$(hostname -I 2>/dev/null | awk "{print \$1}")"
PUB_IP="$(curl -4fsS http://ifconfig.me 2>/dev/null || true)"
[ -z "$LAN_IP" ] && LAN_IP="<LAN_IP>"
[ -z "$PUB_IP" ] && PUB_IP="<PUBLIC_IP>"

echo
say "Done! Use these URLs:"
echo "  Local:  http://$LAN_IP/server/online"
echo "  Local:  http://$LAN_IP/server/json"
echo "  Public: http://$PUB_IP/server/online"
echo "  Public: http://$PUB_IP/server/json"
echo
say "Quick test:"
php -r '"'"'
$cfg="'"$CFG"'"; $p=36712;
if(is_readable($cfg)){$j=json_decode(file_get_contents($cfg),true);if(isset($j["listen"])&&preg_match("/(\d{2,5})$/",(string)$j["listen"],$m))$p=(int)$m[1];}
$ct=trim(shell_exec("command -v conntrack"))?:"/usr/sbin/conntrack";
$cmd="sudo $ct -L -p udp 2>/dev/null | awk '\''$0 ~ (\"dport=$p\") { if (match($0,/src=([0-9.]+)/,m)) print m[1] }'\'' | sort -u | wc -l";
echo "Online now: ".(trim(shell_exec($cmd))?:0)."\n";
'"'"'
BASH
bash /tmp/agnudp_one_shot.sh'
