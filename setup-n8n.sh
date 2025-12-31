#!/bin/bash

# ============================================================
# N8N & Multi-App Management Script (Traefik + Cloudflare Tunnel)
# ============================================================

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

# === Khởi tạo thư mục ===
mkdir -p "$TRAEFIK_DIR" "$APPS_DIR"

# === Functions ===

print_status() { echo -e "${BLUE}>>> $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }

install_core() {
    print_status "Đang cài đặt Docker & Traefik Core..."
    
    # Cài đặt Docker nếu chưa có
    if ! command -v docker &> /dev/null; then
        apt-get update && apt-get install -y docker.io docker-compose-v2
    fi

    docker network create web-proxy 2>/dev/null || true

    if [ ! -f "$CONFIG_FILE" ]; then
        read -p "Nhập Cloudflare Tunnel Token: " CF_TOKEN
        echo "CF_TOKEN=\"$CF_TOKEN\"" > "$CONFIG_FILE"
    else
        source "$CONFIG_FILE"
    fi

    # Docker Compose cho Traefik & Cloudflared
    cat <<EOF > "$TRAEFIK_DIR/docker-compose.yml"
services:
  traefik:
    image: traefik:v2.10
    container_name: traefik
    restart: unless-stopped
    networks: [- web-proxy]
    ports: ["80:80"]
    volumes: ["/var/run/docker.sock:/var/run/docker.sock:ro"]
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    environment: [TUNNEL_TOKEN=$CF_TOKEN]
    command: tunnel --no-autoupdate run
    networks: [web-proxy]

networks:
  web-proxy:
    external: true
EOF
    cd "$TRAEFIK_DIR" && docker compose up -d
    print_success "Hệ thống lõi (Traefik & Cloudflare) đã sẵn sàng."
}

add_n8n() {
    print_status "Đang cấu hình n8n..."
    read -p "Nhập domain cho n8n (vídụ: n8n.domain.com): " N8N_DOMAIN
    mkdir -p "$APPS_DIR/n8n/data"
    chown -R 1000:1000 "$APPS_DIR/n8n/data"
    
    ENC_KEY=$(openssl rand -base64 32)

    cat <<EOF > "$APPS_DIR/n8n/docker-compose.yml"
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    networks: [web-proxy]
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
    cd "$APPS_DIR/n8n" && docker compose up -d
    print_success "n8n đã chạy tại https://$N8N_DOMAIN"
}

add_custom_app() {
    echo -e "${YELLOW}--- Thêm Ứng Dụng Mới ---${NC}"
    echo "1) PHP + MySQL"
    echo "2) Node.js"
    read -p "Chọn loại ứng dụng: " APP_TYPE
    read -p "Nhập tên ứng dụng (viết liền, vd: myweb): " APP_NAME
    read -p "Nhập domain (vd: web.domain.com): " APP_DOMAIN

    APP_PATH="$APPS_DIR/$APP_NAME"
    mkdir -p "$APP_PATH"

    if [ "$APP_TYPE" == "1" ]; then
        # PHP Template
        mkdir -p "$APP_PATH/html"
        cat <<EOF > "$APP_PATH/docker-compose.yml"
services:
  db:
    image: mysql:8.0
    container_name: ${APP_NAME}-db
    environment:
      MYSQL_ROOT_PASSWORD: root_password
    networks: [web-proxy]
  web:
    image: php:8.1-apache
    container_name: ${APP_NAME}-web
    networks: [web-proxy]
    volumes: ["./html:/var/www/html"]
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
        # Node.js Template
        read -p "Cổng nội bộ của App Nodejs (thường là 3000): " NODE_PORT
        cat <<EOF > "$APP_PATH/docker-compose.yml"
services:
  node-app:
    image: node:18-alpine
    container_name: ${APP_NAME}
    working_dir: /app
    networks: [web-proxy]
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
    print_success "Ứng dụng $APP_NAME đã khởi tạo thành công tại domain $APP_DOMAIN!"
}

# === Main Menu ===
while true; do
    echo -e "${BLUE}=== QUẢN LÝ VPS MULTI-APP ===${NC}"
    echo "1) Cài đặt/Cập nhật Core (Traefik & Tunnel)"
    echo "2) Cài đặt n8n"
    echo "3) Thêm ứng dụng mới (PHP/Nodejs)"
    echo "4) Kiểm tra trạng thái các container"
    echo "0) Thoát"
    read -p "Lựa chọn của bạn: " choice

    case $choice in
        1) install_core ;;
        2) add_n8n ;;
        3) add_custom_app ;;
        4) docker ps ;;
        0) exit 0 ;;
        *) echo "Lựa chọn không hợp lệ" ;;
    esac
    echo ""
done