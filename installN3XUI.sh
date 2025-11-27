#!/bin/bash

# Цвета
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   УНИВЕРСАЛЬНЫЙ NGINX BUILDER v2 (SSL + XRAY)    ${NC}"
echo -e "${GREEN}====================================================${NC}"

# 1. ПРОВЕРКА ROOT
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Запустите скрипт от имени root!${NC}"
  exit 1
fi

# 2. УСТАНОВКА ЗАВИСИМОСТЕЙ
echo -e "${BLUE}[INFO] Установка Nginx и Certbot...${NC}"
apt-get update -qq
apt-get install -y nginx curl certbot -qq

# 3. ВВОД ДОМЕНА
echo ""
echo -e "${GREEN}Введите домен ЭТОГО сервера (например: rus.tunnel.ru):${NC}"
read -p "-> " CURRENT_DOMAIN

if [ -z "$CURRENT_DOMAIN" ]; then echo -e "${RED}Домен обязателен!${NC}"; exit 1; fi

# 4. ВЫБОР ИСТОЧНИКА СЕРТИФИКАТОВ
echo ""
echo -e "${YELLOW}Откуда берем SSL сертификаты?${NC}"
echo "1) Сгенерировать НОВЫЕ бесплатно (Let's Encrypt / Certbot)"
echo "2) У меня уже есть файлы (в папке /root/cert/...)"
read -p "Ваш выбор (1 или 2): " CERT_MODE

FINAL_CRT=""
FINAL_KEY=""

if [ "$CERT_MODE" == "1" ]; then
    # === ГЕНЕРАЦИЯ ЧЕРЕЗ CERTBOT ===
    echo -e "${BLUE}[INFO] Останавливаем Nginx для генерации сертификата...${NC}"
    systemctl stop nginx

    echo -e "${BLUE}[INFO] Запрос сертификата у Let's Encrypt...${NC}"
    # Используем standalone режим (нужен 80 порт)
    certbot certonly --standalone -d "$CURRENT_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Сертификат успешно получен!${NC}"
        # Пути к живым сертификатам Certbot
        FINAL_CRT="/etc/letsencrypt/live/$CURRENT_DOMAIN/fullchain.pem"
        FINAL_KEY="/etc/letsencrypt/live/$CURRENT_DOMAIN/privkey.pem"
    else
        echo -e "${RED}ОШИБКА: Не удалось получить сертификат!${NC}"
        echo "Проверьте, что домен $CURRENT_DOMAIN направлен на этот IP адрес (A-запись)."
        exit 1
    fi

else
    # === КОПИРОВАНИЕ ИМЕЮЩИХСЯ ===
    CERT_SRC="/root/cert/$CURRENT_DOMAIN"
    CERT_DEST="/etc/nginx/ssl/$CURRENT_DOMAIN"
    
    echo -e "${BLUE}[INFO] Ищем сертификаты в $CERT_SRC...${NC}"
    if [ ! -f "$CERT_SRC/fullchain.pem" ] || [ ! -f "$CERT_SRC/privkey.pem" ]; then
        echo -e "${RED}ОШИБКА: Файлы не найдены в $CERT_SRC!${NC}"
        echo "Убедитесь, что файлы называются fullchain.pem и privkey.pem"
        exit 1
    fi

    mkdir -p "$CERT_DEST"
    cp "$CERT_SRC/fullchain.pem" "$CERT_DEST/fullchain.pem"
    cp "$CERT_SRC/privkey.pem" "$CERT_DEST/privkey.pem"
    chmod -R 755 "$CERT_DEST"
    
    FINAL_CRT="$CERT_DEST/fullchain.pem"
    FINAL_KEY="$CERT_DEST/privkey.pem"
    echo "Сертификаты скопированы."
fi

# 5. СОЗДАНИЕ ЗАГЛУШКИ
echo ""
echo -e "${BLUE}[INFO] Создание сайта-заглушки...${NC}"
mkdir -p /var/www/html
cat <<EOF > /var/www/html/index.html
<!DOCTYPE html>
<html><head><title>Welcome</title></head>
<body style="width: 35em; margin: 0 auto; font-family: sans-serif; padding-top: 50px;">
<h1>Server Operational</h1>
<p>The system is running correctly.</p>
</body></html>
EOF
chown -R www-data:www-data /var/www/html

# 6. ВЫБОР РЕЖИМА РАБОТЫ
echo ""
echo -e "${GREEN}Выберите роль этого сервера:${NC}"
echo "1) RELAY (Проксирующий сервер в РФ). Пересылает трафик на зарубежный сервер."
echo "2) BACKEND (Сервер с 3XUI). Принимает трафик и отдает в панель."
read -p "Ваш выбор (1 или 2): " SERVER_ROLE

TARGET_HOST=""
if [ "$SERVER_ROLE" == "1" ]; then
    echo ""
    echo -e "${GREEN}Введите домен ЗАРУБЕЖНОГО сервера (куда слать трафик):${NC}"
    read -p "-> " TARGET_HOST
fi

# 7. СБОРКА ЛОКАЦИЙ (LOOP)
LOCATIONS_CONF=""

