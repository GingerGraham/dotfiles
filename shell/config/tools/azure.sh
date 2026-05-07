#!/usr/bin/env bash
# Azure tool configuration.
# Sourced only when az CLI is present (guarded in loader.sh).

# ── aliases ───────────────────────────────────────────────────────────────────
alias azl="az login"
alias azlo="az logout"
alias azs="az account show"
alias azsl="az account list --output table"
alias azss="az account set --subscription"

# ── functions ─────────────────────────────────────────────────────────────────
az-update() {
    log_info "Updating Azure CLI..."
    if [[ "${DOTFILES_OS}" == "Mac" ]] && command -v brew &>/dev/null; then
        brew upgrade azure-cli
    elif command -v apt &>/dev/null; then
        local elevation_cmd
        elevation_cmd="$(get-elevation-command)" || return 1
        ${elevation_cmd} apt-get update && ${elevation_cmd} apt-get install --only-upgrade -y azure-cli
    elif command -v dnf &>/dev/null; then
        local elevation_cmd
        elevation_cmd="$(get-elevation-command)" || return 1
        ${elevation_cmd} dnf update -y azure-cli
    else
        log_warn "Unable to determine update method for Azure CLI on this platform"
        return 1
    fi
    log_info "Azure CLI updated to $(az version --query '"azure-cli"' -o tsv 2>/dev/null)"
}
