#!/usr/bin/env bash
# scripts/external-sync.sh
# ─────────────────────────────────────────────────────────────────────────────
# Generic external add-on repo sync engine. Runs as the user via the
# external-sync systemd user timer (Linux) or launchd agent (macOS), and can
# also be invoked manually.
#
# Invocation:
#   external-sync                        Sync every repo configured under
#                                         ~/.config/external-sync/*/
#   external-sync <name>                 Sync a single repo by name.
#   external-sync <name> --force-hooks   Sync one repo, running its
#                                         post_deploy hook regardless of its
#                                         run_on policy.
#   external-sync --status               Per-repo status table. No git
#                                         operations beyond local, read-only
#                                         plumbing (rev-parse/hash-object);
#                                         no fetch/pull, no lock taken.
#   external-sync --help                 Usage.
#
# Per repo, runtime config lives at:
#   ~/.config/external-sync/<name>/sync.conf    REPO_URL, CLONE_DIR,
#                                                GIT_BRANCH, DEV_MODE
#   ~/.config/external-sync/<name>/deploy.list  src|dest|mode|force|executable
#                                                one line per deploy entry;
#                                                empty or absent = clone-only
#   ~/.config/external-sync/<name>/hooks.list   event|run_on|timeout|argv...
#                                                one line per hook; empty or
#                                                absent = no hooks
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
#   ~/.local/share/external-sync/<name>/manifest-hash    written by Ansible
#                                                         only — this script
#                                                         only ever reads it
#   ~/.local/share/external-sync/<name>/hook-ran         run_on: initial
#                                                         sentinel
#   ~/.local/share/external-sync/<name>/last-hook-status <ISO8601> <ok|failed>
#                                                         <rc> <event>
#   ~/.local/share/external-sync/<name>/logs/sync.log
#
# One repo's failure (bad clone, diverged branch, broken deploy entry, failed
# hook) never aborts the sync of the others — each repo is synced in
# isolation. A hook failure is logged and recorded but is explicitly
# non-fatal to the rest of that repo's sync and to every other repo.
#
# This script never parses .dotfiles-sync.yml directly — Ansible parses the
# manifest once and renders deploy.list/hooks.list, which are the only
# formats bash reads. Manifest changes upstream (a new deploy entry, a new
# hook, an edited branch) take effect on the next Ansible run, not the next
# timer-driven pull — see docs/sync-manifest-spec.md's "How to make your
# repo compatible" section for why. This script detects that gap and warns
# (see check_manifest_drift()) but cannot close it — Bash never parses YAML.
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

# ── OS / WSL detection (runs once) ───────────────────────────────────────────
# Same idiom as shell/config/loader.sh's DOTFILES_OS/DOTFILES_WSL, values
# lower-cased to match the manifest spec's platforms: [linux, macos] and the
# EXTERNAL_SYNC_OS hook env var (see docs/sync-manifest-spec.md §3.6). Kept as
# a second, independent implementation deliberately — this script has no
# business depending on the interactive shell's loader.sh, and a hook runs in
# a bare `bash <script>` process, not a login shell.

case "$(uname -s)" in
    Darwin) EXTERNAL_SYNC_OS="macos" ;;
    *)      EXTERNAL_SYNC_OS="linux" ;;
esac

if [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
    EXTERNAL_SYNC_WSL="true"
else
    EXTERNAL_SYNC_WSL="false"
fi

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
#
# Sets the caller's _repo_head_moved to "true" on an actual successful pull
# (the only branch where content genuinely changed) — used both for DF-5's
# EXTERNAL_SYNC_RESULT line and for hook run_on: changed evaluation. Relies on
# bash's dynamic scoping: _repo_head_moved is declared `local` in sync_one()
# and this function (called from sync_one()) mutates that same variable
# without re-declaring it. Return value is unrelated and still means "is the
# clone ready to deploy from" (0 = yes, 1 = no) — unchanged from before.

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
            _repo_head_moved="true"
        else
            warn "pull --ff-only failed — branches may have diverged"
            warn "Resolve manually in ${clone_dir}, or re-run the Ansible role to reset"
        fi
    fi

    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${state_dir}/last-sync"
    return 0
}

