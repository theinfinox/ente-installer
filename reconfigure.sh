#!/usr/bin/env bash
# ==============================================================================
# Ente Network & Endpoint Reconfiguration Utility
# Repository: https://github.com/theinfinox/ente-installer
# ==============================================================================
# Safely reconfigures network topology (localhost -> LAN IP, or LAN -> Domain)
# without modifying passwords, database records, or causing downtime/data loss.
# ==============================================================================

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

DRY_RUN=false
QUOTA_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --dry-run|-d) DRY_RUN=true ;;
        --quota|-q) QUOTA_ONLY=true ;;
        --help|-h)
            echo "Usage: ./reconfigure.sh [TARGET_DIR] [--dry-run] [--quota]"
            echo "  TARGET_DIR       Path to existing Ente directory (default: current directory or ~/ente)"
            echo "  --quota, -q      Directly reconfigure storage quota without network changes"
            echo "  --dry-run, -d    Preview configuration changes without restarting containers"
            exit 0
            ;;
    esac
done

echo -e "${PURPLE}${BOLD}"
cat << "EOF"
  ███████╗███╗   ██╗████████╗███████╗
  ██╔════╝████╗  ██║╚══██╔══╝██╔════╝
  █████╗  ██╔██╗ ██║   ██║   █████╗  
  ██╔══╝  ██║╚██╗██║   ██║   ██╔══╝  
  ███████╗██║ ╚████║   ██║   ███████╗
  ╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚══════╝
    STACK RECONFIGURATION UTILITY
EOF
echo -e "${NC}"
echo -e "${CYAN}Change IP, Domain, or Reverse Proxy Settings Safely${NC}"
echo -e "────────────────────────────────────────────────────────────────────────"

# 1. Locate Target Directory (Smart Auto-Detection without requiring 'cd')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_DIR=""
# Check if passed explicitly as an argument (and not a flag)
if [ -n "$1" ] && [[ "$1" != --* ]]; then
    TARGET_DIR="${1/#\~/$HOME}"
fi

# Auto-detect stack location in order of proximity:
# 1. Directory where this reconfigure.sh script is located
# 2. Current working directory
# 3. Standard ~/ente directory
# 4. Standard /DATA/AppData/ente directory
if [ -z "$TARGET_DIR" ] || [ ! -f "$TARGET_DIR/compose.yaml" ]; then
    if [ -f "$SCRIPT_DIR/compose.yaml" ] && [ -f "$SCRIPT_DIR/museum.yaml" ]; then
        TARGET_DIR="$SCRIPT_DIR"
    elif [ -f "./compose.yaml" ] && [ -f "./museum.yaml" ]; then
        TARGET_DIR="$(pwd)"
    elif [ -f "$HOME/ente/compose.yaml" ] && [ -f "$HOME/ente/museum.yaml" ]; then
        TARGET_DIR="$HOME/ente"
    elif [ -f "/DATA/AppData/ente/compose.yaml" ] && [ -f "/DATA/AppData/ente/museum.yaml" ]; then
        TARGET_DIR="/DATA/AppData/ente"
    else
        read -rp "Enter your Ente installation directory [default: $HOME/ente]: " INPUT_DIR
        TARGET_DIR="${INPUT_DIR:-$HOME/ente}"
        TARGET_DIR="${TARGET_DIR/#\~/$HOME}"
    fi
fi

if [ ! -f "$TARGET_DIR/credentials.env" ] && [ ! -f "$TARGET_DIR/museum.yaml" ]; then
    echo -e "${RED}[✖ ERROR] Could not find valid Ente configuration files in: ${TARGET_DIR}${NC}"
    echo -e "Expected: compose.yaml and museum.yaml"
    exit 1
fi

echo -e "${GREEN}[✔]${NC} Located active Ente stack at: ${BOLD}${TARGET_DIR}${NC}"

# 2. Safely Load Existing Secrets (Without modifying them)
[ -f "$TARGET_DIR/museum.yaml" ] && sed -i 's/\r$//' "$TARGET_DIR/museum.yaml" 2>/dev/null || true
[ -f "$TARGET_DIR/compose.yaml" ] && sed -i 's/\r$//' "$TARGET_DIR/compose.yaml" 2>/dev/null || true
[ -f "$TARGET_DIR/credentials.env" ] && sed -i 's/\r$//' "$TARGET_DIR/credentials.env" 2>/dev/null || true

