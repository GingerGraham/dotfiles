#!/usr/bin/env bash
# Debian-family distro configuration (Ubuntu, Debian, Linux Mint, Pop!_OS).
# Sourced when DOTFILES_DISTRO == "debian" by loader.sh.

# ── Package update alias ──────────────────────────────────────────────────────
if command -v apt &>/dev/null; then
    alias apt-update='sudo apt update -y && sudo apt upgrade -y && sudo apt autoremove -y'
fi
