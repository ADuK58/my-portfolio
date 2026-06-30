#!/usr/bin/env bash
#
# freed0m-installer.sh
# Автоматическая установка и настройка 3X-UI + nginx + VLESS/Hysteria2 + WARP
#
# Запуск:  bash <(curl -Ls https://your-host/install.sh)
# Или:     bash install.sh
#
set -euo pipefail

# ───────────────────────── Цвета / вывод ─────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; PLAIN='\033[0m'
info()  { echo -e "${BLUE}[i]${PLAIN} $1"; }
ok()    { echo -e "${GREEN}[✓]${PLAIN} $1"; }
warn()  { echo -e "${YELLOW}[!]${PLAIN} $1"; }
err()   { echo -e "${RED}[✗]${PLAIN} $1" >&2; }
die()   { err "$1"; exit 1; }

step_num=0
step() {
    step_num=$((step_num+1))
    echo ""
    echo -e "${GREEN}━━━ Шаг ${step_num}: $1 ━━━${PLAIN}"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Скрипт нужно запускать от root (sudo bash install.sh)"
    fi
}

require_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Не удалось определить ОС"
    fi
    . /etc/os-release
    case "$ID" in
        ubuntu|debian) ok "ОС: $PRETTY_NAME — поддерживается" ;;
        *) die "Скрипт поддерживает только Ubuntu/Debian. Обнаружено: $PRETTY_NAME" ;;
    esac
}

rand_path() {
    # случайный URL-safe путь длиной 16 символов
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

rand_port() {
    # случайный порт в диапазоне 20000-65000, не занятый
    local p
    while true; do
        p=$(( (RANDOM % 45000) + 20000 ))
        if ! ss -tln | grep -q ":$p "; then
            echo "$p"
            return
        fi
    done
}

rand_pass() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20
}

# ───────────────────────── Баннер ─────────────────────────
clear
echo -e "${GREEN}"
cat << 'BANNER'
  ____               _ ___  __  __         _   _ ___
 | __ )  _ __ ___  __| / _ \|  \/  |  _ __ | | | |_ _|
 |  _ \ | '__/ _ \/ _` | | | | |\/| | | '_ \| | | || |
 | |_) || | |  __/ (_| | |_| | |  | | | | | | |_| || |
 |____/ |_|  \___|\__,_|\___/|_|  |_| |_| |_|\___/|___|

      Автоустановка 3X-UI + nginx + VLESS/Hysteria2
BANNER
echo -e "${PLAIN}"

require_root
require_os

# ───────────────────────── Сбор параметров у пользователя ─────────────────────────
echo ""
echo "Перед началом установки ответьте на несколько вопросов."
echo ""

# --- Домен ---
DOMAIN=""
while [[ -z "$DOMAIN" ]]; do
    read -rp "Введите доменное имя (например, freed0m.space): " DOMAIN
    if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]; then
        warn "Похоже на некорректный домен, попробуйте ещё раз"
        DOMAIN=""
    fi
done
ok "Домен: $DOMAIN"

# --- Проверка DNS ---
info "Проверяю, что DNS-запись домена указывает на этот сервер..."
SERVER_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com)
DOMAIN_IP=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)

if [[ -z "$DOMAIN_IP" ]]; then
    warn "Не удалось определить IP домена $DOMAIN. Убедитесь, что A-запись создана."
    read -rp "Продолжить всё равно? (y/N): " CONT
    [[ "$CONT" =~ ^[Yy]$ ]] || die "Установка прервана. Настройте DNS и запустите скрипт снова."
elif [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
    warn "DNS домена ($DOMAIN_IP) не совпадает с IP сервера ($SERVER_IP)."
    warn "Без верной DNS-записи certbot не сможет выпустить сертификат."
    read -rp "Продолжить всё равно? (y/N): " CONT
    [[ "$CONT" =~ ^[Yy]$ ]] || die "Установка прервана. Настройте DNS и запустите скрипт снова."
else
    ok "DNS настроен верно: $DOMAIN → $SERVER_IP"
fi

# --- Email для certbot ---
read -rp "Email для Let's Encrypt (можно пустым, Enter): " CERT_EMAIL

# --- Протоколы ---
echo ""
echo "Какие протоколы настроить?"
echo "  1) Только VLESS + XTLS-Vision"
echo "  2) Только Hysteria2"
echo "  3) Оба (VLESS + Hysteria2) — рекомендуется"
PROTO_CHOICE=""
while [[ -z "$PROTO_CHOICE" ]]; do
    read -rp "Выбор [1-3]: " PROTO_CHOICE
    case "$PROTO_CHOICE" in
        1|2|3) ;;
        *) warn "Введите 1, 2 или 3"; PROTO_CHOICE="" ;;
    esac
