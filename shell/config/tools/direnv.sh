#!/usr/bin/env bash
# direnv configuration — shell hook integration.
# Sourced by loader.sh when direnv is present (guarded by command -v direnv).
# Shell-aware: uses direnv hook bash/zsh depending on DOTFILES_SHELL.
#
# Config lives at ~/.config/direnv/direnv.toml (XDG default — direnv finds it
# automatically, no DIRENV_CONFIG export needed). Deployed by the shell role,
# created once, never overwritten — see shell role README for what it sets.

# ── Quieter output ────────────────────────────────────────────────────────
# Suppresses the "direnv: loading/unloading ..." lines on every cd.
# Per-call verbosity for debugging: DIRENV_LOG_FORMAT='direnv: %s' direnv reload
export DIRENV_LOG_FORMAT=""

# ── Shell hook ─────────────────────────────────────────────────────────────
case "${DOTFILES_SHELL}" in
    bash|zsh)
        eval "$(direnv hook "${DOTFILES_SHELL}")"
        ;;
    *)
        log_warn "direnv: unsupported shell '${DOTFILES_SHELL}' — skipping hook"
        return 0
        ;;
esac

log_debug "direnv: hook installed (shell=${DOTFILES_SHELL})"

# ── functions ────────────────────────────────────────────────────────────────

# Open the direnv config in $EDITOR.
edit-direnv-config() {
    local config_file="${XDG_CONFIG_HOME:-${HOME}/.config}/direnv/direnv.toml"
    "${EDITOR:-vi}" "${config_file}"
}

# direnv-init-project [path]
# Scaffold a starter .envrc in the given directory (default: cwd).
# Does not overwrite an existing .envrc.
direnv-init-project() {
    local target_dir="${1:-.}"
    local envrc="${target_dir}/.envrc"

    if [[ -f "${envrc}" ]]; then
        log_warn "${envrc} already exists — not overwriting"
        return 1
    fi

    cat > "${envrc}" <<'EOF'
# direnv environment for this project.
# See: https://direnv.net/man/direnv-stdlib.1.html

# Load a .env file alongside this .envrc, if present.
dotenv_if_exists

# Example: pin AWS/Azure context per project
# export AWS_PROFILE=myprofile
# export ARM_SUBSCRIPTION_ID=...

# Example: layout for Python venvs
# layout python3
EOF

    log_info "Created ${envrc}"
    echo "  Run 'direnv allow' in ${target_dir} to activate it."
}
