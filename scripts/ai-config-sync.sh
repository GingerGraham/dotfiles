#!/usr/bin/env bash
# scripts/ai-config-sync.sh
# ─────────────────────────────────────────────────────────────────────────────
# GitOps sync for the ai-config repo. Called by the systemd user timer
# (Linux) or launchd agent (macOS) every 30 minutes.
#
# After pulling the repo, this script re-runs the file deployment logic to
# place any new files in the correct destinations. It uses the same
# force: no semantics as the Ansible role — existing destination files are
# never overwritten.
#
# Runtime config lives in sync.conf (created once by Ansible, never
# overwritten). DEV_MODE and GIT_BRANCH are the two values users typically
# edit directly.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
XDG_STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"

SYNC_CONF="${XDG_CONFIG_HOME}/ai-config/sync.conf"
STATE_DIR="${XDG_DATA_HOME}/ai-config-sync"
LOG_FILE="${STATE_DIR}/logs/sync.log"
LAST_SYNC_FILE="${STATE_DIR}/last-sync"
LOCK_FILE="${STATE_DIR}/sync.lock"

# ── Logging ───────────────────────────────────────────────────────────────────

mkdir -p "${STATE_DIR}/logs"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*" | tee -a "${LOG_FILE}"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" | tee -a "${LOG_FILE}" >&2; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "${LOG_FILE}" >&2; }

# ── Config ────────────────────────────────────────────────────────────────────

load_config() {
    if [[ ! -f "${SYNC_CONF}" ]]; then
        log "sync.conf not found at ${SYNC_CONF} — skipping sync (not yet configured)"
        exit 0
    fi

    # shellcheck source=/dev/null
    source "${SYNC_CONF}"

    : "${REPO_URL:?REPO_URL not set in ${SYNC_CONF}}"
    : "${AI_CONFIG_CLONE_DIR:?AI_CONFIG_CLONE_DIR not set in ${SYNC_CONF}}"

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
    git -C "${AI_CONFIG_CLONE_DIR}" rev-parse --git-dir &>/dev/null
}

is_working_tree_clean() {
    [[ -z "$(git -C "${AI_CONFIG_CLONE_DIR}" status --porcelain 2>/dev/null)" ]]
}

get_current_branch() {
    git -C "${AI_CONFIG_CLONE_DIR}" branch --show-current 2>/dev/null || echo "unknown"
}

get_local_commit() {
    git -C "${AI_CONFIG_CLONE_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown"
}

# ── File deployment ───────────────────────────────────────────────────────────
# Mirrors the Ansible role's deploy logic but in bash, with the same
# force: no semantics. Called after a successful pull to place any new
# files that appeared in the repo.

deploy_tool() {
    local tool="$1"
    local dest="$2"
    local src="${AI_CONFIG_CLONE_DIR}/${tool}"

    [[ -d "${src}" ]] || return 0

    mkdir -p "${dest}"

    # Walk source files; copy only if the destination file does not yet exist
    while IFS= read -r -d '' src_file; do
        local rel_path
        rel_path="${src_file#"${src}"/}"
        local dest_file="${dest}/${rel_path}"

        # Create parent directories as needed
        mkdir -p "$(dirname "${dest_file}")"

        if [[ ! -e "${dest_file}" ]]; then
            cp "${src_file}" "${dest_file}"
            log "  deployed: ${rel_path} → ${dest_file}"
        fi
    done < <(find "${src}" -type f -print0)
}

deploy_all_tools() {
    log "Deploying config files from ${AI_CONFIG_CLONE_DIR}"

    # ── Claude ──────────────────────────────────────────────────────────────
    deploy_tool "claude" "${HOME}/.claude"

    # ── GitHub Copilot ───────────────────────────────────────────────────────
    deploy_tool "copilot" "${XDG_CONFIG_HOME}/github-copilot"

    # ── Cursor ───────────────────────────────────────────────────────────────
    if [[ "$(uname -s)" == "Darwin" ]]; then
        deploy_tool "cursor" "${HOME}/Library/Application Support/Cursor/User"
    else
        deploy_tool "cursor" "${HOME}/.cursor"
    fi

    # ── Kiro ─────────────────────────────────────────────────────────────────
    deploy_tool "kiro" "${HOME}/.kiro"
}

# ── Main sync logic ───────────────────────────────────────────────────────────

do_sync() {
    local current_branch local_commit

    if [[ ! -d "${AI_CONFIG_CLONE_DIR}" ]]; then
        warn "ai-config clone directory ${AI_CONFIG_CLONE_DIR} does not exist — skipping sync"
        log "Re-run the ai-tools Ansible role to clone the config repo."
        return 0
    fi

    if ! is_git_repo; then
        warn "${AI_CONFIG_CLONE_DIR} is not a git repository — skipping sync"
        return 0
    fi

    current_branch=$(get_current_branch)
    local_commit=$(get_local_commit)

    log "Fetching from origin (branch: ${GIT_BRANCH}, local: ${current_branch}@${local_commit})"

    if ! git -C "${AI_CONFIG_CLONE_DIR}" fetch origin "${GIT_BRANCH}" 2>>"${LOG_FILE}"; then
        warn "git fetch failed — no network or SSH issue; will retry next cycle"
        return 0
    fi

    local remote_commit
    remote_commit=$(git -C "${AI_CONFIG_CLONE_DIR}" rev-parse --short "origin/${GIT_BRANCH}" 2>/dev/null || echo "unknown")

    if [[ "${local_commit}" == "${remote_commit}" ]]; then
        log "Already up to date (${local_commit})"
        echo "$(date '+%Y-%m-%d %H:%M:%S') up-to-date ${local_commit}" > "${LAST_SYNC_FILE}"
        return 0
    fi

    if ! is_working_tree_clean; then
        warn "Working tree has uncommitted changes — skipping pull to preserve local edits"
        warn "Commit or stash changes in ${AI_CONFIG_CLONE_DIR} to resume sync"
        return 0
    fi

    log "Pulling ${local_commit} → ${remote_commit}"
    if ! git -C "${AI_CONFIG_CLONE_DIR}" pull --ff-only origin "${GIT_BRANCH}" 2>>"${LOG_FILE}"; then
        err "git pull --ff-only failed — repo may have diverged; manual intervention required"
        return 1
    fi

    log "Pull complete: ${local_commit} → ${remote_commit}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') updated ${local_commit} → ${remote_commit}" > "${LAST_SYNC_FILE}"

    # Deploy any new files that appeared after the pull
    deploy_all_tools
}

# ── Entrypoint ────────────────────────────────────────────────────────────────

main() {
    load_config

    if [[ "${DEV_MODE}" == "true" ]]; then
        log "DEV_MODE is active — skipping sync (set DEV_MODE=false in ${SYNC_CONF} to resume)"
        exit 0
    fi

    acquire_lock
    trap release_lock EXIT

    do_sync
}

main "$@"
