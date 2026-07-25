#!/bin/bash
# Скрипт установки Xray (VLESS + XTLS-Vision) с настоящим сертификатом Let's Encrypt
# Перед запуском обязательно задай домен:
# export domain=твой-домен.ru

set -e  # Остановка при первой ошибке

# Проверка, что домен задан
if [ -z "$domain" ]; then
    echo "ОШИБКА: переменная domain не задана."
    echo "Выполните: export domain=ваш-домен.ru"
    echo "Затем перезапустите скрипт."
    exit 1
fi

echo ">>> Обновление пакетов и установка зависимостей..."
apt update
apt install curl wget nginx qrencode jq -y

# Создаём корневую папку веб-сервера, если её нет
mkdir -p /var/www/html

# Останавливаем nginx на всякий случай (чтобы освободить 80 порт)
systemctl stop nginx || true

echo ">>> Установка acme.sh..."
wget -O - https://get.acme.sh | sh
~/.acme.sh/acme.sh --upgrade --auto-upgrade

echo ">>> Выпуск сертификата для $domain..."
# Выпуск через веб-сервер (должен быть запущен nginx на 80 порту)
systemctl start nginx
~/.acme.sh/acme.sh --issue --server letsencrypt -d "$domain" -w /var/www/html --keylength ec-256 --force

echo ">>> Установка сертификата в папку Xray..."
mkdir -p /usr/local/etc/xray/xray_cert/
~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
    --fullchain-file /usr/local/etc/xray/xray_cert/xray.crt \
    --key-file /usr/local/etc/xray/xray_cert/xray.key
chmod +r /usr/local/etc/xray/xray_cert/xray.key

echo ">>> Настройка автопродления сертификата..."
cat << EOF > /usr/local/etc/xray/xray_cert/xray-cert-renew
#!/bin/bash
$HOME/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
    --fullchain-file /usr/local/etc/xray/xray_cert/xray.crt \
    --key-file /usr/local/etc/xray/xray_cert/xray.key
chmod +r /usr/local/etc/xray/xray_cert/xray.key
sudo systemctl restart xray
EOF

chmod +x /usr/local/etc/xray/xray_cert/xray-cert-renew

# Добавляем задание в cron (если ещё нет)
if ! crontab -l 2>/dev/null | grep -q "xray-cert-renew"; then
    (crontab -l 2>/dev/null; echo "0 1 1 * * bash /usr/local/etc/xray/xray_cert/xray-cert-renew") | crontab -
fi

echo ">>> Включение BBR..."
if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo "BBR включён."
else
    echo "BBR уже работает."
fi

echo ">>> Установка Xray..."
bash -c "$(curl -4 -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Генерация ключей
rm -f /usr/local/etc/xray/.keys
touch /usr/local/etc/xray/.keys
echo "shortsid: $(openssl rand -hex 8)" >> /usr/local/etc/xray/.keys
echo "uuid: $(xray uuid)" >> /usr/local/etc/xray/.keys
echo "domain: $domain" >> /usr/local/etc/xray/.keys

export uuid=$(grep 'uuid' /usr/local/etc/xray/.keys | awk -F': ' '{print $2}')

echo ">>> Создание конфигурации Xray..."
cat << EOF > /usr/local/etc/xray/config.json
{
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
                "domain": [
                    "geosite:category-ads-all"
                ],
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
                        "id": "$uuid",
                        "flow": "xtls-rprx-vision",
                        "level": 0
                    }
                ],
                "decryption": "none",
                "fallbacks": [
                  {
                    "dest": 8080
                  }
                ]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "tls",
                "tlsSettings": {
                  "fingerprint": "chrome",
                  "alpn": "http/1.1",
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
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
EOF

echo ">>> Создание управляющих скриптов..."
# userlist
cat << 'EOF' > /usr/local/bin/userlist
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' "/usr/local/etc/xray/config.json"))
if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Список клиентов пуст"
    exit 1
fi
echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done
EOF
chmod +x /usr/local/bin/userlist

# mainuser
cat << 'EOF' > /usr/local/bin/mainuser
#!/bin/bash
protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
uuid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/uuid/ {print $2}')
domain=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/domain/ {print $2}')
fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint' /usr/local/etc/xray/config.json)
link="$protocol://$uuid@$domain:$port?security=tls&alpn=http%2F1.1&fp=$fp&spx=/&type=tcp&flow=xtls-rprx-vision&headerType=none&encryption=none#mainuser"
echo ""
echo "Ссылка для подключения:"
echo "$link"
echo ""
echo "QR-код:"
echo ${link} | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/mainuser

# newuser
cat << 'EOF' > /usr/local/bin/newuser
#!/bin/bash
read -p "Введите имя пользователя (email): " email
if [[ -z "$email" || "$email" == *" "* ]]; then
    echo "Имя пользователя не может быть пустым или содержать пробелы. Попробуйте снова."
    exit 1
fi
user_json=$(jq --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' /usr/local/etc/xray/config.json)
if [[ -z "$user_json" ]]; then
    uuid=$(xray uuid)
    jq --arg email "$email" --arg uuid "$uuid" '.inbounds[0].settings.clients += [{"email": $email, "id": $uuid, "flow": "xtls-rprx-vision"}]' /usr/local/etc/xray/config.json > tmp.json && mv tmp.json /usr/local/etc/xray/config.json
    systemctl restart xray
    index=$(jq --arg email "$email" '.inbounds[0].settings.clients | to_entries[] | select(.value.email == $email) | .key' /usr/local/etc/xray/config.json)
    protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
    port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
    uuid=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].id' /usr/local/etc/xray/config.json)
    username=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].email' /usr/local/etc/xray/config.json)
    domain=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/domain/ {print $2}')
    fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint' /usr/local/etc/xray/config.json)
    link="$protocol://$uuid@$domain:$port?security=tls&alpn=http%2F1.1&fp=$fp&spx=/&type=tcp&flow=xtls-rprx-vision&headerType=none&encryption=none#$username"
    echo ""
    echo "Ссылка для подключения:"
    echo "$link"
    echo ""
    echo "QR-код:"
    echo ${link} | qrencode -t ansiutf8
