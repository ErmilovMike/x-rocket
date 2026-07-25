# x-rocket

Готовый installer для Xray-core с VLESS + TLS и fallback на локальный Nginx для Shadowrocket.

## Что делает проект

- Получает TLS-сертификат через `acme.sh`.
- Ставит Xray-core.
- Поднимает VLESS на `443`.
- Отдает веб-сайт через Nginx на `127.0.0.1:8080`.
- Использует fallback для маскировки трафика.
- Генерирует ссылки в формате, удобном для Shadowrocket.

## Схема работы

1. Клиент подключается к `443`.
2. Xray принимает TLS и проверяет входящий трафик.
3. VLESS-трафик уходит в Xray.
4. Остальной трафик переходит на fallback `8080`.
5. Nginx отдает обычный сайт.

## Требования

- Ubuntu 22.04 или 24.04.
- Root-доступ.
- Домен с A-записью на ваш VPS.
- Открытые порты `80` и `443`.

## Подготовка
Обновите список репозиториев и установите пакет
```
apt update && apt upgrade -y
```

## Установка
Замените "example.com на ваш домен, укажите просто имя домена, не указывайте http:// или https://:
```
export domain=example.com
```
Запустите скрипт, используя эту команду:
```bash
wget -O install.sh https://raw.githubusercontent.com/ErmilovMike/x-rocket/main/install.sh | bash install.sh
```
