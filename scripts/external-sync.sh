#!/usr/bin/env bash
# scripts/external-sync.sh
# ─────────────────────────────────────────────────────────────────────────────
# Generic external add-on repo sync engine. Runs as the user via the
# external-sync systemd user timer (Linux) or launchd agent (macOS), and can
# also be invoked manually.
#
# Invocation:
#   external-sync            Sync every repo configured under
#                             ~/.config/external-sync/*/
#   external-sync <name>     Sync a single repo by name.
#
# Per repo, runtime config lives at:
#   ~/.config/external-sync/<name>/sync.conf    REPO_URL, CLONE_DIR,
#                                                GIT_BRANCH, DEV_MODE
#   ~/.config/external-sync/<name>/deploy.list  src|dest|mode|force|executable
#                                                one line per deploy entry;
#                                                empty or absent = clone-only
#
# sync.conf is written once by the sync-external Ansible role and never
# overwritten — DEV_MODE and GIT_BRANCH are yours to edit at runtime. Set
# DEV_MODE=true to suspend sync for that repo only; other repos keep syncing.
#
# A repo with no sync.conf yet (not registered, or Ansible hasn't run) is
# skipped cleanly — this is expected on a fresh checkout of a new repo entry.
#
# State and logs live per repo at:
#   ~/.local/share/external-sync/<name>/last-sync
#   ~/.local/share/external-sync/<name>/logs/sync.log
#
# One repo's failure (bad clone, diverged branch, broken deploy entry) never
# aborts the sync of the others — each repo is synced in isolation.
#
# This script never parses .dotfiles-sync.yml directly — Ansible parses the
# manifest once and renders deploy.list, which is the only format bash reads.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────

CONFIG_ROOT="${XDG_CONFIG_HOME:-${HOME}/.config}/external-sync"
STATE_ROOT="${XDG_DATA_HOME:-${HOME}/.local/share}/external-sync"

# Reassigned per repo by sync_one() before any log()/warn()/err() call.
LOG_FILE="/dev/null"

# ── Logging ───────────────────────────────────────────────────────────────────

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*" | tee -a "${LOG_FILE}"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" | tee -a "${LOG_FILE}" >&2; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "${LOG_FILE}" >&2; }

# ── Lock ──────────────────────────────────────────────────────────────────────
# Per-repo lock file, guarded by kill -0 so a stale lock from a killed
# process (crash, reboot mid-sync) doesn't wedge that repo's sync forever.

acquire_lock() {
    local lock_file="$1"

    if [[ -e "${lock_file}" ]]; then
        local lock_pid
        lock_pid=$(cat "${lock_file}" 2>/dev/null || echo "")
        if [[ -n "${lock_pid}" ]] && kill -0 "${lock_pid}" 2>/dev/null; then
            log "Another sync instance is already running (PID ${lock_pid}) — skipping"
            return 1
        fi
        warn "Stale lock file found — removing and continuing"
        rm -f "${lock_file}"
    fi

    echo $$ > "${lock_file}"
    return 0
}

# ── Git helpers ───────────────────────────────────────────────────────────────

is_git_repo() {
    git -C "$1" rev-parse --git-dir &>/dev/null
}

is_working_tree_clean() {
    [[ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ]]
}

get_local_commit() {
    git -C "$1" rev-parse --short HEAD 2>/dev/null || echo "unknown"
}

# ── Git sync ──────────────────────────────────────────────────────────────────
# Fetch/pull failures are logged and treated as non-fatal — the next scheduled
# run will retry. A dirty working tree is never clobbered.

