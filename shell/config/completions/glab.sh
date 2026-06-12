#!/usr/bin/env bash
# GitLab CLI completions — version-stamped cache.

_glab_cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/dotfiles/completions"
_glab_version="$(glab --version 2>/dev/null | head -1 | awk '{print $3}')"

if [[ -n "${_glab_version}" ]]; then
    _glab_cache="${_glab_cache_dir}/glab.${DOTFILES_SHELL}.${_glab_version}.sh"

    if [[ ! -f "${_glab_cache}" ]]; then
        mkdir -p "${_glab_cache_dir}"
        if [[ -n "${ZSH_VERSION}" ]]; then
            setopt nullglob
        else
            shopt -s nullglob
        fi
        for _stale in "${_glab_cache_dir}"/glab."${DOTFILES_SHELL}".*.sh; do
            [[ "${_stale}" != "${_glab_cache}" ]] && rm -f "${_stale}"
        done
        if [[ -n "${ZSH_VERSION}" ]]; then
            unsetopt nullglob
        else
            shopt -u nullglob
        fi
        unset _stale
        glab completion -s "${DOTFILES_SHELL}" 2>/dev/null > "${_glab_cache}" \
            || rm -f "${_glab_cache}"
    fi
    # shellcheck disable=SC1090
    [[ -f "${_glab_cache}" ]] && source "${_glab_cache}"
fi

unset _glab_cache_dir _glab_version _glab_cache
