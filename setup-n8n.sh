#!/bin/bash

# ============================================================
# N8N Management Script with Traefik & Cloudflare Tunnel Integration
# ============================================================
# Requirements:
#   - Ubuntu/Debian-based Linux (uses apt, dpkg)
#   - Root/sudo access
#   - Internet connection
#   - Cloudflare account with Zero Trust access (optional)
# ============================================================
# Features:
#   - N8N workflow automation
#   - Traefik reverse proxy with SSL
#   - PHP/Apache projects support
#   - Node.js projects support  
#   - MySQL database
#   - phpMyAdmin for database management
#   - Cloudflare Tunnel integration (optional)
# ============================================================

# === Shell Compatibility Check ===
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires Bash. Please run with: bash $0" >&2
    exit 1
fi

# === Check if running as root ===
if [ "$(id -u)" -ne 0 ]; then
   echo "This script must be run as root. Please use 'sudo bash $0'" >&2
   exit 1
fi

# === Determine the real user and home directory ===
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo "~$REAL_USER")

# === Configuration ===
# Base directories
DOCKER_BASE_DIR="$REAL_HOME/docker-stack"
N8N_BASE_DIR="$DOCKER_BASE_DIR/n8n"
N8N_VOLUME_DIR="$N8N_BASE_DIR/n8n_data"
TRAEFIK_DIR="$DOCKER_BASE_DIR/traefik"
MYSQL_DIR="$DOCKER_BASE_DIR/mysql"
PROJECTS_DIR="$DOCKER_BASE_DIR/projects"
PHP_PROJECTS_DIR="$PROJECTS_DIR/php"
NODEJS_PROJECTS_DIR="$PROJECTS_DIR/nodejs"

# Docker Compose files
MAIN_COMPOSE_FILE="$DOCKER_BASE_DIR/docker-compose.yml"
TRAEFIK_COMPOSE_FILE="$TRAEFIK_DIR/docker-compose.yml"

# Config files
N8N_ENCRYPTION_KEY_FILE="$N8N_BASE_DIR/.n8n_encryption_key"
CLOUDFLARED_CONFIG_FILE="/etc/cloudflared/config.yml"
TRAEFIK_CONFIG_FILE="$TRAEFIK_DIR/traefik.yml"
TRAEFIK_DYNAMIC_DIR="$TRAEFIK_DIR/dynamic"
ACME_FILE="$TRAEFIK_DIR/acme/acme.json"

# Default Timezone if system TZ is not set
DEFAULT_TZ="Asia/Ho_Chi_Minh"

# Backup configuration
BACKUP_DIR="$REAL_HOME/docker-stack-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Config file for installation settings
CONFIG_FILE="$REAL_HOME/.docker_stack_config"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# === Script Execution ===
set -e
set -u
set -o pipefail

# === Helper Functions ===
print_section() {
    echo -e "${BLUE}>>> $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ $1${NC}"
}

# === Config Management Functions ===
save_config() {
    local cf_token="$1"
    local cf_hostname="$2"
    local tunnel_id="$3"
    local account_tag="$4"
    local tunnel_secret="$5"
    local mysql_root_pass="${6:-}"
    local mysql_user="${7:-}"
    local mysql_pass="${8:-}"
    local traefik_user="${9:-admin}"
    local traefik_pass="${10:-}"
    
    cat > "$CONFIG_FILE" << EOF
# Docker Stack Installation Configuration
# Generated on: $(date)
CF_TOKEN="$cf_token"
CF_HOSTNAME="$cf_hostname"
TUNNEL_ID="$tunnel_id"
ACCOUNT_TAG="$account_tag"
TUNNEL_SECRET="$tunnel_secret"
MYSQL_ROOT_PASSWORD="$mysql_root_pass"
MYSQL_USER="$mysql_user"
MYSQL_PASSWORD="$mysql_pass"
TRAEFIK_USER="$traefik_user"
TRAEFIK_PASSWORD="$traefik_pass"
INSTALL_DATE="$(date)"
EOF
    
    chown "$REAL_USER":"$REAL_USER" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    print_success "Config đã được lưu tại: $CONFIG_FILE"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    else
        return 1
    fi
}

show_config_info() {
    if load_config; then
        echo -e "${BLUE}📋 Thông tin config hiện có:${NC}"
        echo "  🌐 Hostname: $CF_HOSTNAME"
        echo "  🔑 Tunnel ID: $TUNNEL_ID"
        if [ -n "${MYSQL_USER:-}" ]; then
            echo "  🗄️ MySQL User: $MYSQL_USER"
        fi
        echo "  📅 Ngày cài đặt: $INSTALL_DATE"
        echo ""
        return 0
    else
        return 1
    fi
}

get_cloudflare_info() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}    HƯỚNG DẪN LẤY THÔNG TIN CLOUDFLARE${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
    echo "🔗 Để lấy Cloudflare Tunnel Token và thông tin:"
    echo ""
    echo "1️⃣ Truy cập Cloudflare Zero Trust Dashboard:"
    echo "   👉 https://one.dash.cloudflare.com/"
    echo ""
    echo "2️⃣ Đăng nhập và chọn 'Access' > 'Tunnels'"
    echo ""
    echo "3️⃣ Tạo tunnel mới hoặc chọn tunnel có sẵn:"
    echo "   • Click 'Create a tunnel'"
    echo "   • Chọn 'Cloudflared' connector"
    echo "   • Đặt tên tunnel (ví dụ: docker-stack-tunnel)"
    echo ""
    echo "4️⃣ Lấy thông tin cần thiết:"
    echo "   🔑 Token: Trong phần 'Install and run a connector'"
    echo "   🌐 Hostname: Domain bạn muốn sử dụng (ví dụ: n8n.yourdomain.com)"
    echo ""
    echo "5️⃣ Cấu hình DNS:"
    echo "   • Trong Cloudflare DNS, tạo CNAME record"
    echo "   • Name: subdomain của bạn (ví dụ: n8n)"
    echo "   • Target: [tunnel-id].cfargotunnel.com"
    echo ""
    echo "💡 Lưu ý:"
    echo "   • Domain phải được quản lý bởi Cloudflare"
    echo "   • Token có dạng: eyJhIjoiXXXXXX..."
    echo "   • Hostname có dạng: n8n.yourdomain.com"
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo ""
}

