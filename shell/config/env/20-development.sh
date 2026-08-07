#!/usr/bin/env bash
# Development environment — language runtimes, SDK paths.
# No subprocesses; uses directory existence checks only.

# ── Go ────────────────────────────────────────────────────────────────────────
if [[ -d "${HOME}/go" ]]; then
    export GOPATH="${HOME}/go"
    [[ -d "${GOPATH}/bin" ]] && PATH="${GOPATH}/bin:${PATH}"
fi
[[ -d "/usr/local/go/bin" ]] && PATH="/usr/local/go/bin:${PATH}"

# ── Python: uv / pyenv ────────────────────────────────────────────────────────
# uv is the primary Python package/project manager. pyenv remains supported but
# its shims are not installed when uv is present: two shim systems competing for
# `python` on PATH is the same class of problem tenv solved for terraform/tofu.
#
# DOTFILES_PYTHON_MANAGER (set in env/90-local.sh):
#   auto   (default) uv wins if present, otherwise pyenv initialises
#   uv     never initialise pyenv shims
#   pyenv  always initialise pyenv shims, even if uv is present
#   both   same as pyenv; kept as an explicit, self-documenting value
#
# PYENV_ROOT/PATH are set unconditionally below (subprocess-free, matches this
# file's contract) so `pyenv` itself stays callable for management regardless
# of the gate. The gate/eval logic that reads DOTFILES_PYTHON_MANAGER is
# deliberately NOT run inline here: env/90-local.sh — the only place that
# variable is meant to be set — sources *after* this file within loader.sh's
# Tier 1 pass, so reading it here would only ever see the default. Instead
# this defines _dotfiles_init_python_manager, and loader.sh invokes it once,
# later, after 90-local.sh has had its final say (same reasoning as
# dedupe-path running "after all tiers").
if [[ -d "${HOME}/.pyenv" ]]; then
    export PYENV_ROOT="${HOME}/.pyenv"
    PATH="${PYENV_ROOT}/bin:${PATH}"
fi

_dotfiles_init_python_manager() {
    # uv is detected with the `command -v` builtin (no subprocess) —
    # ~/.local/bin is already on PATH from 00-core.sh by this point.
    local uv_present=false
    command -v uv &>/dev/null && uv_present=true

    if [[ "${uv_present}" == "true" ]]; then
        # uv tool install already targets ~/.local/bin by default (verified
        # against current uv docs — the "executable directory" is
        # XDG-derived and resolves to ~/.local/bin on both Linux and macOS);
        # setting this explicitly just makes that deterministic rather than
        # implicit. UV_PYTHON_INSTALL_DIR and UV_TOOL_DIR are deliberately
        # left unset — uv already resolves platform-appropriate locations
        # for those on its own, and forcing an override risks orphaning an
        # existing install's interpreters and tools.
        export UV_TOOL_BIN_DIR="${HOME}/.local/bin"
    fi

    local manager="${DOTFILES_PYTHON_MANAGER:-auto}"
    local init_pyenv_shims=false
    case "${manager}" in
        uv)         ;;
        pyenv|both) init_pyenv_shims=true ;;
        *)          [[ "${uv_present}" == "false" ]] && init_pyenv_shims=true ;;
    esac

    [[ -d "${HOME}/.pyenv" ]] && command -v pyenv &>/dev/null || return 0

    if [[ "${init_pyenv_shims}" == "true" ]]; then
        eval "$(pyenv init - "${DOTFILES_SHELL:-bash}")"
        if pyenv commands 2>/dev/null | grep -q virtualenv-init; then
            eval "$(pyenv virtualenv-init -)"
        fi
        log_debug "python manager: pyenv (DOTFILES_PYTHON_MANAGER=${manager}, uv present=${uv_present})"
    else
        log_debug "python manager: uv (pyenv shims not initialised — DOTFILES_PYTHON_MANAGER=${manager})"
    fi
}

# ── Node / nvm ────────────────────────────────────────────────────────────────
export NVM_DIR="${NVM_DIR:-${HOME}/.nvm}"

if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
    _load_nvm() {
        for _nvm_fn in nvm node npm npx yarn pnpm; do
            declare -f "${_nvm_fn}" &>/dev/null && unset -f "${_nvm_fn}"
        done
        unset _nvm_fn
        # shellcheck disable=SC1091
        source "${NVM_DIR}/nvm.sh"
        # shellcheck disable=SC1091
        [[ -s "${NVM_DIR}/bash_completion" ]] && source "${NVM_DIR}/bash_completion"
    }
    nvm()  { _load_nvm; nvm  "$@"; }
    node() { _load_nvm; node "$@"; }
    npm()  { _load_nvm; npm  "$@"; }
    npx()  { _load_nvm; npx  "$@"; }
fi

# ── tfenv ─────────────────────────────────────────────────────────────────────
if [[ -d "${HOME}/.tfenv" ]]; then
    export TFENV_ROOT="${HOME}/.tfenv"
    [[ -d "${TFENV_ROOT}/bin" ]] && PATH="${TFENV_ROOT}/bin:${PATH}"
fi

# ── Cargo (Rust) ──────────────────────────────────────────────────────────────
if [[ -d "${HOME}/.cargo/bin" ]]; then
    PATH="${HOME}/.cargo/bin:${PATH}"
fi

# ── asdf (universal version manager) ─────────────────────────────────────────
if [[ -f "${HOME}/.asdf/asdf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.asdf/asdf.sh"
fi

# ── tenv (OpenTofu / Terraform version manager) ───────────────────────────────
# tenv manages both terraform and tofu binaries via shims.
# TENV_AUTO_INSTALL causes tenv to auto-install the required version on first use.
if command -v tenv &>/dev/null; then
    export TENV_AUTO_INSTALL=true
fi

export PATH
