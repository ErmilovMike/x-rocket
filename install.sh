#!/usr/bin/env bash
set -euo pipefail

trap 'echo "Ошибка на строке $LINENO"; exit 1' ERR

DOMAIN="${domain:-}"
if [[ -z "$DOMAIN" ]]; then
  echo "Сначала задай domain, например: export domain=example.com"
  exit 1
fi

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Запусти от root"; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Не найдено: $1"; exit 1; }
}

json_escape() {
  python3 - <<'PY' "$1"
import json,sys
print(json.dumps(sys.argv[1])[1:-1])
PY
}

urlencode() {
  python3 - <<'PY' "$1"
import urllib.parse,sys
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

mklink() {
  local uuid="$1"
  local name="$2"
  local host="$3"
  local port="$4"
  local fp="$5"
  local sni="$6"
  printf 'vless://%s@%s:%s?encryption=none&security=tls&flow=xtls-rprx-vision&sni=%s&type=tcp&fp=%s&alpn=http%%2F1.1#%s\n' \
    "$uuid" "$host" "$port" "$sni" "$fp" "$(json_escape "$name")"
}

install_pkgs() {
  apt update
  apt install -y curl wget nginx qrencode jq openssl python3
}

ensure_dirs() {
  mkdir -p /usr/local/etc/xray/xray_cert /var/www/html
}

install_acme() {
  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    curl https://get.acme.sh | sh
  fi
  /root/.acme.sh/acme.sh --upgrade --auto-upgrade
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
}

issue_cert() {
  /root/.acme.sh/acme.sh --issue --server letsencrypt -d "$DOMAIN" -w /var/www/html --keylength ec-256 --force
  /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file /usr/local/etc/xray/xray_cert/xray.crt \
    --key-file /usr/local/etc/xray/xray_cert/xray.key
  chmod 600 /usr/local/etc/xray/xray_cert/xray.key
}

write_renew_script() {
  cat > /usr/local/etc/xray/xray_cert/xray-cert-renew <<EOF
#!/usr/bin/env bash
set -euo pipefail
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
  --fullchain-file /usr/local/etc/xray/xray_cert/xray.crt \
  --key-file /usr/local/etc/xray/xray_cert/xray.key
chmod 600 /usr/local/etc/xray/xray_cert/xray.key
systemctl restart xray
systemctl reload nginx
EOF
  chmod +x /usr/local/etc/xray/xray_cert/xray-cert-renew
  crontab -l 2>/dev/null | grep -q "xray-cert-renew" || (
    crontab -l 2>/dev/null
    echo "0 1 1 * * /bin/bash /usr/local/etc/xray/xray_cert/xray-cert-renew"
  ) | crontab -
}

enable_bbr() {
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    echo "bbr уже включен"
  else
    grep -q '^net.core.default_qdisc=fq$' /etc/sysctl.conf || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    grep -q '^net.ipv4.tcp_congestion_control=bbr$' /etc/sysctl.conf || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    sysctl -p
  fi
}

install_xray() {
  bash -c "$(curl -4 -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

write_keys() {
  local sid uuidv
  sid="$(openssl rand -hex 8)"
  uuidv="$(xray uuid)"
  cat > /usr/local/etc/xray/.keys <<EOF
shortsid=$sid
uuid=$uuidv
domain=$DOMAIN
EOF
}

read_key() {
  awk -F= -v k="$1" '$1==k{print substr($0, index($0,$2))}' /usr/local/etc/xray/.keys
}

write_xray_config() {
  local uuidv
  uuidv="$(read_key uuid)"
  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "localhost"
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "email": "main",
            "id": "$uuidv",
            "flow": "xtls-rprx-vision",
            "level": 0
          }
        ],
        "decryption": "none",
        "fallbacks": [
          { "dest": 8080 }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "fingerprint": "chrome",
          "certificates": [
            {
              "certificateFile": "/usr/local/etc/xray/xray_cert/xray.crt",
              "keyFile": "/usr/local/etc/xray/xray_cert/xray.key"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
}

write_nginx() {
  cat > /etc/nginx/sites-available/default <<EOF
server {
  listen 80;
  server_name $DOMAIN;
  return 301 https://\$host\$request_uri;
}

server {
  listen 127.0.0.1:8080;
  server_name $DOMAIN;
  root /var/www/html;
  index index.html;
  add_header Strict-Transport-Security "max-age=63072000" always;
}
EOF

  if [[ -f /var/www/html/index.nginx-debian.html ]]; then
    mv /var/www/html/index.nginx-debian.html /var/www/html/index.html
  fi
}

write_tools() {
  cat > /usr/local/bin/userlist <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mapfile -t emails < <(jq -r '.inbounds[0].settings.clients[].email' /usr/local/etc/xray/config.json)
[[ ${#emails[@]} -gt 0 ]] || { echo "Список клиентов пуст"; exit 1; }
for i in "${!emails[@]}"; do
  echo "$((i+1)). ${emails[$i]}"
done
EOF
  chmod +x /usr/local/bin/userlist

  cat > /usr/local/bin/mainuser <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
uuid=$(awk -F= '/^uuid=/{print $2}' /usr/local/etc/xray/.keys)
domain=$(awk -F= '/^domain=/{print $2}' /usr/local/etc/xray/.keys)
fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint' /usr/local/etc/xray/config.json)
link="vless://${uuid}@${domain}:${port}?encryption=none&security=tls&flow=xtls-rprx-vision&sni=${domain}&type=tcp&fp=${fp}&alpn=http%2F1.1#main"
echo "$link"
echo "$link" | qrencode -t ansiutf8
EOF
  chmod +x /usr/local/bin/mainuser

  cat > /usr/local/bin/newuser <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
read -r -p "Введите имя пользователя (email): " email
[[ -n "$email" && "$email" != *" "* ]] || { echo "Имя не может быть пустым и не должно содержать пробелы"; exit 1; }
exists=$(jq -r --arg email "$email" '.inbounds[0].settings.clients | any(.email == $email)' /usr/local/etc/xray/config.json)
[[ "$exists" == "true" ]] && { echo "Пользователь уже существует"; exit 1; }

nuuid=$(xray uuid)
tmp=$(mktemp)
jq --arg email "$email" --arg uuid "$nuuid" \
  '.inbounds[0].settings.clients += [{"email": $email, "id": $uuid, "flow": "xtls-rprx-vision", "level": 0}]' \
  /usr/local/etc/xray/config.json > "$tmp"
mv "$tmp" /usr/local/etc/xray/config.json
systemctl restart xray

domain=$(awk -F= '/^domain=/{print $2}' /usr/local/etc/xray/.keys)
fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint' /usr/local/etc/xray/config.json)
enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$email")
link="vless://${nuuid}@${domain}:443?encryption=none&security=tls&flow=xtls-rprx-vision&sni=${domain}&type=tcp&fp=${fp}&alpn=http%2F1.1#${enc}"
echo "$link"
echo "$link" | qrencode -t ansiutf8
EOF
  chmod +x /usr/local/bin/newuser

  cat > /usr/local/bin/rmuser <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mapfile -t emails < <(jq -r '.inbounds[0].settings.clients[].email' /usr/local/etc/xray/config.json)
[[ ${#emails[@]} -gt 0 ]] || { echo "Нет клиентов"; exit 1; }
for i in "${!emails[@]}"; do
  echo "$((i+1)). ${emails[$i]}"
done
read -r -p "Введите номер клиента для удаления: " choice
[[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#emails[@]} )) || { echo "Неверный номер"; exit 1; }
selected="${emails[$((choice-1))]}"
tmp=$(mktemp)
jq --arg email "$selected" '(.inbounds[0].settings.clients) |= map(select(.email != $email))' \
  /usr/local/etc/xray/config.json > "$tmp"
mv "$tmp" /usr/local/etc/xray/config.json
systemctl restart xray
echo "Клиент $selected удалён"
EOF
  chmod +x /usr/local/bin/rmuser

  cat > /usr/local/bin/sharelink <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mapfile -t emails < <(jq -r '.inbounds[0].settings.clients[].email' /usr/local/etc/xray/config.json)
[[ ${#emails[@]} -gt 0 ]] || { echo "Нет клиентов"; exit 1; }
for i in "${!emails[@]}"; do
  echo "$((i+1)). ${emails[$i]}"
done
read -r -p "Выберите клиента: " client
[[ "$client" =~ ^[0-9]+$ ]] && (( client >= 1 && client <= ${#emails[@]} )) || { echo "Неверный номер"; exit 1; }
selected="${emails[$((client-1))]}"
uuid=$(jq -r --arg email "$selected" '.inbounds[0].settings.clients[] | select(.email == $email) | .id' /usr/local/etc/xray/config.json)
domain=$(awk -F= '/^domain=/{print $2}' /usr/local/etc/xray/.keys)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint' /usr/local/etc/xray/config.json)
enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$selected")
link="vless://${uuid}@${domain}:${port}?encryption=none&security=tls&flow=xtls-rprx-vision&sni=${domain}&type=tcp&fp=${fp}&alpn=http%2F1.1#${enc}"
echo "$link"
echo "$link" | qrencode -t ansiutf8
EOF
  chmod +x /usr/local/bin/sharelink
}

write_help() {
  cat > "$HOME/help" <<'EOF'
Команды для управления пользователями Xray:

mainuser  - ссылка для основного пользователя
newuser   - добавить нового пользователя
rmuser    - удалить пользователя
sharelink - ссылка для выбранного пользователя
userlist  - список клиентов

Файлы проекта:

/usr/local/etc/xray/config.json      - конфиг Xray
/usr/local/etc/xray/.keys            - служебные данные
/usr/local/etc/xray/xray_cert/       - сертификаты
/var/www/html                        - сайт-прикрытие
EOF
}

start_services() {
  nginx -t
  xray run -test -config /usr/local/etc/xray/config.json
  systemctl restart xray
  systemctl restart nginx
}

main() {
  install_pkgs
  ensure_dirs
  install_acme
  issue_cert
  write_renew_script
  enable_bbr
  install_xray
  write_keys
  write_xray_config
  write_nginx
  write_tools
  start_services
  write_help
  echo "Установка завершена"
  mainuser
}

main "$@"
