#!/usr/bin/env bash
# Ente Storage Quota Utility
# Usage: ./set-quota.sh [SIZE] [USER_ID_OPTIONAL]
# Examples:
#   ./set-quota.sh 60%          # 60% of total drive space
#   ./set-quota.sh 60%free      # 60% of free available space
#   ./set-quota.sh 500GB
#   ./set-quota.sh 10TB

set -eo pipefail

INPUT_SIZE=${1:-"60%"}
TARGET_USER=$2

DOCKER_BIN="docker"
if ! docker info >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
    DOCKER_BIN="sudo docker"
fi

DISK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPPER_SIZE=$(echo "$INPUT_SIZE" | tr '[:lower:]' '[:upper:]')

if [[ "$UPPER_SIZE" =~ ^([0-9]+)%FREE$ ]] || [[ "$UPPER_SIZE" =~ ^([0-9]+)%AVAIL$ ]]; then
    PCT=${BASH_REMATCH[1]}
    AVAIL_KB=$(df -k -P "$DISK_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    AVAIL_KB=${AVAIL_KB:-104857600}
    BYTES=$(( AVAIL_KB * 1024 * PCT / 100 ))
    echo "Calculated ${PCT}% of available free disk space -> $(( BYTES / 1024 / 1024 / 1024 )) GB ($BYTES bytes)"
elif [[ "$UPPER_SIZE" =~ ^([0-9]+)%$ ]]; then
    PCT=${BASH_REMATCH[1]}
    TOTAL_KB=$(df -k -P "$DISK_DIR" 2>/dev/null | awk 'NR==2 {print $2}')
    TOTAL_KB=${TOTAL_KB:-104857600}
    BYTES=$(( TOTAL_KB * 1024 * PCT / 100 ))
    echo "Calculated ${PCT}% of total disk space -> $(( BYTES / 1024 / 1024 / 1024 )) GB ($BYTES bytes)"
elif [[ "$UPPER_SIZE" =~ ^([0-9]+)TB$ ]]; then
    NUM=${BASH_REMATCH[1]}
    BYTES=$(( NUM * 1024 * 1024 * 1024 * 1024 ))
elif [[ "$UPPER_SIZE" =~ ^([0-9]+)GB$ ]]; then
    NUM=${BASH_REMATCH[1]}
    BYTES=$(( NUM * 1024 * 1024 * 1024 ))
elif [[ "$UPPER_SIZE" =~ ^[0-9]+$ ]]; then
    NUM=$UPPER_SIZE
    BYTES=$(( NUM * 1024 * 1024 * 1024 ))
else
    echo "Invalid size format: $INPUT_SIZE. Use e.g. 60%, 60%free, 50GB, 500GB, 2TB, 10TB."
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

echo "Updating account storage quota to $INPUT_SIZE ($BYTES bytes)..."
$DOCKER_BIN exec -i ente-postgres psql -U pguser -d ente_db -c \
  "UPDATE subscriptions SET storage = $BYTES $WHERE_CLAUSE; SELECT user_id, storage, product_id FROM subscriptions $WHERE_CLAUSE;"
echo "Quota updated successfully! Refresh your Ente gallery tab."
