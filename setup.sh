#!/usr/bin/env bash
# =============================================================================
# setup.sh — 3x-ui + Nginx + сайт-заглушка для freed0m.space
# =============================================================================
# Схема:
#   Xray  :443 (TCP) — VLESS + TLS → легитимные клиенты
#   Xray fallback → nginx :80 → /var/www/html (сайт-заглушка)
#
# Требования перед запуском:
#   - Ubuntu 22.04/24.04
#   - 3x-ui уже установлен
#   - Сертификаты уже есть:
#       /etc/letsencrypt/live/freed0m.space/fullchain.pem
#       /etc/letsencrypt/live/freed0m.space/privkey.pem
#   - Панель 3x-ui на порту 1435
#
# Запуск: bash setup.sh
# =============================================================================

set -euo pipefail

# ── Цвета для вывода ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERR]${NC}  $*" >&2; exit 1; }

# ── Переменные ────────────────────────────────────────────────────────────────
DOMAIN="freed0m.space"
CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
REPO="https://github.com/ADuK58/my-portfolio.git"
WEBROOT="/var/www/html"
XUI_PORT="1435"                    # порт панели 3x-ui
XUI_API="https://127.0.0.1:${XUI_PORT}"

# ── Проверки ──────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Запусти скрипт от root (sudo bash setup.sh)"

info "Проверка сертификатов..."
[[ -f "$CERT" ]] || die "Не найден сертификат: $CERT"
[[ -f "$KEY"  ]] || die "Не найден ключ: $KEY"
success "Сертификаты на месте"

info "Проверка 3x-ui..."
systemctl is-active --quiet x-ui || die "Сервис x-ui не запущен. Запусти: systemctl start x-ui"
success "3x-ui работает"

# ── 1. Зависимости ────────────────────────────────────────────────────────────
info "Установка зависимостей..."
apt-get update -qq
apt-get install -y -qq nginx git ufw curl
success "Зависимости установлены"

# ── 2. Сайт-заглушка ──────────────────────────────────────────────────────────
info "Клонирование репозитория сайта-заглушки..."
if [[ -d "${WEBROOT}/.git" ]]; then
    warn "Репозиторий уже существует, делаем git pull..."
    git -C "$WEBROOT" pull --ff-only
else
    # Очищаем директорию если там что-то есть (стандартная страница nginx)
    rm -rf "${WEBROOT}"
    git clone "$REPO" "$WEBROOT"
fi
chown -R www-data:www-data "$WEBROOT"
success "Сайт развёрнут в ${WEBROOT}"

# ── 3. Nginx ──────────────────────────────────────────────────────────────────
info "Настройка Nginx..."

# Удаляем дефолтный сайт если есть
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/freed0m.space << 'NGINX_CONF'
# freed0m.space — fallback-заглушка для Xray
# Xray принимает TLS на :443, при fallback отдаёт трафик сюда на :80
# Nginx слушает только 127.0.0.1:80 — снаружи напрямую недоступен

server {
    listen 127.0.0.1:80;
    server_name freed0m.space www.freed0m.space;

    root /var/www/html;
    index index.html index.htm;

    # Заголовки безопасности
    add_header X-Content-Type-Options  "nosniff"                   always;
    add_header X-Frame-Options         "SAMEORIGIN"                always;
    add_header Referrer-Policy         "no-referrer"               always;
    add_header Permissions-Policy      "interest-cohort=()"        always;

    # Основной маршрут
    location / {
        try_files $uri $uri/ =404;
        expires 30d;
    }

    # Кэш статики
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot|webp)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # ACME challenge (на случай обновления сертификата через standalone или webroot)
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        allow all;
    }

    # Скрываем dotfiles
    location ~ /\. { deny all; }
    location = /robots.txt  { allow all; log_not_found off; access_log off; }
    location = /favicon.ico { log_not_found off; access_log off; }

    # Логи
    access_log /var/log/nginx/freed0m_access.log;
    error_log  /var/log/nginx/freed0m_error.log;
}
NGINX_CONF

# Включаем сайт
ln -sf /etc/nginx/sites-available/freed0m.space /etc/nginx/sites-enabled/freed0m.space

# Проверяем конфиг
nginx -t || die "Ошибка в конфиге nginx, проверь /etc/nginx/sites-available/freed0m.space"

# Директория для ACME challenge
mkdir -p /var/www/certbot
chown www-data:www-data /var/www/certbot

systemctl enable nginx
systemctl restart nginx
success "Nginx настроен и запущен"

# ── 4. 3x-ui inbound через API ────────────────────────────────────────────────
info "Настройка inbound в 3x-ui..."

