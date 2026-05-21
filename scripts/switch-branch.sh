#!/usr/bin/env bash
# scripts/switch-branch.sh
# Manages dotfiles branch targeting and dev mode.
# Deployed as a stable wrapper at ~/.local/bin/dotfiles-branch by the sync Ansible role.
#
# DEV_MODE is persisted in sync.conf so it survives reboots.
# All git operations happen against DOTFILES_DIR as the current user.

set -euo pipefail

SYNC_CONF="${XDG_CONFIG_HOME:-${HOME}/.config}/dotfiles/sync.conf"
STATE_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/dotfiles"
MAIN_BRANCH="main"

# ── Config helpers ────────────────────────────────────────────────────────────

_conf_require() {
    if [[ ! -r "$SYNC_CONF" ]]; then
        echo "ERROR: sync.conf not found at $SYNC_CONF" >&2
        echo "Run install.sh first, or initialise with: dotfiles-branch --init <repo-url> <dotfiles-dir>" >&2
        exit 1
    fi
}

_conf_load() {
    _conf_require
    # shellcheck source=/dev/null
    source "$SYNC_CONF"
    : "${DOTFILES_DIR:?DOTFILES_DIR not set in $SYNC_CONF}"
    GIT_BRANCH="${GIT_BRANCH:-$MAIN_BRANCH}"
    DEV_MODE="${DEV_MODE:-false}"
}

# sed-based in-place key update; adds the key if absent
_conf_set() {
    local key="$1" value="$2"
    _conf_require
    if grep -q "^${key}=" "$SYNC_CONF"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$SYNC_CONF"
    else
        echo "${key}=\"${value}\"" >> "$SYNC_CONF"
    fi
}

# ── Git helpers ───────────────────────────────────────────────────────────────

_working_branch() {
    git -C "$DOTFILES_DIR" branch --show-current 2>/dev/null || echo "unknown"
}

_remote_branch_exists() {
    git -C "$DOTFILES_DIR" fetch origin "$1" 2>/dev/null
    git -C "$DOTFILES_DIR" ls-remote --exit-code --heads origin "$1" > /dev/null 2>&1
}

# ── Timer helpers ─────────────────────────────────────────────────────────────

_timer_status() {
    # Works on both Linux (systemd --user) and macOS (launchd)
    if command -v systemctl > /dev/null 2>&1; then
        systemctl --user is-active dotfiles-sync.timer 2>/dev/null || echo "inactive/unknown"
    elif command -v launchctl > /dev/null 2>&1; then
        launchctl list | grep -q "com.dotfiles.sync" && echo "active" || echo "inactive"
    else
        echo "unknown"
    fi
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_status() {
    _conf_load

    local working last_sync timer_state
    working=$(_working_branch)
    last_sync="never"
    [[ -f "${STATE_DIR}/last-sync" ]] && last_sync=$(cat "${STATE_DIR}/last-sync")
    timer_state=$(_timer_status)

    # Derive a human-readable sync state
    local sync_state
    if [[ "$DEV_MODE" == "true" ]]; then
        sync_state="suspended (dev mode)"
    elif [[ "$timer_state" == "active" ]]; then
        sync_state="active"
    else
        sync_state="timer not running"
    fi

    # Flag mismatches that need attention
    local branch_note=""
    if [[ "$working" != "$GIT_BRANCH" ]]; then
        branch_note="  *** working copy does not match configured branch ***"
    fi

    echo ""
    echo "  Dotfiles sync status"
    echo "  ────────────────────────────────────"
    printf "  %-16s %s\n" "Repo:"        "$DOTFILES_DIR"
    printf "  %-16s %s\n" "Tracking:"    "$GIT_BRANCH"
    printf "  %-16s %s\n" "Working copy:" "$working"
    printf "  %-16s %s\n" "Dev mode:"    "$DEV_MODE"
    printf "  %-16s %s\n" "Sync:"        "$sync_state"
    printf "  %-16s %s\n" "Last synced:" "$last_sync"
    [[ -n "$branch_note" ]] && echo "$branch_note"
    echo ""
}

cmd_switch() {
    local target="$1"
    _conf_load

    local working
    working=$(_working_branch)

    if [[ "$target" == "$working" && "$target" == "$GIT_BRANCH" ]]; then
        echo "Already on '${target}'"
        [[ "$DEV_MODE" == "true" ]] && echo "(dev mode is active — sync is suspended)"
        return 0
    fi

    echo "Fetching '${target}' from origin..."
    if ! _remote_branch_exists "$target"; then
        echo "ERROR: Branch '${target}' not found on origin" >&2
        exit 1
    fi

    # Git operations first — fail fast before touching config
    git -C "$DOTFILES_DIR" checkout "$target" 2>/dev/null \
        || git -C "$DOTFILES_DIR" checkout -b "$target" "origin/${target}"
    git -C "$DOTFILES_DIR" reset --hard "origin/${target}"

    _conf_set "GIT_BRANCH" "$target"

    if [[ "$target" == "$MAIN_BRANCH" ]]; then
        _conf_set "DEV_MODE" "false"
        echo "Switched to '${MAIN_BRANCH}' — dev mode off, sync resumed"
    else
        _conf_set "DEV_MODE" "true"
        echo "Switched to '${target}' — dev mode on, sync suspended"
        echo "Run 'dotfiles-branch --resume' when done to return to ${MAIN_BRANCH}"
    fi
}

cmd_dev() {
    # Suspend sync on the current branch without switching
    _conf_load

    if [[ "$DEV_MODE" == "true" ]]; then
        echo "Dev mode already active (branch: ${GIT_BRANCH})"
        return 0
    fi

    _conf_set "DEV_MODE" "true"
    echo "Dev mode enabled — sync suspended on '${GIT_BRANCH}'"
    echo "Make your changes, then run 'dotfiles-branch --resume' when ready"
}

cmd_resume() {
    # Return to main and re-enable sync
    _conf_load

    local working
    working=$(_working_branch)

    if [[ "$working" == "$MAIN_BRANCH" && "$GIT_BRANCH" == "$MAIN_BRANCH" && "$DEV_MODE" == "false" ]]; then
        echo "Already on '${MAIN_BRANCH}' with sync active — nothing to do"
        return 0
    fi

    echo "Returning to '${MAIN_BRANCH}'..."
    git -C "$DOTFILES_DIR" fetch origin "$MAIN_BRANCH"
    git -C "$DOTFILES_DIR" checkout "$MAIN_BRANCH"
    git -C "$DOTFILES_DIR" reset --hard "origin/${MAIN_BRANCH}"

    _conf_set "GIT_BRANCH" "$MAIN_BRANCH"
    _conf_set "DEV_MODE" "false"

    echo "Back on '${MAIN_BRANCH}' — dev mode off, sync resumed"
}

cmd_reset() {
    # Hard-reset working copy to match remote — escape hatch for diverged branches
    _conf_load

    local working
    working=$(_working_branch)

    echo "WARNING: This will discard any uncommitted local changes on '${working}'"
    read -r -p "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted"; exit 0; }

    git -C "$DOTFILES_DIR" fetch origin "$GIT_BRANCH"
    git -C "$DOTFILES_DIR" reset --hard "origin/${GIT_BRANCH}"
    echo "Reset to origin/${GIT_BRANCH} ($(git -C "$DOTFILES_DIR" rev-parse --short HEAD))"
}

