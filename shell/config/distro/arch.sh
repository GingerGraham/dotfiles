#!/usr/bin/env bash
# Arch/Manjaro system zsh fragments — sourced before prompt engines
# so distro-provided completions and keybindings are in place

for _arch_zsh_frag in \
    /usr/share/zsh/manjaro-zsh-config \
    /usr/share/zsh/arch-zsh-config; do
    # shellcheck disable=SC1090
    [[ -f "${_arch_zsh_frag}" ]] && source "${_arch_zsh_frag}"
done
unset _arch_zsh_frag

# Manjaro ships its own prompt — only use it if we have no prompt engine
# omp/starship/omz election in loader.sh runs after distro/, so we check post-hoc
# via a hook registered here)
# ── Distro-native prompt availability signal ──────────────────────────────────
if [[ -f /usr/share/zsh/manjaro-zsh-prompt ]]; then
    export _DOTFILES_DISTRO_PROMPT_FILE="/usr/share/zsh/manjaro-zsh-prompt"
else
    export _DOTFILES_DISTRO_PROMPT_FILE=""
fi