# ── Manifest drift detection (DF-1) ──────────────────────────────────────────
# deploy.list/hooks.list are Ansible-rendered snapshots of .dotfiles-sync.yml
# at the time Ansible last ran — this script never re-parses the manifest, so
# an upstream manifest edit that lands via a plain `git pull` has no effect
# until 'ansible-playbook site.yml --tags sync-external' runs again (see
# docs/sync-manifest-spec.md). That gap is an accepted design (D3), but it
# must be loud, not silent: compare the manifest's current git blob hash
# against the hash Ansible recorded when it last rendered deploy.list, and
# warn on mismatch. Deliberately never writes manifest-hash — only Ansible
# owns that file; writing it from here would silence the warning without
# actually applying anything.

check_manifest_drift() {
    local name="$1" clone_dir="$2" state_dir="$3"
    local manifest="${clone_dir}/.dotfiles-sync.yml"

    local current_hash="absent"
    if [[ -e "${manifest}" ]]; then
        current_hash=$(git -C "${clone_dir}" hash-object .dotfiles-sync.yml 2>/dev/null || echo "unknown")
    fi

    local recorded_hash=""
    [[ -r "${state_dir}/manifest-hash" ]] && recorded_hash=$(cat "${state_dir}/manifest-hash" 2>/dev/null || echo "")

    if [[ -n "${recorded_hash}" && "${current_hash}" != "${recorded_hash}" ]]; then
        warn "[${name}] manifest changed since the last Ansible run (${recorded_hash:0:7} -> ${current_hash:0:7})"
        warn "[${name}] re-run 'ansible-playbook site.yml --tags sync-external' to apply it"
    fi
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
    # See do_repo_sync()'s comment on dynamic scoping — _deploy_changes is
    # declared local in sync_one() and incremented here without re-declaring.
    _deploy_changes=$((_deploy_changes + 1))
}

