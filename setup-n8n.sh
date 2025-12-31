#!/bin/bash

# ============================================================
# N8N & Multi-App Management Script - VERSION 2.0 (RESET SUPPORT)
# ============================================================

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

# --- 1. Reset toàn bộ hệ thống (Đập đi xây lại) ---
cleanup_all() {
    echo -e "${RED}⚠️ CẢNH BÁO: Toàn bộ container, dữ liệu n8n và các ứng dụng sẽ bị XÓA SẠCH!${NC}"
    read -p "Bạn có chắc chắn muốn tiếp tục không? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        echo -e "${YELLOW}>>> Đang dọn dẹp hệ thống...${NC}"
        
        # Dừng và xóa toàn bộ container
        docker stop $(docker ps -aq) 2>/dev/null
        docker rm $(docker ps -aq) 2>/dev/null
        
        # Xóa toàn bộ image, network và volume
        docker system prune -a --volumes -f
        
        # Xóa các thư mục cấu hình
        rm -rf "$BASE_DIR"
        
        echo -e "${GREEN}✓ Hệ thống đã được dọn dẹp sạch sẽ. Bạn có thể bắt đầu cài đặt lại.${NC}"
        exit 0
    else
        echo "Đã hủy lệnh reset."
    fi
}

# --- 2. Cài đặt Docker sạch (Mới nhất) ---
install_docker() {
    echo -e "${BLUE}>>> Đang cài đặt Docker phiên bản mới nhất...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl enable docker --now
    echo -e "${GREEN}✓ Docker API Version: $(docker version --format '{{.Server.APIVersion}}')${NC}"
}

# --- 3. Cài đặt Traefik & Tunnel Core ---
install_core() {
    if [ ! -f "$CONFIG_FILE" ]; then
        read -p "Nhập Cloudflare Tunnel Token: " CF_TOKEN
        echo "CF_TOKEN=\"$CF_TOKEN\"" > "$CONFIG_FILE"
    else
        source "$CONFIG_FILE"
    fi

    docker network create web-proxy 2>/dev/null || true

    cat > "$TRAEFIK_DIR/docker-compose.yml" <<'EOF'
version: '3'
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
    labels:
	  - "traefik.enable=true"
	  - "traefik.http.services.reverse-proxy.loadbalancer.server.port=80"
	command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    environment:
      - TUNNEL_TOKEN=${CF_TOKEN}
    command: tunnel --no-autoupdate run
    networks:
      - web-proxy

networks:
  web-proxy:
    external: true
EOF
    sed -i "s/\${CF_TOKEN}/$CF_TOKEN/g" "$TRAEFIK_DIR/docker-compose.yml"
    cd "$TRAEFIK_DIR" && docker compose up -d --force-recreate
    echo -e "${GREEN}✓ Traefik & Tunnel đã khởi động.${NC}"
}

# --- 4. Cài đặt n8n ---
add_n8n() {
    read -p "Nhập domain cho n8n (vd: n8n.bengi.us): " N8N_DOMAIN
    APP_PATH="$APPS_DIR/n8n"
    mkdir -p "$APP_PATH/data"
    chown -R 1000:1000 "$APP_PATH/data"
    ENC_KEY=$(openssl rand -base64 32)

    cat > "$APP_PATH/docker-compose.yml" <<'EOF'
version: '3'
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    networks:
      - web-proxy
    environment:
      - N8N_HOST=${DOMAIN}
      - WEBHOOK_URL=https://${DOMAIN}/
      - N8N_ENCRYPTION_KEY=${KEY}
    volumes:
      - ./data:/home/node/.n8n
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${DOMAIN}`)"
      - "traefik.http.routers.n8n.entrypoints=web"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"

networks:
  web-proxy:
    external: true
EOF
    sed -i "s/\${DOMAIN}/$N8N_DOMAIN/g" "$APP_PATH/docker-compose.yml"
    sed -i "s/\${KEY}/$ENC_KEY/g" "$APP_PATH/docker-compose.yml"

    cd "$APP_PATH" && docker compose up -d --force-recreate
    echo -e "${GREEN}✓ n8n đã sẵn sàng!${NC}"
}

# --- Menu chính ---
while true; do
    echo -e "\n${BLUE}========== QUẢN LÝ DOCKER (Bản Chuẩn) ==========${NC}"
    echo "1. Cài đặt Docker"
    echo "2. Cài đặt Traefik & Cloudflare Tunnel"
    echo "3. Cài đặt n8n"
    echo "4. Xem trạng thái các ứng dụng"
    echo -e "${RED}9. XÓA SẠCH TOÀN BỘ (RESET HỆ THỐNG)${NC}"
    echo "0. Thoát"
    read -p "Lựa chọn: " opt

    case $opt in
        1) install_docker ;;
        2) install_core ;;
        3) add_n8n ;;
        4) docker ps && docker network inspect web-proxy | grep Name ;;
        9) cleanup_all ;;
        0) exit 0 ;;
        *) echo "Lựa chọn không hợp lệ." ;;
    esac
done