do_repo_sync() {
    local clone_dir="$1" branch="$2" state_dir="$3"

    if [[ ! -d "${clone_dir}" ]]; then
        warn "Clone directory ${clone_dir} does not exist — skipping git sync"
        log "Re-run 'ansible-playbook site.yml --tags sync-external' to clone it."
        return 1
    fi

    if ! is_git_repo "${clone_dir}"; then
        warn "${clone_dir} is not a git repository — skipping git sync"
        return 1
    fi

    local local_commit
    local_commit=$(get_local_commit "${clone_dir}")

    log "Fetching from origin (branch: ${branch}, local: ${local_commit})"

    if ! git -C "${clone_dir}" fetch origin "${branch}" >>"${LOG_FILE}" 2>&1; then
        warn "git fetch failed — will retry on next scheduled run"
        return 0
    fi

    local remote_commit
    remote_commit=$(git -C "${clone_dir}" rev-parse --short "origin/${branch}" 2>/dev/null || echo "unknown")

    if [[ "${local_commit}" == "${remote_commit}" ]]; then
        log "Already up to date (${local_commit})"
    elif ! is_working_tree_clean "${clone_dir}"; then
        warn "Working tree has uncommitted changes — skipping pull to avoid data loss"
        warn "Commit or stash changes in ${clone_dir}, or set DEV_MODE=true to suppress this warning"
    else
        log "Pulling ${local_commit} → ${remote_commit}"
        if git -C "${clone_dir}" pull --ff-only origin "${branch}" >>"${LOG_FILE}" 2>&1; then
            log "Updated successfully: ${local_commit} → $(get_local_commit "${clone_dir}")"
        else
            warn "pull --ff-only failed — branches may have diverged"
            warn "Resolve manually in ${clone_dir}, or re-run the Ansible role to reset"
        fi
    fi

    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${state_dir}/last-sync"
    return 0
}

# ── Deploy: copy ──────────────────────────────────────────────────────────────

deploy_copy_file() {
    local src="$1" dest="$2" force="$3" executable="$4"

    mkdir -p "$(dirname "${dest}")"

    if [[ -e "${dest}" && "${force}" != "true" ]]; then
        return 0
    fi

    cp -f "${src}" "${dest}"
    [[ "${executable}" == "true" ]] && chmod +x "${dest}"
    log "  deployed (copy): ${dest}"
}

deploy_copy() {
    local src="$1" dest="$2" force="$3" executable="$4"
    # Strip any trailing slash — deploy.list entries for a directory src
    # (e.g. from a manifest's "src: claude/") carry one, and a doubled
    # slash would otherwise break the prefix-strip below.
    src="${src%/}"

    if [[ -d "${src}" ]]; then
        local file rel target
        while IFS= read -r -d '' file; do
            rel="${file#"${src}"/}"
            target="${dest%/}/${rel}"
            deploy_copy_file "${file}" "${target}" "${force}" "${executable}"
        done < <(find "${src}" -type f -print0)
    elif [[ -e "${src}" ]]; then
        deploy_copy_file "${src}" "${dest}" "${force}" "${executable}"
    else
        warn "deploy: source not found: ${src}"
    fi
}

# ── Deploy: link ──────────────────────────────────────────────────────────────
# A pre-existing correct symlink is left as-is. A pre-existing symlink pointing
# elsewhere is always repointed (that's the point of auto-updating mode). A
# pre-existing non-symlink is only replaced when force is true.

deploy_link_file() {
    local src="$1" dest="$2" force="$3" executable="$4"

    mkdir -p "$(dirname "${dest}")"

    if [[ -L "${dest}" ]]; then
        local current_target
        current_target=$(readlink "${dest}")
        if [[ "${current_target}" != "${src}" ]]; then
            rm -f "${dest}"
            ln -s "${src}" "${dest}"
            log "  relinked: ${dest} -> ${src}"
        fi
    elif [[ -e "${dest}" ]]; then
        if [[ "${force}" != "true" ]]; then
            warn "  ${dest} exists and is not a symlink — skipping (set force: true to replace)"
            return 0
        fi
        rm -rf "${dest}"
        ln -s "${src}" "${dest}"
        log "  deployed (link): ${dest} -> ${src}"
    else
        ln -s "${src}" "${dest}"
        log "  deployed (link): ${dest} -> ${src}"
    fi

    # Never chmod the source: it lives inside the repo's git clone, and
    # mutating it would dirty the working tree and trip is_working_tree_clean(),
    # permanently blocking future pulls. The manifest should commit the
    # executable bit upstream instead.
    if [[ "${executable}" == "true" && ! -x "${src}" ]]; then
        warn "  ${src} is marked executable in the manifest but is not +x in the repo — commit the executable bit upstream"
    fi
}

