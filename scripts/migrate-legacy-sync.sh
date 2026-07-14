#!/usr/bin/env bash
# scripts/migrate-legacy-sync.sh
# ─────────────────────────────────────────────────────────────────────────────
# One-shot teardown of the retired per-repo nvim-config-sync / ai-config-sync
# mechanism, for machines that ran the old nvim/ai-tools Ansible roles before
# they were replaced by the generic sync-external engine.
#
# Removes the legacy timers/agents, their sync scripts, and their runtime
# state — but never the config clones themselves (~/.config/nvim and
# ~/.local/share/ai-config), which sync-external adopts in place.
#
# Idempotent and safe to re-run: every removal step checks the target exists
# first, and unit disable/unload calls ignore errors so an already-torn-down
# machine (or one that never had these units) is a clean no-op.
#
# Usage:
#   scripts/migrate-legacy-sync.sh [--yes] [-h|--help]
#
#   --yes, -y     Skip the confirmation prompt (for scripted/non-interactive runs).
#   -h, --help    Show this help.
#
# After running this script, register nvim-config and ai-config as external
# add-on repos — either re-run ./install.sh (it will prompt for them) or hand
# -edit external_synced_repos in ansible/host_vars/localhost.yml — then run:
#   ansible-playbook site.yml --tags sync-external
# See docs/external-sync.md for the full walkthrough.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

ARG_YES="false"

if [[ -t 1 ]] && command -v tput &>/dev/null; then
    _GREEN=$(tput setaf 2)
    _YELLOW=$(tput setaf 3)
    _BOLD=$(tput bold)
    _RESET=$(tput sgr0)
else
    _GREEN="" _YELLOW="" _BOLD="" _RESET=""
fi

info()   { echo "${_GREEN}[INFO]${_RESET}  $*" >&2; }
warn()   { echo "${_YELLOW}[WARN]${_RESET}  $*" >&2; }
header() { { echo; echo "${_BOLD}── $* ${_RESET}"; echo; } >&2; }
die()    { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    cat << EOF
migrate-legacy-sync.sh — tear down the retired nvim-config-sync / ai-config-sync mechanism

Usage: $(basename "$0") [OPTIONS]

  --yes, -y     Skip the confirmation prompt.
  -h, --help    Show this help.

Removes legacy timers/agents, sync scripts, and runtime state. Never removes
~/.config/nvim or ~/.local/share/ai-config — sync-external adopts those
clones in place. Safe to re-run.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y)  ARG_YES="true"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1 — use --help for usage" ;;
        esac
    done
}

confirm() {
    [[ "${ARG_YES}" == "true" ]] && return 0

    local answer=""
    read -r -p "This will remove legacy nvim-config-sync/ai-config-sync units, scripts, and state. Continue? [y/N]: " answer < /dev/tty || true
    [[ "${answer}" == "y" || "${answer}" == "Y" ]]
}

# Populated by the remove_* functions below and printed in the final summary.
REMOVED_PATHS=()

_remove_path_if_present() {
    local path="$1"
    if [[ -e "${path}" || -L "${path}" ]]; then
        rm -rf "${path}"
        info "Removed ${path}"
        REMOVED_PATHS+=("${path}")
    fi
}

remove_linux_units() {
    [[ "$(uname -s)" == "Linux" ]] || return 0

    info "Disabling legacy systemd user timers (errors ignored if already gone)..."
    systemctl --user disable --now nvim-config-sync.timer ai-config-sync.timer &>/dev/null || true

    local unit
    for unit in nvim-config-sync.service nvim-config-sync.timer ai-config-sync.service ai-config-sync.timer; do
        _remove_path_if_present "${HOME}/.config/systemd/user/${unit}"
    done

    systemctl --user daemon-reload &>/dev/null || true
}

remove_macos_agents() {
    [[ "$(uname -s)" == "Darwin" ]] || return 0

    local label
    for label in com.nvim-config.sync com.ai-config.sync; do
        local plist="${HOME}/Library/LaunchAgents/${label}.plist"
        if [[ -f "${plist}" ]]; then
            launchctl unload "${plist}" &>/dev/null || true
        fi
        _remove_path_if_present "${plist}"
    done
}

remove_scripts_and_state() {
    _remove_path_if_present "${HOME}/.local/bin/nvim-config-sync"
    _remove_path_if_present "${HOME}/.local/bin/ai-config-sync"
    _remove_path_if_present "${HOME}/.config/nvim-config"
    _remove_path_if_present "${HOME}/.config/ai-config"
    _remove_path_if_present "${HOME}/.local/share/nvim-config"
    _remove_path_if_present "${HOME}/.local/share/ai-config-sync"
}

print_summary() {
    header "Summary"

    if [[ ${#REMOVED_PATHS[@]} -eq 0 ]]; then
        info "Nothing to remove — this machine has no legacy nvim-config-sync/ai-config-sync state."
    else
        echo "Removed:" >&2
        local p
        for p in "${REMOVED_PATHS[@]}"; do
            echo "  - ${p}" >&2
        done
    fi

    echo >&2
    echo "Preserved (adopted in place by sync-external):" >&2
    echo "  - ${HOME}/.config/nvim" >&2
    echo "  - ${HOME}/.local/share/ai-config" >&2
    echo >&2
    info "Next: register these repos via ./install.sh, or hand-edit"
    info "external_synced_repos in ansible/host_vars/localhost.yml, then run:"
    info "  ansible-playbook site.yml --tags sync-external"
    info "See docs/external-sync.md for the full walkthrough."
}

main() {
    parse_args "$@"

    header "Legacy sync migration"
    info "This tears down the retired nvim-config-sync / ai-config-sync mechanism."
    info "It does not touch ~/.config/nvim or ~/.local/share/ai-config."

    if ! confirm; then
        info "Aborted — no changes made."
        exit 0
    fi

    remove_linux_units
    remove_macos_agents
    remove_scripts_and_state

    print_summary
}

main "$@"