done

INSTALL_VLESS=false
INSTALL_HY2=false
case "$PROTO_CHOICE" in
    1) INSTALL_VLESS=true ;;
    2) INSTALL_HY2=true ;;
    3) INSTALL_VLESS=true; INSTALL_HY2=true ;;
esac

# --- Имя первого клиента ---
read -rp "Имя первого клиента (email в панели, например Eduard): " CLIENT_NAME
CLIENT_NAME=${CLIENT_NAME:-client1}

# --- WARP ---
echo ""
read -rp "Установить Cloudflare WARP (proxy-режим, outbound для Xray)? (y/N): " WARP_CHOICE
INSTALL_WARP=false
[[ "$WARP_CHOICE" =~ ^[Yy]$ ]] && INSTALL_WARP=true

# --- Итоговое подтверждение ---
echo ""
echo "─────────────────────────────────────"
echo "  Домен:        $DOMAIN"
echo "  VLESS:        $([[ $INSTALL_VLESS == true ]] && echo "да" || echo "нет")"
echo "  Hysteria2:    $([[ $INSTALL_HY2 == true ]] && echo "да" || echo "нет")"
echo "  WARP:         $([[ $INSTALL_WARP == true ]] && echo "да" || echo "нет")"
echo "  Клиент:       $CLIENT_NAME"
echo "─────────────────────────────────────"
read -rp "Всё верно? Начать установку? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Установка отменена пользователем"

# ───────────────────────── Генерация случайных параметров ─────────────────────────
PANEL_PORT=$(rand_port)
PANEL_PATH="/$(rand_path)"
SUB_PORT=$(rand_port)
while [[ "$SUB_PORT" == "$PANEL_PORT" ]]; do SUB_PORT=$(rand_port); done
SUB_PATH="/$(rand_path)/"
PANEL_USER="admin_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"
PANEL_PASS=$(rand_pass)

info "Сгенерированы случайные параметры:"
echo "    Порт панели:     $PANEL_PORT"
echo "    Путь панели:     $PANEL_PATH"
echo "    Порт подписки:   $SUB_PORT"
echo "    Путь подписки:   $SUB_PATH"

# ───────────────────────── Шаг: системные пакеты ─────────────────────────
step "Установка системных пакетов"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget git ufw nginx certbot jq uuid-runtime > /dev/null
ok "Пакеты установлены"

# ───────────────────────── Шаг: файрвол ─────────────────────────
step "Настройка файрвола (ufw)"
ufw allow 22/tcp comment 'SSH' > /dev/null
ufw allow 80/tcp comment 'HTTP/ACME' > /dev/null
ufw allow 443/tcp comment 'VLESS/TLS' > /dev/null
if [[ $INSTALL_HY2 == true ]]; then
    ufw allow 443/udp comment 'Hysteria2' > /dev/null
fi
ufw --force enable > /dev/null
ok "Файрвол настроен: 22/tcp, 80/tcp, 443/tcp$([[ $INSTALL_HY2 == true ]] && echo ', 443/udp')"

# ───────────────────────── Шаг: TLS-сертификат ─────────────────────────
step "Получение TLS-сертификата для $DOMAIN"
systemctl stop nginx 2>/dev/null || true

CERTBOT_ARGS=(certonly --standalone -d "$DOMAIN" --agree-tos -n --non-interactive)
if [[ -n "$CERT_EMAIL" ]]; then
    CERTBOT_ARGS+=(--email "$CERT_EMAIL")
else
    CERTBOT_ARGS+=(--register-unsafely-without-email)
fi

if certbot "${CERTBOT_ARGS[@]}"; then
    ok "Сертификат получен"
