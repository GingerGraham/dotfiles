#!/usr/bin/env bash
# macOS platform configuration.
# Sourced on macOS hosts (DOTFILES_OS == "Mac") by loader.sh.

# ── Homebrew ──────────────────────────────────────────────────────────────────
if command -v brew &>/dev/null; then
    alias brew-update='brew update && brew upgrade && brew cleanup'
fi

# ── macOS PATH extensions ─────────────────────────────────────────────────────
# Homebrew on Apple Silicon
[[ -d "/opt/homebrew/bin" ]] && export PATH="/opt/homebrew/bin:${PATH}"

# ── macOS-specific aliases ────────────────────────────────────────────────────
alias flushdns="sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"

# ── iTerm2 shell integration ─────────────────────────────────────────────────
if [[ -f "${HOME}/.iterm2_shell_integration.bash" && -n "${BASH_VERSION}" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.iterm2_shell_integration.bash"
elif [[ -f "${HOME}/.iterm2_shell_integration.zsh" && -n "${ZSH_VERSION}" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.iterm2_shell_integration.zsh"
fi
