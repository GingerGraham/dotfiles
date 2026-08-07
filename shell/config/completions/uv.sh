#!/usr/bin/env bash
# uv completions — version-stamped cache.

_uv_cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/dotfiles/completions"
_uv_version="$(uv --version 2>/dev/null | awk '{print $2}')"

if [[ -n "${_uv_version}" ]]; then
    _uv_cache="${_uv_cache_dir}/uv.${DOTFILES_SHELL}.${_uv_version}.sh"

    if [[ ! -f "${_uv_cache}" ]]; then
        mkdir -p "${_uv_cache_dir}"
        # nullglob: unmatched glob expands to nothing instead of erroring (zsh nomatch)
        if [[ -n "${ZSH_VERSION}" ]]; then
            setopt nullglob
        else
            shopt -s nullglob
        fi
        for _stale in "${_uv_cache_dir}"/uv."${DOTFILES_SHELL}".*.sh; do
            [[ "${_stale}" != "${_uv_cache}" ]] && rm -f "${_stale}"
        done
        if [[ -n "${ZSH_VERSION}" ]]; then
            unsetopt nullglob
        else
            shopt -u nullglob
        fi
        unset _stale
        uv generate-shell-completion "${DOTFILES_SHELL}" 2>/dev/null > "${_uv_cache}" \
            || rm -f "${_uv_cache}"
    fi
    # shellcheck disable=SC1090
    [[ -f "${_uv_cache}" ]] && source "${_uv_cache}"
fi

unset _uv_cache_dir _uv_version _uv_cache
