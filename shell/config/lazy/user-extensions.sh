#!/usr/bin/env bash
# lazy/user-extensions.sh — explicit, uncached check for user-defined config
# extensions (DOTFILES_USER_EXT_DIR — see loader.sh and docs/user-extensions.md).
#
# Stub registration for this file is gated in loader.sh on
# DOTFILES_USER_EXT_ENABLED and DOTFILES_USER_EXT_DIR containing at least one
# *.sh file, so check-user-extensions never shows up in get-functions on a
# machine with an empty or absent user directory.
#
# loader.sh already runs a `bash -n` syntax smoke-test per file on every shell
# start (cached via a stamp file so the steady state costs nothing). This
# module is the full, on-demand pass: syntax + shellcheck lint (if installed)
# + name-collision reporting against $SHELL_CONFIG_DIR. Shellcheck is not run
# at startup because it costs 100ms+ per file.

# check-user-extensions [--quiet]
# Full pass over every *.sh in DOTFILES_USER_EXT_DIR, ignoring the startup
# stamp. Exits non-zero only if at least one file fails the bash -n syntax
# check — a missing shellcheck is informational, and name collisions are a
# breadcrumb, not an error: user files load last, so shadowing a repo-defined
# function or alias is the intended semantic, not a mistake.
check-user-extensions() {
    local _quiet=false
    [[ "${1:-}" == "--quiet" ]] && _quiet=true

    if [[ ! -d "${DOTFILES_USER_EXT_DIR}" ]]; then
        log_warn "check-user-extensions: ${DOTFILES_USER_EXT_DIR} does not exist"
        return 0
    fi

    if [[ -n "${ZSH_VERSION}" ]]; then
        setopt nullglob
    else
        shopt -s nullglob
    fi
    local -a _files=( "${DOTFILES_USER_EXT_DIR}"/*.sh )
    if [[ -n "${ZSH_VERSION}" ]]; then
        unsetopt nullglob
    else
        shopt -u nullglob
    fi

    if [[ ${#_files[@]} -eq 0 ]]; then
        log_warn "check-user-extensions: no *.sh files in ${DOTFILES_USER_EXT_DIR}"
        return 0
    fi

    local _f _fail=false

    # ── 1. Syntax ─────────────────────────────────────────────────────────────
    # bash -n runs even under zsh — it's a syntax smoke-test for "is this
    # obviously broken", not a compatibility gate, and zsh has no equivalent
    # that is safe to run on arbitrary user files.
    for _f in "${_files[@]}"; do
        if bash -n "${_f}" 2>/dev/null; then
            [[ "${_quiet}" == "false" ]] && log_info "check-user-extensions: OK    ${_f}"
        else
            log_warn "check-user-extensions: FAIL  ${_f} — syntax error (bash -n)"
            _fail=true
        fi
    done

    # ── 2. Lint (informational only — never fails the function) ─────────────
    if command -v shellcheck &>/dev/null; then
        for _f in "${_files[@]}"; do
            [[ "${_quiet}" == "false" ]] && log_info "check-user-extensions: shellcheck ${_f}"
            shellcheck "${_f}" || true
        done
    else
        [[ "${_quiet}" == "false" ]] && log_info "check-user-extensions: shellcheck not installed — skipping lint pass"
    fi

    # ── 3. Collisions (informational only) ───────────────────────────────────
    # Reuse the same extraction helpers get-functions uses, on the same
    # repo-wide file collection, rather than writing new grep logic here.
    local -a _repo_files=()
    local _globstar_was_off=0
    if [[ -n "${BASH_VERSION}" ]]; then
        shopt -q globstar || { shopt -s globstar; _globstar_was_off=1; }
    fi
    local _sf
    while IFS= read -r _sf; do
        [[ -n "${_sf}" ]] && _repo_files+=("${_sf}")
    done < <(printf '%s\n' "${SHELL_CONFIG_DIR}"/**/*.sh 2>/dev/null | grep -Fv "/loader.sh")
    if [[ -n "${BASH_VERSION}" && "${_globstar_was_off}" -eq 1 ]]; then
        shopt -u globstar
    fi

    if [[ ${#_repo_files[@]} -gt 0 ]]; then
        local _repo_fn_names _repo_alias_names _n
        _repo_fn_names="$(_extract_function_names "${_repo_files[@]}")"
        _repo_alias_names="$(_extract_alias_names "${_repo_files[@]}")"

        while IFS= read -r _n; do
            [[ -z "${_n}" ]] && continue
            if printf '%s\n' "${_repo_fn_names}" | grep -Fxq "${_n}"; then
                [[ "${_quiet}" == "false" ]] && log_info "check-user-extensions: '${_n}' shadows a function already defined under ${SHELL_CONFIG_DIR} — expected, user files load last"
            fi
        done < <(_extract_function_names "${_files[@]}")

        while IFS= read -r _n; do
            [[ -z "${_n}" ]] && continue
            if printf '%s\n' "${_repo_alias_names}" | grep -Fxq "${_n}"; then
                [[ "${_quiet}" == "false" ]] && log_info "check-user-extensions: '${_n}' shadows an alias already defined under ${SHELL_CONFIG_DIR} — expected, user files load last"
            fi
        done < <(_extract_alias_names "${_files[@]}")
    fi

    # ── 4. Stamp ──────────────────────────────────────────────────────────────
    # A clean manual run also short-circuits the next startup check.
    if [[ "${_fail}" == "false" ]]; then
        local _cache_dir="${XDG_CACHE_HOME}/dotfiles"
        [[ -d "${_cache_dir}" ]] || mkdir -p "${_cache_dir}"
        : > "${_cache_dir}/user-ext.stamp"
    fi

    [[ "${_fail}" == "true" ]] && return 1
    return 0
}
