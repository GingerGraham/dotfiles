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
# Thin wrapper — install-azure (lazy/installers-iac.sh) already handles both
# the fresh-install and update-in-place cases across every distro and macOS.
# Kept here as a short, memorable name for anyone reaching for "az-update" out
# of habit.
az-update() {
    install-azure
}
