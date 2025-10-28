sudo bash -c 'cat > /tmp/setup_agnudp_online.sh << "BASH"
#!/usr/bin/env bash
set -euo pipefail

# ===== Config (ปรับได้ถ้าจำเป็น) =====
DOCROOT_DEFAULT="/var/www/html"
CONFIG_JSON="/etc/hysteria/config.json"
CREATE_JSON=1  # 1 = ทำ /server/json ด้วย
# =====================================

say(){ echo -e "\033[1;32m==>\033[0m $*"; }
warn(){ echo -e "\033[1;33m!!\033[0m $*"; }
err(){ echo -e "\033[1;31mxx\033[0m $*"; }

# 1) เลือก DOCROOT
DOCROOT="$DOCROOT_DEFAULT"
[[ -d /usr/share/nginx/html ]] && DOCROOT="/usr/share/nginx/html"
mkdir -p "$DOCROOT/server"

# 2) หาแพ็กเกจและติดตั้ง
have(){ command -v "$1" >/dev/null 2>&1; }
pm_install(){ if have apt-get; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y && apt-get install -y "$@"
elif have dnf; then dnf install -y "$@"
elif have yum; then yum install -y "$@"
elif have zypper; then zypper install -y "$@"
elif have pacman; then pacman -Sy --noconfirm "$@"
else err "ไม่พบแพ็กเกจเมเนเจอร์ที่รองรับ"; exit 1; fi; }

say "Installing dependencies (conntrack, jq, php-cli/php-fpm/mod_php)…"
have conntrack || pm_install conntrack
have jq        || pm_install jq
have php       || pm_install php-cli

# 3) ตรวจ web server
HAS_NGINX=0; HAS_APACHE=0
systemctl list-unit-files 2>/dev/null | grep -q nginx.service  && HAS_NGINX=1 || true
systemctl list-unit-files 2>/dev/null | grep -Eq "apache2\.service|httpd\.service" && HAS_APACHE=1 || true

WEB_USER="www-data"
if [[ "$HAS_NGINX" -eq 1 ]]; then
  say "Detected nginx; ensuring PHP-FPM running…"
  if ! systemctl list-unit-files | awk "/php.*fpm\.service/ {f=1} END{exit f?0:1}"; then
    pm_install php-fpm
  fi
  PHPFPM_SVC="$(systemctl list-unit-files | awk '"'"'/php.*fpm\.service/ {print $1; exit}'"'"')"
  [[ -n "$PHPFPM_SVC" ]] && systemctl enable --now "$PHPFPM_SVC" || true
  systemctl enable --now nginx || true
  # บางดิสโทร user จะเป็น nginx
  id nginx >/dev/null 2>&1 && WEB_USER="nginx" || WEB_USER="www-data"
elif [[ "$HAS_APACHE" -eq 1 ]]; then
  say "Detected Apache; ensuring PHP module present…"
  if have apt-get; then pm_install libapache2-mod-php; systemctl enable --now apache2 || true
  else pm_install php; systemctl enable --now httpd || true; fi
else
  warn "No nginx/apache detected; will use PHP built-in server on port 8181"
fi

# 4) เตรียม sudoers (เฉพาะกรณี nginx/apache)
CONNTRACK_BIN="$(command -v conntrack)"
if [[ "$HAS_NGINX" -eq 1 || "$HAS_APACHE" -eq 1 ]]; then
  say "Granting sudo for web user ($WEB_USER) to run conntrack…"
  [[ -z "$(id -u "$WEB_USER" 2>/dev/null || true)" ]] && useradd -r -s /usr/sbin/nologin "$WEB_USER" || true
  echo "$WEB_USER ALL=(root) NOPASSWD: $CONNTRACK_BIN" > "/etc/sudoers.d/${WEB_USER}-conntrack"
  chmod 440 "/etc/sudoers.d/${WEB_USER}-conntrack"
  visudo -c >/dev/null || { err "sudoers syntax error"; exit 1; }
fi

# 5) เขียน endpoint
say "Deploying endpoints to $DOCROOT/server …"
cat > "$DOCROOT/server/online" <<PHP
<?php
header('Content-Type: text/plain; charset=UTF-8');
header('Cache-Control: no-store');
function hysteria_listen_port(\$path = "$CONFIG_JSON"){
  \$fb=36712;
  if(!is_readable(\$path)) return \$fb;
  \$j=json_decode(file_get_contents(\$path), true);
  if(!is_array(\$j) || !isset(\$j['listen'])) return \$fb;
  return preg_match('/(\d{2,5})$/', (string)\$j['listen'], \$m) ? (int)\$m[1] : \$fb;
}
\$port = hysteria_listen_port();
\$ct = trim(shell_exec('command -v conntrack')) ?: '/usr/sbin/conntrack';
\$cmd = 'sudo '.escapeshellarg(\$ct).' -L -p udp 2>/dev/null'
     ." | awk '\\$0 ~ (\"dport=\$port\") { if (match(\\$0,/src=([0-9.]+)/,m)) print m[1] }'"
     .' | sort -u | wc -l';
