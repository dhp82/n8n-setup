#!/bin/bash

# ============================================================
# N8N & App Manager (PHP/Node.js) - Cloudflare Zero Trust
# ============================================================

# Kiểm tra quyền root
if [ "$(id -u)" -ne 0 ]; then
   echo "Vui lòng chạy với quyền sudo: sudo bash $0"
   exit 1
fi

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo "~$REAL_USER")
NETWORK_NAME="web_proxy"

# === Màu sắc cho terminal ===
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# === Hàm tạo Docker Network chung ===
setup_network() {
    if ! docker network inspect $NETWORK_NAME >/dev/null 2>&1; then
        echo -e "${BLUE}Đang tạo network $NETWORK_NAME...${NC}"
        docker network create $NETWORK_NAME
    fi
}

# === Hàm cài đặt N8N (Theo bài viết) ===
install_n8n() {
    setup_network
    N8N_DIR="$REAL_HOME/n8n-stack"
    mkdir -p "$N8N_DIR"
    
    read -p "Nhập Main Domain (VD: domain.com): " DOMAIN
    read -p "Nhập UI Subdomain (VD: n8n): " UI_SUB
    read -p "Nhập Webhook Subdomain (VD: webhook): " WH_SUB
    read -p "Nhập Cloudflare Tunnel Token: " CF_TOKEN

    cat > "$N8N_DIR/.env" << EOF
DOMAIN_NAME=$DOMAIN
N8N_HOST=$UI_SUB.$DOMAIN
WEBHOOK_URL=https://$WH_SUB.$DOMAIN/
TUNNEL_TOKEN=$CF_TOKEN
POSTGRES_USER=n8n_user
POSTGRES_PASSWORD=$(openssl rand -hex 12)
POSTGRES_DB=n8n_db
N8N_ENCRYPTION_KEY=$(openssl rand -hex 24)
EOF

    cat > "$N8N_DIR/docker-compose.yml" << EOF
version: '3.8'
services:
  traefik:
    image: traefik:v2.10
    container_name: traefik
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:5678"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - $NETWORK_NAME

  postgres:
    image: postgres:16-alpine
    container_name: n8n_db
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    networks:
      - default
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n_app
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_USER=\${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - N8N_HOST=\${N8N_HOST}
      - WEBHOOK_URL=\${WEBHOOK_URL}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`\${N8N_HOST}\`) || Host(\`$WH_SUB.\${DOMAIN_NAME}\`)"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
    volumes:
      - ./n8n_data:/home/node/.n8n
    networks:
      - $NETWORK_NAME
      - default

  tunnel:
    image: cloudflare/cloudflared:latest
    container_name: cloudflare_tunnel
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=\${TUNNEL_TOKEN}
    networks:
      - $NETWORK_NAME

networks:
  $NETWORK_NAME:
    external: true
EOF
    cd "$N8N_DIR" && docker compose up -d
    echo -e "${GREEN}N8N đã được cài đặt!${NC}"
}

# === Hàm tạo App PHP + Nginx ===
add_php_app() {
    setup_network
    read -p "Nhập tên App (VD: my-web): " APP_NAME
    read -p "Nhập Domain cho App (VD: web.domain.com): " APP_DOMAIN
    
    APP_DIR="$REAL_HOME/$APP_NAME"
    mkdir -p "$APP_DIR/src"

    # Tạo file nginx.conf
    cat > "$APP_DIR/nginx.conf" << EOF
server {
    listen 80;
    root /var/www/html;
    index index.php index.html;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php$ {
        fastcgi_pass php-app:9000;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF
    # Tạo Docker Compose
    cat > "$APP_DIR/docker-compose.yml" << EOF
version: '3.8'
services:
  php-app:
    image: php:8.2-fpm
    container_name: ${APP_NAME}_php
    volumes:
      - ./src:/var/www/html
    networks:
      - app_net
      - $NETWORK_NAME

  nginx:
    image: nginx:alpine
    container_name: ${APP_NAME}_nginx
    volumes:
      - ./src:/var/www/html
      - ./nginx.conf:/etc/nginx/conf.d/default.conf
    networks:
      - $NETWORK_NAME
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${APP_NAME}.rule=Host(\`$APP_DOMAIN\`)"
      - "traefik.http.services.${APP_NAME}.loadbalancer.server.port=80"

  db:
    image: mysql:8.0
    container_name: ${APP_NAME}_db
    environment:
      MYSQL_ROOT_PASSWORD: $(openssl rand -hex 8)
      MYSQL_DATABASE: app_db
    networks:
      - app_net

networks:
  app_net:
  $NETWORK_NAME:
    external: true
EOF
    echo "<?php phpinfo(); ?>" > "$APP_DIR/src/index.php"
    cd "$APP_DIR" && docker compose up -d
    echo -e "${GREEN}App PHP đã tạo tại $APP_DIR. Hãy trỏ domain $APP_DOMAIN về Cloudflare Tunnel!${NC}"
}

# === Hàm tạo App Node.js ===
add_node_app() {
    setup_network
    read -p "Nhập tên App (VD: my-node): " APP_NAME
    read -p "Nhập Domain cho App (VD: api.domain.com): " APP_DOMAIN
    
    APP_DIR="$REAL_HOME/$APP_NAME"
    mkdir -p "$APP_DIR"

    cat > "$APP_DIR/index.js" << EOF
const http = require('http');
http.createServer((req, res) => {
  res.writeHead(200, {'Content-Type': 'text/plain'});
  res.end('Hello from Node.js!');
}).listen(3000);
console.log('Server running on port 3000');
EOF

    cat > "$APP_DIR/Dockerfile" << EOF
FROM node:alpine
WORKDIR /app
COPY index.js .
EXPOSE 3000
CMD ["node", "index.js"]
EOF

    cat > "$APP_DIR/docker-compose.yml" << EOF
version: '3.8'
services:
  node-app:
    build: .
    container_name: ${APP_NAME}_node
    networks:
      - $NETWORK_NAME
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${APP_NAME}.rule=Host(\`$APP_DOMAIN\`)"
      - "traefik.http.services.${APP_NAME}.loadbalancer.server.port=3000"

networks:
  $NETWORK_NAME:
    external: true
EOF
    cd "$APP_DIR" && docker compose up -d --build
    echo -e "${GREEN}App Node.js đã tạo tại $APP_DIR. Hãy trỏ domain $APP_DOMAIN về Cloudflare Tunnel!${NC}"
}

# === Menu ===
clear
echo -e "${BLUE}=== SERVER MANAGER (N8N - PHP - NODEJS) ===${NC}"
echo "1. Cài đặt N8N (Chuẩn Cloudflare Zero Trust)"
echo "2. Thêm ứng dụng PHP (Nginx + MySQL)"
echo "3. Thêm ứng dụng Node.js"
echo "4. Thoát"
read -p "Lựa chọn của bạn: " choice

case $choice in
    1) install_n8n ;;
    2) add_php_app ;;
    3) add_node_app ;;
    *) exit 0 ;;
esac