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

# ── Node / nvm ────────────────────────────────────────────────────────────────
if [[ -d "${HOME}/.nvm" ]]; then
    export NVM_DIR="${HOME}/.nvm"
    # shellcheck disable=SC1091
    [[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"
    # shellcheck disable=SC1091
    [[ -s "${NVM_DIR}/bash_completion" ]] && source "${NVM_DIR}/bash_completion"
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

export PATH