deploy_copy() {
    local src="$1" dest="$2" force="$3" executable="$4"
    # Strip any trailing slash — deploy.list entries for a directory src
    # (e.g. from a manifest's "src: claude/") carry one, and a doubled
    # slash would otherwise break the prefix-strip below.
    src="${src%/}"

    if [[ -d "${src}" ]]; then
        local file rel target
        # -name .git -prune excludes the repo's own .git directory from the
        # walk entirely (DF-3) — without it, "src: ." (the natural way to
        # deploy an entire repo) would copy/link every object under .git/
        # into dest. The -o binds -print0 to the -type f branch only: prune
        # short-circuits that path before -o is evaluated, so a pruned
        # directory is never tested against -type f (and never printed).
        while IFS= read -r -d '' file; do
            rel="${file#"${src}"/}"
            target="${dest%/}/${rel}"
            deploy_copy_file "${file}" "${target}" "${force}" "${executable}"
        done < <(find "${src}" -name .git -prune -o -type f -print0)
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
            _deploy_changes=$((_deploy_changes + 1))
        fi
    elif [[ -e "${dest}" ]]; then
        if [[ "${force}" != "true" ]]; then
            warn "  ${dest} exists and is not a symlink — skipping (set force: true to replace)"
            return 0
        fi
        rm -rf "${dest}"
        ln -s "${src}" "${dest}"
        log "  deployed (link): ${dest} -> ${src}"
        _deploy_changes=$((_deploy_changes + 1))
    else
        ln -s "${src}" "${dest}"
        log "  deployed (link): ${dest} -> ${src}"
        _deploy_changes=$((_deploy_changes + 1))
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
        # See deploy_copy() for why .git is pruned (DF-3).
        while IFS= read -r -d '' file; do
            rel="${file#"${src}"/}"
            target="${dest%/}/${rel}"
            deploy_link_file "${file}" "${target}" "${force}" "${executable}"
        done < <(find "${src}" -name .git -prune -o -type f -print0)
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

# ── Hooks ─────────────────────────────────────────────────────────────────────
# hooks.list is Ansible-rendered, one line per declared hook:
#   event|run_on|timeout|argv[0]|argv[1]|...
# Only the post_deploy event exists in schema v1 (see
# docs/sync-manifest-spec.md) — this loop already filters on event so a
# future event type added to the format is silently ignored by this version
# of the script rather than mis-invoked.
#
# A hook is gated twice before it ever reaches this script: the manifest must
# declare it, and host_vars must set allow_hooks: true for that repo — when
# ungated, Ansible renders an empty hooks.list, which the [[ -s ]] guard below
# treats identically to "no hooks declared". This script has no visibility
# into *why* hooks.list is empty and does not need it.

# Bash 3.2 (macOS system bash, still current there) has a well-known bug:
# expanding "${arr[@]}" (whole-array or a slice) under `set -u` when the
# result has zero elements raises "unbound variable", fixed only in bash 4.4.
# A hook command with no extra arguments (e.g. command: ["hooks/post-deploy.sh"])
# is the common case that would trigger it via a naive
# `bash "$script" "${hook_args[@]}"`. Every array expansion below that could
# plausibly be empty is guarded with an explicit ${#arr[@]} length check
# first, rather than expanding it directly — see invoke_hook().

invoke_hook() {
    local name="$1" clone_dir="$2" reason="$3" branch="$4" timeout_s="$5"
    shift 5
    local argv=("$@")

    # argv[0] is already the fully-expanded absolute path — hooks.list.j2
    # renders it as {{ _clone_dir_absolute }}/{{ command[0] }}, the same
    # convention deploy.list.j2 uses for src, so bash never re-joins it.
    local script_path="${argv[0]}"
    local hook_args=()
    if [[ "${#argv[@]}" -gt 1 ]]; then
        hook_args=("${argv[@]:1}")
    fi

    local timeout_bin=""
    if command -v timeout &>/dev/null; then
        timeout_bin="timeout"
    elif command -v gtimeout &>/dev/null; then
        timeout_bin="gtimeout"
    else
        warn "[${name}] neither 'timeout' nor 'gtimeout' is available — running the post_deploy hook without a timeout"
    fi

    log "[${name}] running post_deploy hook: ${argv[*]} (reason: ${reason}, timeout: ${timeout_s}s)"

    # shellcheck disable=SC2094 # false positive: EXTERNAL_SYNC_LOG below is
    # assigned LOG_FILE's *path string*, not its contents — nothing in this
    # subshell reads the file. The >> at the end is the only actual write.
    (
        cd "${clone_dir}" || exit 1
        export EXTERNAL_SYNC_NAME="${name}"
        export EXTERNAL_SYNC_CLONE_DIR="${clone_dir}"
        export EXTERNAL_SYNC_BRANCH="${branch}"
        export EXTERNAL_SYNC_REASON="${reason}"
        export EXTERNAL_SYNC_OS
        export EXTERNAL_SYNC_WSL
        export EXTERNAL_SYNC_LOG="${LOG_FILE}"
        export EXTERNAL_SYNC_MANIFEST_VERSION="1"

        if [[ -n "${timeout_bin}" ]]; then
            if [[ "${#hook_args[@]}" -gt 0 ]]; then
                "${timeout_bin}" "${timeout_s}" bash "${script_path}" "${hook_args[@]}"
            else
                "${timeout_bin}" "${timeout_s}" bash "${script_path}"
            fi
        else
            if [[ "${#hook_args[@]}" -gt 0 ]]; then
                bash "${script_path}" "${hook_args[@]}"
            else
                bash "${script_path}"
            fi
        fi
    ) >>"${LOG_FILE}" 2>&1

    return $?
}

# run_on: initial fires when ${state_dir}/hook-ran does not exist yet (this
# repo's first successful hook run). changed (default) additionally fires on
# a moved HEAD or an actual deploy action this run, via the _repo_head_moved/
# _deploy_changes counters set during do_repo_sync()/deploy_repo() above —
# and also whenever the initial condition holds, so a repo's very first sync
# always gets a chance to run its hook even if nothing "changed" by the
# narrower definition. always fires unconditionally. --force-hooks overrides
# all of the above.
#
# Sets the caller's _hook_status (declared local in sync_one(), see
# do_repo_sync()'s comment on dynamic scoping) to one of:
#   none    — no hooks declared (hooks.list empty/absent, including when
#             gated off by allow_hooks)
#   skipped — a hook is declared but its run_on policy did not fire this run
#   ok      — a hook ran and exited 0
#   failed  — a hook ran and exited non-zero (including 124 = timed out)

run_post_deploy_hooks() {
    local name="$1" hooks_list="$2" clone_dir="$3" branch="$4" state_dir="$5" invocation_mode="$6" force_hooks="$7"

    [[ -s "${hooks_list}" ]] || return 0

    local hook_ran_file="${state_dir}/hook-ran"
    local hook_ran_exists="false"
    [[ -e "${hook_ran_file}" ]] && hook_ran_exists="true"

    # EXTERNAL_SYNC_REASON: forced (--force-hooks) > manual (a named
    # `external-sync <name>` invocation) > initial (first successful hook
    # run for this repo) > updated (everything else). Computed once per
    # sync_one() call, not per hook — schema v1 only has one event anyway.
    local reason
    if [[ "${force_hooks}" == "true" ]]; then
        reason="forced"
    elif [[ "${invocation_mode}" == "manual" ]]; then
        reason="manual"
    elif [[ "${hook_ran_exists}" == "false" ]]; then
        reason="initial"
    else
        reason="updated"
    fi

    local event run_on timeout_s
    while IFS='|' read -ra _fields; do
        [[ -z "${_fields[0]:-}" ]] && continue
        event="${_fields[0]}"
        [[ "${event}" != "post_deploy" ]] && continue

        if [[ "${#_fields[@]}" -lt 4 ]]; then
            err "[${name}] malformed hooks.list entry (missing command) — skipping"
            _hook_status="failed"
            continue
        fi

        run_on="${_fields[1]:-changed}"
        timeout_s="${_fields[2]:-300}"
        local argv=("${_fields[@]:3}")

        local should_run="false"
        if [[ "${force_hooks}" == "true" ]]; then
            should_run="true"
        else
            case "${run_on}" in
                initial) [[ "${hook_ran_exists}" == "false" ]] && should_run="true" ;;
                always)  should_run="true" ;;
                *)
                    # changed, or any unrecognised value — same default the
                    # manifest spec documents for a missing run_on field.
                    if [[ "${_repo_head_moved}" == "true" || "${_deploy_changes}" -gt 0 || "${hook_ran_exists}" == "false" ]]; then
                        should_run="true"
                    fi
                    ;;
            esac
        fi

        if [[ "${should_run}" != "true" ]]; then
            log "[${name}] post_deploy hook not due this run (run_on: ${run_on})"
            _hook_status="skipped"
            continue
        fi

        invoke_hook "${name}" "${clone_dir}" "${reason}" "${branch}" "${timeout_s}" "${argv[@]}"
        local rc=$?

        local now_iso
        now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        if [[ "${rc}" -eq 0 ]]; then
            echo "${now_iso} ok 0 ${event}" > "${state_dir}/last-hook-status"
            touch "${hook_ran_file}"
            _hook_status="ok"
            log "[${name}] post_deploy hook succeeded"
        else
            echo "${now_iso} failed ${rc} ${event}" > "${state_dir}/last-hook-status"
            err "[${name}] post_deploy hook failed (exit ${rc}$([[ "${rc}" -eq 124 ]] && echo ", timed out"))"
            _hook_status="failed"
        fi
    done < "${hooks_list}"
}

