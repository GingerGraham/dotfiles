#!/usr/bin/env bash
# WSL (Windows Subsystem for Linux) configuration.
# Sourced when DOTFILES_WSL == "true", in addition to the Linux platform file.

# ── Windows interop ───────────────────────────────────────────────────────────
# Allow calling Windows executables without .exe suffix
export WSLENV="${WSLENV:-}"

# Use Windows browser for xdg-open
if command -v wslview &>/dev/null; then
    alias open="wslview"
elif [[ -x "/mnt/c/Windows/System32/cmd.exe" ]]; then
    alias open="cmd.exe /c start"
fi

# ── Clipboard via win32yank or clip.exe ───────────────────────────────────────
if command -v win32yank.exe &>/dev/null; then
    alias copy="win32yank.exe -i"
    alias paste="win32yank.exe -o"
elif [[ -f "/mnt/c/Windows/System32/clip.exe" ]]; then
    alias copy="/mnt/c/Windows/System32/clip.exe"
fi

# ── Docker Desktop socket (when using Docker on Windows host) ─────────────────
if [[ -S "/var/run/docker.sock" ]]; then
    export DOCKER_HOST="unix:///var/run/docker.sock"
fi