cmd_init() {
    # Minimal bootstrapping path if someone calls this directly rather than via install.sh
    local repo_url="${1:?Usage: dotfiles-branch --init <repo-url> <dotfiles-dir>}"
    local dotfiles_dir="${2:?Usage: dotfiles-branch --init <repo-url> <dotfiles-dir>}"

    local conf_dir
    conf_dir=$(dirname "$SYNC_CONF")
    mkdir -p "$conf_dir" "${STATE_DIR}/logs"

    if [[ -f "$SYNC_CONF" ]]; then
        echo "Config already exists at $SYNC_CONF — not overwriting"
        return 0
    fi

    cat > "$SYNC_CONF" <<EOF
# Dotfiles sync configuration
# Created by dotfiles-branch --init
# Edit SSH_KEY if you are not using an SSH agent
DOTFILES_DIR="${dotfiles_dir}"
REPO_URL="${repo_url}"
GIT_BRANCH="main"
DEV_MODE="false"
# SSH_KEY="\${HOME}/.ssh/dotfiles_ed25519"
EOF

    echo "Initialised sync config at $SYNC_CONF"
}

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
dotfiles-branch — manage dotfiles sync branch and dev mode

Usage:
  dotfiles-branch <branch>          Switch to <branch>; enables dev mode if not main
  dotfiles-branch --resume          Return to main and re-enable sync
  dotfiles-branch --dev             Suspend sync on current branch (no branch switch)
  dotfiles-branch --reset           Hard-reset working copy to match remote HEAD
  dotfiles-branch --status          Show sync state, branch, and last sync time
  dotfiles-branch --init <url> <dir>  Initialise sync.conf (normally done by install.sh)
  dotfiles-branch --help            Show this help

Examples:
  # Start working on a feature
  dotfiles-branch feat/new-aliases

  # Check what's going on
  dotfiles-branch --status

  # Done developing — push your branch first, then return to main
  git -C ~/dotfiles push origin feat/new-aliases
  dotfiles-branch --resume

  # Suspend sync temporarily without switching branches
  dotfiles-branch --dev
EOF
}

# ── Entry point ───────────────────────────────────────────────────────────────

main() {
    case "${1:-}" in
        --status|-s)            cmd_status ;;
        --dev)                  cmd_dev ;;
        --resume|--main)        cmd_resume ;;
        --reset)                cmd_reset ;;
        --init)                 shift; cmd_init "$@" ;;
        --help|-h|"")           usage ;;
        -*)                     echo "Unknown option: $1" >&2; usage; exit 1 ;;
        *)                      cmd_switch "$1" ;;
    esac
}

main "$@"