decode_token_info() {
    local token="$1"
    local tunnel_id=""
    local account_tag=""
    local tunnel_secret=""
    
    if command -v base64 >/dev/null 2>&1; then
        local TOKEN_PAYLOAD
        if [[ "$token" == *"."* ]]; then
            TOKEN_PAYLOAD=$(echo "$token" | cut -d'.' -f2)
        else
            TOKEN_PAYLOAD="$token"
        fi
        
        case $((${#TOKEN_PAYLOAD} % 4)) in
            2) TOKEN_PAYLOAD="${TOKEN_PAYLOAD}==" ;;
            3) TOKEN_PAYLOAD="${TOKEN_PAYLOAD}=" ;;
        esac
        
        local DECODED
        DECODED=$(echo "$TOKEN_PAYLOAD" | base64 -d 2>/dev/null || echo "")
        if [ -n "$DECODED" ]; then
            tunnel_id=$(echo "$DECODED" | grep -o '"t":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
            account_tag=$(echo "$DECODED" | grep -o '"a":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
            tunnel_secret=$(echo "$DECODED" | grep -o '"s":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
        fi
    fi
    
    TUNNEL_ID="$tunnel_id"
    ACCOUNT_TAG="$account_tag"
    TUNNEL_SECRET="$tunnel_secret"
}

get_new_config() {
    echo ""
    read -p "❓ Bạn muốn sử dụng Cloudflare Tunnel không? (y/N): " use_cloudflare
    
    if [[ ! "$use_cloudflare" =~ ^[Yy]$ ]]; then
        print_success "Chế độ Local được chọn"
        echo ""
        echo "📝 Thông tin cấu hình Local Mode:"
        echo "  • Các services sẽ chạy qua Traefik tại các subdomain localhost"
        echo "  • N8N: http://n8n.localhost"
        echo "  • phpMyAdmin: http://pma.localhost"
        echo "  • Traefik Dashboard: http://traefik.localhost"
        echo ""
        
        CF_TOKEN="local"
        CF_HOSTNAME="localhost"
        TUNNEL_ID="local"
        ACCOUNT_TAG="local"
        TUNNEL_SECRET="local"
    else
        read -p "❓ Bạn có cần xem hướng dẫn lấy thông tin Cloudflare không? (y/N): " show_guide
        
        if [[ "$show_guide" =~ ^[Yy]$ ]]; then
            get_cloudflare_info
            read -p "Nhấn Enter để tiếp tục sau khi đã chuẩn bị thông tin..."
        fi
        
        echo ""
        echo "📝 Nhập thông tin Cloudflare Tunnel:"
        echo ""
        
        while true; do
            read -p "🔑 Nhập Cloudflare Tunnel Token (hoặc dòng lệnh cloudflared): " CF_TOKEN
            if [ -z "$CF_TOKEN" ]; then
                print_error "Token không được để trống!"
                continue
            fi
            
            if [[ "$CF_TOKEN" =~ cloudflared ]]; then
                CF_TOKEN=$(echo "$CF_TOKEN" | grep -oP 'service install \K.*' | tr -d ' ')
                if [ -z "$CF_TOKEN" ]; then
                    print_error "Không thể trích xuất token từ dòng lệnh. Vui lòng paste lại!"
                    continue
                fi
            fi
            
            if [[ "$CF_TOKEN" =~ ^eyJ[A-Za-z0-9_-]+ ]]; then
                print_success "Token hợp lệ"
                break
            else
                print_error "Token phải bắt đầu bằng 'eyJ'. Vui lòng kiểm tra lại!"
                continue
            fi
        done
        
        while true; do
            read -p "🌐 Nhập Base Domain (ví dụ: yourdomain.com): " CF_HOSTNAME
            if [ -z "$CF_HOSTNAME" ]; then
                print_error "Domain không được để trống!"
                continue
            fi
            
            if [[ "$CF_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
                print_success "Domain hợp lệ"
                break
            else
                print_warning "Domain có vẻ không đúng format. Bạn có chắc chắn muốn tiếp tục? (y/N)"
                read -p "" confirm_hostname
                if [[ "$confirm_hostname" =~ ^[Yy]$ ]]; then
                    break
                fi
            fi
        done
        
        echo ""
        echo "🔍 Đang phân tích token..."
        decode_token_info "$CF_TOKEN"
        
        if [ -n "$TUNNEL_ID" ]; then
            print_success "Đã phân tích được thông tin từ token:"
            echo "  🆔 Tunnel ID: $TUNNEL_ID"
            echo "  🏢 Account Tag: $ACCOUNT_TAG"
        else
            print_warning "Không thể phân tích token, sẽ sử dụng thông tin mặc định"
            TUNNEL_ID="unknown"
            ACCOUNT_TAG="unknown"
            TUNNEL_SECRET="unknown"
        fi
    fi
    
    # MySQL configuration
    echo ""
    echo "📝 Cấu hình MySQL:"
    
    while true; do
        read -s -p "🔐 Nhập MySQL Root Password (ít nhất 8 ký tự): " MYSQL_ROOT_PASSWORD
        echo ""
        if [ ${#MYSQL_ROOT_PASSWORD} -lt 8 ]; then
            print_error "Password phải có ít nhất 8 ký tự!"
            continue
        fi
        break
    done
    
    read -p "👤 Nhập MySQL Username (default: dbuser): " MYSQL_USER
    MYSQL_USER=${MYSQL_USER:-dbuser}
    
    while true; do
        read -s -p "🔐 Nhập MySQL User Password (ít nhất 8 ký tự): " MYSQL_PASSWORD
        echo ""
        if [ ${#MYSQL_PASSWORD} -lt 8 ]; then
            print_error "Password phải có ít nhất 8 ký tự!"
            continue
        fi
        break
    done
    
    # Traefik Dashboard configuration
    echo ""
    echo "📝 Cấu hình Traefik Dashboard:"
    read -p "👤 Nhập Traefik Dashboard Username (default: admin): " TRAEFIK_USER
    TRAEFIK_USER=${TRAEFIK_USER:-admin}
    
    while true; do
        read -s -p "🔐 Nhập Traefik Dashboard Password (ít nhất 6 ký tự): " TRAEFIK_PASSWORD
        echo ""
        if [ ${#TRAEFIK_PASSWORD} -lt 6 ]; then
            print_error "Password phải có ít nhất 6 ký tự!"
            continue
        fi
        break
    done
    
    save_config "$CF_TOKEN" "$CF_HOSTNAME" "$TUNNEL_ID" "$ACCOUNT_TAG" "$TUNNEL_SECRET" \
                "$MYSQL_ROOT_PASSWORD" "$MYSQL_USER" "$MYSQL_PASSWORD" "$TRAEFIK_USER" "$TRAEFIK_PASSWORD"
}

manage_config() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}    QUẢN LÝ CONFIG${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
    
    if show_config_info; then
        echo "Chọn hành động:"
        echo "1. 👁️ Xem chi tiết config"
        echo "2. ✏️ Chỉnh sửa config"
        echo "3. 🗑️ Xóa config"
        echo "4. 📋 Tạo config mới"
        echo "0. ⬅️ Quay lại"
        echo ""
        read -p "Nhập lựa chọn (0-4): " config_choice
        
        case $config_choice in
            1) show_detailed_config ;;
            2) edit_config ;;
            3) delete_config ;;
            4) get_new_config ;;
            0) return 0 ;;
            *) print_error "Lựa chọn không hợp lệ!" ;;
        esac
    else
        echo "📭 Chưa có config nào được lưu."
        echo ""
        read -p "Bạn có muốn tạo config mới không? (y/N): " create_new
        if [[ "$create_new" =~ ^[Yy]$ ]]; then
            get_new_config
        fi
    fi
}

show_detailed_config() {
    if load_config; then
        echo -e "${BLUE}📋 Chi tiết config:${NC}"
        echo ""
        echo "🌐 Hostname: $CF_HOSTNAME"
        echo "🆔 Tunnel ID: $TUNNEL_ID"
        echo "🏢 Account Tag: $ACCOUNT_TAG"
        if [ "${CF_TOKEN:-}" != "local" ]; then
            echo "🔑 Token: ${CF_TOKEN:0:20}...${CF_TOKEN: -10}"
        else
            echo "🔑 Mode: Local"
        fi
        echo "🗄️ MySQL User: ${MYSQL_USER:-not set}"
        echo "👤 Traefik User: ${TRAEFIK_USER:-not set}"
        echo "📅 Ngày cài đặt: $INSTALL_DATE"
        echo ""
        echo "📁 File config: $CONFIG_FILE"
        echo ""
    else
        print_error "Không thể đọc config!"
    fi
}

edit_config() {
    echo "✏️ Chỉnh sửa config:"
    echo ""
    
    if load_config; then
        echo "Config hiện tại:"
        echo "  🌐 Hostname: $CF_HOSTNAME"
        
        if [ "$CF_HOSTNAME" = "localhost" ]; then
            echo "  📝 Mode: Local (không cần Cloudflare)"
            echo ""
            print_warning "⚠️  Bạn đang ở chế độ Local Mode"
            echo "Để chuyển sang Cloudflare Mode, vui lòng tạo config mới"
            echo ""
            return 0
        fi
        
        echo "  🔑 Token: ${CF_TOKEN:0:20}...${CF_TOKEN: -10}"
        echo ""
        
        read -p "Nhập hostname mới (Enter để giữ nguyên): " new_hostname
        read -p "Nhập token mới (Enter để giữ nguyên): " new_token
        
        if [ -n "$new_hostname" ]; then
            CF_HOSTNAME="$new_hostname"
        fi
        
        if [ -n "$new_token" ]; then
            CF_TOKEN="$new_token"
            echo "🔍 Phân tích token mới..."
            decode_token_info "$CF_TOKEN"
            if [ -n "$TUNNEL_ID" ]; then
                print_success "Đã phân tích lại token mới:"
                echo "  🆔 Tunnel ID: $TUNNEL_ID"
                echo "  🏢 Account Tag: $ACCOUNT_TAG"
            else
                print_warning "Không thể phân tích token mới, sẽ sử dụng thông tin cũ"
            fi
        fi
        
        save_config "$CF_TOKEN" "$CF_HOSTNAME" "$TUNNEL_ID" "$ACCOUNT_TAG" "$TUNNEL_SECRET" \
                    "${MYSQL_ROOT_PASSWORD:-}" "${MYSQL_USER:-}" "${MYSQL_PASSWORD:-}" \
                    "${TRAEFIK_USER:-admin}" "${TRAEFIK_PASSWORD:-}"
        print_success "Config đã được cập nhật!"
    else
        print_error "Không thể đọc config hiện tại!"
    fi
}

delete_config() {
    echo "🗑️ Xóa config:"
    echo ""
    
    if [ -f "$CONFIG_FILE" ]; then
        show_config_info
        echo ""
        read -p "⚠️ Bạn có chắc chắn muốn xóa config này không? (y/N): " confirm_delete
        
        if [[ "$confirm_delete" =~ ^[Yy]$ ]]; then
            rm -f "$CONFIG_FILE"
            print_success "Config đã được xóa!"
        else
            echo "Hủy xóa config"
        fi
    else
        print_warning "Không có config nào để xóa"
    fi
}

# === Utility Functions ===
check_disk_space() {
    local required_space_mb="$1"
    local target_dir="$2"
    
    local available_kb
    available_kb=$(df "$target_dir" | awk 'NR==2 {print $4}')
    local available_mb=$((available_kb / 1024))
    
    if [ $available_mb -lt $required_space_mb ]; then
        print_error "Không đủ dung lượng! Cần: ${required_space_mb}MB, Có: ${available_mb}MB"
        return 1
    else
        print_success "Dung lượng đủ: ${available_mb}MB khả dụng"
        return 0
    fi
}

generate_password() {
    openssl rand -base64 16 | tr -d '/+=' | head -c 16
}

generate_htpasswd() {
    local username="$1"
    local password="$2"
    
    # Use htpasswd if available, otherwise use openssl
    if command -v htpasswd &> /dev/null; then
        echo $(htpasswd -nbB "$username" "$password")
    else
        # Fallback using openssl
        local salt=$(openssl rand -base64 6)
        local hash=$(openssl passwd -apr1 -salt "$salt" "$password")
        echo "${username}:${hash}"
    fi
}

health_check() {
    print_section "Kiểm tra sức khỏe các services"
    
    local max_attempts=6
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        echo "🔍 Thử kết nối lần $attempt/$max_attempts..."
        
        # Check containers are running
        if ! docker compose -f "$MAIN_COMPOSE_FILE" ps 2>/dev/null | grep -q "Up"; then
            print_warning "Một số container không chạy"
        fi
        
        # Check Traefik
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/overview 2>/dev/null | grep -q "200"; then
            print_success "Traefik API đang hoạt động"
        fi
        
        # Check N8N
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:5678 2>/dev/null | grep -q "200\|302\|401"; then
            print_success "N8N service đang hoạt động"
        fi
        
        # Check MySQL
        if docker exec mysql mysqladmin ping -h localhost -u root -p"${MYSQL_ROOT_PASSWORD:-}" 2>/dev/null | grep -q "alive"; then
            print_success "MySQL đang hoạt động"
        fi
        
        # If we've successfully checked something, break
        if [ $attempt -ge 2 ]; then
            break
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            echo "⏳ Đợi 10 giây trước khi thử lại..."
            sleep 10
        fi
        
        attempt=$((attempt + 1))
    done
    
    echo ""
    echo "📊 Trạng thái containers:"
    docker compose -f "$MAIN_COMPOSE_FILE" ps 2>/dev/null || true
}

# === Installation Functions ===
install_prerequisites() {
    print_section "Cài đặt các gói cần thiết..."
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release wget apache2-utils
}

install_docker() {
    if command -v docker &> /dev/null; then
        print_success "Docker đã được cài đặt: $(docker --version)"
        
        if ! systemctl is-active docker &> /dev/null; then
            echo ">>> Docker service không chạy, khởi động..."
            systemctl start docker
            systemctl enable docker
            print_success "Docker service đã được khởi động"
        else
            print_success "Docker service đang chạy"
        fi
    else
        echo ">>> Docker not found. Installing Docker..."
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update

        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        print_success "Docker installed successfully: $(docker --version)"

        systemctl start docker
        systemctl enable docker
        print_success "Docker service started and enabled"

        if id "$REAL_USER" &>/dev/null && ! getent group docker | grep -qw "$REAL_USER"; then
          echo ">>> Adding user '$REAL_USER' to the 'docker' group..."
          usermod -aG docker "$REAL_USER"
          echo ">>> NOTE: User '$REAL_USER' needs to log out and log back in for docker group changes to take full effect."
        fi
    fi
}

install_cloudflared() {
    if [ "${CF_HOSTNAME:-localhost}" = "localhost" ]; then
        print_info "Chế độ Local - bỏ qua cài đặt Cloudflared"
        return 0
    fi
    
    if command -v cloudflared &> /dev/null; then
        print_success "Cloudflared đã được cài đặt: $(cloudflared --version 2>/dev/null | head -1)"
    else
        echo ">>> Cloudflared not found. Installing Cloudflared..."
    
        local ARCH
        ARCH=$(dpkg --print-architecture)
        echo ">>> Detected system architecture: $ARCH"
    
        local CLOUDFLARED_DEB_URL
        local CLOUDFLARED_DEB_PATH="/tmp/cloudflared-linux-$ARCH.deb"
    
        case "$ARCH" in
            amd64)
                CLOUDFLARED_DEB_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"
                ;;
            arm64|armhf)
                CLOUDFLARED_DEB_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH.deb"
                ;;
            *)
                print_error "Unsupported architecture: $ARCH. Cannot install Cloudflared automatically."
                exit 1
                ;;
        esac
    
        echo ">>> Downloading Cloudflared package for $ARCH from $CLOUDFLARED_DEB_URL..."
        wget -q "$CLOUDFLARED_DEB_URL" -O "$CLOUDFLARED_DEB_PATH"
    
        if [ $? -ne 0 ]; then
            print_error "Failed to download Cloudflared package."
            exit 1
        fi
    
        echo ">>> Installing Cloudflared package..."
        dpkg -i "$CLOUDFLARED_DEB_PATH"
    
        if [ $? -ne 0 ]; then
            print_error "Failed to install Cloudflared. Please check logs for details."
            exit 1
        fi
    
        rm "$CLOUDFLARED_DEB_PATH"
        print_success "Cloudflared installed successfully: $(cloudflared --version 2>/dev/null | head -1)"
    fi
}

setup_directories() {
    print_section "Tạo cấu trúc thư mục..."
    
    # Main directories
    mkdir -p "$DOCKER_BASE_DIR"
    mkdir -p "$N8N_BASE_DIR"
    mkdir -p "$N8N_VOLUME_DIR"
    mkdir -p "$TRAEFIK_DIR"
    mkdir -p "$TRAEFIK_DIR/acme"
    mkdir -p "$TRAEFIK_DYNAMIC_DIR"
    mkdir -p "$MYSQL_DIR/data"
    mkdir -p "$MYSQL_DIR/init"
    mkdir -p "$PROJECTS_DIR"
    mkdir -p "$PHP_PROJECTS_DIR"
    mkdir -p "$NODEJS_PROJECTS_DIR"
    
    # Set permissions
    chown -R 1000:1000 "$N8N_VOLUME_DIR"
    chmod -R 700 "$N8N_VOLUME_DIR"
    
    # Create acme.json with correct permissions
    touch "$ACME_FILE"
    chmod 600 "$ACME_FILE"
    
    print_success "Cấu trúc thư mục đã được tạo"
}

generate_encryption_key() {
    local N8N_ENCRYPTION_KEY
    if [ -f "$N8N_ENCRYPTION_KEY_FILE" ]; then
        echo ">>> Loading existing N8N encryption key..."
        N8N_ENCRYPTION_KEY=$(cat "$N8N_ENCRYPTION_KEY_FILE")
        print_success "Encryption key loaded from: $N8N_ENCRYPTION_KEY_FILE"
    else
        echo ">>> Generating new N8N encryption key..."
        N8N_ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '\n')
        
        echo "$N8N_ENCRYPTION_KEY" > "$N8N_ENCRYPTION_KEY_FILE"
        chmod 600 "$N8N_ENCRYPTION_KEY_FILE"
        
        print_success "New encryption key generated and saved to: $N8N_ENCRYPTION_KEY_FILE"
        print_warning "⚠️  QUAN TRỌNG: Backup file này để có thể restore credentials sau này!"
    fi
    
    echo "$N8N_ENCRYPTION_KEY"
}

create_traefik_config() {
    print_section "Tạo cấu hình Traefik..."
    
    local SYSTEM_TZ
    SYSTEM_TZ=$(cat /etc/timezone 2>/dev/null || echo "$DEFAULT_TZ")
    
    # Create main traefik.yml config
    cat > "$TRAEFIK_CONFIG_FILE" << 'EOF'
# Traefik Static Configuration
api:
  dashboard: true
  insecure: false

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: letsencrypt

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: traefik-network
  file:
    directory: /etc/traefik/dynamic
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@example.com
      storage: /etc/traefik/acme/acme.json
      httpChallenge:
        entryPoint: web

log:
  level: INFO
  format: common

accessLog:
  format: common
EOF

    # For local mode, modify the config
    if [ "${CF_HOSTNAME:-localhost}" = "localhost" ]; then
        cat > "$TRAEFIK_CONFIG_FILE" << 'EOF'
# Traefik Static Configuration - Local Mode
api:
  dashboard: true
  insecure: true

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: traefik-network
  file:
    directory: /etc/traefik/dynamic
    watch: true

log:
  level: DEBUG
  format: common

accessLog:
  format: common
EOF
    fi
    
    # Create dynamic config for middlewares
    cat > "$TRAEFIK_DYNAMIC_DIR/middlewares.yml" << EOF
http:
  middlewares:
    # Basic Auth middleware
    auth:
      basicAuth:
        users:
          - "${TRAEFIK_HTPASSWD:-admin:\$apr1\$default}"
    
    # Security headers
    security-headers:
      headers:
        browserXssFilter: true
        contentTypeNosniff: true
        forceSTSHeader: true
        stsIncludeSubdomains: true
        stsPreload: true
        stsSeconds: 31536000
        customFrameOptionsValue: "SAMEORIGIN"
        customResponseHeaders:
          X-Robots-Tag: "noindex,nofollow,nosnippet,noarchive,notranslate,noimageindex"
    
    # Rate limiting
    rate-limit:
      rateLimit:
        average: 100
        burst: 50
    
    # Middleware chains
    secure-chain:
      chain:
        middlewares:
          - security-headers
          - rate-limit
EOF

    print_success "Cấu hình Traefik đã được tạo"
}

create_docker_compose() {
    print_section "Tạo Docker Compose file..."
    
    local SYSTEM_TZ
    SYSTEM_TZ=$(cat /etc/timezone 2>/dev/null || echo "$DEFAULT_TZ")
    
    local N8N_ENCRYPTION_KEY
    N8N_ENCRYPTION_KEY=$(generate_encryption_key)
    
    # Escape special characters in passwords for YAML
    local MYSQL_ROOT_PASS_SAFE=$(printf '%s' "${MYSQL_ROOT_PASSWORD:-rootpassword123}" | sed "s/'/'\\\\''/g")
    local MYSQL_PASS_SAFE=$(printf '%s' "${MYSQL_PASSWORD:-password}" | sed "s/'/'\\\\''/g")
    local MYSQL_USER_SAFE="${MYSQL_USER:-dbuser}"
    
    local BASE_DOMAIN="${CF_HOSTNAME:-localhost}"
    
    # Xác định hosts
    local N8N_HOST="n8n.${BASE_DOMAIN}"
    local PMA_HOST="pma.${BASE_DOMAIN}"
    local TRAEFIK_HOST="traefik.${BASE_DOMAIN}"
    
    if [ "$BASE_DOMAIN" = "localhost" ]; then
        N8N_HOST="n8n.localhost"
        PMA_HOST="pma.localhost"
        TRAEFIK_HOST="traefik.localhost"
    fi

    # QUAN TRỌNG: Dùng 'ENDOFFILE' có quote để tránh expansion
    cat > "$MAIN_COMPOSE_FILE" << 'ENDOFFILE'
networks:
  traefik-network:
    name: traefik-network
    driver: bridge
  internal:
    name: internal-network
    driver: bridge

services:
  traefik:
    image: traefik:v3.2
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"
    command:
      - "--api.dashboard=true"
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=traefik-network"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--log.level=INFO"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(`TRAEFIK_HOST_PLACEHOLDER`)"
      - "traefik.http.routers.traefik.entrypoints=web"
      - "traefik.http.routers.traefik.service=api@internal"

  mysql:
    image: mysql:8.0
    container_name: mysql
    restart: unless-stopped
    environment:
      - MYSQL_ROOT_PASSWORD=MYSQL_ROOT_PASS_PLACEHOLDER
      - MYSQL_USER=MYSQL_USER_PLACEHOLDER
      - MYSQL_PASSWORD=MYSQL_PASS_PLACEHOLDER
      - MYSQL_DATABASE=n8n
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - internal
    command: --default-authentication-plugin=mysql_native_password --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    environment:
      - TZ=TIMEZONE_PLACEHOLDER
      - N8N_ENCRYPTION_KEY=ENCRYPTION_KEY_PLACEHOLDER
      - DB_TYPE=mysqldb
      - DB_MYSQLDB_HOST=mysql
      - DB_MYSQLDB_PORT=3306
      - DB_MYSQLDB_DATABASE=n8n
      - DB_MYSQLDB_USER=MYSQL_USER_PLACEHOLDER
      - DB_MYSQLDB_PASSWORD=MYSQL_PASS_PLACEHOLDER
    volumes:
      - n8n_data:/home/node/.n8n
    networks:
      - traefik-network
      - internal
    depends_on:
      mysql:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`N8N_HOST_PLACEHOLDER`)"
      - "traefik.http.routers.n8n.entrypoints=web"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
      - "traefik.docker.network=traefik-network"
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:5678/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  phpmyadmin:
    image: phpmyadmin:latest
    container_name: phpmyadmin
    restart: unless-stopped
    environment:
      - PMA_HOST=mysql
      - PMA_PORT=3306
      - UPLOAD_LIMIT=100M
    networks:
      - traefik-network
      - internal
    depends_on:
      mysql:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.phpmyadmin.rule=Host(`PMA_HOST_PLACEHOLDER`)"
      - "traefik.http.routers.phpmyadmin.entrypoints=web"
      - "traefik.http.services.phpmyadmin.loadbalancer.server.port=80"
      - "traefik.docker.network=traefik-network"

volumes:
  mysql_data:
  n8n_data:
ENDOFFILE

    # Thay thế các placeholder bằng giá trị thực
    sed -i "s|TRAEFIK_HOST_PLACEHOLDER|${TRAEFIK_HOST}|g" "$MAIN_COMPOSE_FILE"
    sed -i "s|N8N_HOST_PLACEHOLDER|${N8N_HOST}|g" "$MAIN_COMPOSE_FILE"
    sed -i "s|PMA_HOST_PLACEHOLDER|${PMA_HOST}|g" "$MAIN_COMPOSE_FILE"
    sed -i "s|MYSQL_ROOT_PASS_PLACEHOLDER|${MYSQL_ROOT_PASS_SAFE}|g" "$MAIN_COMPOSE_FILE"
    sed -i "s|MYSQL_USER_PLACEHOLDER|${MYSQL_USER_SAFE}|g" "$MAIN_COMPOSE_FILE"
    sed -i "s|MYSQL_PASS_PLACEHOLDER|${MYSQL_PASS_SAFE}|g" "$MAIN_COMPOSE_FILE"
    sed -i "s|TIMEZONE_PLACEHOLDER|${SYSTEM_TZ}|g" "$MAIN_COMPOSE_FILE"
    sed -i "s|ENCRYPTION_KEY_PLACEHOLDER|${N8N_ENCRYPTION_KEY}|g" "$MAIN_COMPOSE_FILE"

    print_success "Docker Compose file đã được tạo"
}


