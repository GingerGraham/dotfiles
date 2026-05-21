#!/usr/bin/env bash
# scripts/sync.sh
# Dotfiles GitOps sync — runs as the user via systemd user timer or launchd agent
# Reads ~/.config/dotfiles/sync.conf; respects DEV_MODE to suspend sync during development

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────

SYNC_CONF="${XDG_CONFIG_HOME:-${HOME}/.config}/dotfiles/sync.conf"
STATE_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/dotfiles"
LOG_FILE="${STATE_DIR}/logs/sync.log"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/dotfiles-sync.lock"

# ── Logging ───────────────────────────────────────────────────────────────────

mkdir -p "${STATE_DIR}/logs"

# Source bash-logger if the common role installed it; fall back to inline stubs
_setup_logging() {
    local logger_paths=(
        "${XDG_DATA_HOME:-${HOME}/.local/share}/bash-logger/bash-logger.sh"
        "/usr/local/lib/bash-logger/bash-logger.sh"
        "${HOME}/.local/lib/bash-logger/bash-logger.sh"
    )
    for p in "${logger_paths[@]}"; do
        if [[ -r "$p" ]]; then
            # shellcheck source=/dev/null
            source "$p"
            return 0
        fi
    done

    # Fallback — mirrors bash-logger's interface closely enough
    log()   { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO]  dotfiles-sync: $*" | tee -a "$LOG_FILE"; }
    warn()  { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN]  dotfiles-sync: $*" | tee -a "$LOG_FILE"; }
    error() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] dotfiles-sync: $*" | tee -a "$LOG_FILE" >&2; exit 1; }
}

# ── Config ────────────────────────────────────────────────────────────────────

load_config() {
    if [[ ! -r "$SYNC_CONF" ]]; then
        # Config missing: likely first-run before install.sh has completed.
        # Exit cleanly — the timer will retry; don't error loudly into the journal.
        echo "dotfiles-sync: config not found at $SYNC_CONF — skipping" >&2
        exit 0
    fi

    # shellcheck source=/dev/null
    source "$SYNC_CONF"

    : "${DOTFILES_DIR:?DOTFILES_DIR not set in $SYNC_CONF}"
    : "${GIT_BRANCH:?GIT_BRANCH not set in $SYNC_CONF}"
    DEV_MODE="${DEV_MODE:-false}"
    SSH_KEY="${SSH_KEY:-}"
}

# ── Lock file ─────────────────────────────────────────────────────────────────

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log "Another sync is already running (PID: $pid) — skipping this run"
            exit 0
        fi
        warn "Removing stale lock file (PID: $pid no longer exists)"
        rm -f "$LOCK_FILE"
    fi

    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT INT TERM
}

# ── Dev mode ──────────────────────────────────────────────────────────────────

check_dev_mode() {
    if [[ "$DEV_MODE" == "true" ]]; then
        log "Dev mode active — sync suspended (tracking: ${GIT_BRANCH})"
        exit 0
    fi
}

# ── Git helpers ───────────────────────────────────────────────────────────────

setup_git_ssh() {
    # If an explicit key is configured, pin it; otherwise let the running agent handle auth
    if [[ -n "$SSH_KEY" && -r "$SSH_KEY" ]]; then
        export GIT_SSH_COMMAND="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
    fi
}

current_branch() {
    git -C "$DOTFILES_DIR" branch --show-current 2>/dev/null || echo "unknown"
}

has_upstream_changes() {
    # Returns 0 (true) if a sync is needed, 1 (false) if already up to date
    local branch="$1"
    local working_branch
    working_branch=$(current_branch)

    if [[ "$working_branch" != "$branch" ]]; then
        warn "Working copy is on '$working_branch' but configured branch is '$branch' — sync will realign"
        return 0
    fi

    if ! git -C "$DOTFILES_DIR" fetch origin "$branch" 2>/dev/null; then
        warn "Could not reach origin — skipping this cycle (network or SSH issue)"
        exit 0
    fi

    local local_hash remote_hash
    local_hash=$(git -C "$DOTFILES_DIR" rev-parse HEAD)
    remote_hash=$(git -C "$DOTFILES_DIR" rev-parse "origin/${branch}")

    if [[ "$local_hash" == "$remote_hash" ]]; then
        log "Up to date on '${branch}' (${local_hash:0:8})"
        return 1
    fi

    log "Upstream changes found on '${branch}': ${local_hash:0:8} → ${remote_hash:0:8}"
    return 0
}

sync_repo() {
    local branch="$1"
    local working_branch
    working_branch=$(current_branch)

    cd "$DOTFILES_DIR"

    if [[ "$working_branch" != "$branch" ]]; then
        log "Realigning working copy to '${branch}'..."
        git fetch origin "$branch"
        git checkout "$branch"
        git reset --hard "origin/${branch}"
        log "Realigned to '${branch}'"
        return
    fi

    # Fast-forward only: if the branch has diverged locally (e.g. accidental commit
    # on a non-dev machine), refuse to clobber — warn and exit cleanly rather than
    # silently force-resetting work.
    if ! git pull --ff-only origin "$branch"; then
        warn "Fast-forward pull failed — local and remote '${branch}' have diverged."
        warn "Run 'dotfiles-branch --status' and resolve manually, or use 'dotfiles-branch --reset' to discard local changes."
        exit 1
    fi

    log "Sync complete on '${branch}' ($(git -C "$DOTFILES_DIR" rev-parse --short HEAD))"
}

record_sync_time() {
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${STATE_DIR}/last-sync"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    _setup_logging
    load_config
    acquire_lock
    check_dev_mode
    setup_git_ssh

    log "Dotfiles sync starting (branch: ${GIT_BRANCH})"

    if has_upstream_changes "$GIT_BRANCH"; then
        sync_repo "$GIT_BRANCH"
        record_sync_time
    fi
}

main "$@"