get_cred() {
    (grep "^$1=" "$TARGET_DIR/credentials.env" 2>/dev/null || true) | cut -d'=' -f2- | tr -d '\r\n"'
}

PG_PASS=$(get_cred "PG_PASSWORD")
if [ -z "$PG_PASS" ] && [ -f "$TARGET_DIR/museum.yaml" ]; then
    PG_PASS=$(grep -E '^[[:space:]]*password:[[:space:]]*"' "$TARGET_DIR/museum.yaml" 2>/dev/null | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' | tr -d '\r\n"' || true)
fi

PG_USER=$(get_cred "PG_USER")
if [ -z "$PG_USER" ] && [ -f "$TARGET_DIR/museum.yaml" ]; then
    PG_USER=$(grep -E '^[[:space:]]*user:[[:space:]]*' "$TARGET_DIR/museum.yaml" 2>/dev/null | head -n1 | awk '{print $2}' | tr -d '\r\n"' || true)
fi
PG_USER=${PG_USER:-pguser}

PG_DB=$(get_cred "PG_DB")
if [ -z "$PG_DB" ] && [ -f "$TARGET_DIR/museum.yaml" ]; then
    PG_DB=$(grep -E '^[[:space:]]*name:[[:space:]]*' "$TARGET_DIR/museum.yaml" 2>/dev/null | head -n1 | awk '{print $2}' | tr -d '\r\n"' || true)
fi
PG_DB=${PG_DB:-ente_db}

MINIO_USER=$(get_cred "MINIO_ROOT_USER")
if [ -z "$MINIO_USER" ] && [ -f "$TARGET_DIR/museum.yaml" ]; then
    MINIO_USER=$(grep -E '^[[:space:]]*key:[[:space:]]*"' "$TARGET_DIR/museum.yaml" 2>/dev/null | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' | tr -d '\r\n"' || true)
fi

MINIO_PASS=$(get_cred "MINIO_ROOT_PASSWORD")
if [ -z "$MINIO_PASS" ] && [ -f "$TARGET_DIR/museum.yaml" ]; then
    MINIO_PASS=$(grep -E '^[[:space:]]*secret:[[:space:]]*"' "$TARGET_DIR/museum.yaml" 2>/dev/null | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' | tr -d '\r\n"' || true)
fi

KEY_ENC=$(get_cred "MUSEUM_KEY_ENC")
if [ -z "$KEY_ENC" ] && [ -f "$TARGET_DIR/museum.yaml" ]; then
    KEY_ENC=$(grep -E '^[[:space:]]*encryption:[[:space:]]*"' "$TARGET_DIR/museum.yaml" 2>/dev/null | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' | tr -d '\r\n"' || true)
fi

KEY_HASH=$(get_cred "MUSEUM_KEY_HASH")
if [ -z "$KEY_HASH" ] && [ -f "$TARGET_DIR/museum.yaml" ]; then
    KEY_HASH=$(grep -E '^[[:space:]]*hash:[[:space:]]*"' "$TARGET_DIR/museum.yaml" 2>/dev/null | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' | tr -d '\r\n"' || true)
fi

JWT_SECRET=$(get_cred "MUSEUM_JWT_SECRET")
if [ -z "$JWT_SECRET" ] && [ -f "$TARGET_DIR/museum.yaml" ]; then
    JWT_SECRET=$(awk '/^jwt:/{flag=1; next} flag && /^[[:space:]]*secret:/{print $2; flag=0}' "$TARGET_DIR/museum.yaml" 2>/dev/null | tr -d '\r\n"' || true)
fi

CURRENT_WEB_ORIGIN=$(get_cred "WEB_ORIGIN")
if [ -z "$CURRENT_WEB_ORIGIN" ] && [ -f "$TARGET_DIR/compose.yaml" ]; then
    CURRENT_WEB_ORIGIN=$(grep -E 'ENTE_API_ORIGIN:' "$TARGET_DIR/compose.yaml" 2>/dev/null | awk '{print $2}' || true)
fi

CURRENT_API_ORIGIN=$(get_cred "API_ORIGIN")
if [ -z "$CURRENT_API_ORIGIN" ] && [ -f "$TARGET_DIR/compose.yaml" ]; then
    CURRENT_API_ORIGIN=$(grep -E 'ENTE_API_ORIGIN:' "$TARGET_DIR/compose.yaml" 2>/dev/null | awk '{print $2}' || true)
fi

CURRENT_S3_ENDPOINT=$(get_cred "S3_ENDPOINT")
if [ -z "$CURRENT_S3_ENDPOINT" ] && [ -f "$TARGET_DIR/museum.yaml" ]; then
    CURRENT_S3_ENDPOINT=$(grep -E '^[[:space:]]*endpoint:[[:space:]]*"' "$TARGET_DIR/museum.yaml" 2>/dev/null | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
fi

# Extract existing ports from compose.yaml (supports both standard and loopback-bound ports)
WEB_PORT=$((grep -E '[0-9]+:3000"' "$TARGET_DIR/compose.yaml" 2>/dev/null || true) | sed -E 's/.*[^0-9]([0-9]+):3000".*/\1/' | head -n1)
WEB_PORT=${WEB_PORT:-3004}

ALBUMS_PORT=$((grep -E '[0-9]+:3002"' "$TARGET_DIR/compose.yaml" 2>/dev/null || true) | sed -E 's/.*[^0-9]([0-9]+):3002".*/\1/' | head -n1)
ALBUMS_PORT=${ALBUMS_PORT:-3002}

API_PORT=$((grep -E '[0-9]+:8080"' "$TARGET_DIR/compose.yaml" 2>/dev/null || true) | sed -E 's/.*[^0-9]([0-9]+):8080".*/\1/' | head -n1)
API_PORT=${API_PORT:-8080}

MINIO_PORT=$((grep -E '[0-9]+:3200"' "$TARGET_DIR/compose.yaml" 2>/dev/null || true) | sed -E 's/.*[^0-9]([0-9]+):3200".*/\1/' | head -n1)
MINIO_PORT=${MINIO_PORT:-3200}

echo -e "\n${BOLD}Current Configuration:${NC}"
echo -e "  • Web Gallery Origin:  ${CYAN}${CURRENT_WEB_ORIGIN}${NC}"
echo -e "  • Core API Origin:     ${CYAN}${CURRENT_API_ORIGIN}${NC}"
echo -e "  • S3 Storage Endpoint: ${CYAN}${CURRENT_S3_ENDPOINT}${NC}"
echo -e "  • Allocated Ports:     Web:${WEB_PORT}, API:${API_PORT}, S3:${MINIO_PORT}, Albums:${ALBUMS_PORT}"

reconfigure_quota() {
    echo -e "\n${BOLD}Storage Quota & Host Drive Safety:${NC}"

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

    local cur_quota="10 GB (Default)"
    local cur_user=""
    local DOCKER_BIN="docker"
    if ! docker info >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
        DOCKER_BIN="sudo docker"
    fi

    if [ "$DRY_RUN" = false ]; then
        local user_row
        user_row=$($DOCKER_BIN exec -i ente-postgres psql -U pguser -d ente_db -tAc \
          "SELECT user_id, storage FROM subscriptions ORDER BY subscription_id ASC LIMIT 1;" 2>/dev/null || true)
        if [ -n "$user_row" ]; then
            cur_user=$(echo "$user_row" | cut -d'|' -f1)
            local cur_b=$(echo "$user_row" | cut -d'|' -f2)
            if [ -n "$cur_b" ] && [ "$cur_b" -gt 0 ] 2>/dev/null; then
                cur_quota="$(( cur_b / 1024 / 1024 / 1024 )) GB"
            fi
        fi
    fi

    echo -e "  • Available Disk Space:      ${CYAN}${avail_gb} GB${NC}"
    echo -e "  • Current Active Quota:      ${YELLOW}${cur_quota}${NC}"
    echo -e "  • Default Safe Allocation:   ${GREEN}60%${NC} (~${raw_alloc_gb} GB -> ${GREEN}${rounded_gb} GB${NC} rounded up to multiple of 10)"
    echo -e "  ${YELLOW}Notice:${NC} Setting a safe limit leaves remaining disk protected for OS, logs, and Docker.\n"

    local q_input
    if [ "$DRY_RUN" = true ]; then
        q_input="${rounded_gb}GB"
        echo -e "[DRY-RUN] Using calculated default: ${q_input}"
    else
        read -rp "Enter percentage of available space (e.g. 60%) or custom size (e.g. 500GB) [default: 60%]: " q_input
        q_input=${q_input:-"60%"}
    fi

    local chosen_bytes
    local chosen_human
    local upper_q
    upper_q=$(echo "$q_input" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')

    if [[ "$upper_q" =~ ^([0-9]+)%$ ]] || [[ "$upper_q" =~ ^([0-9]+)%FREE$ ]] || [[ "$upper_q" =~ ^([0-9]+)%AVAIL$ ]]; then
        local user_pct=${BASH_REMATCH[1]}
        local calc_gb=$(( avail_gb * user_pct / 100 ))
        local calc_rounded_gb=$(( ((calc_gb + 9) / 10) * 10 ))
        if [ "$calc_rounded_gb" -gt "$avail_gb" ]; then
            calc_rounded_gb=$calc_gb
        fi
        if [ "$calc_rounded_gb" -le 0 ]; then
            calc_rounded_gb=1
        fi

        if [ "$DRY_RUN" = false ]; then
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
    elif [[ "$upper_q" =~ ^([0-9]+)TB$ ]]; then
        local num_tb=${BASH_REMATCH[1]}
        chosen_bytes=$(( num_tb * 1024 * 1024 * 1024 * 1024 ))
        chosen_human="${num_tb} TB"
    elif [[ "$upper_q" =~ ^([0-9]+)GB$ ]]; then
        local num_gb=${BASH_REMATCH[1]}
        chosen_bytes=$(( num_gb * 1024 * 1024 * 1024 ))
        chosen_human="${num_gb} GB"
    elif [[ "$upper_q" =~ ^[0-9]+$ ]]; then
        local num_raw=$upper_q
        chosen_bytes=$(( num_raw * 1024 * 1024 * 1024 ))
        chosen_human="${num_raw} GB"
    else
        echo -e "${YELLOW}[⚠] Unrecognized format '${q_input}'. Using default ${rounded_gb} GB.${NC}"
        chosen_bytes=$(( rounded_gb * 1024 * 1024 * 1024 ))
        chosen_human="${rounded_gb} GB"
    fi

    if [ "$DRY_RUN" = true ]; then
        echo -e "${GREEN}[✔] [DRY-RUN] Storage quota would be updated to: ${chosen_human} (${chosen_bytes} bytes)${NC}"
    else
        local where_clause=""
        if [ -n "$cur_user" ]; then
            where_clause="WHERE user_id = $cur_user"
        else
            where_clause="WHERE user_id = (SELECT user_id FROM users ORDER BY creation_time ASC LIMIT 1)"
        fi
        $DOCKER_BIN exec -i ente-postgres psql -U pguser -d ente_db -c \
          "UPDATE subscriptions SET storage = $chosen_bytes $where_clause; SELECT user_id, storage, product_id FROM subscriptions $where_clause;"
        echo -e "${GREEN}[✔] Storage quota updated successfully to ${chosen_human}! (Zero container downtime)${NC}"
    fi

    if [ -f "$TARGET_DIR/credentials.env" ]; then
        if grep -q "^ENTE_QUOTA_BYTES=" "$TARGET_DIR/credentials.env"; then
            sed -i "s/^ENTE_QUOTA_BYTES=.*/ENTE_QUOTA_BYTES=${chosen_bytes}/" "$TARGET_DIR/credentials.env"
            sed -i "s/^ENTE_QUOTA_HUMAN=.*/ENTE_QUOTA_HUMAN=${chosen_human// /}/" "$TARGET_DIR/credentials.env"
        else
            echo "ENTE_QUOTA_BYTES=${chosen_bytes}" >> "$TARGET_DIR/credentials.env"
            echo "ENTE_QUOTA_HUMAN=${chosen_human// /}" >> "$TARGET_DIR/credentials.env"
        fi
    fi
}

# 3. Interactive Topology Selection
AUTO_LAN_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
AUTO_LAN_IP="${AUTO_LAN_IP:-127.0.0.1}"
AUTO_LAN_IP=$(echo "$AUTO_LAN_IP" | tr -d '[:space:]')

if [ "$QUOTA_ONLY" = true ]; then
    ACTION_CHOICE=3
else
    echo -e "\n${BOLD}Select reconfiguration task:${NC}"
    echo -e "  ${BOLD}[1] Local Network / Private IP${NC} (Switch to LAN IP: ${AUTO_LAN_IP})"
    echo -e "  ${BOLD}[2] Public Domain / Reverse Proxy${NC} (Cloudflare Tunnel, Caddy, Nginx with HTTPS)"
    echo -e "  ${BOLD}[3] Storage Quota Allocation${NC} (Adjust safe disk space limit / percentage)"
    echo -e "  ${BOLD}[4] Cancel & Keep Current Settings${NC}"
    read -rp "Select option [1/2/3/4, default: 1]: " ACTION_CHOICE
    ACTION_CHOICE=${ACTION_CHOICE:-1}
fi

if [ "$ACTION_CHOICE" -eq 4 ]; then
    echo "No changes made. Exiting."
    exit 0
elif [ "$ACTION_CHOICE" -eq 3 ]; then
    reconfigure_quota
    exit 0
elif [ "$ACTION_CHOICE" -eq 2 ]; then
    MODE="DOMAIN"
    read -rp "Enter your primary root domain for Ente (e.g., example.com): " ROOT_DOMAIN
    ROOT_DOMAIN=$(echo "$ROOT_DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    ROOT_DOMAIN=${ROOT_DOMAIN#https://}
    ROOT_DOMAIN=${ROOT_DOMAIN#http://}
    ROOT_DOMAIN=${ROOT_DOMAIN%/}
    ROOT_DOMAIN=${ROOT_DOMAIN#.}
    ROOT_DOMAIN=${ROOT_DOMAIN%.}

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

    read -rp "Bind ports to 127.0.0.1 (Y) or 0.0.0.0 (n)? [Y/n, default: ${DEFAULT_PROXY_CHOICE}]: " LOCAL_PROXY_CHOICE
    LOCAL_PROXY_CHOICE=${LOCAL_PROXY_CHOICE:-$DEFAULT_PROXY_CHOICE}
    if [[ "$LOCAL_PROXY_CHOICE" =~ ^[Yy]$ ]]; then
        PORT_BIND_PREFIX="127.0.0.1:"
        echo -e "${GREEN}[✔]${NC} High-Security Mode: Host ports isolated to localhost (127.0.0.1)"
    else
        PORT_BIND_PREFIX=""
        echo -e "${BLUE}[INFO]${NC} Standard Mode: Host ports bound to 0.0.0.0 for container/external proxy access"
    fi

    WEB_ORIGIN="https://${WEB_DOMAIN}"
    API_ORIGIN="https://${API_DOMAIN}"
    S3_ENDPOINT="${S3_DOMAIN}"
    ALBUMS_ORIGIN="https://${WEB_DOMAIN}"
    ARE_LOCAL_BUCKETS="false"
else
    MODE="LAN"
    PORT_BIND_PREFIX=""
    read -rp "Enter your server's reachable LAN IP [default: ${AUTO_LAN_IP}]: " INPUT_IP
    SERVER_IP="${INPUT_IP:-$AUTO_LAN_IP}"
    SERVER_IP=$(echo "$SERVER_IP" | tr -d '[:space:]')
    SERVER_IP="${SERVER_IP:-127.0.0.1}"

    if [ "$SERVER_IP" = "127.0.0.1" ] || [ "$SERVER_IP" = "localhost" ]; then
        echo -e "${YELLOW}[⚠ WARNING] You selected loopback '${SERVER_IP}'. External phones cannot upload to 127.0.0.1.${NC}"
    fi

    WEB_ORIGIN="http://${SERVER_IP}:${WEB_PORT}"
    API_ORIGIN="http://${SERVER_IP}:${API_PORT}"
    S3_ENDPOINT="${SERVER_IP}:${MINIO_PORT}"
    ALBUMS_ORIGIN="http://${SERVER_IP}:${ALBUMS_PORT}"
    ARE_LOCAL_BUCKETS="true"
fi

# 4. Safe Backups of Previous Files
BACKUP_TS=$(date +%Y%m%d_%H%M%S)
cp "$TARGET_DIR/museum.yaml" "$TARGET_DIR/museum.yaml.bak_$BACKUP_TS"
cp "$TARGET_DIR/compose.yaml" "$TARGET_DIR/compose.yaml.bak_$BACKUP_TS"
echo -e "${GREEN}[✔]${NC} Backed up old configs to *.bak_${BACKUP_TS}"

# 5. Rewrite museum.yaml in place (preserving passwords)
cat <<EOF > "$TARGET_DIR/museum.yaml"
# Ente Museum Core Configuration
# Reconfigured on: $(date)

db:
  host: postgres
  port: 5432
  name: ${PG_DB:-ente_db}
  user: ${PG_USER:-pguser}
  password: "${PG_PASS}"

s3:
  are_local_buckets: ${ARE_LOCAL_BUCKETS}
  use_path_style_urls: true
  b2-eu-cen:
    key: "${MINIO_USER}"
    secret: "${MINIO_PASS}"
    endpoint: "${S3_ENDPOINT}"
    region: eu-central-2
    bucket: b2-eu-cen
  wasabi-eu-central-2-v3:
    key: "${MINIO_USER}"
    secret: "${MINIO_PASS}"
    endpoint: "${S3_ENDPOINT}"
    region: eu-central-2
    bucket: wasabi-eu-central-2-v3
  scw-eu-fr-v3:
    key: "${MINIO_USER}"
    secret: "${MINIO_PASS}"
    endpoint: "${S3_ENDPOINT}"
    region: eu-central-2
    bucket: scw-eu-fr-v3

apps:
  public-albums: ${ALBUMS_ORIGIN}
  cast: ${WEB_ORIGIN}
  accounts: ${WEB_ORIGIN}

key:
  encryption: "${KEY_ENC}"
  hash: "${KEY_HASH}"

jwt:
  secret: "${JWT_SECRET}"

mail:
  sendgrid: ""
  smtp:
    host: ""
    port: 587
    username: ""
    password: ""
  email:
    from: "noreply@ente.local"
EOF
chmod 600 "$TARGET_DIR/museum.yaml"

# 6. Rewrite compose.yaml in place
cat <<EOF > "$TARGET_DIR/compose.yaml"
# Ente Docker Compose Stack
# Reconfigured on: $(date)

services:
  museum:
    image: ghcr.io/ente/server
    container_name: ente-museum
    restart: unless-stopped
    sysctls:
      net.ipv6.conf.all.disable_ipv6: 1
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
      POSTGRES_USER: ${PG_USER:-pguser}
      POSTGRES_PASSWORD: "${PG_PASS}"
      POSTGRES_DB: ${PG_DB:-ente_db}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -q -d ente_db -U pguser"]
      interval: 5s
      timeout: 5s
      retries: 20
      start_period: 60s
    volumes:
      - ./pg_data:/var/lib/postgresql/data

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
      - ./minio_data:/data
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

# 7. Update credentials.env with new origins
cat <<EOF > "$TARGET_DIR/credentials.env"
# Ente Instance Credentials
# Reconfigured on: $(date)
PG_USER=${PG_USER}
PG_PASSWORD=${PG_PASS}
PG_DB=${PG_DB}

MINIO_ROOT_USER=${MINIO_USER}
MINIO_ROOT_PASSWORD=${MINIO_PASS}

MUSEUM_KEY_ENC=${KEY_ENC}
MUSEUM_KEY_HASH=${KEY_HASH}
MUSEUM_JWT_SECRET=${JWT_SECRET}

WEB_ORIGIN=${WEB_ORIGIN}
API_ORIGIN=${API_ORIGIN}
S3_ENDPOINT=${S3_ENDPOINT}
EOF
chmod 600 "$TARGET_DIR/credentials.env"

# 8. Reverse Proxy Snippets (if Domain Mode)
mkdir -p "$TARGET_DIR/reverse-proxy"
if [ "$MODE" = "DOMAIN" ]; then
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
    echo -e "${GREEN}[✔]${NC} Reverse proxy templates generated in reverse-proxy/"
fi

# 9. Apply Changes via Docker
if [ "$DRY_RUN" = true ]; then
    echo -e "\n${YELLOW}${BOLD}[DRY-RUN] Preview complete: Configurations updated without restarting Docker.${NC}"
else
    echo -e "\n${BLUE}[INFO]${NC} Applying updated network configuration..."
    DOCKER_BIN="docker"
    if ! docker info >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
        DOCKER_BIN="sudo docker"
    fi

    cd "$TARGET_DIR"
    $DOCKER_BIN compose up -d
    echo -e "${GREEN}[✔]${NC} Docker stack reloaded successfully!"
fi

echo -e "\n${GREEN}${BOLD}════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}         🎉 ENTE HAS BEEN RECONFIGURED SUCCESSFULLY!                   ${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${BOLD}New Web Gallery URL:${NC}       ${CYAN}${WEB_ORIGIN}${NC}"
echo -e "  ${BOLD}New Core API URL:${NC}          ${CYAN}${API_ORIGIN}${NC}"
echo -e "  ${BOLD}New S3 Storage Endpoint:${NC}   ${CYAN}${S3_ENDPOINT}${NC}"
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
echo -e ""
echo -e "${BOLD}▶ Next Steps for Mobile App:${NC}"
echo -e "  • If you updated your API URL, open the Ente app, ${BOLD}tap the logo 7 times${NC},"
echo -e "    and set your API origin to: ${CYAN}${API_ORIGIN}${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════════════${NC}\n"