create_mysql_init() {
    print_section "Tạo MySQL initialization script..."
    
    cat > "$MYSQL_DIR/init/01-init.sql" << EOF
-- Create additional databases if needed
CREATE DATABASE IF NOT EXISTS n8n CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Grant privileges
GRANT ALL PRIVILEGES ON n8n.* TO '${MYSQL_USER:-dbuser}'@'%';
FLUSH PRIVILEGES;
EOF
    
    print_success "MySQL init script đã được tạo"
}

setup_cloudflared() {
    if [ "${CF_HOSTNAME:-localhost}" = "localhost" ]; then
        print_info "Chế độ Local - bỏ qua cấu hình Cloudflared"
        return 0
    fi
    
    print_section "Cấu hình Cloudflared..."
    
    mkdir -p /etc/cloudflared

    cat > "$CLOUDFLARED_CONFIG_FILE" << EOF
# Cloudflare Tunnel Configuration
# Routes traffic through Cloudflare Tunnel to Traefik

ingress:
  # All traffic goes to Traefik
  - service: http://localhost:80
EOF

    # Check if service already exists
    if systemctl is-enabled cloudflared &> /dev/null 2>&1; then
        print_warning "⚠️  Cloudflared service đã được cài đặt!"
        local cf_status
        cf_status=$(systemctl is-active cloudflared 2>/dev/null || echo "unknown")
        print_success "Cloudflared service status: $cf_status"
        
        if [ "$cf_status" != "active" ]; then
            echo ">>> Khởi động lại Cloudflared service..."
            systemctl restart cloudflared
            print_success "Cloudflared service đã được khởi động"
        fi
    else
        echo ">>> Installing Cloudflared service using the provided token..."
        cloudflared service install "$CF_TOKEN"
        print_success "Cloudflared service installed."

        echo ">>> Enabling and starting Cloudflared service..."
        systemctl enable cloudflared
        systemctl start cloudflared
    fi
    
    sleep 5
    echo ">>> Checking Cloudflared service status:"
    systemctl status cloudflared --no-pager || echo "Warning: Cloudflared status check indicates an issue."
}