else
    die "Не удалось получить сертификат. Проверьте DNS и доступность порта 80 (curl ifconfig.me и сверьте с A-записью)."
fi

CERT_FULLCHAIN="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
CERT_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

# Автообновление сертификата
cat > /etc/cron.d/certbot-renew << EOF
0 3 * * * root certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF
ok "Автообновление сертификата настроено (cron)"

systemctl start nginx

# ───────────────────────── Шаг: установка 3X-UI ─────────────────────────
step "Установка 3X-UI"

if [[ -x /usr/bin/x-ui ]]; then
    warn "3X-UI уже установлен, пропускаю установку, использую существующий"
else
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh) <<< "" || die "Установка 3X-UI завершилась с ошибкой"
fi

systemctl enable x-ui > /dev/null 2>&1 || true
systemctl restart x-ui
sleep 2

XUI_DB="/etc/x-ui/x-ui.db"
[[ -f "$XUI_DB" ]] || die "Не найдена база данных x-ui по пути $XUI_DB. Установка повреждена."
ok "3X-UI установлен"

# ───────────────────────── Шаг: настройка панели через CLI x-ui ─────────────────────────
step "Настройка панели 3X-UI (порт, путь, логин, сертификат)"

# x-ui management binary поддерживает прямую настройку панели через подкоманду `setting`
# (реальные флаги: -port -username -password -webBasePath -listenIP -webCert -webCertKey)
x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT" -webBasePath "$PANEL_PATH" -listenIP "127.0.0.1" \
    || die "Не удалось настроить панель через x-ui CLI"

x-ui setting -webCert "$CERT_FULLCHAIN" -webCertKey "$CERT_KEY" \
    || warn "Не удалось задать TLS-сертификат панели через CLI — задайте вручную в Panel Settings"

systemctl restart x-ui
sleep 3
ok "Панель настроена: порт $PANEL_PORT, путь $PANEL_PATH, listen 127.0.0.1"
ok "Логин: $PANEL_USER  /  Пароль: $PANEL_PASS"

# ───────────────────────── Шаг: nginx ─────────────────────────
step "Настройка nginx"

mkdir -p /var/www/html /var/www/certbot
cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html><html><head><title>Welcome</title></head>
<body><h1>It works.</h1></body></html>
EOF

cat > "/etc/nginx/sites-available/$DOMAIN" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        allow all;
    }

    root /var/www/html;
    index index.html;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "no-referrer" always;

    location / {
        try_files \$uri \$uri/ =404;
        expires 30d;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # Панель 3X-UI
    location ^~ ${PANEL_PATH} {
        proxy_pass https://127.0.0.1:${PANEL_PORT};
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 60s;
    }

    # Подписка
    location ^~ ${SUB_PATH} {
        proxy_pass https://127.0.0.1:${SUB_PORT};
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }

    location ~ /\. { deny all; }
    location = /robots.txt { allow all; log_not_found off; access_log off; }
    location = /favicon.ico { log_not_found off; access_log off; }
}
EOF

ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
rm -f /etc/nginx/sites-enabled/default

nginx -t || die "Ошибка в конфигурации nginx — см. вывод выше"
systemctl reload nginx
ok "nginx настроен и перезапущен"

# ───────────────────────── Шаг: логин в панель через API ─────────────────────────
step "Подключение к API панели"

COOKIE_JAR="/tmp/xui-cookie-$$.txt"
PANEL_BASE="https://127.0.0.1:${PANEL_PORT}${PANEL_PATH}"