else
    echo "Пользователь с таким именем уже существует. Попробуйте снова."
fi
EOF
chmod +x /usr/local/bin/newuser

# rmuser
cat << 'EOF' > /usr/local/bin/rmuser
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' "/usr/local/etc/xray/config.json"))
if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Нет клиентов для удаления."
    exit 1
fi
echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done
read -p "Введите номер клиента для удаления: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
    echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
    exit 1
fi
selected_email="${emails[$((choice - 1))]}"
jq --arg email "$selected_email" \
   '(.inbounds[0].settings.clients) |= map(select(.email != $email))' \
   "/usr/local/etc/xray/config.json" > tmp && mv tmp "/usr/local/etc/xray/config.json"
systemctl restart xray
echo "Клиент $selected_email удалён."
EOF
chmod +x /usr/local/bin/rmuser

# sharelink
cat << 'EOF' > /usr/local/bin/sharelink
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' /usr/local/etc/xray/config.json))
for i in "${!emails[@]}"; do
   echo "$((i + 1)). ${emails[$i]}"
done
read -p "Выберите клиента: " client
if ! [[ "$client" =~ ^[0-9]+$ ]] || (( client < 1 || client > ${#emails[@]} )); then
    echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
    exit 1
fi
selected_email="${emails[$((client - 1))]}"
index=$(jq --arg email "$selected_email" '.inbounds[0].settings.clients | to_entries[] | select(.value.email == $email) | .key' /usr/local/etc/xray/config.json)
protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
uuid=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].id' /usr/local/etc/xray/config.json)
username=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].email' /usr/local/etc/xray/config.json)
domain=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/domain/ {print $2}')
fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint' /usr/local/etc/xray/config.json)
link="$protocol://$uuid@$domain:$port?security=tls&alpn=http%2F1.1&fp=$fp&spx=/&type=tcp&flow=xtls-rprx-vision&headerType=none&encryption=none#$username"
echo ""
echo "Ссылка для подключения:"
echo "$link"
echo ""
echo "QR-код:"
echo ${link} | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/sharelink

echo ">>> Настройка Nginx..."
cat << EOF > /etc/nginx/sites-available/default
server {
    listen 80;
    server_name $domain;
    return 301 https://\$http_host\$request_uri;
}

server {
    listen 127.0.0.1:8080;
    server_name $domain;
    root /var/www/html/;
    index index.html;
    add_header Strict-Transport-Security "max-age=63072000" always;
}
EOF

# Создаём индексную страницу, если её нет
[ -f /var/www/html/index.html ] || echo "Xray server $domain" > /var/www/html/index.html

systemctl restart nginx
systemctl restart xray

echo ""
echo "Установка завершена!"
echo "Основная ссылка:"
mainuser
echo ""
cat << 'EOF'
Полезные команды:
  mainuser  - показать ссылку основного пользователя
  newuser   - добавить нового пользователя
  rmuser    - удалить пользователя
  sharelink - получить ссылку для любого пользователя
  userlist  - список пользователей

Конфигурация Xray: /usr/local/etc/xray/config.json
Перезагрузка Xray: systemctl restart xray
Перезагрузка Nginx: systemctl restart nginx
Папка сайта: /var/www/html
EOF
