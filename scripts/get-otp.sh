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