api_login() {
    local resp
    resp=$(curl -sk -c "$COOKIE_JAR" -b "$COOKIE_JAR" -X POST \
        "${PANEL_BASE}/login" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${PANEL_USER}&password=${PANEL_PASS}")
    if echo "$resp" | grep -q '"success":true'; then
        return 0
    else
        return 1
    fi
}

LOGIN_OK=false
for i in 1 2 3 4 5; do
    if api_login; then
        LOGIN_OK=true
        break
    fi
    sleep 2
done

if [[ "$LOGIN_OK" != true ]]; then
    die "Не удалось залогиниться в панель через API после 5 попыток. Проверьте что x-ui запущен (systemctl status x-ui) и настройте Xray вручную через веб-интерфейс: ${PANEL_BASE}"
fi
ok "Успешный логин в API панели"

# Универсальная функция API-запроса с понятной ошибкой при смене формата ответа
api_post() {
    local path="$1"
    local data="$2"
    local resp
    resp=$(curl -sk -c "$COOKIE_JAR" -b "$COOKIE_JAR" -X POST \
        "${PANEL_BASE}${path}" \
        -H "Content-Type: application/json" \
        -d "$data")
    echo "$resp"
}

check_api_success() {
    local resp="$1"
    local what="$2"
    if echo "$resp" | grep -q '"success":true'; then
        return 0
    else
        warn "API-запрос '$what' не вернул success:true."
        warn "Ответ панели: $(echo "$resp" | head -c 300)"
        warn "Возможно, в установленной версии 3X-UI изменился формат API."
        warn "Настройте этот параметр вручную через веб-интерфейс: ${PANEL_BASE}"
        return 1
    fi
}

# ───────────────────────── Шаг: настройка Subscription через API ─────────────────────────
step "Настройка сервера подписки (Subscription)"

SUB_DOMAIN_URL="https://${DOMAIN}${SUB_PATH}"

SUB_SETTINGS_JSON=$(cat << EOF
{
  "subEnable": true,
  "subListen": "127.0.0.1",
  "subPort": ${SUB_PORT},
  "subPath": "${SUB_PATH}",
  "subDomain": "${SUB_DOMAIN_URL}",
  "subCertFile": "${CERT_FULLCHAIN}",
  "subKeyFile": "${CERT_KEY}",
  "subEncrypt": true,
  "subShowInfo": true
}
EOF
)

# Пробуем новый путь API (v3.x: /panel/api/setting/...), при неудаче — старый (/panel/setting/...)
RESP=$(api_post "/panel/api/setting/update" "$SUB_SETTINGS_JSON")
if ! echo "$RESP" | grep -q '"success":true'; then
    RESP=$(api_post "/panel/setting/update" "$SUB_SETTINGS_JSON")
fi
check_api_success "$RESP" "настройка Subscription" || warn "Доделайте вручную: Panel Settings → Subscription"

systemctl restart x-ui
sleep 3
ok "Subscription настроена: порт $SUB_PORT, путь $SUB_PATH"

# Повторный логин после рестарта x-ui (сессия могла обнулиться)
sleep 1
api_login || warn "Повторный логин после рестарта не удался, попробую продолжить с текущей cookie"

CLIENT_UUID=$(uuidgen)
CLIENT_SUBID=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 16)

# ───────────────────────── Шаг: inbound VLESS + XTLS-Vision ─────────────────────────
if [[ $INSTALL_VLESS == true ]]; then
    step "Создание inbound VLESS + XTLS-Vision"

    VLESS_SETTINGS=$(cat << EOF
{"clients":[{"id":"${CLIENT_UUID}","email":"${CLIENT_NAME}","flow":"xtls-rprx-vision","limitIp":0,"totalGB":0,"expiryTime":0,"enable":true,"tgId":"","subId":"${CLIENT_SUBID}","comment":"","reset":0}],"decryption":"none","fallbacks":[{"name":"","alpn":"","path":"","dest":80,"xver":0}]}
EOF
)

    VLESS_STREAM=$(cat << EOF
{"network":"tcp","security":"tls","tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}},"tlsSettings":{"serverName":"${DOMAIN}","minVersion":"1.2","maxVersion":"1.3","certificates":[{"certificateFile":"${CERT_FULLCHAIN}","keyFile":"${CERT_KEY}"}],"alpn":["http/1.1"],"settings":{"fingerprint":"randomized"}}}
EOF
)

    VLESS_INBOUND_JSON=$(jq -n \
        --arg remark "🌐 VLESS" \
        --argjson port 443 \
        --arg settings "$VLESS_SETTINGS" \
        --arg stream "$VLESS_STREAM" \
        '{
            up: 0, down: 0, total: 0,
            remark: $remark,
            enable: true,
            expiryTime: 0,
            listen: "",
            port: $port,
            protocol: "vless",
            settings: $settings,
            streamSettings: $stream,
            sniffing: "{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"]}"
        }')

    RESP=$(api_post "/panel/api/inbounds/add" "$VLESS_INBOUND_JSON")
    if ! echo "$RESP" | grep -q '"success":true'; then
        RESP=$(api_post "/panel/inbound/add" "$VLESS_INBOUND_JSON")
    fi
    if check_api_success "$RESP" "создание VLESS inbound"; then
        ok "VLESS inbound создан (порт 443, fallback на nginx:80)"
    fi
