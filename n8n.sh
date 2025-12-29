#!/bin/bash

# ============================================================
# N8N Management Script with Cloudflare Tunnel Integration
# ============================================================
# Requirements:
#   - Ubuntu/Debian-based Linux (uses apt, dpkg)
#   - Root/sudo access
#   - Internet connection
#   - Cloudflare account with Zero Trust access
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
# When running with sudo, $HOME points to root's home (/root)
# We need to use the original user's home directory
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo "~$REAL_USER")

# === Configuration ===
# N8N Data Directory (using real user's home, not root's)
N8N_BASE_DIR="$REAL_HOME/n8n"
N8N_VOLUME_DIR="$N8N_BASE_DIR/n8n_data"
DOCKER_COMPOSE_FILE="$N8N_BASE_DIR/docker-compose.yml"
N8N_ENCRYPTION_KEY_FILE="$N8N_BASE_DIR/.n8n_encryption_key"
# Cloudflared config file path
CLOUDFLARED_CONFIG_FILE="/etc/cloudflared/config.yml"
# Default Timezone if system TZ is not set
DEFAULT_TZ="Asia/Ho_Chi_Minh"

# Backup configuration
BACKUP_DIR="$REAL_HOME/n8n-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Config file for installation settings
CONFIG_FILE="$REAL_HOME/.n8n_install_config"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# === Script Execution ===
# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Prevent errors in a pipeline from being masked.
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

# === Config Management Functions ===
save_config() {
    local cf_token="$1"
    local cf_hostname="$2"
    local tunnel_id="$3"
    local account_tag="$4"
    local tunnel_secret="$5"
    
    cat > "$CONFIG_FILE" << EOF
# N8N Installation Configuration
# Generated on: $(date)
CF_TOKEN="$cf_token"
CF_HOSTNAME="$cf_hostname"
TUNNEL_ID="$tunnel_id"
ACCOUNT_TAG="$account_tag"
TUNNEL_SECRET="$tunnel_secret"
INSTALL_DATE="$(date)"
EOF
    
    chown "$REAL_USER":"$REAL_USER" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"  # Bảo mật file config
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
    echo "   • Đặt tên tunnel (ví dụ: n8n-tunnel)"
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

get_new_config() {
    echo ""
    read -p "❓ Bạn muốn sử dụng Cloudflare Tunnel không? (y/N): " use_cloudflare
    
    if [[ ! "$use_cloudflare" =~ ^[Yy]$ ]]; then
        # Local mode - không cần Cloudflare
        print_success "Chế độ Local được chọn"
        echo ""
        echo "📝 Thông tin cấu hình Local Mode:"
        echo "  • N8N sẽ chạy tại: http://localhost:5678"
        echo "  • Chỉ có thể truy cập từ máy local"
        echo "  • Không cần token Cloudflare"
        echo "  • Không cần cấu hình DNS"
        echo ""
        
        CF_TOKEN="local"
        CF_HOSTNAME="localhost"
        TUNNEL_ID="local"
        ACCOUNT_TAG="local"
        TUNNEL_SECRET="local"
        
        save_config "$CF_TOKEN" "$CF_HOSTNAME" "$TUNNEL_ID" "$ACCOUNT_TAG" "$TUNNEL_SECRET"
        print_success "Config Local Mode đã được lưu"
        return 0
    fi
    
    # Cloudflare mode
    read -p "❓ Bạn có cần xem hướng dẫn lấy thông tin Cloudflare không? (y/N): " show_guide
    
    if [[ "$show_guide" =~ ^[Yy]$ ]]; then
        get_cloudflare_info
        read -p "Nhấn Enter để tiếp tục sau khi đã chuẩn bị thông tin..."
    fi
    
    echo ""
    echo "📝 Nhập thông tin Cloudflare Tunnel:"
    echo ""
    
    # Lấy Cloudflare Token
    while true; do
        read -p "🔑 Nhập Cloudflare Tunnel Token (hoặc dòng lệnh cloudflared): " CF_TOKEN
        if [ -z "$CF_TOKEN" ]; then
            print_error "Token không được để trống!"
            continue
        fi
        
        # Xử lý nếu user paste toàn bộ dòng lệnh: cloudflared.exe service install TOKEN
        # Hoặc: cloudflared service install TOKEN
        if [[ "$CF_TOKEN" =~ cloudflared ]]; then
            # Trích xuất token từ dòng lệnh
            CF_TOKEN=$(echo "$CF_TOKEN" | grep -oP 'service install \K.*' | tr -d ' ')
            if [ -z "$CF_TOKEN" ]; then
                print_error "Không thể trích xuất token từ dòng lệnh. Vui lòng paste lại!"
                continue
            fi
        fi
        
        # Kiểm tra format token (JWT format hoặc payload)
        # Chấp nhận cả token đầy đủ (3 phần) hoặc payload (1 phần)
        if [[ "$CF_TOKEN" =~ ^eyJ[A-Za-z0-9_-]+ ]]; then
            print_success "Token hợp lệ"
            break
        else
            print_error "Token phải bắt đầu bằng 'eyJ'. Vui lòng kiểm tra lại!"
            continue
        fi
    done
    
    # Lấy Hostname
    while true; do
        read -p "🌐 Nhập Public Hostname (ví dụ: n8n.yourdomain.com): " CF_HOSTNAME
        if [ -z "$CF_HOSTNAME" ]; then
            print_error "Hostname không được để trống!"
            continue
        fi
        
        # Kiểm tra format hostname
        if [[ "$CF_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
            print_success "Hostname hợp lệ"
            break
        else
            print_warning "Hostname có vẻ không đúng format. Bạn có chắc chắn muốn tiếp tục? (y/N)"
            read -p "" confirm_hostname
            if [[ "$confirm_hostname" =~ ^[Yy]$ ]]; then
                break
            fi
        fi
    done
    
    # Decode token để lấy thông tin tunnel (nếu có thể)
    echo ""
    echo "🔍 Đang phân tích token..."
    
    # Sử dụng hàm helper để decode token
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
    
    # Lưu config
    save_config "$CF_TOKEN" "$CF_HOSTNAME" "$TUNNEL_ID" "$ACCOUNT_TAG" "$TUNNEL_SECRET"
}

manage_config() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}    QUẢN LÝ CONFIG CLOUDFLARE${NC}"
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
            1)
                show_detailed_config
                ;;
            2)
                edit_config
                ;;
            3)
                delete_config
                ;;
            4)
                get_new_config
                ;;
            0)
                return 0
                ;;
            *)
                print_error "Lựa chọn không hợp lệ!"
                ;;
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
        echo "🔑 Token: ${CF_TOKEN:0:20}...${CF_TOKEN: -10}"
        echo "📅 Ngày cài đặt: $INSTALL_DATE"
        echo ""
        echo "📁 File config: $CONFIG_FILE"
        echo ""
    else
        print_error "Không thể đọc config!"
    fi
}

