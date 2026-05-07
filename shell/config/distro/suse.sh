#!/usr/bin/env bash
# SUSE-family distro configuration (openSUSE, SLES).
# Sourced when DOTFILES_DISTRO == "suse" by loader.sh.

# ── Package update alias ──────────────────────────────────────────────────────
if command -v zypper &>/dev/null; then
    alias zypper-update='sudo zypper update -y && sudo zypper clean -a'
fi
