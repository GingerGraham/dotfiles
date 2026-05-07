#!/usr/bin/env bash
# GitHub CLI shell completions.
# Sourced when gh is present (guarded in loader.sh).

if [[ -n "${BASH_VERSION}" ]]; then
    # shellcheck disable=SC1090
    source <(gh completion -s bash 2>/dev/null) || true
elif [[ -n "${ZSH_VERSION}" ]]; then
    # shellcheck disable=SC1090
    source <(gh completion -s zsh 2>/dev/null) || true
fi