# Ждём пока панель поднимется
for i in {1..10}; do
    if curl -sfk "${XUI_API}/login" -o /dev/null 2>&1; then
        break
    fi
    warn "Ожидание панели 3x-ui... (${i}/10)"
    sleep 3
done

# ── Запрашиваем учётные данные панели ────────────────────────────────────────
echo ""
echo -e "${YELLOW}Введи учётные данные панели 3x-ui:${NC}"
read -rp "  Логин [admin]: " XUI_USER
XUI_USER="${XUI_USER:-admin}"
read -rsp "  Пароль: " XUI_PASS
echo ""

# Логин в панель — получаем cookie сессии
COOKIE_JAR=$(mktemp)
LOGIN_RESP=$(curl -sfk -c "$COOKIE_JAR" \
    -X POST "${XUI_API}/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${XUI_USER}&password=${XUI_PASS}" 2>&1) || true

if ! echo "$LOGIN_RESP" | grep -q '"success":true'; then
    rm -f "$COOKIE_JAR"
    die "Не удалось войти в панель 3x-ui. Проверь логин/пароль и порт (${XUI_PORT})."
fi
success "Авторизация в 3x-ui успешна"

# Генерируем UUID для нового клиента
NEW_UUID=$(cat /proc/sys/kernel/random/uuid)
CLIENT_EMAIL="user1"

# Создаём inbound: VLESS + TLS + TCP, fallback на nginx :80
INBOUND_JSON=$(cat <<EOF
{
  "remark": "vless-tls-443",
  "enable": true,
  "listen": "",
  "port": 443,
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "${NEW_UUID}",
        "email": "${CLIENT_EMAIL}",
        "flow": "xtls-rprx-vision"
      }
    ],
    "decryption": "none",
    "fallbacks": [
      {
        "dest": "127.0.0.1:80",
        "xver": 0
      }
    ]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "tls",
    "tlsSettings": {
      "serverName": "${DOMAIN}",
      "minVersion": "1.2",
      "maxVersion": "1.3",
      "alpn": ["http/1.1"],
      "certificates": [
        {
          "certificateFile": "${CERT}",
          "keyFile": "${KEY}"
        }
      ]
    },
    "tcpSettings": {
      "header": { "type": "none" }
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  }
}
EOF
)

ADD_RESP=$(curl -sfk -b "$COOKIE_JAR" \
    -X POST "${XUI_API}/xui/inbound/add" \
    -H "Content-Type: application/json" \
    -d "$INBOUND_JSON" 2>&1) || true

rm -f "$COOKIE_JAR"

if echo "$ADD_RESP" | grep -q '"success":true'; then
    success "Inbound VLESS+TLS на порту 443 создан"
else
    warn "Ответ панели: $ADD_RESP"
    warn "Inbound не удалось создать через API — добавь вручную через панель (инструкция ниже)"
fi

# ── 5. UFW ────────────────────────────────────────────────────────────────────
info "Настройка UFW..."
ufw allow 22/tcp    comment "SSH"
ufw allow 443/tcp   comment "Xray VLESS TLS"
ufw allow 443/udp   comment "Xray UDP"
ufw allow "${XUI_PORT}/tcp" comment "3x-ui panel"

# Закрываем порт 80 снаружи — nginx слушает только 127.0.0.1:80
ufw deny 80/tcp comment "nginx only localhost"

ufw --force enable
success "UFW настроен"

# ── 6. Итог ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Настройка завершена!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Домен:         ${CYAN}${DOMAIN}${NC}"
echo -e "  Xray VLESS:    ${CYAN}:443 TCP${NC}  (TLS, xtls-rprx-vision)"
echo -e "  Fallback:      ${CYAN}127.0.0.1:80${NC} → сайт-заглушка"
echo -e "  Панель 3x-ui:  ${CYAN}http://YOUR_IP:${XUI_PORT}${NC}"
echo ""
echo -e "  Клиент для подключения:"
echo -e "    UUID:     ${YELLOW}${NEW_UUID}${NC}"
echo -e "    Email:    ${YELLOW}${CLIENT_EMAIL}${NC}"
echo -e "    Flow:     ${YELLOW}xtls-rprx-vision${NC}"
echo -e "    SNI:      ${YELLOW}${DOMAIN}${NC}"
echo ""
echo -e "${YELLOW}  Если inbound не создался через API — добавь вручную:${NC}"
echo -e "    Панель → Inbounds → Add"
echo -e "    Protocol: vless | Port: 443 | Network: tcp | Security: tls"
echo -e "    Cert: ${CERT}"
echo -e "    Key:  ${KEY}"
echo -e "    Fallback dest: 127.0.0.1:80"
echo ""
echo -e "  Проверь заглушку:"
echo -e "    curl -sk https://${DOMAIN} | head -5"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