while true; do
    echo ""
    echo -e "${GREEN}--- Добавление маршрута (Location) ---${NC}"
    echo "1) gRPC (Рекомендуется)"
    echo "2) WebSocket (WS)"
    echo "3) XHTTP / SplitHTTP (Новый стандарт)"
    echo "0) ЗАКОНЧИТЬ и создать конфиг"
    read -p "Выберите транспорт: " TRANSPORT_TYPE

    if [ "$TRANSPORT_TYPE" == "0" ]; then
        break
    fi

    echo -e "Введите путь (Path/ServiceName). Например: ${BLUE}/minecraft${NC} или ${BLUE}/grpc-secret${NC}"
    read -p "-> " PATH_NAME

    LOCAL_PORT=""
    if [ "$SERVER_ROLE" == "2" ]; then
        echo -e "Введите ЛОКАЛЬНЫЙ порт Inbound в 3XUI (например: ${BLUE}2053${NC}):"
        read -p "-> " LOCAL_PORT
    fi

    # ГЕНЕРАЦИЯ БЛОКА LOCATION
    BLOCK=""
    
    # === gRPC ===
    if [ "$TRANSPORT_TYPE" == "1" ]; then
        BLOCK="
    # --- gRPC ($PATH_NAME) ---
    location $PATH_NAME {
        if (\$content_type !~ \"application/grpc\") { return 404; }
        
        client_max_body_size 0;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
"
        if [ "$SERVER_ROLE" == "1" ]; then
            # RELAY
            BLOCK+="\
        grpc_pass grpcs://$TARGET_HOST:443;
        grpc_ssl_server_name on;
        grpc_ssl_name $TARGET_HOST;
"
        else
            # BACKEND
            BLOCK+="\
        grpc_pass grpc://127.0.0.1:$LOCAL_PORT;
"
        fi
        BLOCK+="    }"

    # === WebSocket ===
    elif [ "$TRANSPORT_TYPE" == "2" ]; then
        BLOCK="
    # --- WebSocket ($PATH_NAME) ---
    location $PATH_NAME {
        if (\$http_upgrade != \"websocket\") { return 404; }
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
"
        if [ "$SERVER_ROLE" == "1" ]; then
            # RELAY
            BLOCK+="\
        proxy_pass https://$TARGET_HOST;
        proxy_ssl_server_name on;
        proxy_ssl_name $TARGET_HOST;
        proxy_set_header Host $TARGET_HOST;
"
        else
            # BACKEND
            BLOCK+="\
        proxy_pass http://127.0.0.1:$LOCAL_PORT;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
"
        fi
        BLOCK+="    }"

    # === XHTTP / SplitHTTP ===
    elif [ "$TRANSPORT_TYPE" == "3" ]; then
        BLOCK="
    # --- SplitHTTP/XHTTP ($PATH_NAME) ---
    location $PATH_NAME {
        client_max_body_size 0;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Connection \"\";
        keepalive_timeout 1h;
"
        if [ "$SERVER_ROLE" == "1" ]; then
            # RELAY
            BLOCK+="\
        proxy_pass https://$TARGET_HOST;
        proxy_ssl_server_name on;
        proxy_ssl_name $TARGET_HOST;
        proxy_set_header Host $TARGET_HOST;
"
        else
            # BACKEND
            BLOCK+="\
        proxy_pass http://127.0.0.1:$LOCAL_PORT;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
"
        fi
        BLOCK+="    }"
    fi

    LOCATIONS_CONF+="$BLOCK"$'\n'
    echo -e "${GREEN}Маршрут добавлен! Добавим еще?${NC}"
done

# 8. ЗАПИСЬ ИТОГОВОГО КОНФИГА
echo ""
echo -e "${BLUE}[INFO] Генерация конфигурации Nginx...${NC}"

# Удаляем дефолтные конфиги
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default
rm -f "/etc/nginx/sites-enabled/$CURRENT_DOMAIN.conf"

CONF_FILE="/etc/nginx/sites-available/$CURRENT_DOMAIN.conf"

cat <<EOF > "$CONF_FILE"
server {
    listen 80;
    server_name $CURRENT_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $CURRENT_DOMAIN;

    # Сертификаты
    ssl_certificate $FINAL_CRT;
    ssl_certificate_key $FINAL_KEY;

    # SSL настройки (TLS 1.3)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;

    # Глобальные настройки
    keepalive_timeout 1h;
    client_body_timeout 1h;
    client_max_body_size 0;

    # Сайт-заглушка
    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # === МАРШРУТЫ XRAY ===
$LOCATIONS_CONF
}
EOF

# Активация
ln -sf "$CONF_FILE" "/etc/nginx/sites-enabled/$CURRENT_DOMAIN.conf"

# 9. ФИНАЛ
echo -e "${BLUE}[INFO] Проверка и перезагрузка Nginx...${NC}"
nginx -t

if [ $? -eq 0 ]; then
    systemctl restart nginx
    echo ""
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}   УСПЕШНО! КОНФИГУРАЦИЯ ПРИМЕНЕНА   ${NC}"
    echo -e "${GREEN}==============================================${NC}"
    if [ "$SERVER_ROLE" == "2" ]; then
        echo "Не забудьте настроить 3XUI Inbounds на указанных локальных портах!"
    else
        echo "Relay сервер готов к работе."
    fi
else
    echo -e "${RED}ОШИБКА КОНФИГУРАЦИИ! Проверьте вывод выше.${NC}"
    exit 1
fi