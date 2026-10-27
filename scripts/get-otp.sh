#!/usr/bin/env bash
# Determine Docker command (sudo-aware)
DOCKER_BIN="docker"
if ! docker info >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
    DOCKER_BIN="sudo docker"
fi

echo "Fetching latest Ente email verification codes..."
$DOCKER_BIN logs --tail 60 ente-museum 2>&1 | grep -i "code" || echo "No verification codes logged in recent output."

