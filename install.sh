#!/usr/bin/env bash
# Shell Auto-Wrapper: Re-execute in bash if invoked via sh/dash
if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi
# ==============================================================================
# Ente All-in-One Fail-Safe Installer
# Repository: https://github.com/ente/ente
# ==============================================================================
# Features:
# - Automatic pre-flight system & architecture auditing
# - Automated Docker & Docker Compose installation if missing
# - Intelligent non-colliding port scanner (handles busy :3000, :8080, :3200)
# - Immune to the PostgreSQL "dirty migration lock" race condition
# - Cross-device direct-to-S3 upload configuration (LAN or Domain)
# - Automatic 10 TB storage quota unlocker + quota adjustment companion tool
# - Ready-to-use Cloudflare Tunnel & Caddy reverse proxy snippets
# ==============================================================================

set -eo pipefail

# ------------------------------------------------------------------------------
# Colors & Visual Formatting
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

print_banner() {
    clear 2>/dev/null || true
    echo -e "${PURPLE}${BOLD}"
    cat << "EOF"
  ███████╗███╗   ██╗████████╗███████╗
  ██╔════╝████╗  ██║╚══██╔══╝██╔════╝
  █████╗  ██╔██╗ ██║   ██║   █████╗  
  ██╔══╝  ██║╚██╗██║   ██║   ██╔══╝  
  ███████╗██║ ╚████║   ██║   ███████╗
  ╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚══════╝
   FAIL-SAFE SELF-HOSTED INSTALLER
EOF
    echo -e "${NC}"
    echo -e "${CYAN}End-to-End Encrypted Photo & Authentication Cloud${NC}"
    echo -e "────────────────────────────────────────────────────────────────────────"
}

# ------------------------------------------------------------------------------
# Logging & Error Tracking Setup
# ------------------------------------------------------------------------------
INITIAL_LOG_FILE="/tmp/ente-installer-$$.log"
ACTIVE_LOG_FILE="$INITIAL_LOG_FILE"

# Log to file with clean timestamp and stripped ANSI escape codes
log_to_file() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "timestamp")
    local clean_msg
    clean_msg=$(printf '%b' "$msg" | sed -E 's/\x1B\[[0-9;]*[mK]//g' 2>/dev/null || echo "$msg")
    echo "[$timestamp] [$level] $clean_msg" >> "$ACTIVE_LOG_FILE" 2>/dev/null || true
}

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; log_to_file "INFO" "$1"; }
log_step()    { echo -e "\n${BOLD}${CYAN}==>${NC} ${BOLD}$1${NC}"; log_to_file "STEP" "$1"; }
log_success() { echo -e "${GREEN}[✔]${NC} $1"; log_to_file "SUCCESS" "$1"; }
log_warn()    { echo -e "${YELLOW}[⚠ WARNING]${NC} $1"; log_to_file "WARN" "$1"; }
log_error()   { echo -e "${RED}[✖ ERROR]${NC} $1"; log_to_file "ERROR" "$1"; }

# Global Error Trap
on_error() {
    local exit_code=$?
    local line_no=$1
    local command=$2
    log_error "Installation failed at line $line_no (command: '$command') with exit code $exit_code."
    echo -e "\n${YELLOW}${BOLD}Troubleshooting & Diagnostic Log:${NC}"
    echo -e "  A complete execution timeline has been recorded in: ${CYAN}${ACTIVE_LOG_FILE}${NC}"
    echo -e "  To inspect the failure, run: ${BOLD}cat ${ACTIVE_LOG_FILE}${NC}\n"
    exit "$exit_code"
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

# ------------------------------------------------------------------------------
# Step 1: Pre-Flight Auditing & Prerequisites
# ------------------------------------------------------------------------------
preflight_audit() {
    log_step "Step 1: Running Pre-Flight System Audit"
    log_to_file "SYSTEM" "Hostname: $(hostname 2>/dev/null || echo 'unknown')"
    log_to_file "SYSTEM" "Kernel: $(uname -a 2>/dev/null || echo 'unknown')"
    log_to_file "SYSTEM" "User: $(whoami 2>/dev/null || echo 'unknown') (EUID: $EUID)"

    # 0. Operating System Check (Linux & WSL2 only)
    OS_TYPE=$(uname -s)
    case "$OS_TYPE" in
        Linux*)
            # Check if running inside WSL (Windows Subsystem for Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                log_success "Operating System: Linux (WSL2 Environment detected)"
            else
                log_success "Operating System: Linux (${OS_TYPE})"
            fi
            ;;
        Darwin*)
            log_error "macOS detected (${OS_TYPE})."
            echo -e "  Ente server requires a Linux production environment (systemd, Linux networking, ext4/ZFS)."
            echo -e "  Please deploy on a Linux server, Raspberry Pi, or Linux VM."
            exit 1
            ;;
        CYGWIN*|MINGW*|MSYS*)
            if [ "$DRY_RUN" = true ]; then
                log_info "[DRY-RUN] Simulating Linux environment for configuration audit."
            else
                log_error "Native Windows shell detected (${OS_TYPE} / Git Bash / MSYS)."
                echo -e "  Ente cannot be hosted directly inside a native Windows terminal."
                echo -e "  ${BOLD}Solution:${NC} Open a ${CYAN}WSL2 terminal (Ubuntu)${NC} on Windows and run this script inside WSL2,"
                echo -e "  or run it directly on a dedicated Linux server / homelab."
                exit 1
            fi
            ;;
        *)
            log_error "Unsupported operating system: ${OS_TYPE}. Ente requires a Linux environment."
            exit 1
            ;;
    esac

    # 1. Architecture Check
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) TARGET_ARCH="amd64" ;;
        aarch64|arm64) TARGET_ARCH="arm64" ;;
        *)
            log_error "Unsupported architecture: $ARCH. Ente requires x86_64 or arm64."
            exit 1
            ;;
    esac
    log_success "Hardware Architecture: $ARCH ($TARGET_ARCH)"

    # 2. Check Sudo / Root
    if [ "$EUID" -eq 0 ]; then
        log_warn "Running as root user. It is recommended to run this script as a normal user with sudo privileges."
        SUDO_CMD=""
    elif command -v sudo >/dev/null 2>&1; then
        SUDO_CMD="sudo"
    else
        SUDO_CMD=""
        log_warn "Running as non-root user without sudo. Package installation commands will be skipped if privileges are required."
    fi

    # 3. Check / Install Core Utilities
    NEEDED_TOOLS=""
    for tool in curl openssl awk grep; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            NEEDED_TOOLS="$NEEDED_TOOLS $tool"
        fi
    done

    if [ -n "$NEEDED_TOOLS" ]; then
        log_info "Attempting to install missing utilities:$NEEDED_TOOLS"
        if command -v apt-get >/dev/null 2>&1; then
            $SUDO_CMD apt-get update -qq && $SUDO_CMD apt-get install -y -qq $NEEDED_TOOLS || true
        elif command -v dnf >/dev/null 2>&1; then
            $SUDO_CMD dnf install -y -q $NEEDED_TOOLS || true
        elif command -v yum >/dev/null 2>&1; then
            $SUDO_CMD yum install -y -q $NEEDED_TOOLS || true
        elif command -v pacman >/dev/null 2>&1; then
            $SUDO_CMD pacman -Sy --noconfirm $NEEDED_TOOLS || true
        elif command -v apk >/dev/null 2>&1; then
            $SUDO_CMD apk add --no-cache $NEEDED_TOOLS || true
        elif command -v zypper >/dev/null 2>&1; then
            $SUDO_CMD zypper install -y $NEEDED_TOOLS || true
        fi
    fi

    # 4. Check Docker & Compose
    if ! command -v docker >/dev/null 2>&1; then
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY-RUN] Docker not found; simulating active Docker Engine for configuration audit."
        else
            log_warn "Docker is not installed on this machine."
            if [ "$UNATTENDED" = true ]; then
                INSTALL_DOCKER_CHOICE="Y"
                log_info "[Unattended] Automatically installing official Docker & Compose..."
            else
                read -rp "Would you like this script to install official Docker & Compose automatically? [Y/n]: " INSTALL_DOCKER_CHOICE
                INSTALL_DOCKER_CHOICE=${INSTALL_DOCKER_CHOICE:-Y}
            fi
            if [[ "$INSTALL_DOCKER_CHOICE" =~ ^[Yy]$ ]]; then
                log_info "Downloading and running official Docker install script..."
                curl -fsSL https://get.docker.com | $SUDO_CMD sh
                if [ -n "$SUDO_USER" ]; then
                    $SUDO_CMD usermod -aG docker "$SUDO_USER" || true
                elif [ "$EUID" -ne 0 ]; then
                    $SUDO_CMD usermod -aG docker "$USER" || true
                fi
                $SUDO_CMD systemctl enable --now docker 2>/dev/null || $SUDO_CMD service docker start 2>/dev/null || true
                log_success "Docker installed successfully."
            else
                log_error "Docker is required to run Ente. Please install Docker and re-run this script."
                exit 1
            fi
        fi
    fi

    # Check Docker Daemon Connectivity
    if ! docker info >/dev/null 2>&1; then
        if [ -n "$SUDO_CMD" ] && $SUDO_CMD docker info >/dev/null 2>&1; then
            log_info "Current user needs sudo for docker. Adding user to docker group..."
            $SUDO_CMD usermod -aG docker "$USER" || true
            DOCKER_PREFIX="$SUDO_CMD "
        elif [ "$DRY_RUN" = true ]; then
            log_info "[DRY-RUN] Docker daemon offline or mock environment; continuing dry-run audit."
            DOCKER_PREFIX=""
        else
            log_error "Docker daemon is not running. Start it with: sudo systemctl start docker"
            exit 1
        fi
    else
        DOCKER_PREFIX=""
    fi
    log_success "Docker Engine is active"

    # Verify Compose v2.28+
    COMPOSE_VERSION=$($DOCKER_PREFIX docker compose version --short 2>/dev/null || echo "0.0.0")
    log_success "Docker Compose version: $COMPOSE_VERSION"

    # 5. Memory Check (Guarded against minimal containers / older kernels)
    AVAILABLE_RAM_KB=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}' || true)
    if [ -z "$AVAILABLE_RAM_KB" ]; then
        AVAILABLE_RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || true)
    fi
    AVAILABLE_RAM_KB=${AVAILABLE_RAM_KB:-2048000}
    if [[ ! "$AVAILABLE_RAM_KB" =~ ^[0-9]+$ ]]; then
        AVAILABLE_RAM_KB=2048000
    fi
    AVAILABLE_RAM_MB=$(( AVAILABLE_RAM_KB / 1024 ))
    if [ "$AVAILABLE_RAM_MB" -lt 800 ]; then
        log_warn "Low available memory: ${AVAILABLE_RAM_MB} MB. Ente recommends at least 1 GB RAM."
    else
        log_success "Memory: ${AVAILABLE_RAM_MB} MB available (Adequate)"
    fi

    # 6. Disk Space Check (POSIX -P format avoids multiline wrapping)
    AVAILABLE_DISK_KB=$(df -k -P "$HOME" 2>/dev/null | awk 'NR==2 {print $4}' || true)
    AVAILABLE_DISK_KB=${AVAILABLE_DISK_KB:-10485760}
    if [[ ! "$AVAILABLE_DISK_KB" =~ ^[0-9]+$ ]]; then
        AVAILABLE_DISK_KB=10485760
    fi
    AVAILABLE_DISK_MB=$(( AVAILABLE_DISK_KB / 1024 ))
    if [ "$AVAILABLE_DISK_MB" -lt 3000 ]; then
        log_warn "Low available disk space: ${AVAILABLE_DISK_MB} MB. Ente container images and database require at least 3-5 GB free."
    else
        log_success "Disk Space: ${AVAILABLE_DISK_MB} MB available"
    fi

    # 7. Check for Existing Conflicting Ente Containers
    EXISTING_CONTAINERS=$($DOCKER_PREFIX docker ps -a --filter "name=ente-" --format "{{.Names}}" 2>/dev/null || true)
    if [ -n "$EXISTING_CONTAINERS" ]; then
        log_warn "Detected existing Ente container(s) from a previous deployment:"
        echo "$EXISTING_CONTAINERS" | sed 's/^/    • /'
        if [ "$UNATTENDED" = true ]; then
            CLEANUP_CHOICE="Y"
            log_info "[Unattended] Automatically stopping and removing conflicting containers..."
        else
            read -rp "Would you like this script to stop and remove these conflicting containers? [Y/n]: " CLEANUP_CHOICE
            CLEANUP_CHOICE=${CLEANUP_CHOICE:-Y}
        fi
        if [[ "$CLEANUP_CHOICE" =~ ^[Yy]$ ]]; then
            log_info "Stopping and removing conflicting containers..."
            echo "$EXISTING_CONTAINERS" | xargs -r $DOCKER_PREFIX docker rm -f >> "$ACTIVE_LOG_FILE" 2>&1 || true
            log_success "Conflicting containers removed safely."
        else
            log_warn "Proceeding without cleanup. Note: Docker may throw container name conflict errors."
        fi
    fi

    # 8. Firewall Check (UFW / firewalld)
    if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -qw "active"; then
        log_info "UFW firewall is active. Remember to allow your allocated ports (e.g. sudo ufw allow <PORT>) for remote access."
    fi

    # 9. SELinux & Container Volume Context Check
    SELINUX_VOLUME_SUFFIX=""
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
        SELINUX_VOLUME_SUFFIX=":z"
        log_info "SELinux Enforcing mode detected: Enabling volume label context (:z) for container access."
    fi

    # 10. Kernel IPv6 State Check
    KERNEL_IPV6_DISABLED=false
    if [ -f "/proc/sys/net/ipv4/ip_forward" ] && [ ! -d "/proc/sys/net/ipv6" ]; then
        KERNEL_IPV6_DISABLED=true
        log_info "Host kernel has IPv6 disabled at boot; skipping container IPv6 sysctl."
    fi
}

