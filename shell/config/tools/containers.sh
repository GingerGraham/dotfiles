#!/usr/bin/env bash
# Container tool configuration — Docker and Podman aliases.
# Sourced when docker or podman is present (guarded in loader.sh).

# ── aliases ───────────────────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
    alias d="docker"
    alias dps="docker ps"
    alias dpsa="docker ps -a"
    alias di="docker images"
    alias drm="docker rm"
    alias drmi="docker rmi"
    alias dex="docker exec -it"
    alias dlog="docker logs"
fi

if command -v podman &>/dev/null; then
    alias pd="podman"
    alias pdps="podman ps"
    alias pdpsa="podman ps -a"
    alias pdi="podman images"
fi

# Prefer podman over docker when both are available (rootless-first)
if command -v podman &>/dev/null && ! command -v docker &>/dev/null; then
    alias docker="podman"
fi

if command -v docker-compose &>/dev/null || command -v podman-compose &>/dev/null; then
    alias dc="${DOCKER_COMPOSE_CMD:-docker-compose}"
fi
