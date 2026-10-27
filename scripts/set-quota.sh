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