fi

# ───────────────────────── Шаг: inbound Hysteria2 ─────────────────────────
if [[ $INSTALL_HY2 == true ]]; then
    step "Создание inbound Hysteria2"

    HY2_PASSWORD=$(rand_pass)

    HY2_SETTINGS=$(cat << EOF
{"clients":[{"password":"${HY2_PASSWORD}","email":"${CLIENT_NAME}-hy2","limitIp":0,"totalGB":0,"expiryTime":0,"enable":true,"tgId":"","subId":"${CLIENT_SUBID}","comment":"","reset":0}]}
EOF
)

    HY2_STREAM=$(cat << EOF
{"network":"hysteria2","security":"tls","hysteria2Settings":{"udpIdleTimeout":60},"tlsSettings":{"serverName":"${DOMAIN}","minVersion":"1.2","maxVersion":"1.3","certificates":[{"certificateFile":"${CERT_FULLCHAIN}","keyFile":"${CERT_KEY}"}],"alpn":["h3"]}}
EOF
)

    HY2_INBOUND_JSON=$(jq -n \
        --arg remark "🚀 Hysteria2" \
        --argjson port 443 \
        --arg settings "$HY2_SETTINGS" \
        --arg stream "$HY2_STREAM" \
        '{
            up: 0, down: 0, total: 0,
            remark: $remark,
            enable: true,
            expiryTime: 0,
            listen: "",
            port: $port,
            protocol: "hysteria2",
            settings: $settings,
            streamSettings: $stream,
            sniffing: "{\"enabled\":false,\"destOverride\":[]}"
        }')

    RESP=$(api_post "/panel/api/inbounds/add" "$HY2_INBOUND_JSON")
    if ! echo "$RESP" | grep -q '"success":true'; then
        RESP=$(api_post "/panel/inbound/add" "$HY2_INBOUND_JSON")
    fi
    if check_api_success "$RESP" "создание Hysteria2 inbound"; then
        ok "Hysteria2 inbound создан (порт 443/udp)"
    fi
fi

systemctl restart x-ui
sleep 2

# ───────────────────────── Шаг: Hosts (исправление localhost в ссылках) ─────────────────────────
step "Настройка Hosts (адрес для ссылок клиентов)"
warn "Поле Address в разделе Hosts иногда требует ручной правки через веб-интерфейс,"
warn "если ссылки клиента показывают 'localhost' вместо '${DOMAIN}'."
warn "Панель: ${PANEL_BASE} → меню Hosts → Address → ${DOMAIN}"

# ───────────────────────── Шаг: Cloudflare WARP (опционально) ─────────────────────────
if [[ $INSTALL_WARP == true ]]; then
    step "Установка Cloudflare WARP (proxy-режим)"

    if ! command -v warp-cli &> /dev/null; then
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        DISTRO_CODENAME=$(lsb_release -cs 2>/dev/null || echo "$VERSION_CODENAME")
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${DISTRO_CODENAME} main" \
            | tee /etc/apt/sources.list.d/cloudflare-client.list > /dev/null
        apt-get update -y -qq
        apt-get install -y -qq cloudflare-warp > /dev/null || { warn "Не удалось установить cloudflare-warp — пропускаю шаг WARP"; INSTALL_WARP=false; }
    else
        ok "warp-cli уже установлен"
    fi
fi