decode_token_info() {
    local token="$1"
    local tunnel_id=""
    local account_tag=""
    local tunnel_secret=""
    
    # Decode JWT payload
    if command -v base64 >/dev/null 2>&1; then
        # Xác định payload: nếu có dấu chấm thì lấy phần thứ 2, nếu không thì lấy toàn bộ
        local TOKEN_PAYLOAD
        if [[ "$token" == *"."* ]]; then
            TOKEN_PAYLOAD=$(echo "$token" | cut -d'.' -f2)
        else
            # Token chỉ có payload (không có header và signature)
            TOKEN_PAYLOAD="$token"
        fi
        
        # Thêm padding nếu cần
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
    
    # Return values via global variables
    TUNNEL_ID="$tunnel_id"
    ACCOUNT_TAG="$account_tag"
    TUNNEL_SECRET="$tunnel_secret"
}

edit_config() {
    echo "✏️ Chỉnh sửa config:"
    echo ""
    
    if load_config; then
        echo "Config hiện tại:"
        echo "  🌐 Hostname: $CF_HOSTNAME"
        
        # Kiểm tra xem có phải local mode không
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
            # !!! FIX: Gọi lại logic giải mã token để cập nhật thông tin
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
        
        save_config "$CF_TOKEN" "$CF_HOSTNAME" "$TUNNEL_ID" "$ACCOUNT_TAG" "$TUNNEL_SECRET"
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
    
    # Lấy dung lượng trống (KB) và chuyển sang MB
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

validate_encryption_key() {
    local key="$1"
    
    # Kiểm tra key không rỗng
    if [ -z "$key" ]; then
        print_error "Encryption key không được để trống!"
        return 1
    fi
    
    # Kiểm tra độ dài tối thiểu (base64 của 32 bytes = ~44 chars)
    if [ ${#key} -lt 32 ]; then
        print_error "Encryption key quá ngắn! Cần ít nhất 32 ký tự"
        return 1
    fi
    
    # Kiểm tra format base64 (optional - vì có thể dùng plain text)
    if echo "$key" | base64 -d >/dev/null 2>&1; then
        print_success "Encryption key hợp lệ (Base64 format)"
    else
        print_warning "Encryption key không phải Base64, nhưng vẫn có thể sử dụng"
    fi
    
    return 0
}

# === Enhanced Utility Functions ===

check_container_health() {
    local container_name="$1"
    local max_wait="${2:-60}"
    local wait_time=0
    
    print_section "Kiểm tra sức khỏe container: $container_name"
    
    while [ $wait_time -lt $max_wait ]; do
        local health_status
        health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "no-healthcheck")
        
        case "$health_status" in
            "healthy")
                print_success "Container $container_name đang khỏe mạnh"
                return 0
                ;;
            "unhealthy")
                print_error "Container $container_name không khỏe mạnh"
                return 1
                ;;
            "starting")
                echo "⏳ Container đang khởi động... ($wait_time/${max_wait}s)"
                ;;
            "no-healthcheck")
                # Fallback: kiểm tra container có đang chạy không
                if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
                    print_success "Container $container_name đang chạy (không có healthcheck)"
                    return 0
                else
                    print_error "Container $container_name không chạy"
                    return 1
                fi
                ;;
        esac
        
        sleep 5
        wait_time=$((wait_time + 5))
    done
    
    print_warning "Timeout khi kiểm tra container health"
    return 1
}

backup_encryption_key() {
    local backup_location="$1"
    
    if [ -f "$N8N_ENCRYPTION_KEY_FILE" ]; then
        cp "$N8N_ENCRYPTION_KEY_FILE" "$backup_location/n8n_encryption_key_backup"
        chmod 600 "$backup_location/n8n_encryption_key_backup"
        print_success "Đã backup encryption key"
    else
        print_warning "Không tìm thấy encryption key file để backup"
    fi
}

