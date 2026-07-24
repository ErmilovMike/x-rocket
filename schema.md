
## `schema.md`

```md
# Схема работы Xray с веб-сайтом

```mermaid
flowchart LR
  C[Клиент] -->|443 / VLESS + TLS| X1[Xray на 443]
  C -->|80 HTTP| N1[Nginx]
  X1 --> D{Проверка входящего трафика}
  D -->|VLESS-трафик| X2[Обработчик Xray / outbound]
  D -->|Не-VLESS| F[Fallback на 127.0.0.1:8080]
  F --> N2[Nginx на 127.0.0.1:8080]
  N2 --> W[Сайт-прикрытие в /var/www/html]
  X2 --> I[Интернет]
  N1 --> R[Редирект HTTP -> HTTPS]
  R --> X1
