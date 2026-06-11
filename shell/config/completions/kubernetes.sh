#!/usr/bin/env bash
# kubectl shell completions — version-stamped cache, no API calls at startup.

_kc_cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/dotfiles/completions"

# --client prevents any contact with the API server.
# Parse the clientVersion.gitVersion field directly from JSON — no jq required.
_kc_version="$(kubectl version --client -o json 2>/dev/null \
    | grep '"gitVersion"' | head -1 \
    | sed 's/.*"gitVersion": *"\([^"]*\)".*/\1/')"

if [[ -n "${_kc_version}" ]]; then
    _kc_cache="${_kc_cache_dir}/kubectl.${DOTFILES_SHELL}.${_kc_version}.sh"

    if [[ ! -f "${_kc_cache}" ]]; then
        mkdir -p "${_kc_cache_dir}"
        # nullglob: unmatched glob expands to nothing instead of erroring (zsh nomatch)
        if [[ -n "${ZSH_VERSION}" ]]; then
            setopt nullglob
        else
            shopt -s nullglob
        fi
        for _stale in "${_kc_cache_dir}"/kubectl."${DOTFILES_SHELL}".*.sh; do
            [[ "${_stale}" != "${_kc_cache}" ]] && rm -f "${_stale}"
        done
        if [[ -n "${ZSH_VERSION}" ]]; then
            unsetopt nullglob
        else
            shopt -u nullglob
        fi
        unset _stale
        kubectl completion "${DOTFILES_SHELL}" 2>/dev/null > "${_kc_cache}" \
            || rm -f "${_kc_cache}"
    fi
    # shellcheck disable=SC1090
    [[ -f "${_kc_cache}" ]] && source "${_kc_cache}"
fi

# bash only: make completions work for the 'k' alias
[[ -n "${BASH_VERSION}" ]] && complete -o default -F __start_kubectl k 2>/dev/null || true

unset _kc_cache_dir _kc_version _kc_cache
