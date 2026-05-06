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
export NVM_DIR="${NVM_DIR:-${HOME}/.nvm}"

# ── tfenv ─────────────────────────────────────────────────────────────────────
[[ -d "${HOME}/.tfenv/bin" ]] && PATH="${HOME}/.tfenv/bin:${PATH}"

# ── Cargo (Rust) ──────────────────────────────────────────────────────────────
[[ -d "${HOME}/.cargo/bin" ]] && PATH="${HOME}/.cargo/bin:${PATH}"

export PATH
