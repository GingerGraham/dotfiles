#!/usr/bin/env bash
# Terraform / OpenTofu shell completions.
# Sourced when terraform or tofu is present (guarded in loader.sh).

if command -v tofu &>/dev/null; then
    if [[ -n "${BASH_VERSION}" ]]; then
        complete -C tofu tofu 2>/dev/null || true
    fi
fi

if command -v terraform &>/dev/null; then
    if [[ -n "${BASH_VERSION}" ]]; then
        complete -C terraform terraform 2>/dev/null || true
    fi
fi
