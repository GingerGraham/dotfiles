#!/usr/bin/env bash
# GitHub CLI shell completions — cached to avoid network calls at startup.

_gh_completion_cache="${XDG_CACHE_HOME:-${HOME}/.cache}/dotfiles/completions/gh.${DOTFILES_SHELL}.sh"

if [[ -n "${BASH_VERSION}" ]]; then
    if [[ ! -f "${_gh_completion_cache}" ]]; then
        mkdir -p "$(dirname "${_gh_completion_cache}")"
        gh completion -s bash 2>/dev/null > "${_gh_completion_cache}" || rm -f "${_gh_completion_cache}"
    fi
    # shellcheck disable=SC1090
    [[ -f "${_gh_completion_cache}" ]] && source "${_gh_completion_cache}"
elif [[ -n "${ZSH_VERSION}" ]]; then
    if [[ ! -f "${_gh_completion_cache}" ]]; then
        mkdir -p "$(dirname "${_gh_completion_cache}")"
        gh completion -s zsh 2>/dev/null > "${_gh_completion_cache}" || rm -f "${_gh_completion_cache}"
    fi
    # shellcheck disable=SC1090
    [[ -f "${_gh_completion_cache}" ]] && source "${_gh_completion_cache}"
fi
unset _gh_completion_cache
