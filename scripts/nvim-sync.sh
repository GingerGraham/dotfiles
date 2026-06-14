#!/usr/bin/env bash
# scripts/nvim-sync.sh
# Neovim config GitOps sync — runs as the user via systemd user timer or
# launchd agent. Reads ~/.config/nvim-config/sync.conf; respects DEV_MODE
# to suspend sync during active config development.
#
# Deliberately does NOT run ':Lazy sync' or ':Lazy update'. Plugin management
# is intentionally manual — pull the config, then decide whether to update
# plugins. This avoids unexpected plugin changes mid-session.

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────

SYNC_CONF="${XDG_CONFIG_HOME:-${HOME}/.config}/nvim-config/sync.conf"
STATE_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/nvim-config"
LOG_FILE="${STATE_DIR}/logs/sync.log"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/nvim-config-sync.lock"

# ── Logging ───────────────────────────────────────────────────────────────────

mkdir -p "${STATE_DIR}/logs"

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
            LOG_FILE="${LOG_FILE}" # bash-logger reads this if set before sourcing
            return 0
        fi
    done

    # Fallback — mirrors bash-logger interface
    log()   { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO]  nvim-config-sync: $*" | tee -a "${LOG_FILE}"; }
    warn()  { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN]  nvim-config-sync: $*" | tee -a "${LOG_FILE}"; }
    error() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] nvim-config-sync: $*" | tee -a "${LOG_FILE}" >&2; exit 1; }
}

# ── Config ────────────────────────────────────────────────────────────────────

load_config() {
    if [[ ! -r "${SYNC_CONF}" ]]; then
        # Config missing: likely first-run before install.sh has completed.
        # Exit cleanly — the timer will retry; no need to journal an error.
        log "sync.conf not found at ${SYNC_CONF} — skipping sync (not yet configured)"
        exit 0
    fi

    # shellcheck source=/dev/null
    source "${SYNC_CONF}"

    : "${REPO_URL:?REPO_URL not set in ${SYNC_CONF}}"
    : "${NVIM_CONFIG_DIR:?NVIM_CONFIG_DIR not set in ${SYNC_CONF}}"

    GIT_BRANCH="${GIT_BRANCH:-main}"
    DEV_MODE="${DEV_MODE:-false}"
}

# ── Lock ──────────────────────────────────────────────────────────────────────

acquire_lock() {
    if [[ -e "${LOCK_FILE}" ]]; then
        local lock_pid
        lock_pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")
        if [[ -n "${lock_pid}" ]] && kill -0 "${lock_pid}" 2>/dev/null; then
            log "Another sync instance is running (PID ${lock_pid}) — exiting"
            exit 0
        fi
        warn "Stale lock file found — removing and continuing"
        rm -f "${LOCK_FILE}"
    fi
    echo $$ > "${LOCK_FILE}"
}

release_lock() {
    rm -f "${LOCK_FILE}"
}

# ── Git helpers ───────────────────────────────────────────────────────────────

is_git_repo() {
    git -C "${NVIM_CONFIG_DIR}" rev-parse --git-dir &>/dev/null
}

is_working_tree_clean() {
    [[ -z "$(git -C "${NVIM_CONFIG_DIR}" status --porcelain 2>/dev/null)" ]]
}

get_current_branch() {
    git -C "${NVIM_CONFIG_DIR}" branch --show-current 2>/dev/null || echo "unknown"
}

get_local_commit() {
    git -C "${NVIM_CONFIG_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown"
}

# ── Main sync logic ───────────────────────────────────────────────────────────

do_sync() {
    local current_branch local_commit remote_commit

    # Guard: directory must exist and be a git repo
    if [[ ! -d "${NVIM_CONFIG_DIR}" ]]; then
        warn "nvim config directory ${NVIM_CONFIG_DIR} does not exist — skipping sync"
        log "Re-run the nvim Ansible role to clone the config repo."
        return 0
    fi

    if ! is_git_repo; then
        warn "${NVIM_CONFIG_DIR} is not a git repository — skipping sync"
        return 0
    fi

    current_branch=$(get_current_branch)
    local_commit=$(get_local_commit)

    log "Fetching from origin (branch: ${GIT_BRANCH}, local: ${current_branch}@${local_commit})"

    # Fetch — failure here is non-fatal (no network, SSH key issues, etc.)
    if ! git -C "${NVIM_CONFIG_DIR}" fetch origin "${GIT_BRANCH}" 2>&1 | tee -a "${LOG_FILE}"; then
        warn "git fetch failed — will retry on next scheduled run"
        return 0
    fi

    # Compare local HEAD to remote tracking ref
    remote_commit=$(git -C "${NVIM_CONFIG_DIR}" rev-parse --short "origin/${GIT_BRANCH}" 2>/dev/null || echo "unknown")

    if [[ "${local_commit}" == "${remote_commit}" ]]; then
        log "Already up to date (${local_commit})"
        return 0
    fi

    log "Updates available: ${local_commit} → ${remote_commit}"

    # Guard: do not pull over local edits
    if ! is_working_tree_clean; then
        warn "Working tree has uncommitted changes — skipping pull to avoid data loss"
        warn "Commit or stash your changes, or set DEV_MODE=true in ${SYNC_CONF} to suppress this warning"
        return 0
    fi

    # Fast-forward only — refuse a pull that would require a merge commit
    if git -C "${NVIM_CONFIG_DIR}" pull --ff-only origin "${GIT_BRANCH}" 2>&1 | tee -a "${LOG_FILE}"; then
        local new_commit
        new_commit=$(get_local_commit)
        log "Updated successfully: ${local_commit} → ${new_commit}"
        date '+%Y-%m-%d %H:%M:%S' > "${STATE_DIR}/last-sync"
    else
        warn "pull --ff-only failed — branches may have diverged"
        warn "Resolve manually in ${NVIM_CONFIG_DIR} or re-run the Ansible nvim role to reset"
    fi
}

# ── Entry point ───────────────────────────────────────────────────────────────

main() {
    _setup_logging
    load_config
    acquire_lock
    trap release_lock EXIT

    log "nvim-config sync starting"

    # DEV_MODE suspends sync without stopping the timer. This lets you edit
    # your config on a machine without upstream changes clobbering your work.
    if [[ "${DEV_MODE}" == "true" ]]; then
        log "DEV_MODE is active — sync suspended"
        log "Set DEV_MODE=false in ${SYNC_CONF} to resume"
        exit 0
    fi

    do_sync

    log "nvim-config sync complete"
}

main "$@"