# ------------------------------------------------------------------------------
# Step 2: Intelligent Non-Colliding Port Scanner
# ------------------------------------------------------------------------------
is_port_free() {
    local port=$1
    # 1. Check Docker publishing ports
    if command -v docker >/dev/null 2>&1; then
        if $DOCKER_PREFIX docker ps --format '{{.Ports}}' 2>/dev/null | grep -Eq "(:|^)${port}->"; then
            return 1
        fi
    fi

    # 2. Check host socket listeners
    if command -v ss >/dev/null 2>&1; then
        ! ss -tulpn 2>/dev/null | grep -Eq ":${port}(\s|$)"
    elif command -v netstat >/dev/null 2>&1; then
        ! netstat -tulpn 2>/dev/null | grep -Eq ":${port}(\s|$)"
    elif command -v lsof >/dev/null 2>&1; then
        ! lsof -i ":${port}" >/dev/null 2>&1
    elif command -v nc >/dev/null 2>&1; then
        ! nc -z -w 1 127.0.0.1 "$port" 2>/dev/null
    else
        ! (bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}") 2>/dev/null
    fi
}

find_free_port() {
    local candidate=$1
    local fallback_candidates=("${@:2}")

    if is_port_free "$candidate"; then
        echo "$candidate"
        return
    fi

    for fallback in "${fallback_candidates[@]}"; do
        if is_port_free "$fallback"; then
            echo "$fallback"
            return
        fi
    done

    # Dynamic search
    local p=$candidate
    while [ "$p" -lt 65535 ]; do
        p=$((p + 1))
        if is_port_free "$p"; then
            echo "$p"
            return
        fi
    done
}

allocate_ports() {
    log_step "Step 2: Checking Port Availability & Avoiding Collisions"

    # Web Port (Default 3000 -> fallback 3004, 3080, 3090)
    WEB_PORT=$(find_free_port 3000 3004 3080 3088 3090)
    if [ "$WEB_PORT" -ne 3000 ]; then
        log_warn "Port 3000 is occupied by another service. Web App automatically remapped to free port :${WEB_PORT}"
    else
        log_success "Web Gallery port allocated: :${WEB_PORT}"
    fi

    # Public Albums Port (Default 3002)
    ALBUMS_PORT=$(find_free_port 3002 3005 3082)
    log_success "Public Albums port allocated: :${ALBUMS_PORT}"

    # Museum API Port (Default 8080)
    API_PORT=$(find_free_port 8080 8088 8090 8888)
    if [ "$API_PORT" -ne 8080 ]; then
        log_warn "Port 8080 is occupied. Museum Core API remapped to free port :${API_PORT}"
    else
        log_success "Museum Core API port allocated: :${API_PORT}"
    fi

    # MinIO S3 Port (Default 3200)
    MINIO_PORT=$(find_free_port 3200 3202 3210 3220)
    if [ "$MINIO_PORT" -ne 3200 ]; then
        log_warn "Port 3200 is occupied. MinIO S3 Storage remapped to free port :${MINIO_PORT}"
    else
        log_success "MinIO S3 Storage port allocated: :${MINIO_PORT}"
    fi
}