if [[ $INSTALL_WARP == true ]]; then
    systemctl enable warp-svc > /dev/null 2>&1 || true
    systemctl start warp-svc
    sleep 3

    if ! warp-cli registration show &> /dev/null; then
        warp-cli registration new > /dev/null 2>&1 || warn "Не удалось зарегистрировать WARP-аккаунт автоматически"
    fi

    warp-cli mode proxy > /dev/null 2>&1 || warn "Не удалось установить режим proxy для WARP"
    warp-cli connect > /dev/null 2>&1 || warn "Не удалось подключить WARP автоматически — выполните 'warp-cli connect' вручную"
    sleep 2

    WARP_STATUS=$(warp-cli status 2>/dev/null | grep -i "status" || echo "unknown")
    if echo "$WARP_STATUS" | grep -qi "connected"; then
        ok "WARP подключен (SOCKS5 на 127.0.0.1:40000)"
    else
        warn "WARP установлен, но статус подключения не подтверждён. Проверьте: warp-cli status"
    fi

    # Автоподключение после перезагрузки
    cat > /etc/systemd/system/warp-connect.service << 'EOF'
[Unit]
Description=Cloudflare WARP connect
After=warp-svc.service
Wants=warp-svc.service

[Service]
Type=oneshot
ExecStart=/usr/bin/warp-cli connect
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable warp-connect > /dev/null 2>&1
    ok "Автоподключение WARP после перезагрузки настроено"

    warn "WARP установлен как SOCKS5-прокси (127.0.0.1:40000)."
    warn "Чтобы Xray использовал его как outbound — добавьте outbound 'warp' (socks, 127.0.0.1:40000)"
    warn "и routing rule в разделе Xray Settings панели: ${PANEL_BASE}"
fi

rm -f "$COOKIE_JAR"

# ───────────────────────── Финал: сохранение и вывод итогов ─────────────────────────
step "Готово"

CREDS_FILE="/root/freed0m-install-info.txt"
cat > "$CREDS_FILE" << EOF
═══════════════════════════════════════════════════
  Установка завершена: $(date '+%Y-%m-%d %H:%M:%S')
═══════════════════════════════════════════════════

ДОМЕН:           $DOMAIN
СЕРВЕР IP:       $SERVER_IP

── Панель 3X-UI ──────────────────────────────────
URL:             https://${DOMAIN}${PANEL_PATH}
Логин:           $PANEL_USER
Пароль:          $PANEL_PASS
Внутр. порт:     $PANEL_PORT (только 127.0.0.1)

── Подписка ──────────────────────────────────────
URL:             ${SUB_DOMAIN_URL}<subId>
Внутр. порт:     $SUB_PORT (только 127.0.0.1)

── Клиент: $CLIENT_NAME ──────────────────────────
EOF

if [[ $INSTALL_VLESS == true ]]; then
    cat >> "$CREDS_FILE" << EOF
VLESS UUID:      $CLIENT_UUID
VLESS subId:     $CLIENT_SUBID
VLESS ссылка:    vless://${CLIENT_UUID}@${DOMAIN}:443?security=tls&flow=xtls-rprx-vision&fp=randomized&alpn=http%2F1.1&type=tcp#${CLIENT_NAME}
EOF
fi

if [[ $INSTALL_HY2 == true ]]; then
    cat >> "$CREDS_FILE" << EOF
Hysteria2 пароль: $HY2_PASSWORD
Hysteria2 ссылка: hysteria2://${HY2_PASSWORD}@${DOMAIN}:443?sni=${DOMAIN}#${CLIENT_NAME}-hy2
EOF
fi

cat >> "$CREDS_FILE" << EOF

── Подписка (универсальная ссылка для клиента) ───
${SUB_DOMAIN_URL}${CLIENT_SUBID}

── WARP ───────────────────────────────────────────
Установлен:      $([[ $INSTALL_WARP == true ]] && echo "да (SOCKS5 127.0.0.1:40000)" || echo "нет")
EOF

chmod 600 "$CREDS_FILE"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${PLAIN}"
echo -e "${GREEN}  Установка завершена!${PLAIN}"
echo -e "${GREEN}═══════════════════════════════════════════════════${PLAIN}"
echo ""
cat "$CREDS_FILE"
echo ""
warn "Полная информация сохранена в: $CREDS_FILE (доступен только root)"
echo ""

if [[ $INSTALL_WARP == true ]]; then
    warn "Не забудьте вручную привязать outbound WARP к routing в Xray Settings панели,"
    warn "если хотите чтобы трафик клиентов шёл через WARP."
fi

echo ""
ok "Проверьте подключение и не забудьте удалить этот файл с сервера после сохранения данных в надёжном месте:"
echo "    shred -u $CREDS_FILE"
echo ""
