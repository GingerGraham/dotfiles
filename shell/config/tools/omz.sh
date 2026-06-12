#!/usr/bin/env bash
# oh-my-zsh prompt engine — loaded by loader.sh only when:
#   - oh-my-posh and starship are NOT present (lost the prompt-engine election), AND
#   - ~/.oh-my-zsh exists, AND
#   - the current shell is zsh
#
# Guard is handled in loader.sh; this file assumes omz is available.
# bash-sourcing this file is a no-op (the ZSH_VERSION guard below protects it).

[[ -z "${ZSH_VERSION}" ]] && return 0

# ── Core paths ────────────────────────────────────────────────────────────────
export ZSH="${HOME}/.oh-my-zsh"

# ── Theme ─────────────────────────────────────────────────────────────────────
ZSH_THEME="jonathan"

# ── Update behaviour ──────────────────────────────────────────────────────────
zstyle ':omz:update' mode auto
zstyle ':omz:update' frequency 7

# ── History ───────────────────────────────────────────────────────────────────
HISTCONTROL=ignoreboth
# shellcheck disable=SC2034
HIST_STAMPS="yyyy-mm-dd"

# ── UX ────────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2034
ENABLE_CORRECTION="true"
# shellcheck disable=SC2034
COMPLETION_WAITING_DOTS="true"

# ── Plugins ───────────────────────────────────────────────────────────────────
# Keep this list minimal — each plugin adds startup time.
# Tool-specific completions live in shell/config/completions/ and load separately.
# shellcheck disable=SC2034
plugins=(
    aliases
    git
    kubectl
    terraform
)

# ── Init ──────────────────────────────────────────────────────────────────────
# shellcheck disable=SC1091
source "${ZSH}/oh-my-zsh.sh"
log_debug "oh-my-zsh: initialised with theme '${ZSH_THEME}'"

export DOTFILES_PROMPT_ENGINE="omz"