cleanup_old_backups() {
    print_section "Dọn dẹp backup cũ"
    
    if [ -d "$BACKUP_DIR" ]; then
        local BACKUP_COUNT
        BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
        
        # Giữ lại 10 backup gần nhất
        if [ $BACKUP_COUNT -gt 10 ]; then
            echo "🧹 Tìm thấy $BACKUP_COUNT backup, giữ lại 10 backup gần nhất..."
            
            # Tính toán dung lượng sẽ được giải phóng
            local space_to_free=0
            ls -t "$BACKUP_DIR"/*.tar.gz | tail -n +11 | while read old_backup; do
                local file_size
                file_size=$(du -m "$old_backup" 2>/dev/null | cut -f1)
                space_to_free=$((space_to_free + file_size))
                echo "  🗑️ Xóa: $(basename "$old_backup") (${file_size}MB)"
                rm -f "$old_backup"
                # Xóa file info tương ứng
                local info_file="${old_backup%.tar.gz}.info"
                [ -f "$info_file" ] && rm -f "$info_file"
            done
            
            print_success "Đã dọn dẹp backup cũ, giải phóng ~${space_to_free}MB"
        else
            echo "✅ Số lượng backup ($BACKUP_COUNT) trong giới hạn cho phép"
        fi
    fi
    echo ""
}

get_latest_version() {
    # Cải thiện cách lấy phiên bản mới nhất
    echo "🔍 Đang kiểm tra phiên bản mới nhất..."
    
    # Thử nhiều cách để lấy version
    local LATEST_VERSION=""
    
    # Cách 1: Docker Hub API
    if [ -z "$LATEST_VERSION" ]; then
        LATEST_VERSION=$(curl -s "https://registry.hub.docker.com/v2/repositories/n8nio/n8n/tags/?page_size=100" | \
            grep -o '"name":"[0-9][^"]*"' | grep -v "latest\|beta\|alpha\|rc\|exp" | head -1 | cut -d'"' -f4 2>/dev/null || echo "")
    fi
    
    # Cách 2: GitHub API
    if [ -z "$LATEST_VERSION" ]; then
        LATEST_VERSION=$(curl -s "https://api.github.com/repos/n8n-io/n8n/releases/latest" | \
            grep '"tag_name":' | cut -d'"' -f4 | sed 's/^n8n@//' 2>/dev/null || echo "")
    fi
    
    # Fallback
    if [ -z "$LATEST_VERSION" ]; then
        LATEST_VERSION="latest"
    fi
    
    echo "$LATEST_VERSION"
}

health_check() {
    print_section "Kiểm tra sức khỏe N8N"
    
    local max_attempts=6
    local attempt=1
    
    # Load config để biết mode hiện tại
    if ! load_config; then
        print_warning "Không thể đọc config, sẽ kiểm tra container..."
    fi
    
    while [ $attempt -le $max_attempts ]; do
        echo "🔍 Thử kết nối lần $attempt/$max_attempts..."
        
        # Kiểm tra container đang chạy
        if ! docker compose -f "$DOCKER_COMPOSE_FILE" ps | grep -q "Up"; then
            print_error "Container không chạy!"
            return 1
        fi
        
        # Kiểm tra port 5678
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:5678 | grep -q "200\|302\|401"; then
            print_success "N8N service đang hoạt động bình thường"
            
            # Hiển thị URL dựa trên mode
            if [ "${CF_HOSTNAME:-}" = "localhost" ]; then
                print_success "📍 Truy cập (Local Mode): http://localhost:5678"
            else
                print_success "📍 Truy cập (Cloudflare Mode): https://${CF_HOSTNAME:-}"
            fi
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            echo "⏳ Đợi 10 giây trước khi thử lại..."
            sleep 10
        fi
        
        attempt=$((attempt + 1))
    done
    
    print_warning "N8N service có thể chưa sẵn sàng hoặc có vấn đề"
    echo "📋 Container logs (20 dòng cuối):"
    docker compose -f "$DOCKER_COMPOSE_FILE" logs --tail=20
    return 1
}

rollback_backup() {
    print_section "Rollback từ backup"
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR"/*.tar.gz 2>/dev/null)" ]; then
        print_error "Không tìm thấy backup nào để rollback!"
        return 1
    fi
    
    echo "📋 Danh sách backup khả dụng:"
    ls -lah "$BACKUP_DIR"/*.tar.gz | nl
    echo ""
    
    read -p "Nhập số thứ tự backup muốn rollback (hoặc Enter để hủy): " backup_choice
    
    if [ -z "$backup_choice" ]; then
        echo "Hủy rollback"
        return 0
    fi
    
    local SELECTED_BACKUP
    SELECTED_BACKUP=$(ls -t "$BACKUP_DIR"/*.tar.gz | sed -n "${backup_choice}p")
    
    if [ -z "$SELECTED_BACKUP" ] || [ ! -f "$SELECTED_BACKUP" ]; then
        print_error "Backup không hợp lệ!"
        return 1
    fi
    
    echo "🔄 Rollback từ: $(basename "$SELECTED_BACKUP")"
    echo ""
    print_warning "⚠️  CẢNH BÁO: Rollback dữ liệu từ một phiên bản n8n cũ có thể gây ra vấn đề tương thích"
    print_warning "với phiên bản container hiện tại. Cơ sở dữ liệu có thể cần được di chuyển (migrate)."
    print_warning "Hãy chắc chắn rằng bạn hiểu rõ rủi ro trước khi tiếp tục."
    echo ""
    read -p "Bạn có chắc chắn muốn rollback? (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Hủy rollback"
        return 0
    fi
    
    # Dừng container hiện tại
    print_warning "Dừng N8N container..."
    docker compose -f "$DOCKER_COMPOSE_FILE" down
    
    # Backup trạng thái hiện tại trước khi rollback
    local ROLLBACK_BACKUP="n8n_before_rollback_$(date +%Y%m%d_%H%M%S).tar.gz"
    echo "💾 Tạo backup trạng thái hiện tại: $ROLLBACK_BACKUP"
    tar -czf "$BACKUP_DIR/$ROLLBACK_BACKUP" -C "$(dirname "$N8N_BASE_DIR")" "$(basename "$N8N_BASE_DIR")" 2>/dev/null || true
    
    # Restore từ backup
    echo "📦 Restore từ backup..."
    cd "$(dirname "$N8N_BASE_DIR")"
    tar -xzf "$SELECTED_BACKUP"
    
    # Khởi động lại
    echo "🚀 Khởi động N8N..."
    docker compose -f "$DOCKER_COMPOSE_FILE" up -d
    
    sleep 15
    
    if health_check; then
        print_success "Rollback thành công!"
        print_success "Backup trạng thái trước rollback: $ROLLBACK_BACKUP"
    else
        print_error "Có vấn đề sau rollback, hãy kiểm tra logs"
        return 1
    fi
}

# === Backup & Update Functions ===
check_current_version() {
    print_section "Kiểm tra phiên bản hiện tại"
    
    if [ -f "$DOCKER_COMPOSE_FILE" ] && docker compose -f "$DOCKER_COMPOSE_FILE" ps | grep -q "Up"; then
        CURRENT_VERSION=$(docker compose -f "$DOCKER_COMPOSE_FILE" exec -T n8n n8n --version 2>/dev/null || echo "Unknown")
        print_success "Phiên bản hiện tại: $CURRENT_VERSION"
        
        # Kiểm tra phiên bản mới nhất
        print_section "Kiểm tra phiên bản mới nhất"
        local LATEST_VERSION
        LATEST_VERSION=$(get_latest_version)
        print_success "Tìm thấy phiên bản mới nhất: $LATEST_VERSION"
        
        if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ] && [ "$LATEST_VERSION" != "latest" ]; then
            print_warning "Có phiên bản mới khả dụng!"
        else
            print_success "Bạn đang sử dụng phiên bản mới nhất"
        fi
    else
        print_warning "N8N chưa được cài đặt hoặc không chạy"
        CURRENT_VERSION="Not installed"
    fi
    echo ""
}

show_server_status() {
    print_section "Trạng thái server"
    echo -e "${YELLOW}Thời gian: $(date)${NC}"
    
    echo "System Info:"
    # ! FIX: Missing closing parenthesis
    echo "  - Uptime: $(uptime -p)"
    # ! FIX: Missing closing parenthesis
    echo "  - Load: $(uptime | awk -F'load average:' '{print $2}')"
    echo "  - Memory: $(free -h | awk 'NR==2{printf "%.1f%% (%s/%s)", $3*100/$2, $3, $2}')"
    echo "  - Disk: $(df -h / | awk 'NR==2{printf "%s (%s used)", $5, $3}')"
    echo ""
    
    if [ -f "$DOCKER_COMPOSE_FILE" ]; then
        echo "N8N Container Status:"
        docker compose -f "$DOCKER_COMPOSE_FILE" ps
        echo ""
        
        echo "Cloudflared Service Status:"
        if systemctl list-units --full -all | grep -q 'cloudflared.service'; then
            systemctl status cloudflared --no-pager -l | head -5
        else
            echo "  (Cloudflared service not installed)"
        fi
    fi
    echo ""
}

count_backups() {
    print_section "Thông báo đã backup bao nhiêu bản và mô tả chi tiết"
    
    if [ -d "$BACKUP_DIR" ]; then
        local BACKUP_COUNT
        BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
        local TOTAL_SIZE
        TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
        
        echo "📦 Số lượng backup hiện có: $BACKUP_COUNT bản"
        echo "💾 Tổng dung lượng backup: $TOTAL_SIZE"
        echo ""
        
        if [ $BACKUP_COUNT -gt 0 ]; then
            echo "📋 Danh sách backup gần đây:"
            ls -lah "$BACKUP_DIR"/*.tar.gz 2>/dev/null | tail -5 | while read line; do
                echo "  $line"
            done
            echo ""
            
            echo "📄 Chi tiết nội dung backup:"
            echo "  ✓ N8N workflows và database (SQLite)"
            echo "  ✓ N8N settings và configurations"
            echo "  ✓ Custom nodes và packages"
            echo "  ✓ Cloudflared tunnel configurations"
            echo "  ✓ Docker compose files"
            echo "  ✓ Local files và uploads"
            echo "  ✓ Environment variables"
            echo "  ✓ Management scripts"
        else
            echo "📭 Chưa có backup nào được tạo"
        fi
    else
        echo "📁 Thư mục backup chưa tồn tại"
    fi
    echo ""
}

create_backup() {
    print_section "Backup tại $(date)"
    
    # Tạo thư mục backup nếu chưa có
    mkdir -p "$BACKUP_DIR"
    
    local BACKUP_FILE="n8n_backup_${TIMESTAMP}.tar.gz"
    echo "📦 Backup file: $BACKUP_FILE"
    # ! FIX: Missing closing parenthesis
    echo "⏰ Thời gian backup: $(date)"
    
    # Dừng container để backup an toàn
    if [ -f "$DOCKER_COMPOSE_FILE" ]; then
        print_warning "Dừng N8N container để backup an toàn..."
        docker compose -f "$DOCKER_COMPOSE_FILE" down
    fi
    
    # Tạo backup chi tiết
    echo ""
    echo "🔄 Đang backup các thành phần:"
    echo "  📁 N8N data directory: $N8N_BASE_DIR"
    echo "  🔧 Cloudflared config: /etc/cloudflared/"
    echo "  📜 Scripts và configs"
    echo "  🗃️ Local files và uploads"
    
    # Backup toàn bộ
    tar -czf "$BACKUP_DIR/$BACKUP_FILE" \
        -C "$(dirname "$N8N_BASE_DIR")" "$(basename "$N8N_BASE_DIR")" \
        -C /etc cloudflared/ \
        -C "$(dirname "$0")" "$(basename "$0")" \
        2>/dev/null || true
    
    local BACKUP_SIZE
    BACKUP_SIZE=$(du -sh "$BACKUP_DIR/$BACKUP_FILE" | cut -f1)
    print_success "Backup hoàn thành: $BACKUP_DIR/$BACKUP_FILE ($BACKUP_SIZE)"
    
    # Cập nhật thống kê backup
    local BACKUP_COUNT
    BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
    echo "📊 Tổng số backup: $BACKUP_COUNT bản"
    
    # Dọn dẹp backup cũ nếu cần
    cleanup_old_backups
    
    # Tạo file mô tả backup
    cat > "$BACKUP_DIR/backup_${TIMESTAMP}.info" << EOF
N8N Backup Information
======================
Timestamp: $(date)
Backup File: $BACKUP_FILE
Size: $BACKUP_SIZE
N8N Version: ${CURRENT_VERSION:-Unknown}
Server IP: $(hostname -I | awk '{print $1}')
Hostname: $(hostname)

Backup Contents:
================
✓ N8N workflows và database (SQLite)
✓ N8N user settings và preferences  
✓ Custom nodes và installed packages
✓ Cloudflared tunnel configurations
✓ Docker compose files
✓ Local files và file uploads
✓ Environment variables
✓ SSL certificates (if any)
✓ Management scripts

Restore Instructions:
====================
1. Stop current N8N: docker compose -f $DOCKER_COMPOSE_FILE down
2. Extract backup: cd $(dirname "$N8N_BASE_DIR") && tar -xzf $BACKUP_DIR/$BACKUP_FILE
3. Start N8N: docker compose -f $DOCKER_COMPOSE_FILE up -d

System Info at Backup:
======================
Uptime: $(uptime -p)
Load: $(uptime | awk -F'load average:' '{print $2}')
Memory: $(free -h | awk 'NR==2{printf "%.1f%% (%s/%s)", $3*100/$2, $3, $2}')
Disk: $(df -h / | awk 'NR==2{printf "%s (%s used)", $5, $3}')
EOF
    
    print_success "Thông tin backup đã lưu: backup_${TIMESTAMP}.info"
    echo ""
}

update_n8n() {
    print_section "Cập nhật N8N lên phiên bản mới nhất"
    
    if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
        print_error "N8N chưa được cài đặt!"
        return 1
    fi
    
    echo "🔄 Đang pull image mới nhất từ Docker Hub..."
    docker compose -f "$DOCKER_COMPOSE_FILE" pull
    
    echo "🚀 Khởi động lại với phiên bản mới..."
    docker compose -f "$DOCKER_COMPOSE_FILE" up -d
    
    echo "⏳ Đợi container khởi động (15 giây)..."
    sleep 15
    
    # Kiểm tra trạng thái
    if docker compose -f "$DOCKER_COMPOSE_FILE" ps | grep -q "Up"; then
        local NEW_VERSION
        NEW_VERSION=$(docker compose -f "$DOCKER_COMPOSE_FILE" exec -T n8n n8n --version 2>/dev/null || echo "Unknown")
        print_success "Update thành công!"
        print_success "Phiên bản mới: $NEW_VERSION"
        
        echo ""
        echo "📊 Container status:"
        docker compose -f "$DOCKER_COMPOSE_FILE" ps
        
        # Kiểm tra service health
        health_check
    else
        print_error "Có lỗi khi khởi động container!"
        echo "📋 Container logs:"
        docker compose -f "$DOCKER_COMPOSE_FILE" logs --tail=20
        return 1
    fi
    echo ""
}

backup_and_update() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}    N8N BACKUP & UPDATE PROCESS${NC}"
    echo -e "${BLUE}================================================${NC}"
    
    check_current_version
    show_server_status
    count_backups
    create_backup
    update_n8n
    
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}    BACKUP & UPDATE HOÀN THÀNH${NC}"
    echo -e "${GREEN}================================================${NC}"
    print_success "Backup: $BACKUP_DIR/n8n_backup_${TIMESTAMP}.tar.gz"
    print_success "N8N đã được cập nhật và đang chạy"
    print_success "Truy cập: https://${CF_HOSTNAME:-localhost:5678}"
}

# === Uninstall Functions ===
create_manifest() {
    local manifest_file="$N8N_BASE_DIR/.n8n_manifest"
    
    cat > "$manifest_file" << EOF
# N8N Installation Manifest
# Generated on: $(date)
# This file tracks what was installed for uninstall purposes

INSTALL_DATE="$(date)"
N8N_BASE_DIR="$N8N_BASE_DIR"
N8N_VOLUME_DIR="$N8N_VOLUME_DIR"
BACKUP_DIR="$BACKUP_DIR"
CONFIG_FILE="$CONFIG_FILE"
DOCKER_COMPOSE_FILE="$DOCKER_COMPOSE_FILE"
CLOUDFLARED_CONFIG_FILE="$CLOUDFLARED_CONFIG_FILE"

# Installed components
DOCKER_INSTALLED="yes"
CLOUDFLARED_INSTALLED="yes"
N8N_CONTAINER_CREATED="yes"
CLOUDFLARED_SERVICE_CREATED="yes"

# Backup location
MANIFEST_FILE="$manifest_file"
EOF
    
    chmod 600 "$manifest_file"
    print_success "Manifest created: $manifest_file"
}

scan_installation() {
    print_section "Quét VPS để tìm các thành phần N8N"
    echo ""
    
    local found_items=0
    
    # Kiểm tra Docker
    echo "🔍 Kiểm tra Docker..."
    if command -v docker &> /dev/null; then
        # ! FIX: Missing closing parenthesis
        echo "  ✅ Docker: $(docker --version)"
        ((found_items++))
    else
        echo "  ❌ Docker: Không tìm thấy"
    fi
    
    # Kiểm tra Docker Compose
    echo "🔍 Kiểm tra Docker Compose..."
    if docker compose version &> /dev/null 2>&1; then
        # ! FIX: Missing closing parenthesis
        echo "  ✅ Docker Compose: $(docker compose version 2>/dev/null | head -1)"
        ((found_items++))
    else
        echo "  ❌ Docker Compose: Không tìm thấy"
    fi
    
    # Kiểm tra N8N container
    echo "🔍 Kiểm tra N8N container..."
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^n8n$"; then
        local status
        status=$(docker ps --format '{{.Status}}' --filter "name=^n8n$" 2>/dev/null || echo "stopped")
        echo "  ✅ N8N container: $status"
        ((found_items++))
    else
        echo "  ❌ N8N container: Không tìm thấy"
    fi
    
    # Kiểm tra N8N image
    echo "🔍 Kiểm tra N8N image..."
    if docker images --format '{{.Repository}}' 2>/dev/null | grep -q "n8nio/n8n"; then
        local image_id
        image_id=$(docker images --format '{{.ID}}' --filter "reference=n8nio/n8n" 2>/dev/null | head -1)
        echo "  ✅ N8N image: $image_id"
        ((found_items++))
    else
        echo "  ❌ N8N image: Không tìm thấy"
    fi
    
    # Kiểm tra N8N network
    echo "🔍 Kiểm tra N8N network..."
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "n8n-network"; then
        echo "  ✅ N8N network: n8n-network"
        ((found_items++))
    else
        echo "  ❌ N8N network: Không tìm thấy"
    fi
    
    # Kiểm tra Cloudflared
    echo "🔍 Kiểm tra Cloudflared..."
    if command -v cloudflared &> /dev/null; then
        # ! FIX: Missing closing parenthesis
        echo "  ✅ Cloudflared: $(cloudflared --version 2>/dev/null | head -1)"
        ((found_items++))
    else
        echo "  ❌ Cloudflared: Không tìm thấy"
    fi
    
    # Kiểm tra Cloudflared service
    echo "🔍 Kiểm tra Cloudflared service..."
    if systemctl is-enabled cloudflared &> /dev/null 2>&1; then
        local cf_status
        cf_status=$(systemctl is-active cloudflared 2>/dev/null || echo "unknown")
        echo "  ✅ Cloudflared service: $cf_status"
        ((found_items++))
    else
        echo "  ❌ Cloudflared service: Không tìm thấy"
    fi
    
    # Kiểm tra N8N data directory
    echo "🔍 Kiểm tra N8N data directory..."
    if [ -d "$N8N_BASE_DIR" ]; then
        local size
        size=$(du -sh "$N8N_BASE_DIR" 2>/dev/null | cut -f1)
        # ! FIX: Missing closing parenthesis
        echo "  ✅ N8N directory: $N8N_BASE_DIR ($size)"
        ((found_items++))
    else
        echo "  ❌ N8N directory: Không tìm thấy"
    fi
    
    # Kiểm tra Backup directory
    echo "🔍 Kiểm tra Backup directory..."
    if [ -d "$BACKUP_DIR" ]; then
        local backup_count
        backup_count=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
        local backup_size
        backup_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
        # ! FIX: Missing closing parenthesis
        echo "  ✅ Backup directory: $BACKUP_DIR ($backup_count backups, $backup_size)"
        ((found_items++))
    else
        echo "  ❌ Backup directory: Không tìm thấy"
    fi
    
    # Kiểm tra Cloudflared config
    echo "🔍 Kiểm tra Cloudflared config..."
    if [ -f "$CLOUDFLARED_CONFIG_FILE" ]; then
        echo "  ✅ Cloudflared config: $CLOUDFLARED_CONFIG_FILE"
        ((found_items++))
    else
        echo "  ❌ Cloudflared config: Không tìm thấy"
    fi
    
    # Kiểm tra Config file
    echo "🔍 Kiểm tra Config file..."
    if [ -f "$CONFIG_FILE" ]; then
        echo "  ✅ Config file: $CONFIG_FILE"
        ((found_items++))
    else
        echo "  ❌ Config file: Không tìm thấy"
    fi
    
    echo ""
    echo "📊 Tổng cộng tìm thấy: $found_items thành phần"
    echo ""
    
    return 0
}

uninstall_n8n() {
    print_section "Gỡ cài đặt N8N"
    echo ""
    
    # Scan trước
    scan_installation
    echo ""
    
    # Xác nhận
    print_warning "⚠️  CẢNH BÁO: Quá trình gỡ cài sẽ:"
    echo "  • Dừng N8N container"
    echo "  • Xóa N8N container"
    echo "  • Xóa N8N image"
    echo "  • Xóa N8N network"
    echo "  • Dừng Cloudflared service"
    echo "  • Xóa Cloudflared config"
    echo "  • Xóa N8N data directory (workflows, database, etc.)"
    echo "  • Xóa config files"
    echo ""
    print_warning "⚠️  Backup sẽ được GIỮ LẠI trong: $BACKUP_DIR"
    echo ""
    
    read -p "Bạn có chắc chắn muốn gỡ cài N8N? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Hủy gỡ cài"
        return 0
    fi
    
    echo ""
    print_section "Bắt đầu gỡ cài..."
    echo ""
    
    # 1. Dừng N8N container
    echo "1️⃣ Dừng N8N container..."
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^n8n$"; then
        docker compose -f "$DOCKER_COMPOSE_FILE" down 2>/dev/null || true
        print_success "N8N container đã dừng"
    else
        echo "   (N8N container không chạy)"
    fi
    
    # 2. Xóa N8N container
    echo "2️⃣ Xóa N8N container..."
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^n8n$"; then
        docker rm -f n8n 2>/dev/null || true
        print_success "N8N container đã xóa"
    else
        echo "   (N8N container không tồn tại)"
    fi
    
    # 3. Xóa N8N image
    echo "3️⃣ Xóa N8N image..."
    if docker images --format '{{.Repository}}' 2>/dev/null | grep -q "n8nio/n8n"; then
        docker rmi -f n8nio/n8n 2>/dev/null || true
        print_success "N8N image đã xóa"
    else
        echo "   (N8N image không tồn tại)"
    fi
    
    # 4. Xóa N8N network
    echo "4️⃣ Xóa N8N network..."
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "n8n-network"; then
        docker network rm n8n-network 2>/dev/null || true
        print_success "N8N network đã xóa"
    else
        echo "   (N8N network không tồn tại)"
    fi
    
    # 5. Dừng Cloudflared service
    echo "5️⃣ Dừng Cloudflared service..."
    if systemctl is-active cloudflared &> /dev/null 2>&1; then
        systemctl stop cloudflared 2>/dev/null || true
        systemctl disable cloudflared 2>/dev/null || true
        print_success "Cloudflared service đã dừng"
    else
        echo "   (Cloudflared service không chạy)"
    fi
    
    # 6. Xóa Cloudflared config
    echo "6️⃣ Xóa Cloudflared config..."
    if [ -f "$CLOUDFLARED_CONFIG_FILE" ]; then
        rm -f "$CLOUDFLARED_CONFIG_FILE" 2>/dev/null || true
        print_success "Cloudflared config đã xóa"
    else
        echo "   (Cloudflared config không tồn tại)"
    fi
    
    # 7. Xóa N8N data directory
    echo "7️⃣ Xóa N8N data directory..."
    if [ -d "$N8N_BASE_DIR" ]; then
        rm -rf "$N8N_BASE_DIR" 2>/dev/null || true
        print_success "N8N data directory đã xóa"
    else
        echo "   (N8N data directory không tồn tại)"
    fi
    
    # 8. Xóa config file
    echo "8️⃣ Xóa config file..."
    if [ -f "$CONFIG_FILE" ]; then
        rm -f "$CONFIG_FILE" 2>/dev/null || true
        print_success "Config file đã xóa"
    else
        echo "   (Config file không tồn tại)"
    fi
    
    echo ""
    print_section "Gỡ cài hoàn thành!"
    echo ""
    echo "✅ Các thành phần đã được gỡ cài:"
    echo "  • N8N container"
    echo "  • N8N image"
    echo "  • N8N network"
    echo "  • N8N data directory"
    echo "  • Cloudflared service"
    echo "  • Cloudflared config"
    echo "  • Config files"
    echo ""
    echo "📦 Backup được giữ lại tại: $BACKUP_DIR"
    echo ""
    echo "💡 Để xóa hoàn toàn backup:"
    echo "   rm -rf $BACKUP_DIR"
    echo ""
}

# === Original Installation Functions ===
install_n8n() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}    CLOUDFLARE TUNNEL & N8N SETUP${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo "Script này sẽ cài đặt Docker, Cloudflared và cấu hình N8N"
    echo "để truy cập qua Cloudflare Tunnel."
    echo ""

    # --- Check for existing config ---
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
    
    echo "" # Newline for better formatting

    # --- System Update and Prerequisites ---
    echo ">>> Updating system packages..."
    apt-get update
    echo ">>> Installing prerequisites (curl, wget, gpg, etc.)..."
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release wget

    # --- Install Docker ---
    if command -v docker &> /dev/null; then
        print_success "Docker đã được cài đặt: $(docker --version)"
        
        # Kiểm tra Docker service
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
        # Add Docker's official GPG key:
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        
        # Add the repository to Apt sources:
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update

        # Install Docker packages
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        print_success "Docker installed successfully: $(docker --version)"

        # Ensure Docker service is running and enabled
        systemctl start docker
        systemctl enable docker
        print_success "Docker service started and enabled"

        # Add the current sudo user (if exists) to the docker group
        # This avoids needing sudo for every docker command AFTER logging out/in again
        if id "$REAL_USER" &>/dev/null && ! getent group docker | grep -qw "$REAL_USER"; then
          echo ">>> Adding user '$REAL_USER' to the 'docker' group..."
          usermod -aG docker "$REAL_USER"
          echo ">>> NOTE: User '$REAL_USER' needs to log out and log back in for docker group changes to take full effect."
        fi
    fi
    
    # --- Install Cloudflared ---
    if command -v cloudflared &> /dev/null; then
        print_success "Cloudflared đã được cài đặt: $(cloudflared --version 2>/dev/null | head -1)"
    else
        echo ">>> Cloudflared not found. Installing Cloudflared..."
    
        # Automatically determine the system architecture
        local ARCH
        ARCH=$(dpkg --print-architecture)
        echo ">>> Detected system architecture: $ARCH"
    
        local CLOUDFLARED_DEB_URL
        local CLOUDFLARED_DEB_PATH="/tmp/cloudflared-linux-$ARCH.deb" # Use detected arch in filename
    
        case "$ARCH" in
            amd64)
                CLOUDFLARED_DEB_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"
                ;;
            arm64|armhf) # armhf for older 32-bit ARM, arm64 for 64-bit ARM
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
    
        rm "$CLOUDFLARED_DEB_PATH" # Clean up downloaded file
        print_success "Cloudflared installed successfully: $(cloudflared --version 2>/dev/null | head -1)"
    fi

    # --- Setup n8n Directory and Permissions ---
    echo ">>> Setting up n8n data directory: $N8N_BASE_DIR"
    mkdir -p "$N8N_VOLUME_DIR" # Create the specific volume dir as well
    
    # Set ownership to UID 1000, GID 1000 (standard 'node' user in n8n official container)
    # This prevents permission errors when n8n tries to write data
    # NOTE: This assumes the official n8n Docker image. Custom images may use different UIDs.
    echo ">>> Setting permissions for n8n data volume..."
    chown -R 1000:1000 "$N8N_VOLUME_DIR"
    
    # Set secure permissions (700 = owner only read/write/execute)
    # This protects sensitive data like credentials, workflows, and database
    echo ">>> Setting secure permissions (700) for n8n data..."
    chmod -R 700 "$N8N_VOLUME_DIR"

    # --- Generate or Load N8N Encryption Key ---
    local N8N_ENCRYPTION_KEY
    if [ -f "$N8N_ENCRYPTION_KEY_FILE" ]; then
        echo ">>> Loading existing N8N encryption key..."
        N8N_ENCRYPTION_KEY=$(cat "$N8N_ENCRYPTION_KEY_FILE")
        print_success "Encryption key loaded from: $N8N_ENCRYPTION_KEY_FILE"
    else
        echo ">>> Generating new N8N encryption key..."
        # Generate a secure random 32-byte key encoded in base64
        N8N_ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '\n')
        
        # Save the key securely
        echo "$N8N_ENCRYPTION_KEY" > "$N8N_ENCRYPTION_KEY_FILE"
        chmod 600 "$N8N_ENCRYPTION_KEY_FILE"
        
        print_success "New encryption key generated and saved to: $N8N_ENCRYPTION_KEY_FILE"
        print_warning "⚠️  QUAN TRỌNG: Backup file này để có thể restore credentials sau này!"
    fi
    
    # --- Check if N8N container already exists ---
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^n8n$"; then
        print_warning "⚠️  N8N container đã tồn tại!"
        read -p "Bạn có muốn khởi động lại container không? (y/N): " restart_container
        if [[ "$restart_container" =~ ^[Yy]$ ]]; then
            docker compose -f "$DOCKER_COMPOSE_FILE" up -d 2>/dev/null || true
            print_success "N8N container đã được khởi động"
            health_check
            exit 0
        fi
    fi
    
    # --- Create Docker Compose File ---
    echo ">>> Creating Docker Compose file: $DOCKER_COMPOSE_FILE"
    # Determine Timezone
    local SYSTEM_TZ
    SYSTEM_TZ=$(cat /etc/timezone 2>/dev/null || echo "$DEFAULT_TZ")
    
    # Determine port binding based on mode
    local PORT_BINDING="127.0.0.1:5678:5678"
    local PORT_COMMENT
    if [ "$CF_HOSTNAME" = "localhost" ]; then
        PORT_COMMENT="# Local mode - bind to localhost only"
    else
        PORT_COMMENT="# Cloudflare mode - bind to localhost, Cloudflared handles external access"
    fi
    
    cat <<EOF > "$DOCKER_COMPOSE_FILE"
services:
  n8n:
    image: n8nio/n8n
    container_name: n8n
    restart: unless-stopped
    ports:
      $PORT_COMMENT
      - "$PORT_BINDING"
    environment:
      # Use system timezone if available, otherwise default
      - TZ=${SYSTEM_TZ}
      # CRITICAL: Encryption key for credentials - DO NOT CHANGE after first run
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
EOF
    
    # Add Cloudflare-specific settings only if not in local mode
    if [ "$CF_HOSTNAME" != "localhost" ]; then
        cat <<EOF >> "$DOCKER_COMPOSE_FILE"
      # Security settings for HTTPS access via Cloudflare
      - N8N_HOST=${CF_HOSTNAME}
      - WEBHOOK_URL=https://${CF_HOSTNAME}/
EOF
    fi
    
    cat <<EOF >> "$DOCKER_COMPOSE_FILE"
      # Performance and security optimizations
      - N8N_METRICS=false
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_VERSION_NOTIFICATIONS_ENABLED=false
      # N8N_SECURE_COOKIE=false # DO NOT USE THIS when accessing via HTTPS (Cloudflared)
    volumes:
      # Mount the local data directory into the container
      - ./n8n_data:/home/node/.n8n
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:5678/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

networks:
  default:
    name: n8n-network # Define a specific network name (optional but good practice)

EOF
    
    print_success "Docker Compose file created with security enhancements"

    # --- Configure Cloudflared Service (skip if local mode) ---
    if [ "$CF_HOSTNAME" != "localhost" ]; then
        echo ">>> Configuring Cloudflared..."
        # Create directory if it doesn't exist
        mkdir -p /etc/cloudflared

        # Create cloudflared config.yml
        echo ">>> Creating Cloudflared config file: $CLOUDFLARED_CONFIG_FILE"
        cat <<EOF > "$CLOUDFLARED_CONFIG_FILE"
# This file is configured for tunnel runs via 'cloudflared service install'
# It defines the ingress rules. Tunnel ID and credentials file are managed
# automatically by the service install command using the provided token.
# Do not add 'tunnel:' or 'credentials-file:' lines here.

ingress:
  - hostname: ${CF_HOSTNAME}
    service: http://localhost:5678 # Points to n8n running locally via Docker port mapping
  - service: http_status:404 # Catch-all rule
EOF
        echo ">>> Cloudflared config file created."

        # --- Check if Cloudflared service already exists ---
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
            # Install cloudflared as a service using the token
            echo ">>> Installing Cloudflared service using the provided token..."
            # The service install command handles storing the token securely
            cloudflared service install "$CF_TOKEN"
            print_success "Cloudflared service installed."

            # --- Start Services ---
            echo ">>> Enabling and starting Cloudflared service..."
            systemctl enable cloudflared
            systemctl start cloudflared
        fi
        # Brief pause to allow service to stabilize
        sleep 5
        echo ">>> Checking Cloudflared service status:"
        systemctl status cloudflared --no-pager || echo "Warning: Cloudflared status check indicates an issue. Use 'sudo journalctl -u cloudflared' for details."
    else
        print_success "Chế độ Local - Cloudflared không được cài đặt"
    fi

    echo ">>> Starting n8n container via Docker Compose..."
    # Use -f to specify the file, ensuring it runs from anywhere
    # Use --remove-orphans to clean up any old containers if the compose file changed significantly
    # Use -d to run in detached mode
    docker compose -f "$DOCKER_COMPOSE_FILE" up --remove-orphans -d

    # --- Create Manifest ---
    echo ">>> Creating installation manifest..."
    create_manifest
    
    # --- Final Instructions ---
    echo ""
    echo "--------------------------------------------------"
    echo " Setup Complete! "
    echo "--------------------------------------------------"
    
    if [ "$CF_HOSTNAME" = "localhost" ]; then
        echo "✅ N8N đã được cài đặt ở chế độ Local Mode"
        echo ""
        echo "🌐 Truy cập N8N tại:"
        echo "   http://localhost:5678"
        echo ""
        echo "📝 Thông tin Local Mode:"
        echo "   • Chỉ có thể truy cập từ máy local"
        echo "   • Không cần cấu hình Cloudflare"
        echo "   • Không cần DNS"
        echo "   • Hoàn hảo cho phát triển và thử nghiệm"
        echo ""
        echo "💡 Để chuyển sang Cloudflare Mode sau này:"
        echo "   1. Chạy: sudo bash $0 config"
        echo "   2. Chọn 'Tạo config mới'"
        echo "   3. Chọn 'Có' khi được hỏi về Cloudflare Tunnel"
        echo ""
    else
        echo "✅ N8N đã được cài đặt với Cloudflare Tunnel"
        echo ""
        echo "🌐 Truy cập N8N tại:"
        echo "   https://${CF_HOSTNAME}"
        echo ""
        echo "⚠️  QUAN TRỌNG: Bạn cần cấu hình DNS trong Cloudflare Dashboard!"
        echo ""
        echo "📋 Các bước tiếp theo:"
        echo ""
        echo "1️⃣ Vào Cloudflare Dashboard: https://dash.cloudflare.com/"
        echo ""
        echo "2️⃣ Tạo DNS Record:"
        # ! FIX: Missing closing parenthesis
        echo "   • Type: CNAME"
        # ! FIX: Missing closing parenthesis
        echo "   • Name: $(echo ${CF_HOSTNAME} | cut -d'.' -f1)"
        echo "   • Target: ${TUNNEL_ID}.cfargotunnel.com"
        # ! FIX: Missing closing parenthesis
        echo "   • Proxy: Proxied (màu cam)"
        echo ""
        echo "3️⃣ Cấu hình Public Hostname trong Tunnel:"
        echo "   • Access → Tunnels → Chọn tunnel"
        echo "   • Public Hostname → Add a public hostname"
        # ! FIX: Missing closing parenthesis
        echo "   • Subdomain: $(echo ${CF_HOSTNAME} | cut -d'.' -f1)"
        # ! FIX: Missing closing parenthesis
        echo "   • Domain: $(echo ${CF_HOSTNAME} | cut -d'.' -f2-)"
        echo "   • Service: http://localhost:5678"
        echo ""
        echo "💡 Hướng dẫn chi tiết: Xem file CLOUDFLARE_DNS_SETUP.md"
        echo ""
    fi
    echo "✅ Kiểm tra trạng thái:"
    echo "   sudo bash $0 status"
    echo ""
    echo "📋 Xem logs:"
    echo "   docker logs n8n"
    if [ "$CF_HOSTNAME" != "localhost" ]; then
        echo "   sudo journalctl -u cloudflared -f"
    fi
    echo ""
    echo "🔧 Các lệnh hữu ích:"
    echo "   • Backup N8N: sudo bash $0 backup"
    echo "   • Update N8N: sudo bash $0 update"  
    echo "   • Backup & Update: sudo bash $0 backup-update"
    echo "   • Quản lý Config: sudo bash $0 config"
    echo "   • Gỡ cài đặt: sudo bash $0 uninstall"
    echo ""
    if [ "$REAL_USER" != "root" ]; then
        echo "💡 Lưu ý: User '$REAL_USER' vừa được thêm vào docker group"
        echo "   Vui lòng đăng xuất và đăng nhập lại để áp dụng thay đổi"
    fi
    echo "--------------------------------------------------"
}

show_menu() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}    N8N MANAGEMENT SCRIPT${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
    echo "Chọn hành động:"
    echo "1. 🚀 Cài đặt N8N mới (với Cloudflare Tunnel)"
    echo "2. 💾 Backup dữ liệu N8N"
    echo "3. 🔄 Update N8N lên phiên bản mới nhất"
    echo "4. 🔄💾 Backup + Update N8N"
    echo "5. 📊 Kiểm tra trạng thái hệ thống"
    echo "6. 📋 Xem thông tin backup"
    echo "7. 🔙 Rollback từ backup"
    echo "8. 🧹 Dọn dẹp backup cũ"
    echo "9. ⚙️ Xem/Quản lý config Cloudflare"
    echo "10. 🔍 Quét VPS để tìm thành phần N8N"
    echo "11. 🗑️ Gỡ cài đặt N8N hoàn toàn"
    echo "0. ❌ Thoát"
    echo ""
    read -p "Nhập lựa chọn (0-11): " choice
}

# === Main Script Logic ===
# Nếu có tham số dòng lệnh
if [ $# -gt 0 ]; then
    case $1 in
        "install")
            install_n8n
            ;;
        "backup")
            check_current_version
            show_server_status
            count_backups
            create_backup
            ;;
        "update")
            check_current_version
            update_n8n
            ;;
        "backup-update")
            backup_and_update
            ;;
        "status")
            check_current_version
            show_server_status
            count_backups
            ;;
        "rollback")
            rollback_backup
            ;;
        "cleanup")
            cleanup_old_backups
            ;;
        "config")
            manage_config
            ;;
        "scan")
            scan_installation
            ;;
        "uninstall")
            uninstall_n8n
            ;;
        *)
            echo "Sử dụng: $0 [install|backup|update|backup-update|status|rollback|cleanup|config|scan|uninstall]"
            echo ""
            echo "Ví dụ:"
            echo "  $0 install        # Cài đặt N8N mới"
            echo "  $0 backup         # Backup dữ liệu"
            echo "  $0 update         # Update N8N"
            echo "  $0 backup-update  # Backup và update"
            echo "  $0 status         # Kiểm tra trạng thái"
            echo "  $0 rollback       # Rollback từ backup"
            echo "  $0 cleanup        # Dọn dẹp backup cũ"
            echo "  $0 config         # Quản lý config"
            echo "  $0 scan           # Quét VPS để tìm thành phần N8N"
            echo "  $0 uninstall      # Gỡ cài đặt N8N hoàn toàn"
            exit 1
            ;;
    esac
else
    # Menu tương tác
    while true; do
        show_menu
        case $choice in
            1)
                install_n8n
                ;;
            2)
                check_current_version
                show_server_status
                count_backups
                create_backup
                ;;
            3)
                check_current_version
                update_n8n
                ;;
            4)
                backup_and_update
                ;;
            5)
                check_current_version
                show_server_status
                count_backups
                ;;
            6)
                count_backups
                ;;
            7)
                rollback_backup
                ;;
            8)
                cleanup_old_backups
                ;;
            9)
                manage_config
                ;;
            10)
                scan_installation
                ;;
            11)
                uninstall_n8n
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
        clear
    done
fi

exit 0
