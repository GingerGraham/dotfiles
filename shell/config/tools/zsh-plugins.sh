#!/usr/bin/env zsh
# Zsh plugins — autosuggestions and syntax highlighting.
# Sourced by loader.sh only when DOTFILES_SHELL == "zsh".
#
# Plugin resolution order (first path that exists wins):
#   1. ~/.zsh/<plugin>/                              manual install
#   2. /usr/share/<plugin>/                          system package (dnf/apt)
#   3. ~/.oh-my-zsh/custom/plugins/<plugin>/         OMZ-managed
#
# zsh-syntax-highlighting MUST be sourced last — it wraps the zle widgets
# set up by compinit and autosuggestions. Changing this order breaks both.

[[ -z "${ZSH_VERSION}" ]] && return 0

# ── zsh-autosuggestions ───────────────────────────────────────────────────────
_zsh_autosuggest_loaded=false

if [[ -f "${HOME}/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh" ]]; then
    source "${HOME}/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh"
    _zsh_autosuggest_loaded=true
elif [[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
    source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
    _zsh_autosuggest_loaded=true
elif [[ -f "${HOME}/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.plugin.zsh" ]]; then
    source "${HOME}/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.plugin.zsh"
    _zsh_autosuggest_loaded=true
fi

if [[ "${_zsh_autosuggest_loaded}" == "true" ]]; then
    ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#c6c6c6"
    ZSH_AUTOSUGGEST_STRATEGY=(history completion)
    log_debug "zsh-plugins: autosuggestions loaded"
else
    log_warn "zsh-plugins: zsh-autosuggestions not found — install via 'sudo dnf install zsh-autosuggestions' or clone to ~/.zsh/zsh-autosuggestions/"
fi
unset _zsh_autosuggest_loaded

# ── zsh-syntax-highlighting ───────────────────────────────────────────────────
# Source LAST — wraps ZLE widgets installed by everything above.
_zsh_syntax_loaded=false

if [[ -f "${HOME}/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]]; then
    source "${HOME}/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
    _zsh_syntax_loaded=true
elif [[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]]; then
    source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
    _zsh_syntax_loaded=true
elif [[ -f "${HOME}/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.plugin.zsh" ]]; then
    source "${HOME}/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.plugin.zsh"
    _zsh_syntax_loaded=true
fi

if [[ "${_zsh_syntax_loaded}" == "true" ]]; then
    log_debug "zsh-plugins: syntax highlighting loaded"
else
    log_warn "zsh-plugins: zsh-syntax-highlighting not found — install via 'sudo dnf install zsh-syntax-highlighting' or clone to ~/.zsh/zsh-syntax-highlighting/"
fi
unset _zsh_syntax_loaded
