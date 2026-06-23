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

# ── Flush DNS ─────────────────────────────────────────────────────────────────
# resolvectl is the current binary (systemd 239+, Fedora 33+, Ubuntu 20.04+).
# systemd-resolve is the legacy name kept as a symlink on some distros but
# absent on others. Check resolvectl first; fall back for older systems.
if command -v resolvectl &>/dev/null; then
    alias flush-dns="sudo resolvectl flush-caches"
    alias flushdns="sudo resolvectl flush-caches"
elif command -v systemd-resolve &>/dev/null; then
    alias flush-dns="sudo systemd-resolve --flush-caches"
    alias flushdns="sudo systemd-resolve --flush-caches"
fi

# ── xdg-open shortcut ─────────────────────────────────────────────────────────
if command -v xdg-open &>/dev/null; then
    alias open="xdg-open"
fi

# ── lvfs firmware updates ─────────────────────────────────────────────────────
if command -v fwupdmgr &>/dev/null; then
    alias lvfs-update='sudo fwupdmgr refresh --force && sudo fwupdmgr get-updates && sudo fwupdmgr update'
fi

# ── dircolors / colour-aware aliases ──────────────────────────────────────────
# Sets up LS_COLORS and makes ls, grep, etc. use colour output.
# GNU coreutils only — this block is a no-op on macOS without coreutils.
if command -v dircolors &>/dev/null; then
    if [[ -r "${HOME}/.dircolors" ]]; then
        eval "$(dircolors -b "${HOME}/.dircolors")"
    else
        eval "$(dircolors -b)"
    fi
fi
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# zsh completion list colours — must be set after dircolors populates LS_COLORS.
# This zstyle is intentionally NOT set in core/zsh.sh because platform/ loads
# after core/ and LS_COLORS would be empty at that point.
if [[ -n "${ZSH_VERSION}" ]]; then
    # shellcheck disable=SC2296
    zstyle ':completion:*:default' list-colors "${(s.:.)LS_COLORS}"
fi

# ── Desktop notifications ─────────────────────────────────────────────────────
# alert: suffix a long-running command with '; alert' to get a desktop
# notification when it finishes (success or failure).
# Example: sleep 30; alert
if command -v notify-send &>/dev/null; then
    # shellcheck disable=SC2142
    alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history | tail -n1 | sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'
fi

# ── Nix package manager ───────────────────────────────────────────────────────
if [[ -e "${HOME}/.nix-profile/etc/profile.d/nix.sh" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.nix-profile/etc/profile.d/nix.sh"
fi
