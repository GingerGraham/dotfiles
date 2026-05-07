#!/usr/bin/env bash
# Linux platform configuration.
# Sourced on Linux hosts (DOTFILES_OS == "Linux") by loader.sh.

# ── Systemd power management ──────────────────────────────────────────────────
if command -v systemctl &>/dev/null; then
    alias zzz="sudo systemctl suspend --check-inhibitors=no"
    alias reboot="sudo systemctl reboot"
    alias bye="sudo systemctl poweroff"
    alias services="systemctl --type=service --state=running"
fi

# ── xdg-open shortcut ─────────────────────────────────────────────────────────
command -v xdg-open &>/dev/null && alias open="xdg-open"

# ── lvfs firmware updates ─────────────────────────────────────────────────────
if command -v fwupdmgr &>/dev/null; then
    alias lvfs-update='sudo fwupdmgr refresh --force && sudo fwupdmgr get-updates && sudo fwupdmgr update'
fi
