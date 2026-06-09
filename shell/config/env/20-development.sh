#!/usr/bin/env bash
# Development environment — language runtimes, SDK paths.
# No subprocesses; uses directory existence checks only.

# ── Go ────────────────────────────────────────────────────────────────────────
if [[ -d "${HOME}/go" ]]; then
    export GOPATH="${HOME}/go"
    [[ -d "${GOPATH}/bin" ]] && PATH="${GOPATH}/bin:${PATH}"
fi
[[ -d "/usr/local/go/bin" ]] && PATH="/usr/local/go/bin:${PATH}"

# ── Python / pyenv ────────────────────────────────────────────────────────────
if [[ -d "${HOME}/.pyenv" ]]; then
    export PYENV_ROOT="${HOME}/.pyenv"
    PATH="${PYENV_ROOT}/bin:${PATH}"
fi
# Activate shims and shell integration — must run after PYENV_ROOT is in PATH.
# pyenv init adds shims to PATH and sets up the version-switching hooks.
# virtualenv-init is only called if the plugin is actually installed.
if [[ -d "${HOME}/.pyenv" ]] && command -v pyenv &>/dev/null; then
    eval "$(pyenv init - "${DOTFILES_SHELL:-bash}")"
    if pyenv commands 2>/dev/null | grep -q virtualenv-init; then
        eval "$(pyenv virtualenv-init -)"
    fi
fi

# ── Node / nvm ────────────────────────────────────────────────────────────────
export NVM_DIR="${NVM_DIR:-${HOME}/.nvm}"

if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
    _load_nvm() {
        unset -f nvm node npm npx yarn pnpm
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
