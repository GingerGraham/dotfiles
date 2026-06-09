#!/usr/bin/env bash
# kubectl shell completions — cached to avoid blocking API calls at startup.

_kubectl_completion_cache="${XDG_CACHE_HOME:-${HOME}/.cache}/dotfiles/completions/kubectl.${DOTFILES_SHELL}.sh"

if [[ -n "${BASH_VERSION}" ]]; then
    if [[ ! -f "${_kubectl_completion_cache}" ]]; then
        mkdir -p "$(dirname "${_kubectl_completion_cache}")"
        kubectl completion bash 2>/dev/null > "${_kubectl_completion_cache}" || rm -f "${_kubectl_completion_cache}"
    fi
    # shellcheck disable=SC1090
    [[ -f "${_kubectl_completion_cache}" ]] && source "${_kubectl_completion_cache}"
    complete -o default -F __start_kubectl k 2>/dev/null || true
elif [[ -n "${ZSH_VERSION}" ]]; then
    if [[ ! -f "${_kubectl_completion_cache}" ]]; then
        mkdir -p "$(dirname "${_kubectl_completion_cache}")"
        kubectl completion zsh 2>/dev/null > "${_kubectl_completion_cache}" || rm -f "${_kubectl_completion_cache}"
    fi
    # shellcheck disable=SC1090
    [[ -f "${_kubectl_completion_cache}" ]] && source "${_kubectl_completion_cache}"
fi
unset _kubectl_completion_cache