# ── Per-repo sync ─────────────────────────────────────────────────────────────

sync_one() {
    local name="$1" invocation_mode="$2" force_hooks="$3"
    local conf="${CONFIG_ROOT}/${name}/sync.conf"
    local deploy_list="${CONFIG_ROOT}/${name}/deploy.list"
    local hooks_list="${CONFIG_ROOT}/${name}/hooks.list"
    local state_dir="${STATE_ROOT}/${name}"
    local lock_file="${state_dir}/sync.lock"

    # Per-repo result state, reset here (not script-global) so one process
    # syncing many repos in a loop never lets one repo's outcome leak into
    # the next — same reasoning as the REPO_URL/CLONE_DIR/GIT_BRANCH/DEV_MODE
    # reset below. do_repo_sync()/deploy_copy_file()/deploy_link_file()/
    # run_post_deploy_hooks() mutate these via bash's dynamic scoping without
    # re-declaring them.
    local _repo_head_moved="false"
    local _deploy_changes=0
    local _hook_status="none"

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
        check_manifest_drift "${name}" "${CLONE_DIR}" "${state_dir}"
        deploy_repo "${name}" "${deploy_list}"
        run_post_deploy_hooks "${name}" "${hooks_list}" "${CLONE_DIR}" "${GIT_BRANCH}" "${state_dir}" "${invocation_mode}" "${force_hooks}"
    else
        log "[${name}] skipping deploy — clone not ready"
    fi

    log "[${name}] sync complete"

    # DF-5: one machine-readable line, independent of the human log() lines
    # above (which can be reworded freely without breaking anything that
    # parses this). repo.yml's initial-deploy task greps this line for
    # changed_when instead of matching log prose.
    echo "EXTERNAL_SYNC_RESULT name=${name} head_moved=${_repo_head_moved} deploy_changes=${_deploy_changes} hook=${_hook_status}"
}