\$out = trim(shell_exec(\$cmd));
echo (ctype_digit(\$out)?\$out:'0');
PHP
chmod 644 "$DOCROOT/server/online"

if [[ "$CREATE_JSON" -eq 1 ]]; then
cat > "$DOCROOT/server/json" <<PHP
<?php
header('Content-Type: application/json; charset=UTF-8');
header('Cache-Control: no-store');
function hysteria_listen_port(\$path = "$CONFIG_JSON"){
  \$fb=36712;
  if(!is_readable(\$path)) return \$fb;
  \$j=json_decode(file_get_contents(\$path), true);
  if(!is_array(\$j) || !isset(\$j['listen'])) return \$fb;
  return preg_match('/(\d{2,5})$/', (string)\$j['listen'], \$m) ? (int)\$m[1] : \$fb;
}
\$port = hysteria_listen_port();
\$ct = trim(shell_exec('command -v conntrack')) ?: '/usr/sbin/conntrack';
\$ips_cmd = 'sudo '.escapeshellarg(\$ct).' -L -p udp 2>/dev/null'
         ." | awk '\\$0 ~ (\"dport=\$port\") { if (match(\\$0,/src=([0-9.]+)/,m)) print m[1] }'"
         .' | sort -u';
\$ips_raw = trim(shell_exec(\$ips_cmd));
\$ips = array_filter(\$ips_raw===''?[]:explode("\n", \$ips_raw));
echo json_encode(["ts"=>gmdate("c"),"port"=>\$port,"online"=>count(\$ips),"ips"=>array_values(\$ips)], JSON_UNESCAPED_SLASHES);
PHP
chmod 644 "$DOCROOT/server/json"
fi

# 6) รีโหลดเว็บ ถ้ามี
if [[ "$HAS_NGINX" -eq 1 ]]; then systemctl reload nginx || true; fi
if [[ "$HAS_APACHE" -eq 1 ]]; then systemctl reload apache2 2>/dev/null || systemctl reload httpd 2>/dev/null || true; fi

# 7) ถ้าไม่มีเว็บเซิร์ฟเวอร์ — เปิด PHP built-in server ที่พอร์ต 8181
SERVE_PORT=80
SERVE_HINT=""
if [[ "$HAS_NGINX" -eq 0 && "$HAS_APACHE" -eq 0 ]]; then
  SERVE_PORT=8181
  SERVE_HINT=" (PHP built-in)"
  if ! pgrep -f "php -S 0.0.0.0:$SERVE_PORT" >/dev/null 2>&1; then
    nohup php -S 0.0.0.0:$SERVE_PORT -t "$DOCROOT" >/tmp/php-server.log 2>&1 &
  fi
fi

# 8) สรุปผล + พิมพ์ลิงก์พร้อม IP
LAN_IP="$(hostname -I 2>/dev/null | awk "{print \$1}")"
PUB_IP="$( (curl -fsS http://ifconfig.me || dig +short myip.opendns.com @resolver1.opendns.com || true) 2>/dev/null | head -1 )"
[[ -z "$LAN_IP" ]] && LAN_IP="<LAN_IP>"
[[ -z "$PUB_IP" ]] && PUB_IP="<PUBLIC_IP>"

say "Ready! Endpoints:"
echo "  • http://$LAN_IP:$SERVE_PORT/server/online$SERVE_HINT"
[[ "$CREATE_JSON" -eq 1 ]] && echo "  • http://$LAN_IP:$SERVE_PORT/server/json$SERVE_HINT"
echo "  • http://$PUB_IP:$SERVE_PORT/server/online"
[[ "$CREATE_JSON" -eq 1 ]] && echo "  • http://$PUB_IP:$SERVE_PORT/server/json"

# 9) ทดสอบทันที (ตัวเลขจำนวน online ปัจจุบัน)
COUNT_NOW=$(php -r '"'"'
$cfg="'"$CONFIG_JSON"'"; $p=36712;
if(is_readable($cfg)){$j=json_decode(file_get_contents($cfg),true);if(isset($j["listen"])&&preg_match("/(\d{2,5})$/",(string)$j["listen"],$m))$p=(int)$m[1];}
$ct=trim(shell_exec("command -v conntrack"))?:"/usr/sbin/conntrack";
$cmd="sudo $ct -L -p udp 2>/dev/null | awk '\''$0 ~ (\"dport=$p\") { if (match($0,/src=([0-9.]+)/,m)) print m[1] }'\'' | sort -u | wc -l";
echo trim(shell_exec($cmd)) ?: "0";
'"'"')
echo
say "Current online (kernel view): $COUNT_NOW"
BASH
chmod +x /tmp/setup_agnudp_online.sh
bash /tmp/setup_agnudp_online.sh'
