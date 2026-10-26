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
for arg in "$@"; do
    case "$arg" in
        --dry-run|-d) DRY_RUN=true ;;
        --help|-h)
            echo "Usage: ./reconfigure.sh [TARGET_DIR] [--dry-run]"
            echo "  TARGET_DIR       Path to existing Ente directory (default: current directory or ~/ente)"
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

# 1. Locate Target Directory
TARGET_DIR="${1:-.}"
if [[ "$TARGET_DIR" == --* ]]; then
    TARGET_DIR="."
fi
TARGET_DIR="${TARGET_DIR/#\~/$HOME}"

if [ ! -f "$TARGET_DIR/credentials.env" ] || [ ! -f "$TARGET_DIR/compose.yaml" ]; then
    if [ -f "$HOME/ente/credentials.env" ] && [ -f "$HOME/ente/compose.yaml" ]; then
        TARGET_DIR="$HOME/ente"
    else
        read -rp "Enter your Ente installation directory [default: $HOME/ente]: " INPUT_DIR
        TARGET_DIR="${INPUT_DIR:-$HOME/ente}"
        TARGET_DIR="${TARGET_DIR/#\~/$HOME}"
    fi
fi

if [ ! -f "$TARGET_DIR/credentials.env" ] || [ ! -f "$TARGET_DIR/compose.yaml" ] || [ ! -f "$TARGET_DIR/museum.yaml" ]; then
    echo -e "${RED}[✖ ERROR] Could not find valid Ente configuration files in: ${TARGET_DIR}${NC}"
    echo -e "Expected: credentials.env, compose.yaml, and museum.yaml"
    exit 1
fi

echo -e "${GREEN}[✔]${NC} Located active Ente stack at: ${BOLD}${TARGET_DIR}${NC}"

# 2. Safely Load Existing Secrets (Without modifying them)
get_cred() {
    grep "^$1=" "$TARGET_DIR/credentials.env" | cut -d'=' -f2- | tr -d '\r\n'
}

PG_PASS=$(get_cred "PG_PASSWORD")
PG_USER=$(get_cred "PG_USER")
PG_DB=$(get_cred "PG_DB")
MINIO_USER=$(get_cred "MINIO_ROOT_USER")
MINIO_PASS=$(get_cred "MINIO_ROOT_PASSWORD")
KEY_ENC=$(get_cred "MUSEUM_KEY_ENC")
KEY_HASH=$(get_cred "MUSEUM_KEY_HASH")
JWT_SECRET=$(get_cred "MUSEUM_JWT_SECRET")

CURRENT_WEB_ORIGIN=$(get_cred "WEB_ORIGIN")
CURRENT_API_ORIGIN=$(get_cred "API_ORIGIN")
CURRENT_S3_ENDPOINT=$(get_cred "S3_ENDPOINT")

# Extract existing ports from compose.yaml (supports both standard and loopback-bound ports)
WEB_PORT=$(grep -E '[0-9]+:3000"' "$TARGET_DIR/compose.yaml" 2>/dev/null | sed -E 's/.*[^0-9]([0-9]+):3000".*/\1/' | head -n1)
WEB_PORT=${WEB_PORT:-3004}

ALBUMS_PORT=$(grep -E '[0-9]+:3002"' "$TARGET_DIR/compose.yaml" 2>/dev/null | sed -E 's/.*[^0-9]([0-9]+):3002".*/\1/' | head -n1)
ALBUMS_PORT=${ALBUMS_PORT:-3002}

API_PORT=$(grep -E '[0-9]+:8080"' "$TARGET_DIR/compose.yaml" 2>/dev/null | sed -E 's/.*[^0-9]([0-9]+):8080".*/\1/' | head -n1)
API_PORT=${API_PORT:-8080}

MINIO_PORT=$(grep -E '[0-9]+:3200"' "$TARGET_DIR/compose.yaml" 2>/dev/null | sed -E 's/.*[^0-9]([0-9]+):3200".*/\1/' | head -n1)
MINIO_PORT=${MINIO_PORT:-3200}

echo -e "\n${BOLD}Current Configuration:${NC}"
echo -e "  • Web Gallery Origin:  ${CYAN}${CURRENT_WEB_ORIGIN}${NC}"
echo -e "  • Core API Origin:     ${CYAN}${CURRENT_API_ORIGIN}${NC}"
echo -e "  • S3 Storage Endpoint: ${CYAN}${CURRENT_S3_ENDPOINT}${NC}"
echo -e "  • Allocated Ports:     Web:${WEB_PORT}, API:${API_PORT}, S3:${MINIO_PORT}, Albums:${ALBUMS_PORT}"

# 3. Interactive Topology Selection
AUTO_LAN_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
AUTO_LAN_IP="${AUTO_LAN_IP:-127.0.0.1}"
AUTO_LAN_IP=$(echo "$AUTO_LAN_IP" | tr -d '[:space:]')

