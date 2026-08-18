#!/usr/bin/env bash
# scripts/sync.sh
# Dotfiles GitOps sync — runs as the user via systemd user timer or launchd agent
# Reads ~/.config/dotfiles/sync.conf; respects DEV_MODE to suspend sync during development
#
# Mode is derived fresh from disk on every run (never cached): if DOTFILES_DIR
# contains a .git directory this is a dev-mode checkout and syncs via
# `git pull --ff-only`; otherwise it is a release-mode install and syncs by
# fetching a GitHub codeload tarball, extracting it to a new release
# directory, and atomically flipping the 'current' symlink. See
# docs/sync.md#install-modes.

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────

SYNC_CONF="${XDG_CONFIG_HOME:-${HOME}/.config}/dotfiles/sync.conf"
STATE_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/dotfiles"
LOG_FILE="${STATE_DIR}/logs/sync.log"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/dotfiles-sync.lock"

# ── Release mode ──────────────────────────────────────────────────────────────

RELEASES_DIR="${STATE_DIR}/releases"
CURRENT_LINK="${STATE_DIR}/current"
KEEP_RELEASES=5

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

# ── Release-mode helpers ──────────────────────────────────────────────────────

# Parses owner/repo out of an https://github.com/<owner>/<repo>[.git] or
# git@github.com:<owner>/<repo>[.git] URL. Prints "<owner> <repo>" on success.
_parse_github_owner_repo() {
    local url="$1"
    if [[ "$url" =~ github\.com[:/]+([^/]+)/([^/.]+)(\.git)?/?$ ]]; then
        # Trailing newline matters: without it, `read` (used by callers via
        # process substitution) sees EOF before a newline and returns
        # non-zero even though it read the values correctly.
        printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

# Release id embedded in the 'current' symlink target's dirname
# (<timestamp>-<shortsha>) — empty if no release is installed yet.
_current_release_id() {
    [[ -L "$CURRENT_LINK" ]] || return 0
    basename "$(readlink "$CURRENT_LINK")" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z-//'
}

# Resolves a branch to its current commit sha via the GitHub API. Prints the
# full sha on success. Note: GitHub's codeload tarball for a branch ref always
# extracts to a constant <repo>-<branch>/ directory regardless of which
# commit is at the tip — there is no sha embedded in the archive itself to
# read back out, so the release id has to come from here instead.
_resolve_branch_sha() {
    local owner="$1" repo="$2" branch="$3"
    # head -1, not grep -m1: the API response is a single (compact) line, so
    # -m1 would still let -o print every match on it — including the nested
    # commit.tree.sha further along — instead of just the first ("sha" is
    # the top-level key, appearing first).
    curl -fsSL "https://api.github.com/repos/${owner}/${repo}/commits/${branch}" \
        | grep -o '"sha":[^,]*' \
        | head -1 \
        | grep -oE '[0-9a-f]{40}'
}

prune_old_releases() {
    local old
    while IFS= read -r old; do
        [[ -n "$old" ]] && rm -rf "$old"
    done < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +$((KEEP_RELEASES + 1)))
}

# Resolves the current GIT_BRANCH commit and — only if it differs from the
# currently installed release — fetches its tarball and flips 'current' to
# it. Returns 0 if a new release was installed, 1 if already up to date (or
# on a recoverable failure the timer should just retry next cycle).
release_sync() {
    local owner repo
    if ! read -r owner repo < <(_parse_github_owner_repo "$REPO_URL"); then
        warn "Could not parse owner/repo from REPO_URL='${REPO_URL}' — skipping release sync"
        return 1
    fi

    local sha shortsha current_id
    sha=$(_resolve_branch_sha "$owner" "$repo" "$GIT_BRANCH")
    if [[ -z "$sha" ]]; then
        warn "Could not resolve '${GIT_BRANCH}' to a commit via the GitHub API — skipping this cycle (network or rate-limit issue)"
        return 1
    fi
    shortsha="${sha:0:7}"
    current_id=$(_current_release_id)

    if [[ "$shortsha" == "$current_id" ]]; then
        log "Up to date on '${GIT_BRANCH}' (release ${shortsha})"
        return 1
    fi

    log "New release found on '${GIT_BRANCH}': ${current_id:-none} -> ${shortsha}"

    mkdir -p "$RELEASES_DIR"

    # Explicit templates: BSD/macOS mktemp requires one (a bare `mktemp`
    # errors), unlike GNU's which defaults to one.
    local tmp_tar tmp_extract
    tmp_tar=$(mktemp "${TMPDIR:-/tmp}/dotfiles-sync.XXXXXX")
    tmp_extract=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-sync.XXXXXX")

    # Fetches the branch tip rather than the exact resolved sha above — on
    # the rare chance a new commit lands in between, the installed content
    # would be one commit ahead of the shortsha it's labelled with. Harmless
    # (config only) and self-corrects next cycle.
    if ! curl -fsSL "https://codeload.github.com/${owner}/${repo}/tar.gz/refs/heads/${GIT_BRANCH}" -o "$tmp_tar"; then
        warn "Could not fetch release tarball for '${owner}/${repo}@${GIT_BRANCH}' — skipping this cycle (network issue)"
        rm -f "$tmp_tar"
        rm -rf "$tmp_extract"
        return 1
    fi

    tar -xzf "$tmp_tar" -C "$tmp_extract"
    rm -f "$tmp_tar"

    local extracted_dir
    extracted_dir=$(find "$tmp_extract" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [[ -z "$extracted_dir" ]]; then
        rm -rf "$tmp_extract"
        warn "Release tarball extraction produced no directory — skipping this cycle"
        return 1
    fi

    local timestamp new_release_dir
    timestamp=$(date -u +"%Y-%m-%dT%H%M%SZ")
    new_release_dir="${RELEASES_DIR}/${timestamp}-${shortsha}"
    mv "$extracted_dir" "$new_release_dir"
    rm -rf "$tmp_extract"

    # `ln -sfn` replaces an existing symlink in place rather than following
    # it — unlike `mv`, which (on both GNU and BSD, and without a portable
    # equivalent of GNU's non-standard -T) treats an existing
    # symlink-to-directory destination as a directory to move *into*,
    # silently nesting the new release inside the old one instead of
    # replacing 'current'.
    ln -sfn "$new_release_dir" "$CURRENT_LINK"

    log "Flipped to release ${shortsha} (${timestamp})"

    prune_old_releases

    return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    _setup_logging
    load_config
    acquire_lock
    check_dev_mode

    if [[ -d "${DOTFILES_DIR}/.git" ]]; then
        log "Dotfiles sync starting — dev mode (branch: ${GIT_BRANCH})"
        setup_git_ssh

        if has_upstream_changes "$GIT_BRANCH"; then
            sync_repo "$GIT_BRANCH"
            record_sync_time
        fi
    else
        log "Dotfiles sync starting — release mode (tracking: ${GIT_BRANCH})"

        if release_sync; then
            record_sync_time
        fi
    fi
}

main "$@"
