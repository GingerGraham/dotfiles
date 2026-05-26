#!/usr/bin/env bash
# Core environment — PATH extensions and fundamental exports.
# No subprocesses; all assignments are pure bash.

# ── XDG base directories ──────────────────────────────────────────────────────
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"

# ── PATH extensions ───────────────────────────────────────────────────────────
# User-local binaries take priority over system paths
[[ -d "${HOME}/.local/bin" ]] && PATH="${HOME}/.local/bin:${PATH}"
[[ -d "${HOME}/bin" ]]        && PATH="${HOME}/bin:${PATH}"

export PATH

# ── Locale ────────────────────────────────────────────────────────────────────
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

# ── History ───────────────────────────────────────────────────────────────────
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL="ignoredups:erasedups"

# ── Dotfiles repository ───────────────────────────────────────────────────────
export DOTFILES_REPO_DIR="${HOME}/Projects/Personal/GitHub/dotfiles"
