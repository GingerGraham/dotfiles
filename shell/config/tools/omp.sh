#!/usr/bin/env bash
# oh-my-posh prompt engine — loaded by loader.sh only when `oh-my-posh` is
# present AND this shell won the prompt-engine election (omp > omz).
#
# Guard is handled in loader.sh; this file assumes omp is available.

# ── Theme resolution ──────────────────────────────────────────────────────────
# XDG-standard install location used by `oh-my-posh init` and the official
# install script. Fallback for manual ~/bin installs that store themes locally.
OMP_THEME="${OMP_THEME:-atomic}"

if [[ -d "${HOME}/.cache/oh-my-posh/themes" ]]; then
    OMP_THEME_DIR="${HOME}/.cache/oh-my-posh/themes"
elif [[ -d "${HOME}/themes" ]]; then
    OMP_THEME_DIR="${HOME}/themes"
else
    OMP_THEME_DIR=""
    log_warn "oh-my-posh: theme directory not found; falling back to default prompt"
fi

export OMP_THEME OMP_THEME_DIR

# ── Init ──────────────────────────────────────────────────────────────────────
if [[ -n "${OMP_THEME_DIR}" ]] && [[ -f "${OMP_THEME_DIR}/${OMP_THEME}.omp.json" ]]; then
    eval "$(oh-my-posh init "${DOTFILES_SHELL}" --config "${OMP_THEME_DIR}/${OMP_THEME}.omp.json")"
    log_debug "oh-my-posh: initialised with theme '${OMP_THEME}'"
else
    eval "$(oh-my-posh init "${DOTFILES_SHELL}")"
    log_debug "oh-my-posh: initialised with built-in default (theme '${OMP_THEME}' not found)"
fi

export DOTFILES_PROMPT_ENGINE="omp"

# ── aliases ───────────────────────────────────────────────────────────────────
# alias omp-themes="ls '\${OMP_THEME_DIR}'"

# ── functions ─────────────────────────────────────────────────────────────────

# List available themes in the terminal with live previews.
omp-themes() {
    if [[ -z "${OMP_THEME_DIR}" ]]; then
        log_error "omp-themes: OMP_THEME_DIR is not set"
        return 1
    fi
    find "${OMP_THEME_DIR}" -maxdepth 1 -type f -name "*.omp.json" | while read -r theme_file; do
        local theme_name
        theme_name="$(basename "${theme_file}" .omp.json)"
        echo "Theme: ${theme_name}"
        oh-my-posh --config "${theme_file}" --print-config
        echo
    done

}

# Temporarily switch to a different theme in the current session.
set-omp-theme() {
    if [[ -z "${1}" ]]; then
        log_error "set-omp-theme: no theme name provided"
        echo "Usage:   set-omp-theme <theme_name>"
        echo "Example: set-omp-theme jandedobbeleer"
        echo "Themes:  https://ohmyposh.dev/docs/themes  |  omp-themes"
        return 1
    fi
    if [[ "${#}" -gt 1 ]]; then
        log_error "set-omp-theme: expected 1 argument, got ${#}"
        echo "Usage:   set-omp-theme <theme_name>"
        return 1
    fi
    if [[ -z "${OMP_THEME_DIR}" ]]; then
        log_error "set-omp-theme: OMP_THEME_DIR is not set"
        return 1
    fi
    if [[ ! -f "${OMP_THEME_DIR}/${1}.omp.json" ]]; then
        log_error "set-omp-theme: theme '${1}' not found in ${OMP_THEME_DIR}"
        echo "Run 'omp-themes' to list available themes."
        return 1
    fi
    eval "$(oh-my-posh init "${DOTFILES_SHELL}" --config "${OMP_THEME_DIR}/${1}.omp.json")"
    OMP_THEME="${1}"
    log_debug "oh-my-posh: switched to theme '${1}' for this session"
}

# Permanently update OMP_THEME in this file so the theme persists across sessions.
set-omp-theme-permanent() {
    if [[ -z "${1}" ]]; then
        log_error "set-omp-theme-permanent: no theme name provided"
        echo "Usage:   set-omp-theme-permanent <theme_name>"
        return 1
    fi
    if [[ "${#}" -gt 1 ]]; then
        log_error "set-omp-theme-permanent: expected 1 argument, got ${#}"
        echo "Usage:   set-omp-theme-permanent <theme_name>"
        return 1
    fi
    if [[ -z "${OMP_THEME_DIR}" ]]; then
        log_error "set-omp-theme-permanent: OMP_THEME_DIR is not set"
        return 1
    fi
    if [[ ! -f "${OMP_THEME_DIR}/${1}.omp.json" ]]; then
        log_error "set-omp-theme-permanent: theme '${1}' not found in ${OMP_THEME_DIR}"
        echo "Run 'omp-themes' to list available themes."
        return 1
    fi
    # Apply in this session
    eval "$(oh-my-posh init "${DOTFILES_SHELL}" --config "${OMP_THEME_DIR}/${1}.omp.json")"
    # Persist in this file
    local this_file="${SHELL_CONFIG_DIR}/tools/omp.sh"
    sed -i "s/^OMP_THEME=\".*\"/OMP_THEME=\"${1}\"/" "${this_file}"
    OMP_THEME="${1}"
    log_info "oh-my-posh: theme '${1}' set permanently in ${this_file}"
}

# Update oh-my-posh binary in-place using the official install script.
update-omp() {
    local omp_dir
    omp_dir="$(dirname "$(command -v oh-my-posh)")"
    log_info "Updating oh-my-posh binary in ${omp_dir} ..."
    curl -s https://ohmyposh.dev/install.sh | bash -s -- -d "${omp_dir}"
    log_info "oh-my-posh updated — restart your shell or run: source-shrc"
}
