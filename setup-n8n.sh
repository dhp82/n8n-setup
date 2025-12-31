#!/bin/bash

# === Check Root ===
if [ "$(id -u)" -ne 0 ]; then echo "Vui lòng chạy với sudo"; exit 1; fi

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo "~$REAL_USER")
BASE_DIR="$REAL_HOME/server-apps"
TRAEFIK_DIR="$BASE_DIR/traefik"
APPS_DIR="$BASE_DIR/apps"
CONFIG_FILE="$BASE_DIR/.system_config"

# Colors
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

mkdir -p "$TRAEFIK_DIR" "$APPS_DIR"

# --- Hàm cài đặt Traefik & Cloudflare ---
install_core() {
    echo -e "${BLUE}>>> Cấu hình Traefik & Cloudflare Tunnel...${NC}"
    if [ ! -f "$CONFIG_FILE" ]; then
        read -p "Nhập Cloudflare Tunnel Token: " CF_TOKEN
        echo "CF_TOKEN=\"$CF_TOKEN\"" > "$CONFIG_FILE"
    else
        source "$CONFIG_FILE"
        echo "Đang dùng Token cũ từ config."
    fi

    docker network create web-proxy 2>/dev/null || true

    cat > "$TRAEFIK_DIR/docker-compose.yml" <<EOF
services:
  traefik:
    image: traefik:v2.10
    container_name: traefik
    restart: unless-stopped
    networks:
      - web-proxy
    ports:
      - "80:80"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    environment:
      - TUNNEL_TOKEN=$CF_TOKEN
    command: tunnel --no-autoupdate run
    networks:
      - web-proxy

networks:
  web-proxy:
    external: true
EOF
    cd "$TRAEFIK_DIR" && docker compose up -d
    echo -e "${GREEN}✓ Đã khởi động xong Traefik Core.${NC}"
}

# --- Hàm cài đặt n8n ---
add_n8n() {
    read -p "Nhập domain cho n8n (vd: n8n.domain.com): " N8N_DOMAIN
    APP_PATH="$APPS_DIR/n8n"
    mkdir -p "$APP_PATH/data"
    chown -R 1000:1000 "$APP_PATH/data"
    ENC_KEY=$(openssl rand -base64 32)

    cat > "$APP_PATH/docker-compose.yml" <<EOF
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    networks:
      - web-proxy
    environment:
      - N8N_HOST=$N8N_DOMAIN
      - WEBHOOK_URL=https://$N8N_DOMAIN/
      - N8N_ENCRYPTION_KEY=$ENC_KEY
    volumes:
      - ./data:/home/node/.n8n
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`$N8N_DOMAIN\`)"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"

networks:
  web-proxy:
    external: true
EOF
    cd "$APP_PATH" && docker compose up -d
    echo -e "${GREEN}✓ n8n đã sẵn sàng tại https://$N8N_DOMAIN${NC}"
}

# --- Hàm thêm ứng dụng Web khác ---
add_custom_app() {
    echo -e "${YELLOW}--- Thêm Ứng Dụng Mới ---${NC}"
    echo "1) PHP + MySQL"
    echo "2) Node.js"
    read -p "Chọn loại ứng dụng: " APP_TYPE
    read -p "Nhập tên folder ứng dụng (vd: my-web): " APP_NAME
    read -p "Nhập domain (vd: app.domain.com): " APP_DOMAIN

    APP_PATH="$APPS_DIR/$APP_NAME"
    mkdir -p "$APP_PATH"

    if [ "$APP_TYPE" == "1" ]; then
        mkdir -p "$APP_PATH/html"
        cat > "$APP_PATH/docker-compose.yml" <<EOF
services:
  db:
    image: mysql:8.0
    container_name: ${APP_NAME}-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: root_password
    networks:
      - web-proxy
    volumes:
      - ./db_data:/var/lib/mysql

  web:
    image: php:8.1-apache
    container_name: ${APP_NAME}-web
    restart: unless-stopped
    networks:
      - web-proxy
    volumes:
      - ./html:/var/www/html
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${APP_NAME}.rule=Host(\`$APP_DOMAIN\`)"
      - "traefik.http.services.${APP_NAME}.loadbalancer.server.port=80"

networks:
  web-proxy:
    external: true
EOF
        echo "<?php phpinfo(); ?>" > "$APP_PATH/html/index.php"

    elif [ "$APP_TYPE" == "2" ]; then
        read -p "Cổng nội bộ của App Nodejs (thường là 3000): " NODE_PORT
        cat > "$APP_PATH/docker-compose.yml" <<EOF
services:
  app:
    image: node:18-alpine
    container_name: ${APP_NAME}
    restart: unless-stopped
    networks:
      - web-proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${APP_NAME}.rule=Host(\`$APP_DOMAIN\`)"
      - "traefik.http.services.${APP_NAME}.loadbalancer.server.port=$NODE_PORT"

networks:
  web-proxy:
    external: true
EOF
    fi

    cd "$APP_PATH" && docker compose up -d
    echo -e "${GREEN}✓ Ứng dụng $APP_NAME đã khởi tạo xong!${NC}"
}

# --- Main Menu ---
while true; do
    echo -e "\n${BLUE}========== QUẢN LÝ HỆ THỐNG ==========${NC}"
    echo "1) Cài đặt/Sửa lỗi Core (Traefik & Tunnel)"
    echo "2) Cài đặt/Cập nhật n8n"
    echo "3) Thêm ứng dụng mới (PHP/Node.js)"
    echo "4) Kiểm tra trạng thái các Container"
    echo "0) Thoát"
    read -p "Lựa chọn của bạn: " choice

    case $choice in
        1) install_core ;;
        2) add_n8n ;;
        3) add_custom_app ;;
        4) docker ps ;;
        0) exit 0 ;;
        *) echo -e "${RED}Lựa chọn không hợp lệ!${NC}" ;;
    esac
done