deploy_link() {
    local src="$1" dest="$2" force="$3" executable="$4"
    # See deploy_copy() — strip a trailing slash before using src as a
    # prefix to strip from each found file's path.
    src="${src%/}"

    if [[ -d "${src}" ]]; then
        local file rel target
        while IFS= read -r -d '' file; do
            rel="${file#"${src}"/}"
            target="${dest%/}/${rel}"
            deploy_link_file "${file}" "${target}" "${force}" "${executable}"
        done < <(find "${src}" -type f -print0)
    elif [[ -e "${src}" ]]; then
        deploy_link_file "${src}" "${dest}" "${force}" "${executable}"
    else
        warn "deploy: source not found: ${src}"
    fi
}

# ── Deploy loop ───────────────────────────────────────────────────────────────
# deploy.list fields are pipe-separated (not whitespace) so a dest containing
# spaces — e.g. macOS's "Application Support" — is handled safely.

deploy_repo() {
    local name="$1" deploy_list="$2"

    if [[ ! -s "${deploy_list}" ]]; then
        log "[${name}] clone-only — no deploy entries"
        return 0
    fi

    log "[${name}] deploying from ${deploy_list}"

    local src dest mode force executable
    while IFS='|' read -r src dest mode force executable; do
        [[ -z "${src}" ]] && continue
        case "${mode}" in
            link) deploy_link "${src}" "${dest}" "${force}" "${executable}" ;;
            *)    deploy_copy "${src}" "${dest}" "${force}" "${executable}" ;;
        esac
    done < "${deploy_list}"
}

# ── Per-repo sync ─────────────────────────────────────────────────────────────

sync_one() {
    local name="$1"
    local conf="${CONFIG_ROOT}/${name}/sync.conf"
    local deploy_list="${CONFIG_ROOT}/${name}/deploy.list"
    local state_dir="${STATE_ROOT}/${name}"
    local lock_file="${state_dir}/sync.lock"

    mkdir -p "${state_dir}/logs"
    LOG_FILE="${state_dir}/logs/sync.log"

    if [[ ! -r "${conf}" ]]; then
        log "[${name}] sync.conf not found at ${conf} — skipping (not yet configured)"
        return 0
    fi

    # Reset before sourcing so a repo missing a field doesn't inherit the
    # previous repo's value from this same process.
    local REPO_URL="" CLONE_DIR="" GIT_BRANCH="" DEV_MODE=""
    # shellcheck source=/dev/null
    source "${conf}"

    GIT_BRANCH="${GIT_BRANCH:-main}"
    DEV_MODE="${DEV_MODE:-false}"

    if [[ -z "${CLONE_DIR}" ]]; then
        err "[${name}] CLONE_DIR not set in ${conf} — skipping"
        return 0
    fi

    log "[${name}] sync starting (repo: ${REPO_URL:-unset})"

    if [[ "${DEV_MODE}" == "true" ]]; then
        log "[${name}] DEV_MODE is active — sync suspended (set DEV_MODE=false in ${conf} to resume)"
        return 0
    fi

    if ! acquire_lock "${lock_file}"; then
        return 0
    fi
    trap 'rm -f "'"${lock_file}"'"' EXIT

    if do_repo_sync "${CLONE_DIR}" "${GIT_BRANCH}" "${state_dir}"; then
        deploy_repo "${name}" "${deploy_list}"
    else
        log "[${name}] skipping deploy — clone not ready"
    fi

    log "[${name}] sync complete"
}

# ── Entry point ───────────────────────────────────────────────────────────────
# Each repo is synced in its own subshell with set -e enabled, so an
# unexpected failure in one repo's git/deploy flow cannot abort the others —
# but run_one still reports failure via its own return code, so callers
# (main's loop, systemd/launchd, Ansible's initial-deploy command) can tell
# something went wrong instead of every invocation silently exiting 0.

run_one() {
    local name="$1"
    if ! ( set -e; sync_one "${name}" ); then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] sync for '${name}' failed unexpectedly — see its log under ${STATE_ROOT}/${name}/logs/" >&2
        return 1
    fi
}

main() {
    mkdir -p "${CONFIG_ROOT}" "${STATE_ROOT}"

    local failures=0

    if [[ $# -gt 0 ]]; then
        run_one "$1" || failures=1
        return "${failures}"
    fi

    local dir name
    for dir in "${CONFIG_ROOT}"/*/; do
        [[ -d "${dir}" ]] || continue
        name=$(basename "${dir}")
        run_one "${name}" || failures=1
    done

    return "${failures}"
}

main "$@"