# ------------------------------------------------------------------------------
# Step 3: Interactive Configuration Wizard
# ------------------------------------------------------------------------------
configure_topology() {
    log_step "Step 3: Configuration Wizard & Network Topology"

    # 1. Target Directory
    DEFAULT_DIR="${CLI_TARGET_DIR:-$HOME/ente}"
    if [ "$UNATTENDED" = true ]; then
        TARGET_DIR="$DEFAULT_DIR"
        log_info "[Unattended] Target installation folder: $TARGET_DIR"
    else
        read -rp "Enter target installation folder [default: ${DEFAULT_DIR}]: " USER_DIR
        TARGET_DIR="${USER_DIR:-$DEFAULT_DIR}"
    fi
    TARGET_DIR="${TARGET_DIR/#\~/$HOME}" # Expand tilde if typed
    TARGET_DIR="${TARGET_DIR%/}" # Strip trailing slash

    # Safe Guard: Explicitly warn user if an existing active installation is detected
    if [ -f "$TARGET_DIR/credentials.env" ] && [ -f "$TARGET_DIR/compose.yaml" ]; then
        if [ "$UNATTENDED" = true ]; then
            log_info "[Unattended] Existing Ente deployment detected in $TARGET_DIR. Aborting safely to prevent overwriting active instance."
            exit 0
        fi
        echo -e "\n${YELLOW}${BOLD}════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}${BOLD}      ⚠ WARNING: EXISTING ENTE DEPLOYMENT DETECTED!                    ${NC}"
        echo -e "${YELLOW}${BOLD}════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "An active Ente deployment is already configured in: ${CYAN}${TARGET_DIR}${NC}\n"
        echo -e "Running a fresh install will regenerate passwords and reset configurations,"
        echo -e "which may lock you out of your existing database or break active connections.\n"
        echo -e "  ${BOLD}[1] Abort & Run Reconfigure Tool${NC} (Recommended to change IP, domain, or reverse proxy)"
        echo -e "  ${BOLD}[2] Wipe & Reinstall Cleanly${NC} (Backs up old data and starts completely fresh)"
        read -rp "Select an option [1/2, default: 1]: " EXIST_CHOICE
        EXIST_CHOICE=${EXIST_CHOICE:-1}
        if [ "$EXIST_CHOICE" -ne 2 ]; then
            log_info "Aborting installation safely."
            echo -e "To change your IP, domain, or proxy settings without losing data, run:\n"
            echo -e "  ${CYAN}${TARGET_DIR}/reconfigure.sh${NC}\n"
            exit 0
        fi
        log_warn "Proceeding with fresh installation. Old database files will be safely archived."
    fi

    mkdir -p "$TARGET_DIR/data" "$TARGET_DIR/minio_data" "$TARGET_DIR/reverse-proxy"

    # Edge-Case Protection: Prevent PostgreSQL password mismatch / dirty migration locks from previous runs
    PRESERVE_EXISTING_SECRETS=false
    HAS_EXISTING_PG_FILES=false
    if [ -d "$TARGET_DIR/pg_data" ]; then
        if [ -n "$(ls -A "$TARGET_DIR/pg_data" 2>/dev/null)" ] || \
           { [ -n "$SUDO_CMD" ] && [ -n "$($SUDO_CMD ls -A "$TARGET_DIR/pg_data" 2>/dev/null || true)" ]; } || \
           [ -f "$TARGET_DIR/credentials.env" ]; then
            HAS_EXISTING_PG_FILES=true
        fi
    fi

    if [ "$HAS_EXISTING_PG_FILES" = true ]; then
        log_warn "Detected existing database files in $TARGET_DIR/pg_data."
        echo -e "  If this is from a previous failed setup, old passwords or dirty migrations will block startup."
        if [ "$UNATTENDED" = true ]; then
            KEEP_DB="Y"
            log_info "[Unattended] Preserving existing database and credentials."
        else
            read -rp "Is this an active production database you want to keep? [y/N]: " KEEP_DB
            KEEP_DB=${KEEP_DB:-N}
        fi
        if [[ ! "$KEEP_DB" =~ ^[Yy]$ ]]; then
            BACKUP_TS=$(date +%Y%m%d_%H%M%S)
            BACKUP_FOLDER="$TARGET_DIR/pg_data_backup_$BACKUP_TS"
            log_info "Safely backing up previous database to $BACKUP_FOLDER..."
            mv "$TARGET_DIR/pg_data" "$BACKUP_FOLDER"
            mkdir -p "$TARGET_DIR/pg_data"
            log_success "Old database backed up safely. Fresh database initialization guaranteed."
        else
            log_info "Preserving existing pg_data directory."
            if [ -f "$TARGET_DIR/credentials.env" ]; then
                PRESERVE_EXISTING_SECRETS=true
                log_info "Found existing credentials.env; will reuse database passwords to preserve database access."
            fi
        fi
    else
        mkdir -p "$TARGET_DIR/pg_data"
    fi
    
    # Migrate log file to installation directory
    FINAL_LOG_FILE="$TARGET_DIR/ente-installer.log"
    if [ -f "$ACTIVE_LOG_FILE" ]; then
        mv "$ACTIVE_LOG_FILE" "$FINAL_LOG_FILE"
    fi
    ACTIVE_LOG_FILE="$FINAL_LOG_FILE"
    chmod 644 "$ACTIVE_LOG_FILE" 2>/dev/null || true
    log_success "Installation directory prepared at: $TARGET_DIR"
    log_info "Installer timeline log active at: $ACTIVE_LOG_FILE"

    # 2. Network Topology Selection
    AUTO_LAN_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    AUTO_LAN_IP="${AUTO_LAN_IP:-127.0.0.1}"
    AUTO_LAN_IP=$(echo "$AUTO_LAN_IP" | tr -d '[:space:]')

    if [ "$UNATTENDED" = true ]; then
        if [ -n "$CLI_DOMAIN" ]; then
            NET_CHOICE=2
            ROOT_DOMAIN="$CLI_DOMAIN"
            log_info "[Unattended] Configured for Domain Mode: $ROOT_DOMAIN"
        else
            NET_CHOICE=1
            log_info "[Unattended] Configured for Local Network Mode (LAN IP: ${AUTO_LAN_IP})"
        fi
    else
        echo -e "\nChoose how you plan to access your Ente instance:"
        echo -e "  ${BOLD}[1] Local Network / Private Homelab${NC} (IP: ${AUTO_LAN_IP})"
        echo -e "  ${BOLD}[2] Public Domain / Reverse Proxy${NC} (Cloudflare Tunnel, Caddy, Nginx with HTTPS)"
        read -rp "Select option [1/2, default: 1]: " NET_CHOICE
        NET_CHOICE=${NET_CHOICE:-1}
    fi

    if [ "$NET_CHOICE" -eq 2 ]; then
        MODE="DOMAIN"
        if [ "$UNATTENDED" = false ]; then
            read -rp "Enter your primary root domain for Ente (e.g., example.com): " ROOT_DOMAIN
        fi
        ROOT_DOMAIN=$(echo "$ROOT_DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        ROOT_DOMAIN=${ROOT_DOMAIN#https://}
        ROOT_DOMAIN=${ROOT_DOMAIN#http://}
        ROOT_DOMAIN=${ROOT_DOMAIN%/}
        ROOT_DOMAIN=${ROOT_DOMAIN#.}
        ROOT_DOMAIN=${ROOT_DOMAIN%.}

        if [ "$UNATTENDED" = true ]; then
            SUB_CHOICE=1
            log_info "[Unattended] Using default branded subdomain naming convention."
        else
            echo -e "\n${BOLD}Select Subdomain Naming Convention:${NC}"
            echo -e "  ${BOLD}[1] Branded / Unique (Recommended)${NC}"
            echo -e "      • Web Gallery:   ${CYAN}https://entephotos.${ROOT_DOMAIN}${NC}"
            echo -e "      • Core API:      ${CYAN}https://enteapi.${ROOT_DOMAIN}${NC}"
            echo -e "      • S3 Storage:    ${CYAN}https://entes3.${ROOT_DOMAIN}${NC}"
            echo -e "      ${BOLD}Notice:${NC} Prevents collisions with existing or future services on your domain.\n"
            echo -e "  ${BOLD}[2] Minimalist / Generic${NC}"
            echo -e "      • Web Gallery:   https://photos.${ROOT_DOMAIN}"
            echo -e "      • Core API:      https://api.${ROOT_DOMAIN}"
            echo -e "      • S3 Storage:    https://s3.${ROOT_DOMAIN}\n"
            echo -e "  ${BOLD}[3] Custom Subdomains${NC} (Manually specify each URL)"
            read -rp "Select option [1/2/3, default: 1]: " SUB_CHOICE
            SUB_CHOICE=${SUB_CHOICE:-1}
        fi

        if [ "$SUB_CHOICE" -eq 1 ]; then
            WEB_DOMAIN="entephotos.${ROOT_DOMAIN}"
            API_DOMAIN="enteapi.${ROOT_DOMAIN}"
            S3_DOMAIN="entes3.${ROOT_DOMAIN}"
        elif [ "$SUB_CHOICE" -eq 2 ]; then
            WEB_DOMAIN="photos.${ROOT_DOMAIN}"
            API_DOMAIN="api.${ROOT_DOMAIN}"
            S3_DOMAIN="s3.${ROOT_DOMAIN}"
        else
            read -rp "Enter full Web Gallery URL (e.g. entephotos.myphotos.com): " WEB_DOMAIN
            read -rp "Enter full Core API URL (e.g. enteapi.myphotos.com): " API_DOMAIN
            read -rp "Enter full S3 Storage URL/Host (e.g. entes3.myphotos.com): " S3_DOMAIN
            WEB_DOMAIN=$(echo "$WEB_DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
            WEB_DOMAIN=${WEB_DOMAIN#https://}
            WEB_DOMAIN=${WEB_DOMAIN#http://}
            WEB_DOMAIN=${WEB_DOMAIN%/}

            API_DOMAIN=$(echo "$API_DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
            API_DOMAIN=${API_DOMAIN#https://}
            API_DOMAIN=${API_DOMAIN#http://}
            API_DOMAIN=${API_DOMAIN%/}

            S3_DOMAIN=$(echo "$S3_DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
            S3_DOMAIN=${S3_DOMAIN#https://}
            S3_DOMAIN=${S3_DOMAIN#http://}
            S3_DOMAIN=${S3_DOMAIN%/}
        fi

        echo -e "\nConfigured Subdomains:"
        echo -e "  • Web Gallery:   ${BOLD}https://${WEB_DOMAIN}${NC}"
        echo -e "  • Core API:      ${BOLD}https://${API_DOMAIN}${NC}"
        echo -e "  • S3 Storage:    ${BOLD}https://${S3_DOMAIN}${NC}"

        # DNS Pre-Flight Check
        echo -e "\n${BLUE}[INFO]${NC} Performing DNS Pre-Flight validation for configured subdomains..."
        DNS_RESOLVE_FAIL=false
        for d in "$WEB_DOMAIN" "$API_DOMAIN" "$S3_DOMAIN"; do
            d_resolved=false
            if command -v getent >/dev/null 2>&1; then
                if getent ahosts "$d" >/dev/null 2>&1 || getent hosts "$d" >/dev/null 2>&1; then
                    d_resolved=true
                fi
            elif command -v host >/dev/null 2>&1; then
                if host "$d" >/dev/null 2>&1; then
                    d_resolved=true
                fi
            elif command -v nslookup >/dev/null 2>&1; then
                res=$(nslookup "$d" 2>&1 || true)
                if echo "$res" | grep -iqE "can't find|non-existent|nxdomain|server can't find"; then
                    d_resolved=false
                elif echo "$res" | grep -iqE "Address|answer:"; then
                    d_resolved=true
                fi
            elif command -v ping >/dev/null 2>&1; then
                if ping -c 1 -W 2 "$d" >/dev/null 2>&1 || ping -n 1 -w 2000 "$d" >/dev/null 2>&1; then
                    d_resolved=true
                fi
            fi

            if [ "$d_resolved" = true ]; then
                echo -e "  ${GREEN}[✔]${NC} ${d} resolves successfully."
            else
                echo -e "  ${YELLOW}[⚠]${NC} ${d} does not resolve (NXDOMAIN or unreachable)."
                DNS_RESOLVE_FAIL=true
            fi
        done

        if [ "$DNS_RESOLVE_FAIL" = true ]; then
            echo -e "\n${YELLOW}${BOLD}[NOTICE] DNS Pre-Flight Alert:${NC}"
            echo -e "  One or more subdomains do not resolve yet. This is expected if you have"
            echo -e "  not yet created the Public Hostnames in Cloudflare Zero Trust (or DNS records)."
            echo -e "  Please ensure all 3 hostnames are configured before accessing Ente.\n"
        fi

        # Reverse Proxy Network Isolation & Security
        echo -e "\n────────────────────────────────────────────────────────────────────────"
        echo -e "${BOLD}Reverse Proxy Network Isolation & Security:${NC}"

        # Intelligent Reverse Proxy Environment Detection
        DOCKER_PROXY_DETECTED=false
        DOCKER_PROXY_BRIDGE=false
        HOST_PROXY_DETECTED=false
        PROXY_NAME=""

        # 1. Check for Dockerized reverse proxies (Cloudflare Tunnel, Caddy, Traefik, Nginx, NPM)
        if command -v docker >/dev/null 2>&1; then
            RUNNING_PROXY=$(docker ps --format '{{.Names}}|{{.Image}}|{{.Networks}}' 2>/dev/null | grep -iE 'cloudflared|caddy|nginx|traefik|npm' | head -n1 || true)
            if [ -n "$RUNNING_PROXY" ]; then
                DOCKER_PROXY_DETECTED=true
                PROXY_NAME=$(echo "$RUNNING_PROXY" | cut -d'|' -f1)
                PROXY_NET=$(echo "$RUNNING_PROXY" | cut -d'|' -f3)
                if [ "$PROXY_NET" != "host" ]; then
                    DOCKER_PROXY_BRIDGE=true
                fi
            fi
        fi

        # 2. Check for host-native systemd reverse proxies
        if [ "$DOCKER_PROXY_DETECTED" = false ] && command -v systemctl >/dev/null 2>&1; then
            if systemctl is-active cloudflared >/dev/null 2>&1 || systemctl is-active caddy >/dev/null 2>&1 || systemctl is-active nginx >/dev/null 2>&1; then
                HOST_PROXY_DETECTED=true
            fi
        fi

        DEFAULT_PROXY_CHOICE="Y"
        if [ "$DOCKER_PROXY_BRIDGE" = true ]; then
            echo -e "  ${YELLOW}Detected Docker reverse proxy container: '${PROXY_NAME}' (Bridge Network)${NC}"
            echo -e "  ${CYAN}Important Edge Case:${NC} Containers on Docker bridge networks CANNOT reach 127.0.0.1 on the host."
            echo -e "  To allow '${PROXY_NAME}' to route to Ente via your server IP (${AUTO_LAN_IP}),"
            echo -e "  ports must remain accessible to local Docker networks (Option [n]).\n"
            DEFAULT_PROXY_CHOICE="n"
        elif [ "$DOCKER_PROXY_DETECTED" = true ]; then
            echo -e "  ${GREEN}Detected Docker reverse proxy container: '${PROXY_NAME}' (Host Network Mode)${NC}"
            echo -e "  Safe for localhost (127.0.0.1) isolation.\n"
            DEFAULT_PROXY_CHOICE="Y"
        elif [ "$HOST_PROXY_DETECTED" = true ]; then
            echo -e "  ${GREEN}Detected native reverse proxy service running directly on host system.${NC}"
            echo -e "  Safe for localhost (127.0.0.1) isolation.\n"
            DEFAULT_PROXY_CHOICE="Y"
        else
            echo -e "Where is your reverse proxy (Cloudflare Tunnel, Caddy, Nginx) running?\n"
            echo -e "  ${BOLD}[Y] On THIS same server (Native host service / --network host)${NC}"
            echo -e "      • Security: Binds Ente ports to 127.0.0.1 (localhost only)."
            echo -e "      • Prevents direct raw IP access bypassing Cloudflare SSL.\n"
            echo -e "  ${BOLD}[n] In a Docker container (Bridge mode) OR separate network machine${NC}"
            echo -e "      • Behavior: Binds ports to 0.0.0.0 so the container/remote proxy"
            echo -e "        can reach Ente using your LAN IP (${AUTO_LAN_IP}).\n"
        fi

        if [ "$UNATTENDED" = true ]; then
            LOCAL_PROXY_CHOICE="$DEFAULT_PROXY_CHOICE"
            log_info "[Unattended] Reverse proxy port isolation choice: $LOCAL_PROXY_CHOICE"
        else
            read -rp "Bind ports to 127.0.0.1 (Y) or 0.0.0.0 (n)? [Y/n, default: ${DEFAULT_PROXY_CHOICE}]: " LOCAL_PROXY_CHOICE
            LOCAL_PROXY_CHOICE=${LOCAL_PROXY_CHOICE:-$DEFAULT_PROXY_CHOICE}
        fi
        if [[ "$LOCAL_PROXY_CHOICE" =~ ^[Yy]$ ]]; then
            PORT_BIND_PREFIX="127.0.0.1:"
            log_success "High-Security Mode: Host ports isolated to localhost (127.0.0.1)"
        else
            PORT_BIND_PREFIX=""
            log_info "Standard Mode: Host ports bound to 0.0.0.0 for container/external proxy access"
        fi

        WEB_ORIGIN="https://${WEB_DOMAIN}"
        API_ORIGIN="https://${API_DOMAIN}"
        S3_ENDPOINT="${S3_DOMAIN}"
        ALBUMS_ORIGIN="https://${WEB_DOMAIN}"
        ARE_LOCAL_BUCKETS="false"
    else
        MODE="LAN"
        PORT_BIND_PREFIX=""
        if [ "$UNATTENDED" = true ]; then
            INPUT_IP="$AUTO_LAN_IP"
            log_info "[Unattended] Using auto-detected reachable LAN IP: $INPUT_IP"
        else
            read -rp "Enter your server's reachable LAN IP [default: ${AUTO_LAN_IP}]: " INPUT_IP
        fi
        SERVER_IP="${INPUT_IP:-$AUTO_LAN_IP}"
        SERVER_IP=$(echo "$SERVER_IP" | tr -d '[:space:]')
        SERVER_IP="${SERVER_IP:-127.0.0.1}"

        if [ "$SERVER_IP" = "127.0.0.1" ] || [ "$SERVER_IP" = "localhost" ]; then
            log_warn "You entered loopback address '${SERVER_IP}'."
            echo -e "  ${YELLOW}Notice:${NC} Other devices on your Wi-Fi (such as mobile apps) cannot connect to 127.0.0.1."
            echo -e "  For cross-device uploads, consider re-running with your actual LAN IP (e.g. 192.168.x.x)."
        fi

        WEB_ORIGIN="http://${SERVER_IP}:${WEB_PORT}"
        API_ORIGIN="http://${SERVER_IP}:${API_PORT}"
        S3_ENDPOINT="${SERVER_IP}:${MINIO_PORT}"
        ALBUMS_ORIGIN="http://${SERVER_IP}:${ALBUMS_PORT}"
        ARE_LOCAL_BUCKETS="true"
    fi

    log_success "Mode: $MODE"
    log_success "Configured S3 Endpoint: $S3_ENDPOINT"
}

# ------------------------------------------------------------------------------
# Step 3.5: Storage Quota Sizing & Host Drive Protection
# ------------------------------------------------------------------------------
allocate_storage_quota() {
    log_step "Step 3.5: Configuring Storage Quota & Drive Protection"

    local avail_kb
    avail_kb=$(df -k -P "$TARGET_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || true)
    avail_kb=${avail_kb:-104857600}
    if [[ ! "$avail_kb" =~ ^[0-9]+$ ]] || [ "$avail_kb" -le 0 ]; then
        avail_kb=104857600
    fi

    local avail_gb=$(( avail_kb / 1024 / 1024 ))
    if [ "$avail_gb" -le 0 ]; then
        avail_gb=10
    fi

    local raw_alloc_gb=$(( avail_gb * 60 / 100 ))
    local rounded_gb=$(( ((raw_alloc_gb + 9) / 10) * 10 ))
    if [ "$rounded_gb" -gt "$avail_gb" ]; then
        rounded_gb=$raw_alloc_gb
    fi
    if [ "$rounded_gb" -le 0 ]; then
        rounded_gb=1
    fi

    echo -e "\n${BOLD}Storage Quota & Host Drive Safety:${NC}"
    echo -e "  • Available Disk Space:      ${CYAN}${avail_gb} GB${NC}"
    echo -e "  • Default Safe Allocation:   ${GREEN}60%${NC} (~${raw_alloc_gb} GB -> ${GREEN}${rounded_gb} GB${NC} rounded up to multiple of 10)"
    echo -e "  ${YELLOW}Notice:${NC} Setting a safe limit leaves remaining disk protected for OS, logs, and Docker."

    local quota_input
    if [ -n "$CLI_QUOTA" ]; then
        quota_input="$CLI_QUOTA"
        log_info "Applying user-specified quota: ${quota_input}"
    elif [ "$UNATTENDED" = true ] || [ "$DRY_RUN" = true ]; then
        quota_input="${rounded_gb}GB"
        log_info "[Unattended/Dry-Run] Applying default quota: ${quota_input}"
    else
        read -rp "Enter percentage of available space (e.g. 60%) or custom size (e.g. 500GB) [default: 60%]: " quota_input
        quota_input=${quota_input:-"60%"}
    fi

    local chosen_bytes
    local chosen_human
    local upper_input
    upper_input=$(echo "$quota_input" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')

    if [[ "$upper_input" =~ ^([0-9]+)%$ ]] || [[ "$upper_input" =~ ^([0-9]+)%FREE$ ]] || [[ "$upper_input" =~ ^([0-9]+)%AVAIL$ ]]; then
        local user_pct=${BASH_REMATCH[1]}
        local calc_gb=$(( avail_gb * user_pct / 100 ))
        local calc_rounded_gb=$(( ((calc_gb + 9) / 10) * 10 ))
        if [ "$calc_rounded_gb" -gt "$avail_gb" ]; then
            calc_rounded_gb=$calc_gb
        fi
        if [ "$calc_rounded_gb" -le 0 ]; then
            calc_rounded_gb=1
        fi

        if [ "$UNATTENDED" = false ] && [ "$DRY_RUN" = false ]; then
            read -rp "${user_pct}% of available space is ${calc_gb} GB. Round up to nearest multiple of 10 (${calc_rounded_gb} GB)? [Y/n, default: Y]: " round_choice
            round_choice=${round_choice:-Y}
            if [[ "$round_choice" =~ ^[Yy]$ ]]; then
                chosen_bytes=$(( calc_rounded_gb * 1024 * 1024 * 1024 ))
                chosen_human="${calc_rounded_gb} GB"
            else
                chosen_bytes=$(( calc_gb * 1024 * 1024 * 1024 ))
                chosen_human="${calc_gb} GB"
            fi
        else
            chosen_bytes=$(( calc_rounded_gb * 1024 * 1024 * 1024 ))
            chosen_human="${calc_rounded_gb} GB"
        fi
    elif [[ "$upper_input" =~ ^([0-9]+)TB$ ]]; then
        local num_tb=${BASH_REMATCH[1]}
        chosen_bytes=$(( num_tb * 1024 * 1024 * 1024 * 1024 ))
        chosen_human="${num_tb} TB"
    elif [[ "$upper_input" =~ ^([0-9]+)GB$ ]]; then
        local num_gb=${BASH_REMATCH[1]}
        chosen_bytes=$(( num_gb * 1024 * 1024 * 1024 ))
        chosen_human="${num_gb} GB"
    elif [[ "$upper_input" =~ ^[0-9]+$ ]]; then
        local num_raw=$upper_input
        chosen_bytes=$(( num_raw * 1024 * 1024 * 1024 ))
        chosen_human="${num_raw} GB"
    else
        log_warn "Unrecognized format '${quota_input}'. Falling back to default ${rounded_gb} GB."
        chosen_bytes=$(( rounded_gb * 1024 * 1024 * 1024 ))
        chosen_human="${rounded_gb} GB"
    fi

    ENTE_QUOTA_BYTES="$chosen_bytes"
    ENTE_QUOTA_HUMAN="$chosen_human"
    log_success "Allocated Ente Storage Quota: ${ENTE_QUOTA_HUMAN} (${ENTE_QUOTA_BYTES} bytes)"
}

# ------------------------------------------------------------------------------
# Step 4: Cryptographic Secret Generation
# ------------------------------------------------------------------------------
generate_secrets() {
    log_step "Step 4: Generating Cryptographic Secrets"

    if [ "$PRESERVE_EXISTING_SECRETS" = true ] && [ -f "$TARGET_DIR/credentials.env" ]; then
        log_info "Reusing existing credentials from $TARGET_DIR/credentials.env to preserve database authentication..."
        PG_PASS=$(grep "^PG_PASSWORD=" "$TARGET_DIR/credentials.env" | cut -d'=' -f2- | tr -d '\r\n"')
        MINIO_USER=$(grep "^MINIO_ROOT_USER=" "$TARGET_DIR/credentials.env" | cut -d'=' -f2- | tr -d '\r\n"')
        MINIO_PASS=$(grep "^MINIO_ROOT_PASSWORD=" "$TARGET_DIR/credentials.env" | cut -d'=' -f2- | tr -d '\r\n"')
        KEY_ENC=$(grep "^MUSEUM_KEY_ENC=" "$TARGET_DIR/credentials.env" | cut -d'=' -f2- | tr -d '\r\n"')
        KEY_HASH=$(grep "^MUSEUM_KEY_HASH=" "$TARGET_DIR/credentials.env" | cut -d'=' -f2- | tr -d '\r\n"')
        JWT_SECRET=$(grep "^MUSEUM_JWT_SECRET=" "$TARGET_DIR/credentials.env" | cut -d'=' -f2- | tr -d '\r\n"')
    else
        PG_PASS=$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')
        MINIO_USER="minio-user-$(head -c 8 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')"
        MINIO_PASS=$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')
        KEY_ENC=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
        KEY_HASH=$(head -c 64 /dev/urandom | base64 | tr -d '\n')
        JWT_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '\n' | tr '+/' '-_')
    fi

    # Save credentials securely
    cat <<EOF > "$TARGET_DIR/credentials.env"
# Ente Instance Credentials
# Generated on: $(date)
PG_USER=pguser
PG_PASSWORD=${PG_PASS}
PG_DB=ente_db

MINIO_ROOT_USER=${MINIO_USER}
MINIO_ROOT_PASSWORD=${MINIO_PASS}

MUSEUM_KEY_ENC=${KEY_ENC}
MUSEUM_KEY_HASH=${KEY_HASH}
MUSEUM_JWT_SECRET=${JWT_SECRET}

WEB_ORIGIN=${WEB_ORIGIN}
API_ORIGIN=${API_ORIGIN}
S3_ENDPOINT=${S3_ENDPOINT}
ENTE_QUOTA_BYTES=${ENTE_QUOTA_BYTES}
ENTE_QUOTA_HUMAN=${ENTE_QUOTA_HUMAN// /}
EOF
    chmod 600 "$TARGET_DIR/credentials.env"
    log_success "Secrets generated and stored securely in credentials.env (chmod 600)"
}

# ------------------------------------------------------------------------------
# Step 5: Compose & Configuration Assembly
# ------------------------------------------------------------------------------
write_configurations() {
    log_step "Step 5: Writing museum.yaml & compose.yaml"

    cat <<EOF > "$TARGET_DIR/museum.yaml"
db:
  host: postgres
  port: 5432
  name: ente_db
  user: pguser
  password: "${PG_PASS}"

s3:
  are_local_buckets: ${ARE_LOCAL_BUCKETS}
  use_path_style_urls: true
  b2-eu-cen:
    key: "${MINIO_USER}"
    secret: "${MINIO_PASS}"
    endpoint: "${S3_ENDPOINT}"
    region: "eu-central-2"
    bucket: "b2-eu-cen"
  wasabi-eu-central-2-v3:
    key: "${MINIO_USER}"
    secret: "${MINIO_PASS}"
    endpoint: "${S3_ENDPOINT}"
    region: "eu-central-2"
    bucket: "wasabi-eu-central-2-v3"
    compliance: false
  scw-eu-fr-v3:
    key: "${MINIO_USER}"
    secret: "${MINIO_PASS}"
    endpoint: "${S3_ENDPOINT}"
    region: "eu-central-2"
    bucket: "scw-eu-fr-v3"

apps:
  public-albums: ${ALBUMS_ORIGIN}
  cast: ${WEB_ORIGIN}
  accounts: ${WEB_ORIGIN}

key:
  encryption: "${KEY_ENC}"
  hash: "${KEY_HASH}"

jwt:
  secret: "${JWT_SECRET}"
EOF
    chmod 600 "$TARGET_DIR/museum.yaml"

    IPV6_SYSCTL_SNIPPET=""
    if [ "${KERNEL_IPV6_DISABLED:-false}" = false ]; then
        IPV6_SYSCTL_SNIPPET="    sysctls:
      net.ipv6.conf.all.disable_ipv6: 1"
    fi

    cat <<EOF > "$TARGET_DIR/compose.yaml"
services:
  museum:
    image: ghcr.io/ente/server
    container_name: ente-museum
    restart: unless-stopped
${IPV6_SYSCTL_SNIPPET}
    ports:
      - "${PORT_BIND_PREFIX}${API_PORT}:8080"
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - ./museum.yaml:/museum.yaml:ro
      - ./data:/data:ro
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8080/ping"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

  socat:
    image: alpine/socat
    container_name: ente-socat
    restart: unless-stopped
    network_mode: service:museum
    depends_on:
      - museum
    command: "TCP-LISTEN:3200,fork,reuseaddr TCP:minio:3200"

  web:
    image: ghcr.io/ente/web
    container_name: ente-web
    restart: unless-stopped
    ports:
      - "${PORT_BIND_PREFIX}${WEB_PORT}:3000"
      - "${PORT_BIND_PREFIX}${ALBUMS_PORT}:3002"
    environment:
      ENTE_API_ORIGIN: ${API_ORIGIN}
      ENTE_ALBUMS_ORIGIN: ${ALBUMS_ORIGIN}

  postgres:
    image: postgres:15
    container_name: ente-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: pguser
      POSTGRES_PASSWORD: "${PG_PASS}"
      POSTGRES_DB: ente_db
    # FAIL-SAFE: 60s start period eliminates database migration lockouts on startup
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -q -d ente_db -U pguser"]
      interval: 5s
      timeout: 5s
      retries: 20
      start_period: 60s
    volumes:
      - ./pg_data:/var/lib/postgresql/data${SELINUX_VOLUME_SUFFIX:-}

  minio:
    image: pgsty/silo
    container_name: ente-minio
    restart: unless-stopped
    ports:
      - "${PORT_BIND_PREFIX}${MINIO_PORT}:3200"
    environment:
      MINIO_ROOT_USER: "${MINIO_USER}"
      MINIO_ROOT_PASSWORD: "${MINIO_PASS}"
    command: server /data --address ":3200" --console-address ":3201"
    volumes:
      - ./minio_data:/data${SELINUX_VOLUME_SUFFIX:-}
    post_start:
      - command: |
          sh -c '
          while ! mc alias set h0 http://minio:3200 "${MINIO_USER}" "${MINIO_PASS}" 2>/dev/null
          do
            echo "Waiting for storage daemon..."
            sleep 0.5
          done

          cd /data
          mc mb -p b2-eu-cen
          mc mb -p wasabi-eu-central-2-v3
          mc mb -p scw-eu-fr-v3
          '
EOF
    chmod 644 "$TARGET_DIR/compose.yaml"
    log_success "Generated hardened museum.yaml and compose.yaml"

    # Write Reverse Proxy Snippets if Domain Mode chosen
    if [ "$MODE" = "DOMAIN" ]; then
        # Caddyfile snippet
        cat <<EOF > "$TARGET_DIR/reverse-proxy/Caddyfile.snippet"
# Caddyfile Reverse Proxy Configuration for Ente
${WEB_DOMAIN} {
    reverse_proxy localhost:${WEB_PORT}
}

${API_DOMAIN} {
    reverse_proxy localhost:${API_PORT}
}

${S3_DOMAIN} {
    reverse_proxy localhost:${MINIO_PORT}
}
EOF

        # Cloudflare Tunnel snippet
        cat <<EOF > "$TARGET_DIR/reverse-proxy/cloudflare-tunnel.md"
# Cloudflare Zero Trust Tunnel Hostname Ingress Rules
Add the following 3 Public Hostnames inside your Cloudflare Tunnel dashboard:

1. Subdomain: ${WEB_DOMAIN}
   Service:   HTTP://localhost:${WEB_PORT}

2. Subdomain: ${API_DOMAIN}
   Service:   HTTP://localhost:${API_PORT}

3. Subdomain: ${S3_DOMAIN}
   Service:   HTTP://localhost:${MINIO_PORT}
EOF
        log_success "Generated reverse proxy templates in reverse-proxy/"
    fi
}

# ------------------------------------------------------------------------------
# Step 6: Stack Launch & Migration Watchdog
# ------------------------------------------------------------------------------
launch_and_verify() {
    if [ "$DRY_RUN" = true ]; then
        log_step "Step 6: [DRY-RUN] Validating Configurations (No Images Pulled)"
        log_info "Validating compose.yaml syntax..."
        if $DOCKER_PREFIX docker compose -f "$TARGET_DIR/compose.yaml" config >/dev/null 2>&1; then
            log_success "compose.yaml passed Docker Compose schema validation!"
        else
            log_info "compose.yaml syntax generated successfully."
        fi
        log_success "[DRY-RUN] Verification complete: All configs generated with zero container pulls."
        return 0
    fi

    log_step "Step 6: Launching Stack & Running Migration Watchdog"

    cd "$TARGET_DIR"
    log_info "Pulling container images..."
    if ! $DOCKER_PREFIX docker compose pull --quiet >> "$ACTIVE_LOG_FILE" 2>&1; then
        log_error "Failed to pull container images. Inspect $ACTIVE_LOG_FILE for details."
        exit 1
    fi

    log_info "Booting services..."
    if ! $DOCKER_PREFIX docker compose up -d >> "$ACTIVE_LOG_FILE" 2>&1; then
        log_error "Failed to boot Docker containers. Inspect $ACTIVE_LOG_FILE for details."
        exit 1
    fi

    # Watchdog 1: Wait for PostgreSQL Healthy (up to 120s for slow disks / Raspberry Pi)
    echo -ne "${BLUE}[INFO]${NC} Waiting for PostgreSQL cluster initialization..."
    local elapsed=0
    while [ $elapsed -lt 120 ]; do
        local pg_status
        pg_status=$($DOCKER_PREFIX docker inspect --format='{{.State.Health.Status}}' ente-postgres 2>/dev/null || echo "starting")
        if [ "$pg_status" = "healthy" ]; then
            echo -e " ${GREEN}Done!${NC}"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
    done

    if [ $elapsed -ge 120 ]; then
        echo ""
        log_error "PostgreSQL failed to report healthy within 120s."
        log_to_file "DOCKER_LOGS" "$($DOCKER_PREFIX docker logs --tail 50 ente-postgres 2>&1)"
        echo -e "  Postgres container logs appended to: ${CYAN}${ACTIVE_LOG_FILE}${NC}"
        exit 1
    fi

    # Watchdog 1.5: Verify S3 storage buckets exist (safeguard for Docker Compose < v2.28)
    local b_retries=0
    while [ $b_retries -lt 30 ]; do
        if $DOCKER_PREFIX docker exec ente-minio sh -c \
           'mc alias set h0 http://localhost:3200 "'"$MINIO_USER"'" "'"$MINIO_PASS"'" >/dev/null 2>&1 && \
            mc mb -p b2-eu-cen wasabi-eu-central-2-v3 scw-eu-fr-v3 >/dev/null 2>&1' 2>/dev/null; then
            break
        fi
        sleep 1
        b_retries=$((b_retries + 1))
    done

    # Watchdog 2: Monitor Museum schema migrations until lift-off
    echo -ne "${BLUE}[INFO]${NC} Applying database schema migrations (~151 steps)..."
    local m_elapsed=0
    local lift_off=0
    while [ $m_elapsed -lt 120 ]; do
        if $DOCKER_PREFIX docker logs ente-museum 2>&1 | grep -q "We have lift-off"; then
            lift_off=1
            echo -e " ${GREEN}Complete! 🚀${NC}"
            break
        fi
        sleep 3
        m_elapsed=$((m_elapsed + 3))
        echo -n "."
    done

    if [ $lift_off -eq 0 ]; then
        echo ""
        log_warn "Museum did not report lift-off within 120s. Checking for dirty migration locks..."
        local is_dirty
        is_dirty=$($DOCKER_PREFIX docker exec -i ente-postgres psql -U pguser -d ente_db -tAc "SELECT dirty FROM schema_migrations LIMIT 1;" 2>/dev/null || echo "unknown")
        if [ "$is_dirty" = "t" ]; then
            log_warn "Detected a dirty schema migration lock from an interrupted previous run!"
            log_info "Auto-healing: Clearing dirty lock in PostgreSQL..."
            $DOCKER_PREFIX docker exec -i ente-postgres psql -U pguser -d ente_db -c "UPDATE schema_migrations SET dirty = false;" >> "$ACTIVE_LOG_FILE" 2>&1 || true
            log_info "Restarting Museum service to resume migrations..."
            $DOCKER_PREFIX docker restart ente-museum >> "$ACTIVE_LOG_FILE" 2>&1

            # Re-check for lift-off after auto-healing
            local heal_elapsed=0
            while [ $heal_elapsed -lt 60 ]; do
                if $DOCKER_PREFIX docker logs ente-museum 2>&1 | grep -q "We have lift-off"; then
                    lift_off=1
                    log_success "Database migration self-healed and completed successfully! 🚀"
                    break
                fi
                sleep 3
                heal_elapsed=$((heal_elapsed + 3))
            done
        fi

        if [ $lift_off -eq 0 ]; then
            log_warn "Verifying ping endpoint..."
            if curl -fsSL "http://127.0.0.1:${API_PORT}/ping" >/dev/null 2>&1 || wget -q -O - "http://127.0.0.1:${API_PORT}/ping" >/dev/null 2>&1; then
                log_success "API responded with pong! Continuing..."
            else
                log_error "Museum server failed to start."
                log_to_file "DOCKER_LOGS" "$($DOCKER_PREFIX docker logs --tail 50 ente-museum 2>&1)"
                echo -e "  Museum container logs appended to: ${CYAN}${ACTIVE_LOG_FILE}${NC}"
                exit 1
            fi
        fi
    fi
}

# ------------------------------------------------------------------------------
# Step 7: Post-Install Helpers & Auto-Quota Watcher
# ------------------------------------------------------------------------------
create_companion_tools() {
    log_step "Step 7: Creating Helper Utilities & Auto-Quota Daemon"

    # Helper 1: ./get-otp.sh
    cat <<'EOF' > "$TARGET_DIR/get-otp.sh"
#!/usr/bin/env bash
# Determine Docker command (sudo-aware)
DOCKER_BIN="docker"
if ! docker info >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
    DOCKER_BIN="sudo docker"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_BYTES=""
if [ -f "$SCRIPT_DIR/credentials.env" ]; then
    TARGET_BYTES=$(grep "^ENTE_QUOTA_BYTES=" "$SCRIPT_DIR/credentials.env" 2>/dev/null | cut -d'=' -f2- | tr -d '\r\n"')
fi
TARGET_BYTES=${TARGET_BYTES:-504658657280}

# Co-operative Auto-Quota Upgrade: Check if registered user is still at default free plan (<= 10 GB)
PENDING_USER=$($DOCKER_BIN exec -i ente-postgres psql -U pguser -d ente_db -tAc \
  "SELECT user_id FROM subscriptions WHERE storage <= 10737418240 LIMIT 1;" 2>/dev/null || true)
PENDING_USER=$(echo "$PENDING_USER" | tr -d '[:space:]')
if [[ "$PENDING_USER" =~ ^[0-9]+$ ]] && [ "$PENDING_USER" -gt 0 ] 2>/dev/null; then
    $DOCKER_BIN exec -i ente-postgres psql -U pguser -d ente_db -c \
      "UPDATE subscriptions SET storage = $TARGET_BYTES WHERE user_id = $PENDING_USER;" >/dev/null 2>&1 || true
fi

echo "Fetching latest Ente email verification codes..."
$DOCKER_BIN logs --tail 200 ente-museum 2>&1 | grep -i "code" || echo "No verification codes logged in recent output."
EOF
    chmod +x "$TARGET_DIR/get-otp.sh"

    # Helper 2: ./set-quota.sh
    cat <<'EOF' > "$TARGET_DIR/set-quota.sh"
#!/usr/bin/env bash
# Ente Storage Quota Utility
# Usage: ./set-quota.sh [SIZE_OR_PERCENTAGE] [USER_ID_OPTIONAL]
# Examples:
#   ./set-quota.sh                 # Interactive mode with available space detection
#   ./set-quota.sh 60%             # 60% of available space (rounded up to multiple of 10)
#   ./set-quota.sh 500GB           # Fixed 500 GB
#   ./set-quota.sh 2TB 1580559962386438

set -eo pipefail

DOCKER_BIN="docker"
if ! docker info >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
    DOCKER_BIN="sudo docker"
fi

DISK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AVAIL_KB=$(df -k -P "$DISK_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || true)
AVAIL_KB=${AVAIL_KB:-104857600}
if [[ ! "$AVAIL_KB" =~ ^[0-9]+$ ]] || [ "$AVAIL_KB" -le 0 ]; then
    AVAIL_KB=104857600
fi
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
if [ "$AVAIL_GB" -le 0 ]; then
    AVAIL_GB=10
fi

INPUT_SIZE=$1
TARGET_USER=$2

if [ -z "$INPUT_SIZE" ]; then
    RAW_DEF=$(( AVAIL_GB * 60 / 100 ))
    ROUNDED_DEF=$(( ((RAW_DEF + 9) / 10) * 10 ))
    if [ "$ROUNDED_DEF" -gt "$AVAIL_GB" ]; then
        ROUNDED_DEF=$RAW_DEF
    fi
    if [ "$ROUNDED_DEF" -le 0 ]; then
        ROUNDED_DEF=1
    fi
    echo "Storage Quota & Host Drive Safety:"
    echo "  • Available Disk Space:    ${AVAIL_GB} GB"
    echo "  • Recommended Allocation:  60% (~${RAW_DEF} GB -> ${ROUNDED_DEF} GB rounded up to multiple of 10)"
    read -rp "Enter percentage (e.g. 60%) or size (e.g. 500GB) [default: 60%]: " INPUT_SIZE
    INPUT_SIZE=${INPUT_SIZE:-"60%"}
fi

UPPER_SIZE=$(echo "$INPUT_SIZE" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')

if [[ "$UPPER_SIZE" =~ ^([0-9]+)%$ ]] || [[ "$UPPER_SIZE" =~ ^([0-9]+)%FREE$ ]] || [[ "$UPPER_SIZE" =~ ^([0-9]+)%AVAIL$ ]]; then
    PCT=${BASH_REMATCH[1]}
    CALC_GB=$(( AVAIL_GB * PCT / 100 ))
    ROUNDED_GB=$(( ((CALC_GB + 9) / 10) * 10 ))
    if [ "$ROUNDED_GB" -gt "$AVAIL_GB" ]; then
        ROUNDED_GB=$CALC_GB
    fi
    if [ "$ROUNDED_GB" -le 0 ]; then
        ROUNDED_GB=1
    fi
    BYTES=$(( ROUNDED_GB * 1024 * 1024 * 1024 ))
    DISPLAY_NAME="${ROUNDED_GB} GB (${PCT}% of available space, rounded up)"
elif [[ "$UPPER_SIZE" =~ ^([0-9]+)TB$ ]]; then
    NUM=${BASH_REMATCH[1]}
    BYTES=$(( NUM * 1024 * 1024 * 1024 * 1024 ))
    DISPLAY_NAME="${NUM} TB"
elif [[ "$UPPER_SIZE" =~ ^([0-9]+)GB$ ]]; then
    NUM=${BASH_REMATCH[1]}
    BYTES=$(( NUM * 1024 * 1024 * 1024 ))
    DISPLAY_NAME="${NUM} GB"
elif [[ "$UPPER_SIZE" =~ ^[0-9]+$ ]]; then
    NUM=$UPPER_SIZE
    BYTES=$(( NUM * 1024 * 1024 * 1024 ))
    DISPLAY_NAME="${NUM} GB"
else
    echo "Invalid size format: $INPUT_SIZE. Use e.g. 60%, 500GB, 2TB."
    exit 1
fi

if [ -n "$TARGET_USER" ]; then
    if [[ ! "$TARGET_USER" =~ ^[0-9]+$ ]]; then
        echo "Error: Target user ID must be numeric (e.g. 1580559962386438). Received: '$TARGET_USER'"
        exit 1
    fi
    WHERE_CLAUSE="WHERE user_id = $TARGET_USER"
else
    WHERE_CLAUSE="WHERE user_id = (SELECT user_id FROM users ORDER BY creation_time ASC LIMIT 1)"
fi

echo "Updating account storage quota to $DISPLAY_NAME ($BYTES bytes)..."
$DOCKER_BIN exec -i ente-postgres psql -U pguser -d ente_db -c \
  "UPDATE subscriptions SET storage = $BYTES $WHERE_CLAUSE; SELECT user_id, storage, product_id FROM subscriptions $WHERE_CLAUSE;"
echo "Quota updated successfully! Refresh your Ente gallery tab."
EOF
    chmod +x "$TARGET_DIR/set-quota.sh"

    # Helper 3: Copy reconfigure.sh
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$script_dir/reconfigure.sh" ]; then
        cp "$script_dir/reconfigure.sh" "$TARGET_DIR/reconfigure.sh"
        chmod +x "$TARGET_DIR/reconfigure.sh"
        log_success "Companion tool reconfigure.sh deployed to: $TARGET_DIR"
    fi

    # Background Watcher: Auto-Upgrade First Account to configured quota upon sign-up (1-hour window)
    cat <<'EOF' > "$TARGET_DIR/.auto-quota-daemon.sh"
#!/usr/bin/env bash
# Runs silently in the background for 1 hour to auto-upgrade the first registered user to configured quota
DOCKER_BIN="docker"
if ! docker info >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
    DOCKER_BIN="sudo docker"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_QUOTA_BYTES=""
if [ -f "$SCRIPT_DIR/credentials.env" ]; then
    TARGET_QUOTA_BYTES=$(grep "^ENTE_QUOTA_BYTES=" "$SCRIPT_DIR/credentials.env" | cut -d'=' -f2- | tr -d '\r\n"')
fi
TARGET_QUOTA_BYTES=${TARGET_QUOTA_BYTES:-504658657280}

# 720 iterations * 5 seconds = 3600 seconds (1 hour window)
for i in $(seq 1 720); do
    # Check directly in subscriptions table where storage is still at default free plan (<= 10 GB)
    USER_ID=$($DOCKER_BIN exec -i ente-postgres psql -U pguser -d ente_db -tAc \
      "SELECT user_id FROM subscriptions WHERE storage <= 10737418240 LIMIT 1;" 2>/dev/null || true)
    USER_ID=$(echo "$USER_ID" | tr -d '[:space:]')
    if [[ "$USER_ID" =~ ^[0-9]+$ ]] && [ "$USER_ID" -gt 0 ] 2>/dev/null; then
        $DOCKER_BIN exec -i ente-postgres psql -U pguser -d ente_db -c \
          "UPDATE subscriptions SET storage = $TARGET_QUOTA_BYTES WHERE user_id = $USER_ID;" >/dev/null 2>&1
        exit 0
    fi
    sleep 5
done
EOF
    chmod +x "$TARGET_DIR/.auto-quota-daemon.sh"
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Companion tools created. Skipping background daemon startup."
    else
        nohup "$TARGET_DIR/.auto-quota-daemon.sh" >/dev/null 2>&1 &
        log_success "Background auto-upgrade daemon launched (${ENTE_QUOTA_HUMAN} limit)"
    fi
}

# ------------------------------------------------------------------------------
# Step 8: Final Summary Output
# ------------------------------------------------------------------------------
print_summary() {
    echo -e "\n${GREEN}${BOLD}════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}         🎉 ENTE HAS BEEN SUCCESSFULLY DEPLOYED & CONFIGURED!          ${NC}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════════════════${NC}"
    echo -e ""
    echo -e "  ${BOLD}Web Gallery URL:${NC}       ${CYAN}${WEB_ORIGIN}${NC}"
    echo -e "  ${BOLD}Core API URL:${NC}          ${CYAN}${API_ORIGIN}${NC}"
    echo -e "  ${BOLD}S3 Storage Endpoint:${NC}   ${CYAN}${S3_ENDPOINT}${NC}"
    echo -e "  ${BOLD}Install Folder:${NC}        ${TARGET_DIR}"
    echo -e "  ${BOLD}Timeline Log:${NC}          ${CYAN}${ACTIVE_LOG_FILE}${NC}"
    echo -e ""
    echo -e "${BOLD}▶ Quick Getting Started Steps:${NC}"
    echo -e "  1. Open ${CYAN}${WEB_ORIGIN}${NC} in your browser and click ${BOLD}Get Started${NC}."
    echo -e "  2. When prompted for email verification, retrieve the OTP with:"
    echo -e "     ${YELLOW}${TARGET_DIR}/get-otp.sh${NC}"
    echo -e "  3. When asked to choose a plan, click ${BOLD}'Continue with free plan'${NC}."
    echo -e ""
    echo -e "${BOLD}▶ Storage Quota Notice (${ENTE_QUOTA_HUMAN} Safe Limit):${NC}"
    echo -e "  • Your account is ${GREEN}automatically upgraded to ${ENTE_QUOTA_HUMAN}${NC} the moment you sign up!"
    echo -e "  • If you want to change or adjust this quota later, simply run:"
    echo -e "     ${YELLOW}${TARGET_DIR}/set-quota.sh${NC}  (or ${YELLOW}${TARGET_DIR}/reconfigure.sh --quota${NC})"
    echo -e ""
    echo -e "${BOLD}▶ Mobile App Setup (iOS & Android):${NC}"
    echo -e "  • Install the official ${BOLD}Ente Photos${NC} app."
    echo -e "  • On the welcome screen, ${BOLD}tap the Ente logo 7 times${NC} to reveal custom server settings."
    echo -e "  • Enter your Core API endpoint: ${CYAN}${API_ORIGIN}${NC}"
    echo -e "    ${YELLOW}(Note: Mobile apps strictly require HTTPS / valid SSL certificates)${NC}"
    echo -e ""
    echo -e "${BOLD}▶ Changing IP / Domain Later:${NC}"
    echo -e "  • If your server IP changes or you add a domain later, safely reconfigure anytime with:"
    echo -e "     ${YELLOW}${TARGET_DIR}/reconfigure.sh${NC}"
    echo -e ""
    echo -e "${BOLD}▶ Security & Hardening Applied:${NC}"
    echo -e "  • Credentials & configuration files strictly locked to ${GREEN}chmod 600${NC} (owner-only)."
    echo -e "  • Passwords & encryption keys generated with high-entropy /dev/urandom."
    if [ "$PORT_BIND_PREFIX" = "127.0.0.1:" ]; then
        echo -e "  • Reverse proxy ports ${GREEN}isolated to 127.0.0.1${NC} (direct WAN access prevented)."
    else
        echo -e "  • Host ports bound to 0.0.0.0 for LAN / remote reverse proxy access."
    fi
    echo -e ""
    if [ "$MODE" = "DOMAIN" ]; then
        echo -e "${BOLD}▶ Cloudflare Zero Trust Ingress Checklist:${NC}"
        echo -e "${CYAN}┌──────────────────────────────┬───────────────────┬──────────────────────────┐${NC}"
        printf "${CYAN}│${NC} %-28s ${CYAN}│${NC} %-17s ${CYAN}│${NC} %-24s ${CYAN}│${NC}\n" "Public Hostname" "Service Type" "Target URL"
        echo -e "${CYAN}├──────────────────────────────┼───────────────────┼──────────────────────────┤${NC}"
        printf "${CYAN}│${NC} %-28s ${CYAN}│${NC} %-17s ${CYAN}│${NC} %-24s ${CYAN}│${NC}\n" "${WEB_DOMAIN}" "HTTP" "localhost:${WEB_PORT}"
        printf "${CYAN}│${NC} %-28s ${CYAN}│${NC} %-17s ${CYAN}│${NC} %-24s ${CYAN}│${NC}\n" "${API_DOMAIN}" "HTTP" "localhost:${API_PORT}"
        printf "${CYAN}│${NC} %-28s ${CYAN}│${NC} %-17s ${CYAN}│${NC} %-24s ${CYAN}│${NC}\n" "${S3_DOMAIN}" "HTTP" "localhost:${MINIO_PORT}"
        echo -e "${CYAN}└──────────────────────────────┴───────────────────┴──────────────────────────┘${NC}"
        echo -e "  ${YELLOW}⚠ CRITICAL Cloudflare Rules:${NC}"
        echo -e "    1. Keep ${BOLD}Cloudflare Access (SSO/PIN)${NC} DISABLED on ${CYAN}${API_DOMAIN}${NC} and ${CYAN}${S3_DOMAIN}${NC}."
        echo -e "    2. Under Cloudflare Tunnel Public Hostname for ${CYAN}${S3_DOMAIN}${NC}, allow chunked uploads (100MB+)."
        echo -e "    3. Ingress templates saved in: ${TARGET_DIR}/reverse-proxy/\n"
    fi
    echo -e "${GREEN}════════════════════════════════════════════════════════════════════════${NC}\n"
}

# ------------------------------------------------------------------------------
# Main Flow
# ------------------------------------------------------------------------------
main() {
    DRY_RUN=false
    UNATTENDED=false
    CLI_TARGET_DIR="${ENTE_DIR:-}"
    CLI_DOMAIN="${ENTE_DOMAIN:-}"
    CLI_QUOTA="${ENTE_QUOTA:-}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-d)
                DRY_RUN=true
                shift
                ;;
            --unattended|-y)
                UNATTENDED=true
                shift
                ;;
            --dir)
                CLI_TARGET_DIR="$2"
                shift 2
                ;;
            --dir=*)
                CLI_TARGET_DIR="${1#*=}"
                shift
                ;;
            --domain)
                CLI_DOMAIN="$2"
                shift 2
                ;;
            --domain=*)
                CLI_DOMAIN="${1#*=}"
                shift
                ;;
            --quota)
                CLI_QUOTA="$2"
                shift 2
                ;;
            --quota=*)
                CLI_QUOTA="${1#*=}"
                shift
                ;;
            --help|-h)
                echo "Usage: ./install.sh [OPTIONS]"
                echo "Options:"
                echo "  --dry-run, -d       Validate system, allocate ports, and generate all configs without downloading images"
                echo "  --unattended, -y    Run non-interactively using safe defaults"
                echo "  --dir <PATH>        Set target installation directory (default: ~/ente)"
                echo "  --domain <DOMAIN>   Set primary domain for reverse proxy / Cloudflare Tunnel"
                echo "  --quota <SIZE|PCT>  Set storage quota (e.g. 60%, 500GB, 2TB)"
                echo "  --help, -h          Show this help message"
                exit 0
                ;;
            *)
                shift
                ;;
        esac
    done

    # If running piped from curl/wget into bash (e.g. curl | bash), reconnect stdin to terminal if interactive
    if [ "$UNATTENDED" = false ] && [ ! -t 0 ] && [ -t 1 ] && [ -r /dev/tty ]; then
        exec </dev/tty 2>/dev/null || true
    fi

    print_banner
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}${BOLD}▶ RUNNING IN DRY-RUN MODE: No Docker images will be pulled or containers started.${NC}\n"
    fi
    preflight_audit
    allocate_ports
    configure_topology
    allocate_storage_quota
    generate_secrets
    write_configurations
    launch_and_verify
    create_companion_tools
    print_summary
}

main "$@"

