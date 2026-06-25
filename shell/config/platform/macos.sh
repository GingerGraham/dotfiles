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
alias flush-dns="sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
alias flushdns="sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"

# ── iTerm2 shell integration ─────────────────────────────────────────────────
if [[ -f "${HOME}/.iterm2_shell_integration.bash" && -n "${BASH_VERSION}" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.iterm2_shell_integration.bash"
elif [[ -f "${HOME}/.iterm2_shell_integration.zsh" && -n "${ZSH_VERSION}" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.iterm2_shell_integration.zsh"
fi

# ── Keychain / security CLI secret management ─────────────────────────────────
# Wrappers around macOS `security` to provide a secret-tool-compatible
# interface matching the Linux libsecret CLI.

# ── aliases ───────────────────────────────────────────────────────────────────
alias delete-secret="remove-secret"

# ── functions ─────────────────────────────────────────────────────────────────
store-secret() {
    local account="$1"
    local service="$2"
    if [[ -z "${account}" || -z "${service}" ]]; then
        log_error "store-secret: usage: store-secret <account> <service>"
        return 1
    fi
    local _secret
    _read_prompt_silent "Enter secret for ${service}: " _secret
    security add-generic-password -a "${account}" -s "${service}" -w "${_secret}" -U
}

get-secret() {
    local account="$1"
    local service="$2"
    if [[ -z "${account}" || -z "${service}" ]]; then
        log_error "get-secret: usage: get-secret <account> <service>"
        return 1
    fi
    security find-generic-password -a "${account}" -s "${service}" -w
}

remove-secret() {
    local account="$1"
    local service="$2"
    if [[ -z "${account}" || -z "${service}" ]]; then
        log_error "remove-secret: usage: remove-secret <account> <service>"
        return 1
    fi
    security delete-generic-password -a "${account}" -s "${service}"
}

secret-tool() {
    case "$1" in
        add|store)
            shift
            store-secret "$@"
            ;;
        lookup|get)
            shift
            get-secret "$@"
            ;;
        clear|remove|delete)
            shift
            remove-secret "$@"
            ;;
        *)
            log_warn "Usage: secret-tool {add|store|lookup|get|clear|remove|delete} <account> <service>"
            return 1
            ;;
    esac
}