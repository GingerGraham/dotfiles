#!/usr/bin/env bash
# kubectl shell completions.
# Sourced when kubectl is present (guarded in loader.sh).

if [[ -n "${BASH_VERSION}" ]]; then
    # shellcheck disable=SC1090
    source <(kubectl completion bash 2>/dev/null) || true
    # Make completions work for the 'k' alias too
    complete -o default -F __start_kubectl k 2>/dev/null || true
elif [[ -n "${ZSH_VERSION}" ]]; then
    # shellcheck disable=SC1090
    source <(kubectl completion zsh 2>/dev/null) || true
fi