# ── Entry point ───────────────────────────────────────────────────────────────
# Each repo is synced in its own subshell with set -e enabled, so an
# unexpected failure in one repo's git/deploy flow cannot abort the others —
# but run_one still reports failure via its own return code, so callers
# (main's loop, systemd/launchd, Ansible's initial-deploy command) can tell
# something went wrong instead of every invocation silently exiting 0.

run_one() {
    local name="$1" invocation_mode="$2" force_hooks="$3"
    if ! ( set -e; sync_one "${name}" "${invocation_mode}" "${force_hooks}" ); then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] sync for '${name}' failed unexpectedly — see its log under ${STATE_ROOT}/${name}/logs/" >&2
        return 1
    fi
}

# ── Status ────────────────────────────────────────────────────────────────────
# Pure read of on-disk state — no fetch/pull, no lock acquired, safe to run
# concurrently with an in-progress sync. `git hash-object`/`rev-parse` below
# are local, read-only plumbing (not network operations) and are needed to
# report manifest drift the same way check_manifest_drift() detects it during
# a real sync. Modelled on scripts/switch-branch.sh's `--status` register —
# same indent, same rule character, same "Field: value" layout.

cmd_status() {
    local dir name found_any="false" any_issue="false"

    echo ""
    echo "  External sync status"
    echo "  ────────────────────────────────────"

    for dir in "${CONFIG_ROOT}"/*/; do
        [[ -d "${dir}" ]] || continue
        name=$(basename "${dir}")
        found_any="true"

        local conf="${CONFIG_ROOT}/${name}/sync.conf"
        local deploy_list="${CONFIG_ROOT}/${name}/deploy.list"
        local state_dir="${STATE_ROOT}/${name}"

        local branch="unknown" clone_dir="unknown" dev_mode="unknown"
        if [[ -r "${conf}" ]]; then
            local GIT_BRANCH="" CLONE_DIR="" DEV_MODE=""
            # shellcheck source=/dev/null
            source "${conf}"
            branch="${GIT_BRANCH:-unknown}"
            clone_dir="${CLONE_DIR:-unknown}"
            dev_mode="${DEV_MODE:-false}"
        fi

        local clone_note=""
        if [[ "${clone_dir}" != "unknown" ]]; then
            if [[ ! -d "${clone_dir}" ]]; then
                clone_note=" (missing)"
            elif ! is_git_repo "${clone_dir}"; then
                clone_note=" (not a git repo)"
            fi
        fi

        local last_sync="never"
        [[ -f "${state_dir}/last-sync" ]] && last_sync=$(cat "${state_dir}/last-sync")

        local deploy_summary="clone-only"
        if [[ -s "${deploy_list}" ]]; then
            local n
            n=$(grep -c . "${deploy_list}" 2>/dev/null || echo 0)
            deploy_summary="${n} entry"
            [[ "${n}" != "1" ]] && deploy_summary="${n} entries"
        fi

        local manifest_state="ok"
        if [[ "${clone_dir}" != "unknown" && -e "${clone_dir}/.dotfiles-sync.yml" && -r "${state_dir}/manifest-hash" ]]; then
            local recorded current
            recorded=$(cat "${state_dir}/manifest-hash" 2>/dev/null || echo "")
            current=$(git -C "${clone_dir}" hash-object .dotfiles-sync.yml 2>/dev/null || echo "unknown")
            if [[ -n "${recorded}" && "${current}" != "${recorded}" ]]; then
                manifest_state="**drift**"
                any_issue="true"
            fi
        fi

        local hook_state="none"
        if [[ -r "${state_dir}/last-hook-status" ]]; then
            local hook_line h_status h_rc
            hook_line=$(cat "${state_dir}/last-hook-status")
            h_status=$(awk '{print $2}' <<<"${hook_line}")
            h_rc=$(awk '{print $3}' <<<"${hook_line}")
            if [[ "${h_status}" == "ok" ]]; then
                hook_state="ok"
            elif [[ "${h_status}" == "failed" ]]; then
                hook_state="failed (${h_rc})"
                any_issue="true"
            fi
        fi

        echo ""
        echo "  ${name}"
        printf "    %-11s %s\n"  "Branch:"    "${branch}"
        printf "    %-11s %s%s\n" "Clone:"    "${clone_dir}" "${clone_note}"
        printf "    %-11s %s\n"  "Dev mode:"  "${dev_mode}"
        printf "    %-11s %s\n"  "Last sync:" "${last_sync}"
        printf "    %-11s %s\n"  "Deploy:"    "${deploy_summary}"
        printf "    %-11s %s\n"  "Manifest:"  "${manifest_state}"
        printf "    %-11s %s\n"  "Hook:"      "${hook_state}"
    done

    if [[ "${found_any}" == "false" ]]; then
        echo ""
        echo "  No repos registered yet — see docs/external-sync.md#adding-a-repo."
    fi

    echo ""

    if [[ "${any_issue}" == "true" ]]; then
        echo "  *** one or more repos need attention — see Manifest/Hook above ***"
        echo "  Manifest drift: ansible-playbook site.yml --tags sync-external"
        echo "  Failed hook:    fix the hook, then external-sync <name> --force-hooks"
        echo ""
        return 1
    fi

    return 0
}

usage() {
    cat << 'EOF'
Usage:
  external-sync                        Sync every registered repo.
  external-sync <name>                 Sync a single repo by name.
  external-sync <name> --force-hooks   Sync one repo, running its
                                        post_deploy hook regardless of its
                                        run_on policy.
  external-sync --status               Show per-repo status. No git
                                        fetch/pull, no lock taken.
  external-sync --help                 Show this usage.
EOF
}

main() {
    local repo_name="" force_hooks="false" want_status="false" want_help="false"

    local arg
    for arg in "$@"; do
        case "${arg}" in
            --status)      want_status="true" ;;
            --help|-h)     want_help="true" ;;
            --force-hooks) force_hooks="true" ;;
            --*)
                echo "Unknown option: ${arg}" >&2
                usage >&2
                exit 2
                ;;
            *)
                if [[ -n "${repo_name}" ]]; then
                    echo "Unexpected extra argument: ${arg}" >&2
                    usage >&2
                    exit 2
                fi
                repo_name="${arg}"
                ;;
        esac
    done

    if [[ "${want_help}" == "true" ]]; then
        usage
        exit 0
    fi

    if [[ "${want_status}" == "true" ]]; then
        cmd_status
        exit $?
    fi

    if [[ "${force_hooks}" == "true" && -z "${repo_name}" ]]; then
        echo "--force-hooks requires a repo name: external-sync <name> --force-hooks" >&2
        exit 2
    fi

    mkdir -p "${CONFIG_ROOT}" "${STATE_ROOT}"

    local failures=0

    if [[ -n "${repo_name}" ]]; then
        run_one "${repo_name}" "manual" "${force_hooks}" || failures=1
        exit "${failures}"
    fi

    local dir name
    for dir in "${CONFIG_ROOT}"/*/; do
        [[ -d "${dir}" ]] || continue
        name=$(basename "${dir}")
        run_one "${name}" "all" "false" || failures=1
    done

    exit "${failures}"
}

main "$@"