echo -e "\n${BOLD}Select new network access mode:${NC}"
echo -e "  ${BOLD}[1] Local Network / Private IP${NC} (Switch to LAN IP: ${AUTO_LAN_IP})"
echo -e "  ${BOLD}[2] Public Domain / Reverse Proxy${NC} (Cloudflare Tunnel, Caddy, Nginx with HTTPS)"
echo -e "  ${BOLD}[3] Cancel & Keep Current Settings${NC}"
read -rp "Select option [1/2/3, default: 1]: " NET_CHOICE
NET_CHOICE=${NET_CHOICE:-1}

if [ "$NET_CHOICE" -eq 3 ]; then
    echo "No changes made. Exiting."
    exit 0
elif [ "$NET_CHOICE" -eq 2 ]; then
    MODE="DOMAIN"
    read -rp "Enter your primary root domain for Ente (e.g., example.com): " ROOT_DOMAIN
    ROOT_DOMAIN=$(echo "$ROOT_DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    ROOT_DOMAIN=${ROOT_DOMAIN#https://}
    ROOT_DOMAIN=${ROOT_DOMAIN#http://}
    ROOT_DOMAIN=${ROOT_DOMAIN%/}
    ROOT_DOMAIN=${ROOT_DOMAIN#.}
    ROOT_DOMAIN=${ROOT_DOMAIN%.}

    WEB_DOMAIN="photos.${ROOT_DOMAIN}"
    API_DOMAIN="api.${ROOT_DOMAIN}"
    S3_DOMAIN="s3.${ROOT_DOMAIN}"

    echo -e "\nProposed Subdomains:"
    echo -e "  • Web Gallery:   ${BOLD}https://${WEB_DOMAIN}${NC}"
    echo -e "  • Core API:      ${BOLD}https://${API_DOMAIN}${NC}"
    echo -e "  • S3 Storage:    ${BOLD}https://${S3_DOMAIN}${NC}"
    read -rp "Confirm subdomain schema? [Y/n]: " DOMAIN_CONFIRM
    DOMAIN_CONFIRM=${DOMAIN_CONFIRM:-Y}
    if [[ ! "$DOMAIN_CONFIRM" =~ ^[Yy]$ ]]; then
        read -rp "Enter full Web Gallery URL (e.g. photos.myphotos.com): " WEB_DOMAIN
        read -rp "Enter full Core API URL (e.g. api.myphotos.com): " API_DOMAIN
        read -rp "Enter full S3 Storage URL/Host (e.g. s3.myphotos.com): " S3_DOMAIN
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

    # Reverse Proxy Network Isolation & Security
    echo -e "\n────────────────────────────────────────────────────────────────────────"
    echo -e "${BOLD}Reverse Proxy Network Isolation & Security:${NC}"
    echo -e "Where is your reverse proxy (Cloudflare Tunnel, Caddy, Nginx) running?\n"
    echo -e "  ${BOLD}[Y] On THIS same server${NC} (Recommended)"
    echo -e "      • Explanation: The Cloudflare Tunnel daemon (cloudflared) or Caddy"
    echo -e "        runs directly on this machine."
    echo -e "      • Security Benefit: Binds Ente ports to 127.0.0.1 (localhost only)."
    echo -e "      • Problem Avoided: Prevents anyone on the public internet from bypassing"
    echo -e "        your Cloudflare SSL/WAF by accessing your raw IP:PORT directly.\n"
    echo -e "  ${BOLD}[n] On a SEPARATE machine or VM on your home network${NC}"
    echo -e "      • Example: An Nginx Proxy Manager or Traefik VM on 192.168.1.10"
    echo -e "        routing traffic to this Ente server on 192.168.1.50."
    echo -e "      • Behavior: Binds ports to 0.0.0.0 so your remote proxy can reach Ente.\n"
    read -rp "Is your reverse proxy running on this same server? [Y/n, default: Y]: " LOCAL_PROXY_CHOICE
    LOCAL_PROXY_CHOICE=${LOCAL_PROXY_CHOICE:-Y}
    if [[ "$LOCAL_PROXY_CHOICE" =~ ^[Yy]$ ]]; then
        PORT_BIND_PREFIX="127.0.0.1:"
        echo -e "${GREEN}[✔]${NC} High-Security Mode: Host ports isolated to localhost (127.0.0.1)"
    else
        PORT_BIND_PREFIX=""
        echo -e "${BLUE}[INFO]${NC} Standard Mode: Host ports bound to 0.0.0.0 for external proxy access"
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
    region: eu-central-1
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
    region: eu-west-1
    bucket: scw-eu-fr-v3

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
echo -e "${BOLD}▶ Next Steps for Mobile App:${NC}"
echo -e "  • If you updated your API URL, open the Ente app, ${BOLD}tap the logo 7 times${NC},"
echo -e "    and set your API origin to: ${CYAN}${API_ORIGIN}${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════════════${NC}\n"

