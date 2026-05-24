#!/usr/bin/env bash
# Bash-specific interactive shell configuration.
# Sourced by loader.sh only when DOTFILES_SHELL == "bash".
# Must not contain zsh-specific constructs.

# ── History ───────────────────────────────────────────────────────────────────
# Append to the history file on exit rather than overwriting it.
# HISTSIZE/HISTFILESIZE/HISTCONTROL are set in env/00-core.sh.
shopt -s histappend

# ── Window size ───────────────────────────────────────────────────────────────
# Re-check terminal dimensions after each command so LINES and COLUMNS stay
# accurate after a resize.
shopt -s checkwinsize

# ── Recursive globbing ────────────────────────────────────────────────────────
# Allow ** to match across directory boundaries (bash 4+).
# Silently ignored on bash 3 (macOS system bash).
shopt -s globstar 2>/dev/null || true

# ── lesspipe ──────────────────────────────────────────────────────────────────
# Allows less to display non-text files (compressed archives, PDFs, etc.)
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# ── System bash-completion ────────────────────────────────────────────────────
# Only source if not already loaded and not in posix mode (which disables it).
if ! shopt -oq posix; then
    if [[ -f /usr/share/bash-completion/bash_completion ]]; then
        # shellcheck disable=SC1091
        source /usr/share/bash-completion/bash_completion
    elif [[ -f /etc/bash_completion ]]; then
        # shellcheck disable=SC1091
        source /etc/bash_completion
    fi
fi

# ── asdf bash completions ─────────────────────────────────────────────────────
# asdf.sh (sourced in env/20-development.sh) initialises shims and PATH.
# The bash completion script is a separate file and is required for tab
# completion of asdf subcommands — it is not loaded by asdf.sh itself.
if [[ -f "${HOME}/.asdf/completions/asdf.bash" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.asdf/completions/asdf.bash"
fi

log_debug "bash: shell-specific config loaded"
