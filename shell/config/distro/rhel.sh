#!/usr/bin/env bash
# RHEL-family distro configuration (Fedora, RHEL, Rocky, AlmaLinux, CentOS).
# Sourced when DOTFILES_DISTRO == "rhel" by loader.sh.

# ── Package update alias ──────────────────────────────────────────────────────
if command -v dnf &>/dev/null; then
    alias dnf-update='sudo dnf check-update --refresh -y || true && sudo dnf update -y || true && sudo dnf autoremove -y'
elif command -v yum &>/dev/null; then
    alias yum-update='sudo yum update -y && sudo yum autoremove -y'
fi
