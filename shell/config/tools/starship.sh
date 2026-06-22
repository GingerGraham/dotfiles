#!/usr/bin/env bash
# starship prompt engine — loaded by loader.sh only when:
#   - oh-my-posh is NOT present (lost the prompt-engine election), AND
#   - starship IS present
#
# Guard is handled in loader.sh; this file assumes starship is available.
# Uses whatever config is found at $STARSHIP_CONFIG or the XDG default
# (~/.config/starship.toml) — including a pre-existing distro-provided
# config (e.g. Omarchy). The shell role only deploys a default config if
# one is not already present, and never overwrites it afterwards.

case "${DOTFILES_SHELL}" in
    bash|zsh)
        eval "$(starship init "${DOTFILES_SHELL}")"
        ;;
    *)
        log_warn "starship: unsupported shell '${DOTFILES_SHELL}' — skipping init"
        return 0
        ;;
esac

export DOTFILES_PROMPT_ENGINE="starship"
log_debug "starship: initialised (config: ${STARSHIP_CONFIG:-${XDG_CONFIG_HOME:-${HOME}/.config}/starship.toml})"

# ── functions ────────────────────────────────────────────────────────────────

# Open the active starship config in $EDITOR.
if command -v starship >/dev/null 2>&1; then
    edit-starship-config() {
        local config_file="${STARSHIP_CONFIG:-${XDG_CONFIG_HOME:-${HOME}/.config}/starship.toml}"
        "${EDITOR:-vi}" "${config_file}"
    }
fi