# === Project Management Functions ===
create_php_project() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}    TẠO PROJECT PHP MỚI${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
    
    read -p "📝 Nhập tên project (ví dụ: myapp): " PROJECT_NAME
    if [ -z "$PROJECT_NAME" ]; then
        print_error "Tên project không được để trống!"
        return 1
    fi
    
    # Sanitize project name
    PROJECT_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
    
    local PROJECT_DIR="$PHP_PROJECTS_DIR/$PROJECT_NAME"
    
    if [ -d "$PROJECT_DIR" ]; then
        print_error "Project '$PROJECT_NAME' đã tồn tại!"
        return 1
    fi
    
    read -p "🗄️ Tạo database cho project? (y/N): " create_db
    local DB_NAME=""
    if [[ "$create_db" =~ ^[Yy]$ ]]; then
        DB_NAME="${PROJECT_NAME}_db"
    fi
    
    local BASE_DOMAIN="${CF_HOSTNAME:-localhost}"
    local PROJECT_HOST="${PROJECT_NAME}.${BASE_DOMAIN}"
    if [ "$BASE_DOMAIN" = "localhost" ]; then
        PROJECT_HOST="${PROJECT_NAME}.localhost"
    fi
    
    echo ""
    print_section "Tạo project PHP: $PROJECT_NAME"
    
    # Create project directory structure
    mkdir -p "$PROJECT_DIR/public"
    mkdir -p "$PROJECT_DIR/src"
    mkdir -p "$PROJECT_DIR/logs"
    
    # Create index.php
    cat > "$PROJECT_DIR/public/index.php" << 'EOF'
<?php
phpinfo();
// Delete this file and add your application code
EOF
    
    # Create docker-compose for the project
    cat > "$PROJECT_DIR/docker-compose.yml" << EOF
# PHP Project: ${PROJECT_NAME}
# Generated on: $(date)

networks:
  traefik-network:
    external: true
  internal:
    external: true
    name: internal-network

services:
  ${PROJECT_NAME}:
    image: php:8.2-apache
    container_name: ${PROJECT_NAME}
    restart: unless-stopped
    environment:
      - TZ=\${TZ:-Asia/Ho_Chi_Minh}
EOF

    if [ -n "$DB_NAME" ]; then
        cat >> "$PROJECT_DIR/docker-compose.yml" << EOF
      - DB_HOST=mysql
      - DB_PORT=3306
      - DB_DATABASE=${DB_NAME}
      - DB_USERNAME=\${MYSQL_USER:-dbuser}
      - DB_PASSWORD=\${MYSQL_PASSWORD:-password}
EOF
    fi

    cat >> "$PROJECT_DIR/docker-compose.yml" << EOF
    volumes:
      - ./public:/var/www/html
      - ./src:/var/www/src
      - ./logs:/var/log/apache2
    networks:
      - traefik-network
EOF

    if [ -n "$DB_NAME" ]; then
        cat >> "$PROJECT_DIR/docker-compose.yml" << EOF
      - internal
EOF
    fi

    cat >> "$PROJECT_DIR/docker-compose.yml" << EOF
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${PROJECT_NAME}.rule=Host(\`${PROJECT_HOST}\`)"
EOF

    if [ "$BASE_DOMAIN" != "localhost" ]; then
        cat >> "$PROJECT_DIR/docker-compose.yml" << EOF
      - "traefik.http.routers.${PROJECT_NAME}.entrypoints=websecure"
      - "traefik.http.routers.${PROJECT_NAME}.tls=true"
      - "traefik.http.routers.${PROJECT_NAME}.tls.certresolver=letsencrypt"
EOF
    else
        cat >> "$PROJECT_DIR/docker-compose.yml" << EOF
      - "traefik.http.routers.${PROJECT_NAME}.entrypoints=web"
EOF
    fi

    cat >> "$PROJECT_DIR/docker-compose.yml" << EOF
      - "traefik.http.services.${PROJECT_NAME}.loadbalancer.server.port=80"
      - "traefik.docker.network=traefik-network"
EOF

    # Create .env file for the project
    cat > "$PROJECT_DIR/.env" << EOF
# Environment variables for ${PROJECT_NAME}
TZ=Asia/Ho_Chi_Minh
MYSQL_USER=${MYSQL_USER:-dbuser}
MYSQL_PASSWORD=${MYSQL_PASSWORD:-password}
EOF

    # Create database if requested
    if [ -n "$DB_NAME" ]; then
        echo ""
        print_section "Tạo database: $DB_NAME"
        
        # Check if MySQL is running
        if docker ps --format '{{.Names}}' | grep -q "^mysql$"; then
            docker exec mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD:-}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true
            docker exec mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD:-}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${MYSQL_USER:-dbuser}'@'%';" 2>/dev/null || true
            docker exec mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD:-}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true
            print_success "Database '$DB_NAME' đã được tạo"
        else
            print_warning "MySQL container không chạy. Hãy chạy 'docker compose up -d' trước, sau đó tạo database thủ công."
        fi
    fi
    
    # Set permissions
    chown -R "$REAL_USER":"$REAL_USER" "$PROJECT_DIR"
    
    echo ""
    print_success "Project PHP '$PROJECT_NAME' đã được tạo!"
    echo ""
    echo "📁 Thư mục project: $PROJECT_DIR"
    echo "🌐 URL: http://${PROJECT_HOST}"
    if [ -n "$DB_NAME" ]; then
        echo "🗄️ Database: $DB_NAME"
    fi
    echo ""
    echo "📋 Để chạy project:"
    echo "   cd $PROJECT_DIR"
    echo "   docker compose up -d"
    echo ""
}

create_nodejs_project() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}    TẠO PROJECT NODE.JS MỚI${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
    
    read -p "📝 Nhập tên project (ví dụ: myapi): " PROJECT_NAME
    if [ -z "$PROJECT_NAME" ]; then
        print_error "Tên project không được để trống!"
        return 1
    fi
    
    # Sanitize project name
    PROJECT_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
    
    local PROJECT_DIR="$NODEJS_PROJECTS_DIR/$PROJECT_NAME"
    
    if [ -d "$PROJECT_DIR" ]; then
        print_error "Project '$PROJECT_NAME' đã tồn tại!"
        return 1
    fi
    
    read -p "🔢 Nhập port cho ứng dụng (default: 3000): " APP_PORT
    APP_PORT=${APP_PORT:-3000}
    
    read -p "🗄️ Tạo database cho project? (y/N): " create_db
    local DB_NAME=""
    if [[ "$create_db" =~ ^[Yy]$ ]]; then
        DB_NAME="${PROJECT_NAME}_db"
    fi
    
    local BASE_DOMAIN="${CF_HOSTNAME:-localhost}"
    local PROJECT_HOST="${PROJECT_NAME}.${BASE_DOMAIN}"
    if [ "$BASE_DOMAIN" = "localhost" ]; then
        PROJECT_HOST="${PROJECT_NAME}.localhost"
    fi
    
    echo ""
    print_section "Tạo project Node.js: $PROJECT_NAME"
    
    # Create project directory structure
    mkdir -p "$PROJECT_DIR/src"
    mkdir -p "$PROJECT_DIR/logs"
    
    # Create package.json
    cat > "$PROJECT_DIR/package.json" << EOF
{
  "name": "${PROJECT_NAME}",
  "version": "1.0.0",
  "description": "Node.js project ${PROJECT_NAME}",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js",
    "dev": "nodemon src/index.js"
  },
  "dependencies": {
    "express": "^4.18.2"
  },
  "devDependencies": {
    "nodemon": "^3.0.1"
  }
}
EOF
    
    # Create index.js
    cat > "$PROJECT_DIR/src/index.js" << EOF
const express = require('express');
const app = express();
const PORT = process.env.PORT || ${APP_PORT};

app.use(express.json());

app.get('/', (req, res) => {
  res.json({
    message: 'Welcome to ${PROJECT_NAME}!',
    status: 'running',
    timestamp: new Date().toISOString()
  });
});

app.get('/health', (req, res) => {
  res.json({ status: 'healthy' });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(\`Server is running on port \${PORT}\`);
});
EOF
    
    # Create Dockerfile
    cat > "$PROJECT_DIR/Dockerfile" << 'EOF'
FROM node:20-alpine

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm install --production

# Copy source code
COPY src ./src

# Expose port
EXPOSE 3000

# Start application
CMD ["npm", "start"]
EOF
    
    # Create docker-compose for the project
    cat > "$PROJECT_DIR/docker-compose.yml" << EOF
# Node.js Project: ${PROJECT_NAME}
# Generated on: $(date)

networks:
  traefik-network:
    external: true
  internal:
    external: true
    name: internal-network

services:
  ${PROJECT_NAME}:
    build: .
    container_name: ${PROJECT_NAME}
    restart: unless-stopped
    environment:
      - TZ=\${TZ:-Asia/Ho_Chi_Minh}
      - NODE_ENV=production
      - PORT=${APP_PORT}
EOF

    if [ -n "$DB_NAME" ]; then
        cat >> "$PROJECT_DIR/docker-compose.yml" << EOF
      - DB_HOST=mysql
      - DB_PORT=3306
      - DB_DATABASE=${DB_NAME}
      - DB_USERNAME=\${MYSQL_USER:-dbuser}
      - DB_PASSWORD=\${MYSQL_PASSWORD:-password}
EOF
    fi

    cat >> "$PROJECT_DIR/docker-compose.yml" << EOF
    volumes:
      - ./src:/app/src
      - ./logs:/app/logs
    networks:
      - traefik-network
EOF

    if [ -n "$DB_NAME" ]; then
        cat >> "$PROJECT_DIR/docker-compose.yml" << EOF
      - internal
EOF
    fi

    cat >> "$PROJECT_DIR/docker-compose.yml" << EOF
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${PROJECT_NAME}.rule=Host(\`${PROJECT_HOST}\`)"
EOF

    if [ "$BASE_DOMAIN" != "localhost" ]; then
        cat >> "$PROJECT_DIR/docker-compose.yml" << EOF
      - "traefik.http.routers.${PROJECT_NAME}.entrypoints=websecure"
      - "traefik.http.routers.${PROJECT_NAME}.tls=true"
      - "traefik.http.routers.${PROJECT_NAME}.tls.certresolver=letsencrypt"
EOF
    else
        cat >> "$PROJECT_DIR/docker-compose.yml" << EOF
      - "traefik.http.routers.${PROJECT_NAME}.entrypoints=web"
EOF
    fi

    cat >> "$PROJECT_DIR/docker-compose.yml" << EOF
      - "traefik.http.services.${PROJECT_NAME}.loadbalancer.server.port=${APP_PORT}"
      - "traefik.docker.network=traefik-network"
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:${APP_PORT}/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s
EOF

    # Create .env file for the project
    cat > "$PROJECT_DIR/.env" << EOF
# Environment variables for ${PROJECT_NAME}
TZ=Asia/Ho_Chi_Minh
NODE_ENV=production
PORT=${APP_PORT}
MYSQL_USER=${MYSQL_USER:-dbuser}
MYSQL_PASSWORD=${MYSQL_PASSWORD:-password}
EOF

    # Create .dockerignore
    cat > "$PROJECT_DIR/.dockerignore" << 'EOF'
node_modules
npm-debug.log
.env
.git
.gitignore
README.md
logs
EOF

    # Create database if requested
    if [ -n "$DB_NAME" ]; then
        echo ""
        print_section "Tạo database: $DB_NAME"
        
        if docker ps --format '{{.Names}}' | grep -q "^mysql$"; then
            docker exec mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD:-}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true
            docker exec mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD:-}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${MYSQL_USER:-dbuser}'@'%';" 2>/dev/null || true
            docker exec mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD:-}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true
            print_success "Database '$DB_NAME' đã được tạo"
        else
            print_warning "MySQL container không chạy. Database sẽ được tạo khi MySQL khởi động."
        fi
    fi
    
    # Set permissions
    chown -R "$REAL_USER":"$REAL_USER" "$PROJECT_DIR"
    
    echo ""
    print_success "Project Node.js '$PROJECT_NAME' đã được tạo!"
    echo ""
    echo "📁 Thư mục project: $PROJECT_DIR"
    echo "🌐 URL: http://${PROJECT_HOST}"
    echo "🔢 Port: $APP_PORT"
    if [ -n "$DB_NAME" ]; then
        echo "🗄️ Database: $DB_NAME"
    fi
    echo ""
    echo "📋 Để chạy project:"
    echo "   cd $PROJECT_DIR"
    echo "   docker compose up -d --build"
    echo ""
}

list_projects() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}    DANH SÁCH PROJECTS${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
    
    local BASE_DOMAIN="${CF_HOSTNAME:-localhost}"
    
    echo "📦 PHP Projects:"
    if [ -d "$PHP_PROJECTS_DIR" ] && [ "$(ls -A $PHP_PROJECTS_DIR 2>/dev/null)" ]; then
        for project in "$PHP_PROJECTS_DIR"/*/; do
            local name=$(basename "$project")
            local status="stopped"
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
                status="running"
            fi
            local host="${name}.${BASE_DOMAIN}"
            if [ "$BASE_DOMAIN" = "localhost" ]; then
                host="${name}.localhost"
            fi
            echo "  • $name (${status}) - http://${host}"
        done
    else
        echo "  (Chưa có project nào)"
    fi
    
    echo ""
    echo "📦 Node.js Projects:"
    if [ -d "$NODEJS_PROJECTS_DIR" ] && [ "$(ls -A $NODEJS_PROJECTS_DIR 2>/dev/null)" ]; then
        for project in "$NODEJS_PROJECTS_DIR"/*/; do
            local name=$(basename "$project")
            local status="stopped"
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
                status="running"
            fi
            local host="${name}.${BASE_DOMAIN}"
            if [ "$BASE_DOMAIN" = "localhost" ]; then
                host="${name}.localhost"
            fi
            echo "  • $name (${status}) - http://${host}"
        done
    else
        echo "  (Chưa có project nào)"
    fi
    
    echo ""
}

manage_projects() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}    QUẢN LÝ PROJECTS${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
    
    echo "Chọn hành động:"
    echo "1. 📋 Xem danh sách projects"
    echo "2. 🐘 Tạo PHP project mới"
    echo "3. 📦 Tạo Node.js project mới"
    echo "4. ▶️ Start project"
    echo "5. ⏹️ Stop project"
    echo "6. 🗑️ Xóa project"
    echo "0. ⬅️ Quay lại"
    echo ""
    read -p "Nhập lựa chọn (0-6): " choice
    
    case $choice in
        1) list_projects ;;
        2) create_php_project ;;
        3) create_nodejs_project ;;
        4) start_project ;;
        5) stop_project ;;
        6) delete_project ;;
        0) return 0 ;;
        *) print_error "Lựa chọn không hợp lệ!" ;;
    esac
}

start_project() {
    list_projects
    echo ""
    read -p "📝 Nhập tên project cần start: " PROJECT_NAME
    
    if [ -z "$PROJECT_NAME" ]; then
        print_error "Tên project không được để trống!"
        return 1
    fi
    
    local PROJECT_DIR=""
    if [ -d "$PHP_PROJECTS_DIR/$PROJECT_NAME" ]; then
        PROJECT_DIR="$PHP_PROJECTS_DIR/$PROJECT_NAME"
    elif [ -d "$NODEJS_PROJECTS_DIR/$PROJECT_NAME" ]; then
        PROJECT_DIR="$NODEJS_PROJECTS_DIR/$PROJECT_NAME"
    else
        print_error "Project '$PROJECT_NAME' không tồn tại!"
        return 1
    fi
    
    echo ">>> Starting project: $PROJECT_NAME"
    cd "$PROJECT_DIR"
    docker compose up -d --build
    print_success "Project '$PROJECT_NAME' đã được start"
}

stop_project() {
    list_projects
    echo ""
    read -p "📝 Nhập tên project cần stop: " PROJECT_NAME
    
    if [ -z "$PROJECT_NAME" ]; then
        print_error "Tên project không được để trống!"
        return 1
    fi
    
    local PROJECT_DIR=""
    if [ -d "$PHP_PROJECTS_DIR/$PROJECT_NAME" ]; then
        PROJECT_DIR="$PHP_PROJECTS_DIR/$PROJECT_NAME"
    elif [ -d "$NODEJS_PROJECTS_DIR/$PROJECT_NAME" ]; then
        PROJECT_DIR="$NODEJS_PROJECTS_DIR/$PROJECT_NAME"
    else
        print_error "Project '$PROJECT_NAME' không tồn tại!"
        return 1
    fi
    
    echo ">>> Stopping project: $PROJECT_NAME"
    cd "$PROJECT_DIR"
    docker compose down
    print_success "Project '$PROJECT_NAME' đã được stop"
}

delete_project() {
    list_projects
    echo ""
    read -p "📝 Nhập tên project cần xóa: " PROJECT_NAME
    
    if [ -z "$PROJECT_NAME" ]; then
        print_error "Tên project không được để trống!"
        return 1
    fi
    
    local PROJECT_DIR=""
    local PROJECT_TYPE=""
    if [ -d "$PHP_PROJECTS_DIR/$PROJECT_NAME" ]; then
        PROJECT_DIR="$PHP_PROJECTS_DIR/$PROJECT_NAME"
        PROJECT_TYPE="PHP"
    elif [ -d "$NODEJS_PROJECTS_DIR/$PROJECT_NAME" ]; then
        PROJECT_DIR="$NODEJS_PROJECTS_DIR/$PROJECT_NAME"
        PROJECT_TYPE="Node.js"
    else
        print_error "Project '$PROJECT_NAME' không tồn tại!"
        return 1
    fi
    
    print_warning "⚠️  Bạn sắp xóa project $PROJECT_TYPE: $PROJECT_NAME"
    read -p "Bạn có chắc chắn? (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Hủy xóa project"
        return 0
    fi
    
    # Stop container if running
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${PROJECT_NAME}$"; then
        echo ">>> Stopping container..."
        cd "$PROJECT_DIR"
        docker compose down 2>/dev/null || true
    fi
    
    # Remove directory
    rm -rf "$PROJECT_DIR"
    print_success "Project '$PROJECT_NAME' đã được xóa"
    
    # Optionally remove database
    read -p "🗄️ Xóa database '${PROJECT_NAME}_db' nếu có? (y/N): " delete_db
    if [[ "$delete_db" =~ ^[Yy]$ ]]; then
        if docker ps --format '{{.Names}}' | grep -q "^mysql$"; then
            docker exec mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD:-}" -e "DROP DATABASE IF EXISTS \`${PROJECT_NAME}_db\`;" 2>/dev/null || true
            print_success "Database '${PROJECT_NAME}_db' đã được xóa"
        fi
    fi
}

# === Backup & Update Functions ===
create_backup() {
    print_section "Backup toàn bộ Docker Stack tại $(date)"
    
    mkdir -p "$BACKUP_DIR"
    
    local BACKUP_FILE="docker_stack_backup_${TIMESTAMP}.tar.gz"
    echo "📦 Backup file: $BACKUP_FILE"
    echo "⏰ Thời gian backup: $(date)"
    
    # Stop containers for safe backup
    print_warning "Dừng containers để backup an toàn..."
    docker compose -f "$MAIN_COMPOSE_FILE" down 2>/dev/null || true
    
    # Stop project containers
    for project_dir in "$PHP_PROJECTS_DIR"/*/ "$NODEJS_PROJECTS_DIR"/*/; do
        if [ -f "$project_dir/docker-compose.yml" ]; then
            docker compose -f "$project_dir/docker-compose.yml" down 2>/dev/null || true
        fi
    done
    
    echo ""
    echo "🔄 Đang backup các thành phần:"
    echo "  📁 Docker Stack directory: $DOCKER_BASE_DIR"
    echo "  🔧 Config files"
    echo "  🗄️ MySQL data"
    echo "  📜 Projects"
    
    # Create backup
    tar -czf "$BACKUP_DIR/$BACKUP_FILE" \
        -C "$(dirname "$DOCKER_BASE_DIR")" "$(basename "$DOCKER_BASE_DIR")" \
        -C "$(dirname "$CONFIG_FILE")" "$(basename "$CONFIG_FILE")" \
        2>/dev/null || true
    
    local BACKUP_SIZE
    BACKUP_SIZE=$(du -sh "$BACKUP_DIR/$BACKUP_FILE" | cut -f1)
    print_success "Backup hoàn thành: $BACKUP_DIR/$BACKUP_FILE ($BACKUP_SIZE)"
    
    # Restart containers
    echo ""
    print_section "Khởi động lại containers..."
    docker compose -f "$MAIN_COMPOSE_FILE" up -d
    
    # Restart project containers
    for project_dir in "$PHP_PROJECTS_DIR"/*/ "$NODEJS_PROJECTS_DIR"/*/; do
        if [ -f "$project_dir/docker-compose.yml" ]; then
            docker compose -f "$project_dir/docker-compose.yml" up -d 2>/dev/null || true
        fi
    done
    
    print_success "Containers đã được khởi động lại"
}

show_status() {
    print_section "Trạng thái Docker Stack"
    echo -e "${YELLOW}Thời gian: $(date)${NC}"
    echo ""
    
    echo "📊 System Info:"
    echo "  - Uptime: $(uptime -p)"
    echo "  - Load: $(uptime | awk -F'load average:' '{print $2}')"
    echo "  - Memory: $(free -h | awk 'NR==2{printf "%.1f%% (%s/%s)", $3*100/$2, $3, $2}')"
    echo "  - Disk: $(df -h / | awk 'NR==2{printf "%s (%s used)", $5, $3}')"
    echo ""
    
    echo "🐳 Core Services:"
    if [ -f "$MAIN_COMPOSE_FILE" ]; then
        docker compose -f "$MAIN_COMPOSE_FILE" ps 2>/dev/null || echo "  (Không có service nào đang chạy)"
    fi
    echo ""
    
    local BASE_DOMAIN="${CF_HOSTNAME:-localhost}"
    echo "🌐 URLs:"
    if [ "$BASE_DOMAIN" = "localhost" ]; then
        echo "  • Traefik Dashboard: http://traefik.localhost:8080"
        echo "  • N8N: http://n8n.localhost"
        echo "  • phpMyAdmin: http://pma.localhost"
    else
        echo "  • Traefik Dashboard: https://traefik.${BASE_DOMAIN}"
        echo "  • N8N: https://n8n.${BASE_DOMAIN}"
        echo "  • phpMyAdmin: https://pma.${BASE_DOMAIN}"
    fi
    echo ""
    
    if [ "${CF_HOSTNAME:-localhost}" != "localhost" ]; then
        echo "☁️ Cloudflared Service:"
        if systemctl list-units --full -all | grep -q 'cloudflared.service'; then
            systemctl status cloudflared --no-pager -l | head -5
        else
            echo "  (Cloudflared service not installed)"
        fi
        echo ""
    fi
    
    list_projects
}

# === Main Installation Function ===
install_stack() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}    DOCKER STACK INSTALLATION${NC}"
    echo -e "${BLUE}    (Traefik + N8N + MySQL + PHP + Node.js)${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""

    # Check for existing config
    if show_config_info; then
        echo -e "${YELLOW}🔍 Bạn đã có config trước đó!${NC}"
        read -p "Bạn có muốn sử dụng lại config này không? (y/N): " use_existing
        
        if [[ "$use_existing" =~ ^[Yy]$ ]]; then
            load_config
            print_success "Sử dụng config có sẵn"
        else
            echo "📝 Nhập config mới..."
            get_new_config
        fi
    else
        echo "📝 Chưa có config, cần nhập thông tin mới..."
        get_new_config
    fi
    
    # Load config
    load_config
    
    echo ""

    # Install prerequisites
    install_prerequisites
    
    # Install Docker
    install_docker
    
    # Install Cloudflared (if needed)
    install_cloudflared
    
    # Setup directories
    setup_directories
    
    # Create Traefik config
    create_traefik_config
    
    # Create Docker Compose
    create_docker_compose
    
    # Create MySQL init
    create_mysql_init
    
    # Setup Cloudflared (if needed)
    setup_cloudflared
    
    # Start services
    print_section "Khởi động Docker Stack..."
    docker compose -f "$MAIN_COMPOSE_FILE" up -d
    
    echo ""
    echo "⏳ Đợi services khởi động (30 giây)..."
    sleep 30
    
    # Health check
    health_check
    
    # Final instructions
    echo ""
    echo "--------------------------------------------------"
    echo " Installation Complete! "
    echo "--------------------------------------------------"
    
    local BASE_DOMAIN="${CF_HOSTNAME:-localhost}"
    
    if [ "$BASE_DOMAIN" = "localhost" ]; then
        echo "✅ Docker Stack đã được cài đặt ở chế độ Local Mode"
        echo ""
        echo "🌐 Truy cập các services:"
        echo "   • Traefik Dashboard: http://traefik.localhost:8080"
        echo "   • N8N: http://n8n.localhost"
        echo "   • phpMyAdmin: http://pma.localhost"
        echo ""
        echo "📝 Thông tin đăng nhập:"
        echo "   • Traefik: ${TRAEFIK_USER:-admin} / [password bạn đã nhập]"
        echo "   • MySQL: ${MYSQL_USER:-dbuser} / [password bạn đã nhập]"
    else
        echo "✅ Docker Stack đã được cài đặt với Cloudflare Tunnel"
        echo ""
        echo "🌐 Truy cập các services (sau khi cấu hình DNS):"
        echo "   • Traefik Dashboard: https://traefik.${BASE_DOMAIN}"
        echo "   • N8N: https://n8n.${BASE_DOMAIN}"
        echo "   • phpMyAdmin: https://pma.${BASE_DOMAIN}"
        echo ""
        echo "⚠️  QUAN TRỌNG: Cấu hình DNS trong Cloudflare Dashboard!"
        echo ""
        echo "📋 Tạo các CNAME records:"
        echo "   • traefik -> ${TUNNEL_ID}.cfargotunnel.com"
        echo "   • n8n -> ${TUNNEL_ID}.cfargotunnel.com"
        echo "   • pma -> ${TUNNEL_ID}.cfargotunnel.com"
        echo "   • * (wildcard) -> ${TUNNEL_ID}.cfargotunnel.com"
    fi
    
    echo ""
    echo "🔧 Các lệnh quản lý:"
    echo "   • Trạng thái: sudo bash $0 status"
    echo "   • Tạo PHP project: sudo bash $0 php"
    echo "   • Tạo Node.js project: sudo bash $0 nodejs"
    echo "   • Quản lý projects: sudo bash $0 projects"
    echo "   • Backup: sudo bash $0 backup"
    echo "   • Logs: docker compose -f $MAIN_COMPOSE_FILE logs -f"
    echo ""
    echo "--------------------------------------------------"
}

# === Uninstall Function ===
uninstall_stack() {
    print_section "Gỡ cài đặt Docker Stack"
    echo ""
    
    print_warning "⚠️  CẢNH BÁO: Quá trình gỡ cài sẽ xóa:"
    echo "  • Tất cả containers (Traefik, N8N, MySQL, phpMyAdmin)"
    echo "  • Tất cả projects (PHP, Node.js)"
    echo "  • Tất cả volumes và data"
    echo "  • Cloudflared service và config"
    echo "  • Docker networks"
    echo ""
    print_warning "⚠️  Backup sẽ được GIỮ LẠI trong: $BACKUP_DIR"
    echo ""
    
    read -p "Bạn có chắc chắn muốn gỡ cài hoàn toàn? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Hủy gỡ cài"
        return 0
    fi
    
    echo ""
    print_section "Bắt đầu gỡ cài..."
    
    # Stop all project containers
    echo "1️⃣ Dừng project containers..."
    for project_dir in "$PHP_PROJECTS_DIR"/*/ "$NODEJS_PROJECTS_DIR"/*/; do
        if [ -f "$project_dir/docker-compose.yml" ]; then
            docker compose -f "$project_dir/docker-compose.yml" down 2>/dev/null || true
        fi
    done
    
    # Stop main containers
    echo "2️⃣ Dừng core containers..."
    if [ -f "$MAIN_COMPOSE_FILE" ]; then
        docker compose -f "$MAIN_COMPOSE_FILE" down -v 2>/dev/null || true
    fi
    
    # Stop Cloudflared
    echo "3️⃣ Dừng Cloudflared service..."
    if systemctl is-active cloudflared &> /dev/null 2>&1; then
        systemctl stop cloudflared 2>/dev/null || true
        systemctl disable cloudflared 2>/dev/null || true
        cloudflared service uninstall 2>/dev/null || true
    fi
    
    # Remove Docker networks
    echo "4️⃣ Xóa Docker networks..."
    docker network rm traefik-network 2>/dev/null || true
    docker network rm internal-network 2>/dev/null || true
    
    # Remove directories
    echo "5️⃣ Xóa thư mục dữ liệu..."
    rm -rf "$DOCKER_BASE_DIR" 2>/dev/null || true
    rm -f "$CONFIG_FILE" 2>/dev/null || true
    rm -f "$CLOUDFLARED_CONFIG_FILE" 2>/dev/null || true
    
    echo ""
    print_success "Gỡ cài hoàn thành!"
    echo ""
    echo "📦 Backup được giữ lại tại: $BACKUP_DIR"
    echo ""
    echo "💡 Để xóa hoàn toàn backup:"
    echo "   rm -rf $BACKUP_DIR"
}

# === Menu Functions ===
show_menu() {
    clear
    echo -e "${MAGENTA}================================================${NC}"
    echo -e "${MAGENTA}    DOCKER STACK MANAGEMENT${NC}"
    echo -e "${MAGENTA}    Traefik + N8N + MySQL + PHP + Node.js${NC}"
    echo -e "${MAGENTA}================================================${NC}"
    echo ""
    echo "Chọn hành động:"
    echo ""
    echo -e "${CYAN}[Cài đặt & Cấu hình]${NC}"
    echo "1. 🚀 Cài đặt Docker Stack đầy đủ"
    echo "2. ⚙️ Quản lý config"
    echo ""
    echo -e "${CYAN}[Quản lý Projects]${NC}"
    echo "3. 📦 Quản lý projects (PHP/Node.js)"
    echo "4. 🐘 Tạo PHP project mới"
    echo "5. 📦 Tạo Node.js project mới"
    echo ""
    echo -e "${CYAN}[Vận hành]${NC}"
    echo "6. 📊 Xem trạng thái"
    echo "7. 💾 Backup"
    echo "8. 🔄 Restart services"
    echo ""
    echo -e "${CYAN}[Khác]${NC}"
    echo "9. 🗑️ Gỡ cài đặt hoàn toàn"
    echo "0. ❌ Thoát"
    echo ""
    read -p "Nhập lựa chọn (0-9): " choice
}

restart_services() {
    print_section "Restart Docker Stack..."
    
    if [ -f "$MAIN_COMPOSE_FILE" ]; then
        docker compose -f "$MAIN_COMPOSE_FILE" restart
        print_success "Core services đã được restart"
    else
        print_error "Docker Compose file không tồn tại"
    fi
}

# === Main Script Logic ===
if [ $# -gt 0 ]; then
    case $1 in
        "install")
            install_stack
            ;;
        "status")
            load_config 2>/dev/null || true
            show_status
            ;;
        "backup")
            load_config 2>/dev/null || true
            create_backup
            ;;
        "config")
            manage_config
            ;;
        "projects")
            load_config 2>/dev/null || true
            manage_projects
            ;;
        "php")
            load_config 2>/dev/null || true
            create_php_project
            ;;
        "nodejs")
            load_config 2>/dev/null || true
            create_nodejs_project
            ;;
        "restart")
            restart_services
            ;;
        "uninstall")
            load_config 2>/dev/null || true
            uninstall_stack
            ;;
        *)
            echo "Sử dụng: $0 [install|status|backup|config|projects|php|nodejs|restart|uninstall]"
            echo ""
            echo "Ví dụ:"
            echo "  $0 install    # Cài đặt Docker Stack đầy đủ"
            echo "  $0 status     # Xem trạng thái"
            echo "  $0 backup     # Backup dữ liệu"
            echo "  $0 config     # Quản lý config"
            echo "  $0 projects   # Quản lý projects"
            echo "  $0 php        # Tạo PHP project mới"
            echo "  $0 nodejs     # Tạo Node.js project mới"
            echo "  $0 restart    # Restart services"
            echo "  $0 uninstall  # Gỡ cài đặt"
            exit 1
            ;;
    esac
else
    # Interactive menu
    while true; do
        show_menu
        case $choice in
            1)
                install_stack
                ;;
            2)
                manage_config
                ;;
            3)
                load_config 2>/dev/null || true
                manage_projects
                ;;
            4)
                load_config 2>/dev/null || true
                create_php_project
                ;;
            5)
                load_config 2>/dev/null || true
                create_nodejs_project
                ;;
            6)
                load_config 2>/dev/null || true
                show_status
                ;;
            7)
                load_config 2>/dev/null || true
                create_backup
                ;;
            8)
                restart_services
                ;;
            9)
                load_config 2>/dev/null || true
                uninstall_stack
                ;;
            0)
                echo "Tạm biệt!"
                exit 0
                ;;
            *)
                print_error "Lựa chọn không hợp lệ!"
                ;;
        esac
        echo ""
        read -p "Nhấn Enter để tiếp tục..."
    done
fi

exit 0
